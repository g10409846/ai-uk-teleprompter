import Foundation

/// Tracks reading position, maps VAD state and recognition results to a stable cursor.
public final class PromptEngine: @unchecked Sendable {
    public let script: Script

    @Published public private(set) var cursor: PromptCursor = .zero
    @Published public private(set) var scrollSpeed: Double = 60
    @Published public private(set) var isMoving: Bool = false

    private let baseSpeed: Double
    private var speedSmoothing: Double
    private var lastRecognitionTime: Date?

    public init(script: Script, baseSpeed: Double = 60) {
        self.script = script
        self.baseSpeed = baseSpeed
        self.scrollSpeed = baseSpeed
        self.speedSmoothing = baseSpeed
    }

    // MARK: - VAD-driven start/stop

    public func applyVADState(_ state: VADState) {
        switch state {
        case .speaking:
            isMoving = true
        case .silent, .paused:
            isMoving = false
        }
    }

    // MARK: - Recognition-driven speed & anchor

    public func applyRecognition(_ result: RecognitionResult, at time: Date = Date()) {
        guard result.isFinal, result.confidence >= 0.5 else { return }

        let transcript = result.transcript
        let now = time

        // Estimate speaking rate from elapsed time since last result
        if let lastTime = lastRecognitionTime {
            let elapsed = now.timeIntervalSince(lastTime)
            guard elapsed > 0.1 else { return }
            let charsPerSecond = Double(transcript.count) / elapsed

            // Map to scroll speed: 3–10 chars/sec → 40–120 px/s, clamped
            let rawSpeed = (charsPerSecond - 3.0) / (10.0 - 3.0) * 80.0 + 40.0
            let clamped = min(max(rawSpeed, 40), 120)

            // Smooth: 70% previous, 30% new
            speedSmoothing = speedSmoothing * 0.7 + clamped * 0.3
            scrollSpeed = speedSmoothing
        }
        lastRecognitionTime = now

        // Anchor: fuzzy match transcript to current script sentence
        if result.confidence >= 0.65, let matchIndex = findBestMatch(transcript: transcript) {
            let oldIndex = cursor.sentenceIndex
            let dist = abs(matchIndex - oldIndex)

            if dist <= 2 {
                // Small correction – apply
                cursor = PromptCursor(sentenceIndex: matchIndex, offsetInSentence: 0)
            }
            // If dist > 2, reject – don't jump. The user may have ad-libbed.
        }
    }

    // MARK: - Anchor matching

    private func findBestMatch(transcript: String) -> Int? {
        let sentences = script.sentences
        guard !sentences.isEmpty else { return nil }

        let normalized = normalize(transcript)
        let searchWindow = 5

        var bestIndex: Int? = nil
        var bestScore: Double = 0

        let start = max(0, cursor.sentenceIndex - searchWindow)
        let end = min(sentences.count - 1, cursor.sentenceIndex + searchWindow)

        for i in start...end {
            let normalizedSentence = normalize(sentences[i])
            let score = jaccardSimilarity(normalized, normalizedSentence)
            if score > bestScore {
                bestScore = score
                bestIndex = i
            }
        }

        return bestScore >= 0.35 ? bestIndex : nil
    }

    private func normalize(_ text: String) -> Set<String> {
        let cleaned = text
            .replacingOccurrences(of: "[，、：；。！？\"\"''（）《》\\[\\]\\s]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let words = cleaned.components(separatedBy: .whitespaces).filter { $0.count > 0 }
        return Set(words)
    }

    private func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return Double(intersection) / Double(union)
    }

    // MARK: - Reset

    public func reset() {
        cursor = .zero
        scrollSpeed = baseSpeed
        speedSmoothing = baseSpeed
        isMoving = false
        lastRecognitionTime = nil
    }

    /// Manual speed override (P0 manual fallback)
    public func setManualSpeed(_ speed: Double) {
        scrollSpeed = min(max(speed, 20), 160)
        speedSmoothing = scrollSpeed
        isMoving = true
    }

    public func stop() {
        isMoving = false
    }
}
