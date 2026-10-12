import Foundation

enum SessionOrigin: String, Codable, Sendable {
    case user
    case lease
}

/// An active keep-awake session. `endsAt` is the only thing that keeps sleep
/// disabled; everything else is bookkeeping.
struct Session: Codable, Equatable, Sendable {
    var startedAt: Date
    var endsAt: Date
    /// Every extension applied, in order, in seconds.
    var extensions: [TimeInterval]
    /// Who started the session. Only a `lease` session is ended by
    /// `Insomnia lease-end`.
    var origin: SessionOrigin
    /// The latest time agent leases may push `endsAt` to, fixed at the first
    /// lease (`SessionMath.leaseCap`). nil until a lease touches the session.
    var leaseCapAt: Date?

    init(startedAt: Date, endsAt: Date, extensions: [TimeInterval] = [], origin: SessionOrigin = .user, leaseCapAt: Date? = nil) {
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.extensions = extensions
        self.origin = origin
        self.leaseCapAt = leaseCapAt
    }

    /// `origin` and `leaseCapAt` are newer than the other keys. A file from
    /// an older build has neither and reads as a user session; a value of
    /// the wrong type reads the same way, so it never makes lease-end end
    /// a session. backstop.sh and uninstall.sh ignore both keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
        extensions = try c.decode([TimeInterval].self, forKey: .extensions)
        origin = (try? c.decodeIfPresent(SessionOrigin.self, forKey: .origin)) ?? .user
        leaseCapAt = (try? c.decodeIfPresent(Date.self, forKey: .leaseCapAt)) ?? nil
    }

    /// Seconds left until `endsAt`, never negative.
    func remaining(at now: Date) -> TimeInterval {
        SessionMath.remaining(until: endsAt, at: now)
    }

    /// True once `now` reaches `endsAt`.
    func isExpired(at now: Date) -> Bool {
        SessionMath.isExpired(endsAt: endsAt, at: now)
    }

    /// Shape of the menu bar countdown, derived from the session's span so it
    /// survives a relaunch without another persisted field. Because
    /// `remaining` never exceeds this span, the shape always has room for the
    /// value. An extension widens the span and can promote the shape, which
    /// is a one-off change at a user action, never a per-tick one.
    var countdownShape: CountdownShape {
        CountdownShape(initialDuration: endsAt.timeIntervalSince(startedAt))
    }
}
