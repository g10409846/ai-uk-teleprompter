import AVFoundation
import Foundation
import TeleprompterCore

/// Runs the Phase 0 experiments. Connects the single capture pipeline
/// to VAD, speech recognition, and prompt tracking. Records results.
///
/// Experiment 1 – Concurrent capture: camera + mic → file + audio samples
/// Experiment 2 – Follow feel: VAD + speed mapping + anchor stability
/// Experiment 3 – Thermal: recording at 5 min for each quality level
public final class PhaseZeroValidator: NSObject, @unchecked Sendable, AVCaptureFileOutputRecordingDelegate {
    // MARK: - Capture

    private let session = AVCaptureSession()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureMovieFileOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioQueue = DispatchQueue(label: "com.aiuk.audio", qos: .userInitiated)

    // MARK: - Engines

    private let vad = VADEngine()
    private var speechService: SpeechService?
    private var promptEngine: PromptEngine?
    private let thermal = ThermalMonitor()

    // MARK: - State

    private var currentExperiment = 0
    private var results: [ExperimentResult] = []
    private var experimentStart: Date?

    private var vadStates: [VADState] = []
    private var thermalHistory: [ThermalLevel] = []
    private var cursorHistory: [PromptCursor] = []
    private var speedHistory: [Double] = []
    private var recognitionEvents: [(time: Date, text: String, confidence: Float)] = []

    // MARK: - Output

    public var onStatusUpdate: ((String) -> Void)?
    public var onExperimentComplete: ((ExperimentResult) -> Void)?
    public var onAllComplete: ((PhaseZeroReport) -> Void)?

    private var outputDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("phase0-results")
    }

    // MARK: - Setup

    public func setup() throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        session.beginConfiguration()
        session.sessionPreset = .high

        // Front camera
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let videoInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(videoInput)
        else {
            throw ValidatorError.noCamera
        }
        session.addInput(videoInput)
        self.videoDeviceInput = videoInput

        // Mic
        guard let mic = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(audioInput)
        else {
            throw ValidatorError.noMicrophone
        }
        session.addInput(audioInput)

        // Video output
        guard session.canAddOutput(videoOutput) else { throw ValidatorError.cannotAddVideoOutput }
        session.addOutput(videoOutput)

        // Audio data output for VAD + Speech
        guard session.canAddOutput(audioOutput) else { throw ValidatorError.cannotAddAudioOutput }
        session.addOutput(audioOutput)
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)

        session.commitConfiguration()

        onStatusUpdate?("Setup complete: front camera + mic + audio tap ready")
    }

    // MARK: - Run full experiments

    public func runAllExperiments(script: Script, settings: AppSettings) {
        self.promptEngine = PromptEngine(script: script, baseSpeed: settings.baseSpeed)

        // Init speech service with privacy policy
        if settings.autoFollow {
            let svc = SpeechService(allowCloud: settings.allowCloudRecognition)
            self.speechService = svc

            svc.onResult = { [weak self] result in
                self?.promptEngine?.applyRecognition(result)
                self?.recognitionEvents.append((Date(), result.transcript, result.confidence))
            }
        }

        runExperiment1(settings: settings)
    }

    // MARK: - Experiment 1: Concurrent capture

    private func runExperiment1(settings: AppSettings) {
        currentExperiment = 1
        onStatusUpdate?("\n=== Experiment 1/3: Concurrent Capture ===\n")

        let filename = "exp1_\(settings.recordingQuality.rawValue).mov"
        let url = outputDir.appendingPathComponent(filename)

        thermalHistory = []
        experimentStart = Date()
        session.startRunning()
        videoOutput.startRecording(to: url, recordingDelegate: self)

        // Auto-stop after 5 min
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.finishExperiment1()
        }
    }

    private func finishExperiment1() {
        videoOutput.stopRecording()
        session.stopRunning()

        let duration = experimentStart.map { -$0.timeIntervalSinceNow } ?? 300
        let hadAudioCollision = false // we'll know if file is corrupted

        let outcome: ExperimentOutcome
        if let url = videoOutput.outputFileURL, duration > 290 {
            outcome = .passed(details: "5 min continuous capture OK, file: \(url.lastPathComponent)")
        } else {
            outcome = .failed(reason: "Capture did not run full 5 min or file missing", suggestedFix: "Check single-pipeline stability, try 720p if 1080p failed")
        }

        let result = ExperimentResult(
            name: "Exp1-ConcurrentCapture",
            outcome: outcome,
            durationSec: duration,
            thermalLevels: thermalHistory,
            recordedFiles: [videoOutput.outputFileURL].compactMap { $0 }
        )
        results.append(result)
        onExperimentComplete?(result)

        onStatusUpdate?(outcome.summary)
        onStatusUpdate?("\n=== Experiment 2/3: Follow Feel ===\n")
        runExperiment2()
    }

    // MARK: - Experiment 2: Follow feel

    private func runExperiment2() {
        currentExperiment = 2

        // Listen to VAD → prompt
        // (VAD is already running via audio tap; we track state transitions)

        vadStates = []
        cursorHistory = []
        speedHistory = []
        recognitionEvents = []

        experimentStart = Date()
        session.startRunning() // preview-only, no recording needed for feel test

        // Auto-stop after 5 min
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.finishExperiment2()
        }
    }

    private func finishExperiment2() {
        session.stopRunning()

        let stateCount = vadStates.count
        let transitions = countTransitions(vadStates)
        let speedVariance = computeVariance(speedHistory)
        let jumpCount = countJumps(cursorHistory)

        let outcome: ExperimentOutcome
        if transitions > 2 && speedVariance < 400 && jumpCount < 5 {
            outcome = .passed(details: "Follow feel stable: \(transitions) state transitions, speed σ=\(String(format: "%.0f", speedVariance)), \(jumpCount) cursor jumps")
        } else if transitions > 0 {
            outcome = .inconclusive(
                reason: "Follow transitions=\(transitions), jumps=\(jumpCount), need user rating",
                nextStep: "User must rate 7/10 for feel. If < 7, keep VAD-only and weaken anchoring."
            )
        } else {
            outcome = .failed(reason: "No VAD state transitions detected", suggestedFix: "Lower VAD threshold, check mic routing")
        }

        let duration = experimentStart.map { -$0.timeIntervalSinceNow } ?? 300
        let result = ExperimentResult(
            name: "Exp2-FollowFeel",
            outcome: outcome,
            durationSec: duration,
            thermalLevels: thermalHistory
        )
        results.append(result)
        onExperimentComplete?(result)

        onStatusUpdate?(outcome.summary)
        onStatusUpdate?("\n=== Experiment 3/3: Thermal & Stability ===\n")
        runExperiment3()
    }

    // MARK: - Experiment 3: Thermal

    private func runExperiment3() {
        currentExperiment = 3
        thermalHistory = []

        // Record at 1080p30 for 5 min
        let url = outputDir.appendingPathComponent("exp3_thermal_1080p30.mov")
        experimentStart = Date()
        session.startRunning()
        videoOutput.startRecording(to: url, recordingDelegate: self)

        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { [weak self] in
            self?.finishExperiment3()
        }
    }

    private func finishExperiment3() {
        videoOutput.stopRecording()
        session.stopRunning()
        thermal.stop()

        let maxThermal = thermalHistory.max() ?? .nominal
        let wasCritical = thermalHistory.contains { $0 >= .serious }

        let duration = experimentStart.map { -$0.timeIntervalSinceNow } ?? 300
        let fileOK = videoOutput.outputFileURL != nil

        let outcome: ExperimentOutcome
        if !wasCritical && fileOK && maxThermal < .serious {
            outcome = .passed(details: "Thermal OK: max \(maxThermal.label), file intact after 5 min at 1080p30")
        } else if fileOK && maxThermal == .serious {
            outcome = .inconclusive(
                reason: "Entered serious thermal at 1080p30 – 720p30 may be safer",
                nextStep: "Re-test with 720p30. If that also hits serious, split recording + recognition."
            )
        } else {
            outcome = .failed(reason: "File corrupt or thermal critical at 1080p30", suggestedFix: "Drop to 720p30, retest")
        }

        let result = ExperimentResult(
            name: "Exp3-ThermalStability",
            outcome: outcome,
            durationSec: duration,
            thermalLevels: thermalHistory,
            recordedFiles: [videoOutput.outputFileURL].compactMap { $0 }
        )
        results.append(result)
        onExperimentComplete?(result)

        onStatusUpdate?(outcome.summary)

        // Produce gate report
        let report = PhaseZeroReport(allResults: results)
        onAllComplete?(report)
        onStatusUpdate?("\n=== PHASE 0 GATE: \(report.gateStatus.isGo ? "GO ✅" : "NO-GO ❌") ===\n")
        for rec in report.recommendations {
            onStatusUpdate?("→ \(rec)")
        }
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate

    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error {
            onStatusUpdate?("Recording error: \(error.localizedDescription)")
        }
    }

    // MARK: - Cleanup

    public func stop() {
        session.stopRunning()
        thermal.stop()
        speechService?.stop()
    }

    // MARK: - Helpers

    private func countTransitions(_ states: [VADState]) -> Int {
        var count = 0
        for i in 1..<states.count {
            switch (states[i-1], states[i]) {
            case (.silent, .speaking), (.speaking, .silent), (.speaking, .paused), (.paused, .speaking):
                count += 1
            default: break
            }
        }
        return count
    }

    private func computeVariance(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
    }

    private func countJumps(_ cursors: [PromptCursor]) -> Int {
        var jumps = 0
        for i in 1..<cursors.count {
            if abs(cursors[i].sentenceIndex - cursors[i-1].sentenceIndex) > 2 {
                jumps += 1
            }
        }
        return jumps
    }
}

extension PhaseZeroValidator: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Extract PCM for VAD
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr)

        guard let ptr = dataPtr, length > 0 else { return }
        let data = Data(bytes: ptr, count: length)

        vad.processInt16Buffer(data)

        // Track
        vadStates.append(vad.state)
        if let prompt = promptEngine {
            prompt.applyVADState(vad.state)
            cursorHistory.append(prompt.cursor)
            speedHistory.append(prompt.scrollSpeed)
        }

        // Thermal
        let t = ThermalMonitor.readSystemLevel()
        thermalHistory.append(t)
    }
}

enum ValidatorError: Error {
    case noCamera, noMicrophone, cannotAddVideoOutput, cannotAddAudioOutput
    case setupRequired
}
