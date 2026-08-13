import Foundation

/// Simple energy-based VAD that runs on raw audio samples.
/// Phase 0: this is the minimum-working fallback when speech recognition is not available.
public final class VADEngine: @unchecked Sendable {

    private let threshold: Float
    private let holdDuration: TimeInterval
    private let resumeDuration: TimeInterval
    private var lastSpeakingTime: Date?
    private var lastSilenceStart: Date?

    @Published public private(set) var state: VADState = .silent

    public init(threshold: Float = 0.035, holdDuration: TimeInterval = 0.6, resumeDuration: TimeInterval = 0.15) {
        self.threshold = threshold
        self.holdDuration = holdDuration
        self.resumeDuration = resumeDuration
    }

    /// Feed a buffer of Float samples (mono, normalised -1…1).
    public func processBuffer(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let isSpeaking = rms > threshold
        let now = Date()

        switch (state, isSpeaking) {
        case (.silent, true):
            state = .speaking
            lastSpeakingTime = now
            lastSilenceStart = nil

        case (.speaking, true):
            lastSpeakingTime = now
            lastSilenceStart = nil

        case (.speaking, false):
            if lastSilenceStart == nil { lastSilenceStart = now }
            if let start = lastSilenceStart, now.timeIntervalSince(start) >= holdDuration {
                state = .paused(duration: now.timeIntervalSince(start))
            }

        case (.paused, true):
            if let last = lastSpeakingTime, now.timeIntervalSince(last) >= resumeDuration {
                state = .speaking
                lastSpeakingTime = now
                lastSilenceStart = nil
            }

        case (.paused, false), (.silent, false):
            break
        }
    }

    public func reset() {
        state = .silent
        lastSpeakingTime = nil
        lastSilenceStart = nil
    }

    /// Convenience: feed raw PCM Int16 data (16 kHz mono).
    public func processInt16Buffer(_ data: Data) {
        let count = data.count / 2
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<count {
                samples[i] = Float(ptr[i]) / 32768.0
            }
        }
        processBuffer(samples)
    }
}
