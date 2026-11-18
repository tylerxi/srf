import Testing
@testable import ClipboardCore

@Suite struct SessionGateTests {
    @Test func displayWakeDoesNotUnlockSession() {
        var gate = SessionGate()
        gate.set(.locked, active: true)
        gate.set(.displaySleeping, active: true)
        gate.set(.displaySleeping, active: false)
        #expect(gate.suspended)
        gate.set(.locked, active: false)
        #expect(!gate.suspended)
    }
    @Test func overlappingLifecycleEventsStaySuspended() {
        var gate = SessionGate()
        gate.set(.sleeping, active: true)
        gate.set(.inactiveSession, active: true)
        gate.set(.sleeping, active: false)
        #expect(gate.suspended)
        gate.set(.inactiveSession, active: false)
        #expect(!gate.suspended)
        gate.set(.shuttingDown, active: true)
        gate.set(.sleeping, active: false)
        gate.set(.locked, active: false)
        #expect(gate.suspended)
    }
}
