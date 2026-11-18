public struct SessionGate: Sendable {
    public enum Reason: Hashable, Sendable { case sleeping, displaySleeping, inactiveSession, locked, shuttingDown }
    private var reasons: Set<Reason> = []
    public init() {}
    public var suspended: Bool { !reasons.isEmpty }
    public mutating func set(_ reason: Reason, active: Bool) {
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
    }
}
