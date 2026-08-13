import Foundation

// MARK: - Script

public struct Script: Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var rawText: String
    public var createdAt: Date
    public var lastEditedAt: Date

    public init(id: UUID = UUID(), title: String = "", rawText: String = "", createdAt: Date = Date(), lastEditedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.rawText = rawText
        self.createdAt = createdAt
        self.lastEditedAt = lastEditedAt
    }

    public var sentences: [String] {
        rawText
            .components(separatedBy: CharacterSet(charactersIn: "。！？；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public var characterCount: Int { rawText.count }

    public func estimatedDuration(atSpeed charsPerSecond: Double = 4.5) -> TimeInterval {
        guard charsPerSecond > 0 else { return 0 }
        return Double(characterCount) / charsPerSecond
    }
}

// MARK: - Cursor

public struct PromptCursor: Equatable {
    public var sentenceIndex: Int
    public var offsetInSentence: Int

    public static let zero = PromptCursor(sentenceIndex: 0, offsetInSentence: 0)

    public init(sentenceIndex: Int = 0, offsetInSentence: Int = 0) {
        self.sentenceIndex = sentenceIndex
        self.offsetInSentence = offsetInSentence
    }
}

// MARK: - Recognition

public struct RecognitionResult: Equatable {
    public let transcript: String
    public let isFinal: Bool
    public let confidence: Float

    public init(transcript: String, isFinal: Bool, confidence: Float = 0.0) {
        self.transcript = transcript
        self.isFinal = isFinal
        self.confidence = confidence
    }

    var isHighConfidence: Bool { confidence >= 0.65 }
}

// MARK: - App state

public enum AppPhase: Equatable {
    case editing
    case ready
    case recording
    case completed
}

// MARK: - VAD State

public enum VADState: Equatable {
    case silent
    case speaking
    case paused(duration: TimeInterval)
}

// MARK: - Running mode

public enum RunMode: Equatable {
    case auto
    case manual
}

// MARK: - Thermal state

public enum ThermalLevel: Int, Comparable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Fair – Warm"
        case .serious: "Serious – Throttled"
        case .critical: "Critical – Must Reduce"
        }
    }
}

// MARK: - Settings

public struct AppSettings: Codable, Equatable {
    public var fontSize: CGFloat
    public var textOpacity: Double
    public var backgroundOpacity: Double
    public var baseSpeed: Double         // pixels per second
    public var autoFollow: Bool
    public var recordingQuality: RecordingQuality
    public var allowCloudRecognition: Bool

    public static let `default` = AppSettings(
        fontSize: 36,
        textOpacity: 0.92,
        backgroundOpacity: 0.45,
        baseSpeed: 60,
        autoFollow: true,
        recordingQuality: .hd1080_30,
        allowCloudRecognition: false
    )

    public init(fontSize: CGFloat = 36, textOpacity: Double = 0.92, backgroundOpacity: Double = 0.45, baseSpeed: Double = 60, autoFollow: Bool = true, recordingQuality: RecordingQuality = .hd1080_30, allowCloudRecognition: Bool = false) {
        self.fontSize = fontSize
        self.textOpacity = textOpacity
        self.backgroundOpacity = backgroundOpacity
        self.baseSpeed = baseSpeed
        self.autoFollow = autoFollow
        self.recordingQuality = recordingQuality
        self.allowCloudRecognition = allowCloudRecognition
    }
}

public enum RecordingQuality: String, CaseIterable, Codable {
    case hd720_30 = "720p30"
    case hd1080_30 = "1080p30"
}

// MARK: - Validation report

public enum ExperimentOutcome {
    case passed(details: String)
    case failed(reason: String, suggestedFix: String)
    case inconclusive(reason: String, nextStep: String)

    var isPassed: Bool {
        if case .passed = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .passed(let d): return "✅ PASSED – \(d)"
        case .failed(let r, let f): return "❌ FAILED – \(r)\n   Fix: \(f)"
        case .inconclusive(let r, let n): return "⚠ INCONCLUSIVE – \(r)\n   Next: \(n)"
        }
    }
}

public struct ExperimentResult: Identifiable {
    public let id = UUID()
    public let name: String
    public let outcome: ExperimentOutcome
    public let durationSec: TimeInterval
    public let thermalLevels: [ThermalLevel]
    public let recordedFiles: [URL]
    public let timestamp: Date

    public init(name: String, outcome: ExperimentOutcome, durationSec: TimeInterval, thermalLevels: [ThermalLevel] = [], recordedFiles: [URL] = [], timestamp: Date = Date()) {
        self.name = name
        self.outcome = outcome
        self.durationSec = durationSec
        self.thermalLevels = thermalLevels
        self.recordedFiles = recordedFiles
        self.timestamp = timestamp
    }
}

public struct PhaseZeroReport: Identifiable {
    public let id = UUID()
    public let allResults: [ExperimentResult]
    public let gateStatus: GateStatus
    public let recommendations: [String]
    public let timestamp: Date

    public init(allResults: [ExperimentResult], gateStatus: GateStatus? = nil, recommendations: [String] = [], timestamp: Date = Date()) {
        self.allResults = allResults
        self.timestamp = timestamp
        self.gateStatus = gateStatus ?? GateStatus.evaluate(from: allResults)
        self.recommendations = recommendations.isEmpty ? Self.defaultRecommendations(for: allResults) : recommendations
    }

    static func defaultRecommendations(for results: [ExperimentResult]) -> [String] {
        var recs: [String] = []
        for r in results {
            switch r.outcome {
            case .failed(_, let fix):
                recs.append("[\(r.name)] \(fix)")
            case .inconclusive(_, let next):
                recs.append("[\(r.name)] Suggested next step: \(next)")
            case .passed:
                break
            }
        }
        return recs
    }
}

public enum GateStatus {
    case go
    case noGo(reasons: [String])

    public var isGo: Bool { if case .go = self { return true }; return false }

    static func evaluate(from results: [ExperimentResult]) -> GateStatus {
        var reasons: [String] = []
        for r in results {
            if case .failed(let reason, _) = r.outcome { reasons.append("\(r.name): \(reason)") }
        }
        return reasons.isEmpty ? .go : .noGo(reasons: reasons)
    }
}
