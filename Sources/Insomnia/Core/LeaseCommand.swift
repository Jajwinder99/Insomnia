import AppKit
import Darwin
import Foundation

/// `Insomnia lease <minutes>` and `Insomnia lease-end`
///
/// One-shot modes for programs that know when an agent is working, such as
/// Claude Code hooks. They never open UI or a second app instance, and never
/// touch the journal. Each writes one request file (`Paths.leaseRequestFile`,
/// owner-only, atomic) and posts a distributed notification with no payload
/// as a hint to look at it. The running app does the rest
/// (`SessionManager.processLeaseRequest`), and only when the config sets
/// `allowExternalControl`. If the app is not running, nothing is written.
///
/// `<minutes>` is a whole number from 1 to 60. Exit 0 when the request was
/// handed over, 1 when the app is not running or the file could not be
/// written, 64 for a usage error.
enum LeaseCommand {
    static let leaseWord = "lease"
    static let endWord = "lease-end"
    static let notification = Notification.Name("\(Paths.bundleIdentifier).lease-request")
    static let usageStatus = ResumeFrozenCommand.usageStatus
    static let minutesRange = 1...60
    /// A request older than this is stale and ignored.
    static let maxAge: TimeInterval = 120

    /// nil when `arguments` (the command line without the executable) do
    /// not ask for this mode.
    static func run(
        _ arguments: [String],
        paths: Paths = .fromEnvironment(),
        now: Date = Date(),
        isAppRunning: () -> Bool = LeaseCommand.appIsRunning,
        post: () -> Void = { LeaseCommand.postHint() }
    ) -> ResumeFrozenCommand.Output? {
        guard let word = arguments.first, word == leaseWord || word == endWord else { return nil }
        let request: LeaseRequest
        if word == leaseWord {
            guard arguments.count == 2, let minutes = Self.minutes(arguments[1]) else { return usage() }
            request = LeaseRequest(mode: leaseWord, minutes: minutes, createdAt: now)
        } else {
            guard arguments.count == 1 else { return usage() }
            request = LeaseRequest(mode: endWord, minutes: nil, createdAt: now)
        }
        guard isAppRunning() else {
            return Output(lines: ["Insomnia is not running"], status: 1)
        }
        do {
            try Store(paths: paths).write(request, to: paths.leaseRequestFile)
        } catch {
            return Output(lines: ["could not write the request: \(error.localizedDescription)"], status: 1)
        }
        post()
        return Output(lines: [], status: 0)
    }

    private typealias Output = ResumeFrozenCommand.Output

    private static func usage() -> Output {
        FileHandle.standardError.write(Data("usage: Insomnia \(leaseWord) <minutes \(minutesRange.lowerBound)-\(minutesRange.upperBound)> | Insomnia \(endWord)\n".utf8))
        return Output(lines: ["usage"], status: usageStatus)
    }

    /// One or two ASCII digits in `minutesRange`; nil otherwise.
    static func minutes(_ text: String) -> Int? {
        guard (1...2).contains(text.utf8.count),
              text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let value = Int(text), minutesRange.contains(value)
        else { return nil }
        return value
    }

    static func appIsRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleIdentifier)
            .contains { $0.processIdentifier != getpid() }
    }

    static func postHint() {
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}

/// What the CLI writes and the app reads. Nothing in it is trusted: the app
/// checks every field (`action`).
struct LeaseRequest: Codable, Equatable, Sendable {
    var mode: String
    var minutes: Int?
    var createdAt: Date
}

enum LeaseAction: Equatable, Sendable {
    case lease(minutes: Int)
    case end
}

enum LeaseRefusal: Error, Equatable, Sendable {
    case controlOff
    case notOwnerOnly
    case wrongOwner
    case stale
    case unknownMode
    case minutesOutOfRange
}

extension LeaseRequest {
    /// The action this request asks for, or why it is refused. `owner` and
    /// `mode` are the request file's, as read from the open descriptor.
    func action(
        now: Date,
        allowExternalControl: Bool,
        owner: uid_t,
        mode fileMode: mode_t,
        currentUser: uid_t = getuid()
    ) -> Result<LeaseAction, LeaseRefusal> {
        guard allowExternalControl else { return .failure(.controlOff) }
        guard owner == currentUser else { return .failure(.wrongOwner) }
        guard fileMode & 0o077 == 0 else { return .failure(.notOwnerOnly) }
        let age = now.timeIntervalSince(createdAt)
        // A few seconds of clock skew is allowed; a request from the future is not.
        guard age >= -5, age < LeaseCommand.maxAge else { return .failure(.stale) }
        switch self.mode {
        case LeaseCommand.leaseWord:
            guard let minutes, LeaseCommand.minutesRange.contains(minutes) else { return .failure(.minutesOutOfRange) }
            return .success(.lease(minutes: minutes))
        case LeaseCommand.endWord:
            return .success(.end)
        default:
            return .failure(.unknownMode)
        }
    }
}

/// The app's side of the request file.
enum LeaseInbox {
    struct Taken {
        let request: LeaseRequest?
        let owner: uid_t
        let mode: mode_t
        /// Why `request` is nil, when it is.
        let problem: String?
    }

    /// Reads the request file if there is one and deletes it, whatever it
    /// held, so a bad file is not read again. Only a regular file is opened
    /// (no FIFO wait, no symlink), and its owner and mode come from the
    /// open descriptor, not from a second look at the path. nil when there
    /// is no file.
    static func take(paths: Paths) -> Taken? {
        let path = paths.leaseRequestFile.path
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        defer { unlink(path) }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            return Taken(request: nil, owner: info.st_uid, mode: info.st_mode, problem: "could not open it: \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else {
            return Taken(request: nil, owner: info.st_uid, mode: info.st_mode, problem: "it is not a regular file")
        }
        let data = (try? handle.read(upToCount: 4096)) ?? nil
        guard let data, let request = try? Store.makeDecoder().decode(LeaseRequest.self, from: data) else {
            return Taken(request: nil, owner: opened.st_uid, mode: opened.st_mode, problem: "it is not a lease request")
        }
        return Taken(request: request, owner: opened.st_uid, mode: opened.st_mode, problem: nil)
    }
}
