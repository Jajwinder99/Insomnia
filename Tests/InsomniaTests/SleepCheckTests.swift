import XCTest
@testable import Insomnia

/// The 60 s SleepDisabled check during a session (`checkSleepDisabled`).
@MainActor
final class SleepCheckTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    private var log: String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }

    func testBitStillSetChangesNothing() async {
        let m = h.makeManager()
        await m.start(duration: 3600)
        await m.checkSleepDisabled()
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "pmset -g"])
        XCTAssertNotNil(m.session)
    }

    func testReadsZeroOnceThenOneReappliesOnceAndKeepsTheSession() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.guardFake.sleepDisabled = false

        await m.checkSleepDisabled()
        await m.checkSleepDisabled()

        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "pmset -g", "disablesleep 1", "pmset -g"])
        XCTAssertTrue(h.guardFake.unlockedPrivilegedCalls.isEmpty, "the read and reapply ran outside the recovery lock")
        XCTAssertNotNil(m.session)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertTrue(log.contains("disablesleep 1 reapplied"), log)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
    }

    func testReadsZeroTwiceEndsTheSessionWithTheNewReason() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.guardFake.sleepDisabled = false
        await m.checkSleepDisabled()
        h.guardFake.sleepDisabled = false

        await m.checkSleepDisabled()

        XCTAssertNil(m.session)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(h.guardFake.calls.last, "disablesleep 0")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        let body = try XCTUnwrap(h.notifier.posts.last?.body)
        XCTAssertTrue(body.hasPrefix("macOS kept turning sleep back on"), body)
    }

    func testFailedReapplyEndsTheSession() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.guardFake.sleepDisabled = false
        h.guardFake.throwOn = ["disablesleep 1"]

        await m.checkSleepDisabled()

        XCTAssertNil(m.session)
        XCTAssertEqual(h.guardFake.calls.suffix(2), ["disablesleep 1", "disablesleep 0"])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    func testNoCheckRunsWhileAnEndIsPending() async {
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.guardFake.sleepDisabled = false
        // A held lock keeps the end pending and the session active.
        let held = try? RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire()
        _ = await m.end(reason: .user)
        held?.release()
        XCTAssertEqual(m.pendingEnd, .user)
        let before = h.guardFake.calls

        await m.checkSleepDisabled()

        XCTAssertEqual(h.guardFake.calls, before)
    }
}
