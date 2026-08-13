import Foundation
import Speech
import AVFoundation

/// Wraps SFSpeechRecognizer with runtime capability checks.
/// Respects the privacy policy: on-device first, cloud only if explicitly allowed.
public final class SpeechService: NSObject, @unchecked Sendable, SFSpeechRecognizerDelegate {
    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private let allowCloud: Bool

    public var onResult: ((RecognitionResult) -> Void)?
    public var onAvailabilityChange: ((Bool) -> Void)?

    public private(set) var isRunning = false
    public private(set) var isOnDeviceAvailable = false

    public init(locale: Locale = Locale(identifier: "zh-CN"), allowCloud: Bool = false) {
        self.allowCloud = allowCloud
        self.recognizer = SFSpeechRecognizer(locale: locale)
        super.init()
        recognizer?.delegate = self

        // Runtime check: can we do on-device?
        if #available(iOS 13, macOS 10.15, *) {
            isOnDeviceAvailable = recognizer?.supportsOnDeviceRecognition ?? false
        }
    }

    public func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    public class var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// Start a recognition session using the shared AVAudioEngine.
    /// If `audioEngine` is nil, creates its own engine + tap (standalone timeline).
    /// Passing a shared engine lets us verify single-pipeline audio during Phase 0.
    public func start(with sharedEngine: AVAudioEngine? = nil) throws {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable
        }

        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        if #available(iOS 13, macOS 10.15, *) {
            request.requiresOnDeviceRecognition = !allowCloud
        }
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        // Use shared engine or create our own
        let engine: AVAudioEngine
        if let shared = sharedEngine {
            engine = shared
        } else {
            engine = AVAudioEngine()
            self.audioEngine = engine
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        if !engine.isRunning {
            try engine.start()
        }

        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                print("[SpeechService] Recognition error: \(error.localizedDescription)")
                self.onResult?(RecognitionResult(transcript: "", isFinal: true, confidence: 0))
                return
            }

            guard let result = result else { return }

            let transcript = result.bestTranscription.formattedString
            let confidence = Float(result.bestTranscription.segments.map { $0.confidence }.reduce(0, +) / Float(max(1, result.bestTranscription.segments.count)))

            self.onResult?(RecognitionResult(
                transcript: transcript,
                isFinal: result.isFinal,
                confidence: confidence
            ))
        }

        isRunning = true
    }

    public func stop() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }

        isRunning = false
    }

    // MARK: - SFSpeechRecognizerDelegate

    public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        onAvailabilityChange?(available)
    }

    public enum SpeechError: Error {
        case recognizerUnavailable
        case notAuthorized
    }
}
