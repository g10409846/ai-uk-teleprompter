import Foundation

/// Monitors system thermal state and warns when levels escalate.
/// On iOS/macOS with ProcessInfo.thermalState, this is direct.
public final class ThermalMonitor: @unchecked Sendable {
    @Published public private(set) var currentLevel: ThermalLevel = .nominal
    @Published public private(set) var history: [ThermalLevel] = []
    @Published public private(set) var isSafeToRecord: Bool = true

    private var pollingTimer: Timer?

    public init(pollInterval: TimeInterval = 2.0) {
        // Pull initially
        updateLevel()

        // Then poll
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.updateLevel()
        }
    }

    deinit {
        pollingTimer?.invalidate()
    }

    private func updateLevel() {
        let newLevel = Self.readSystemLevel()
        history.append(newLevel)
        if history.count > 300 { history.removeFirst() } // keep ~10 min at 2s

        currentLevel = newLevel
        isSafeToRecord = newLevel < .serious
    }

    public static func readSystemLevel() -> ThermalLevel {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    public func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
}
