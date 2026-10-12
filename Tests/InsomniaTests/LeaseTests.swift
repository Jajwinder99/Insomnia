import XCTest
@testable import Insomnia

final class LeaseMathTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 3600

    func testNewLeaseSessionRecordsOriginAndCap() {
        let s = SessionMath.newLeaseSession(now: t0, lease: 600, maxLeaseHours: 4)
        XCTAssertEqual(s.origin, .lease)
        XCTAssertEqual(s.endsAt, t0.addingTimeInterval(600))
        XCTAssertEqual(s.leaseCapAt, t0.addingTimeInterval(4 * hour))
    }

    func testRepeatLeasesDoNotStack() {
        var s = SessionMath.newLeaseSession(now: t0, lease: 600, maxLeaseHours: 4)
        // Same lease again 30 s later: now + 600 is 30 s past the end, under the debounce.
        let again = SessionMath.leased(s, lease: 600, now: t0.addingTimeInterval(30), maxLeaseHours: 4)
        XCTAssertEqual(again.session, s)
        // 100 s later it moves to now + 600, not to end + 600.
        s = SessionMath.leased(s, lease: 600, now: t0.addingTimeInterval(100), maxLeaseHours: 4).session
        XCTAssertEqual(s.endsAt, t0.addingTimeInterval(700))
    }

    func testDebounceSkipsAMoveUnderSixtySeconds() {
        let s = SessionMath.newLeaseSession(now: t0, lease: 600, maxLeaseHours: 4)
        let r = SessionMath.leased(s, lease: 600, now: t0.addingTimeInterval(59), maxLeaseHours: 4)
        XCTAssertEqual(r.session.endsAt, s.endsAt)
        let moved = SessionMath.leased(s, lease: 600, now: t0.addingTimeInterval(60), maxLeaseHours: 4)
        XCTAssertEqual(moved.session.endsAt, t0.addingTimeInterval(660))
    }

    func testCapHoldsAndIsReported() {
        var s = SessionMath.newLeaseSession(now: t0, lease: 3600, maxLeaseHours: 1)
        let late = t0.addingTimeInterval(1800)
        let r = SessionMath.leased(s, lease: 3600, now: late, maxLeaseHours: 1)
        XCTAssertEqual(r.session.endsAt, t0.addingTimeInterval(hour), "capped at first lease + 1 h")
        XCTAssertTrue(r.capped)
        s = r.session
        let again = SessionMath.leased(s, lease: 3600, now: late.addingTimeInterval(600), maxLeaseHours: 1)
        XCTAssertEqual(again.session.endsAt, s.endsAt)
    }

    func testLeaseNeverShortensAHumanEnd() {
        let human = Session(startedAt: t0, endsAt: t0.addingTimeInterval(8 * hour))
        let r = SessionMath.leased(human, lease: 600, now: t0.addingTimeInterval(60), maxLeaseHours: 4)
        XCTAssertEqual(r.session.endsAt, human.endsAt)
        XCTAssertFalse(r.capped)
        XCTAssertEqual(r.session.origin, .user)
        XCTAssertEqual(r.session.leaseCapAt, t0.addingTimeInterval(8 * hour), "the first lease fixes the cap at the human end")
    }

    func testCapOnAHumanSessionIsTheLaterOfHoursAndHumanEnd() {
        XCTAssertEqual(
            SessionMath.leaseCap(firstLeaseAt: t0, maxLeaseHours: 4, humanEndsAt: t0.addingTimeInterval(hour)),
            t0.addingTimeInterval(4 * hour)
        )
        XCTAssertEqual(
            SessionMath.leaseCap(firstLeaseAt: t0, maxLeaseHours: 4, humanEndsAt: t0.addingTimeInterval(6 * hour)),
            t0.addingTimeInterval(6 * hour)
        )
        // A short human session: a lease extends it up to the cap, no further.
        let human = Session(startedAt: t0, endsAt: t0.addingTimeInterval(600))
        let r = SessionMath.leased(human, lease: 3600, now: t0.addingTimeInterval(300), maxLeaseHours: 4)
        XCTAssertEqual(r.session.endsAt, t0.addingTimeInterval(300 + 3600))
    }

    func testSessionFromAnOlderBuildReadsAsUserOrigin() throws {
        let json = #"{"startedAt":"2027-01-15T08:00:00Z","endsAt":"2027-01-15T09:00:00Z","extensions":[]}"#
        let s = try Store.makeDecoder().decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(s.origin, .user)
        XCTAssertNil(s.leaseCapAt)
        let bad = #"{"startedAt":"2027-01-15T08:00:00Z","endsAt":"2027-01-15T09:00:00Z","extensions":[],"origin":3,"leaseCapAt":"x"}"#
        let b = try Store.makeDecoder().decode(Session.self, from: Data(bad.utf8))
        XCTAssertEqual(b.origin, .user)
        XCTAssertNil(b.leaseCapAt)
    }

    func testConfigDefaultsAndOlderFiles() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertFalse(c.allowExternalControl)
        XCTAssertEqual(c.maxLeaseHours, 4)
        let on = try JSONDecoder().decode(Config.self, from: Data(#"{"allowExternalControl":true,"maxLeaseHours":2}"#.utf8))
        XCTAssertTrue(on.allowExternalControl)
        XCTAssertEqual(on.maxLeaseHours, 2)
    }
}

final class LeaseRequestTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let me: uid_t = 501

    func check(_ r: LeaseRequest, allow: Bool = true, owner: uid_t = 501, mode: mode_t = 0o600) -> Result<LeaseAction, LeaseRefusal> {
        r.action(now: now, allowExternalControl: allow, owner: owner, mode: mode, currentUser: me)
    }

    func testValidLeaseAndEnd() {
        XCTAssertEqual(check(LeaseRequest(mode: "lease", minutes: 10, createdAt: now)), .success(.lease(minutes: 10)))
        XCTAssertEqual(check(LeaseRequest(mode: "lease-end", minutes: nil, createdAt: now.addingTimeInterval(-119))), .success(.end))
    }

    func testRefusals() {
        let ok = LeaseRequest(mode: "lease", minutes: 10, createdAt: now)
        XCTAssertEqual(check(ok, allow: false), .failure(.controlOff))
        XCTAssertEqual(check(ok, owner: 0), .failure(.wrongOwner))
        XCTAssertEqual(check(ok, mode: 0o644), .failure(.notOwnerOnly))
        XCTAssertEqual(check(ok, mode: 0o660), .failure(.notOwnerOnly))
        XCTAssertEqual(check(LeaseRequest(mode: "lease", minutes: 10, createdAt: now.addingTimeInterval(-120))), .failure(.stale))
        XCTAssertEqual(check(LeaseRequest(mode: "lease", minutes: 10, createdAt: now.addingTimeInterval(600))), .failure(.stale))
        XCTAssertEqual(check(LeaseRequest(mode: "extend", minutes: 10, createdAt: now)), .failure(.unknownMode))
        for minutes in [0, -1, 61, 600] {
            XCTAssertEqual(check(LeaseRequest(mode: "lease", minutes: minutes, createdAt: now)), .failure(.minutesOutOfRange), "\(minutes)")
        }
        XCTAssertEqual(check(LeaseRequest(mode: "lease", minutes: nil, createdAt: now)), .failure(.minutesOutOfRange))
    }

    func testMinutesArgument() {
        XCTAssertEqual(LeaseCommand.minutes("1"), 1)
        XCTAssertEqual(LeaseCommand.minutes("60"), 60)
        for bad in ["0", "61", "100", "", "-5", "1.5", "ten", "٣"] { XCTAssertNil(LeaseCommand.minutes(bad), bad) }
    }

    func testCommandWritesAnOwnerOnlyFileAndPostsOnce() throws {
        let home = TempHome()
        defer { home.destroy() }
        var posts = 0
        let out = try XCTUnwrap(LeaseCommand.run(["lease", "15"], paths: home.paths, now: now, isAppRunning: { true }, post: { posts += 1 }))
        XCTAssertEqual(out.status, 0)
        XCTAssertEqual(posts, 1)
        var info = stat()
        XCTAssertEqual(stat(home.paths.leaseRequestFile.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        let taken = try XCTUnwrap(LeaseInbox.take(paths: home.paths))
        XCTAssertEqual(taken.request, LeaseRequest(mode: "lease", minutes: 15, createdAt: now))
        XCTAssertEqual(taken.owner, getuid())
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.leaseRequestFile.path), "read and deleted")
        XCTAssertNil(LeaseInbox.take(paths: home.paths))
    }

    func testCommandWithoutTheAppWritesNothingAndFails() {
        let home = TempHome()
        defer { home.destroy() }
        var posts = 0
        let out = LeaseCommand.run(["lease-end"], paths: home.paths, now: now, isAppRunning: { false }, post: { posts += 1 })
        XCTAssertEqual(out?.status, 1)
        XCTAssertEqual(posts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.leaseRequestFile.path))
    }

    func testUsageAndOtherModes() {
        let home = TempHome()
        defer { home.destroy() }
        func run(_ a: [String]) -> ResumeFrozenCommand.Output? {
            LeaseCommand.run(a, paths: home.paths, now: now, isAppRunning: { true }, post: {})
        }
        XCTAssertNil(run([]))
        XCTAssertNil(run(["--resume-frozen", "5"]))
        for bad in [["lease"], ["lease", "0"], ["lease", "61"], ["lease", "5", "x"], ["lease-end", "5"]] {
            XCTAssertEqual(run(bad)?.status, LeaseCommand.usageStatus, "\(bad)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.leaseRequestFile.path))
    }

    func testInboxDeletesAFileItCannotUse() throws {
        let home = TempHome()
        defer { home.destroy() }
        try home.paths.createDirectories()
        try Data("not json".utf8).write(to: home.paths.leaseRequestFile)
        let taken = try XCTUnwrap(LeaseInbox.take(paths: home.paths))
        XCTAssertNil(taken.request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.leaseRequestFile.path))
    }

    func testInboxRefusesASymlink() throws {
        let home = TempHome()
        defer { home.destroy() }
        try home.paths.createDirectories()
        let target = home.root.appendingPathComponent("elsewhere.json")
        try Data(#"{"mode":"lease-end","createdAt":"2027-01-15T08:00:00Z"}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: home.paths.leaseRequestFile, withDestinationURL: target)
        let taken = try XCTUnwrap(LeaseInbox.take(paths: home.paths))
        XCTAssertNil(taken.request)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "the target is not touched")
    }
}

@MainActor
final class LeaseManagerTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    /// Writes a request the way the CLI does, then lets the manager take it.
    func send(_ m: SessionManager, _ request: LeaseRequest) async throws {
        try h.store.write(request, to: h.home.paths.leaseRequestFile)
        await m.processLeaseRequest()
    }

    func lease(_ minutes: Int) -> LeaseRequest { LeaseRequest(mode: "lease", minutes: minutes, createdAt: h.clock.now) }
    var leaseEnd: LeaseRequest { LeaseRequest(mode: "lease-end", minutes: nil, createdAt: h.clock.now) }

    func enable(_ m: SessionManager) { m.config.allowExternalControl = true }

    func testFirstLeaseStartsALeaseSession() async throws {
        let m = h.makeManager()
        enable(m)
        try await send(m, lease(10))

        let s = try XCTUnwrap(m.session)
        XCTAssertEqual(s.origin, .lease)
        XCTAssertEqual(s.endsAt, h.clock.now.addingTimeInterval(600))
        XCTAssertEqual(try h.store.loadSession(), s, "origin is on disk")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertEqual(h.backstop.arms, 1)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
    }

    func testControlOffDoesNothingAndDeletesTheFile() async throws {
        let m = h.makeManager()
        try await send(m, lease(10))
        XCTAssertNil(m.session)
        XCTAssertEqual(h.guardFake.calls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.home.paths.leaseRequestFile.path))
    }

    func testStaleRequestIsIgnored() async throws {
        let m = h.makeManager()
        enable(m)
        try await send(m, LeaseRequest(mode: "lease", minutes: 10, createdAt: h.clock.now.addingTimeInterval(-300)))
        XCTAssertNil(m.session)
    }

    func testLooseFileModeIsIgnored() async throws {
        let m = h.makeManager()
        enable(m)
        try h.store.write(lease(10), to: h.home.paths.leaseRequestFile)
        chmod(h.home.paths.leaseRequestFile.path, 0o644)
        await m.processLeaseRequest()
        XCTAssertNil(m.session)
    }

    func testLeaseExtendsWithoutArmingAgainAndNeverShortens() async throws {
        let m = h.makeManager()
        enable(m)
        try await send(m, lease(10))
        let first = try XCTUnwrap(m.session)
        h.clock.advance(120)
        try await send(m, lease(10))
        let second = try XCTUnwrap(m.session)
        XCTAssertEqual(second.endsAt, h.clock.now.addingTimeInterval(600))
        XCTAssertEqual(second.startedAt, first.startedAt)
        XCTAssertEqual(h.backstop.arms, 1, "a lease extend does not arm again for this session")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        // A shorter lease right after changes nothing.
        h.clock.advance(10)
        try await send(m, lease(1))
        XCTAssertEqual(m.session?.endsAt, second.endsAt)
        XCTAssertEqual(try h.store.loadSession(), m.session)
    }

    func testDebouncedLeaseWritesNothing() async throws {
        let m = h.makeManager()
        enable(m)
        try await send(m, lease(10))
        let first = try XCTUnwrap(m.session)
        try FileManager.default.removeItem(at: h.home.paths.sessionFile)
        h.clock.advance(20)
        try await send(m, lease(10))
        XCTAssertEqual(m.session, first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.home.paths.sessionFile.path), "no write inside the debounce")
    }

    func testCapStopsLeasesAndNotifiesOnce() async throws {
        let m = h.makeManager()
        enable(m)
        m.config.maxLeaseHours = 1
        try await send(m, lease(60))
        let start = h.clock.now
        h.clock.advance(1800)
        try await send(m, lease(60))
        XCTAssertEqual(m.session?.endsAt, start.addingTimeInterval(3600))
        h.clock.advance(600)
        try await send(m, lease(60))
        h.clock.advance(600)
        try await send(m, lease(60))
        XCTAssertEqual(m.session?.endsAt, start.addingTimeInterval(3600), "the cap holds")
        XCTAssertEqual(h.notifier.posts.filter { $0.title == SessionManager.leaseCapTitle }.count, 1)
    }

    func testLeaseOnAHumanSessionNeverShortensIt() async throws {
        let m = h.makeManager()
        enable(m)
        await m.start(duration: 8 * 3600)
        let human = try XCTUnwrap(m.session)
        h.clock.advance(60)
        try await send(m, lease(10))
        XCTAssertEqual(m.session?.endsAt, human.endsAt)
        XCTAssertEqual(m.session?.origin, .user)
    }

    func testLeaseEndEndsOnlyLeaseSessions() async throws {
        let m = h.makeManager()
        enable(m)
        await m.start(duration: 3600)
        try await send(m, leaseEnd)
        XCTAssertNotNil(m.session, "a session you started is left alone")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])

        _ = await m.end(reason: .user)
        try await send(m, lease(10))
        XCTAssertEqual(m.session?.origin, .lease)
        try await send(m, leaseEnd)
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.guardFake.calls.last, "disablesleep 0")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    func testLeaseEndWithNoSessionDoesNothing() async throws {
        let m = h.makeManager()
        enable(m)
        try await send(m, leaseEnd)
        XCTAssertNil(m.session)
        XCTAssertEqual(h.guardFake.calls, [])
    }

    func testExtendingALeaseSessionByHandTakesItOver() async throws {
        let m = h.makeManager()
        enable(m)
        try await send(m, lease(10))
        await m.extend(by: 3600)
        XCTAssertEqual(m.session?.origin, .user)
        try await send(m, leaseEnd)
        XCTAssertNotNil(m.session)
    }

    func testLeaseIsRefusedWhileQuitting() async throws {
        let m = h.makeManager()
        enable(m)
        _ = await m.end(reason: .quit)
        try await send(m, lease(10))
        XCTAssertNil(m.session)
    }
}
