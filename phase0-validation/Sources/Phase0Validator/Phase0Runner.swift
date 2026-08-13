import Foundation
import AVFoundation
import Speech
import TeleprompterCore

@main
struct Phase0Runner {
    static func main() async {
        print("AI-UK 智能提词器 · Phase 0 原生可行性验证")
        print("==============================================\n")

        // 1. Check system
        print("--- System Check ---")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Thermal: \(ThermalMonitor.readSystemLevel().label)")

        let speechAuth = SpeechService.authorizationStatus
        print("Speech recognition auth: \(speechAuth.rawValue)")
        if speechAuth != .authorized {
            print("⚠ Speech recognition not authorized. Experiment 2 will use VAD-only mode.")
        }

        let cameraAuth = AVCaptureDevice.authorizationStatus(for: .video)
        print("Camera auth: \(cameraAuth.rawValue)")
        if cameraAuth != .authorized {
            print("⚠ Camera not authorized. You must grant permission to run capture experiments.")
        }

        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        print("Microphone auth: \(micAuth.rawValue)")
        if micAuth != .authorized {
            print("⚠ Microphone not authorized.")
        }

        print("\n--- Speech Recognizer Capabilities ---")
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        print("zh-CN recognizer available: \(recognizer?.isAvailable ?? false)")
        if #available(macOS 10.15, *) {
            print("On-device supported: \(recognizer?.supportsOnDeviceRecognition ?? false)")
        }

        // 2. Load embedded test script (Package.swift resources not usable from CLI; use default)
        print("\n--- Test Script ---")
        let scriptText = defaultScript
        print("Using default script (\(scriptText.count) chars)")
        let script = Script(title: "Phase 0 Test", rawText: scriptText)

        // 3. VAD smoke test
        print("\n--- VAD Smoke Test ---")
        let vad = VADEngine()
        vad.processBuffer(generateSilence(duration: 0.5))
        print("After silence: \(vad.state)")

        vad.processBuffer(generateSpeech(duration: 1.0, amplitude: 0.3))
        print("After speech: \(vad.state)")

        try? await Task.sleep(nanoseconds: 700_000_000)
        print("After hold: \(vad.state)")
        vad.reset()

        // 4. Prompt engine smoke test
        print("\n--- Prompt Engine Smoke Test ---")
        let prompt = PromptEngine(script: script, baseSpeed: 60)
        prompt.applyVADState(.speaking)
        print("VAD=speaking → isMoving: \(prompt.isMoving), speed: \(prompt.scrollSpeed)")

        prompt.applyVADState(.paused(duration: 0.6))
        print("VAD=paused → isMoving: \(prompt.isMoving)")

        prompt.applyRecognition(RecognitionResult(transcript: "大家好我是老K", isFinal: true, confidence: 0.8))
        print("After recognition anchor: cursor=\(prompt.cursor.sentenceIndex), speed=\(String(format: "%.1f", prompt.scrollSpeed))")

        // 5. Integration test
        print("\n--- Integration: VAD + Prompt ---")
        let script2 = Script(title: "Integration Test", rawText: "第一句。第二句。第三句。")
        let prompt2 = PromptEngine(script: script2)
        let vad2 = VADEngine()

        vad2.processBuffer(generateSpeech(duration: 3.0, amplitude: 0.2))
        prompt2.applyVADState(vad2.state)
        print("Speaking → moving: \(prompt2.isMoving), cursor: \(prompt2.cursor.sentenceIndex)")

        try? await Task.sleep(nanoseconds: 700_000_000)
        vad2.processBuffer(generateSilence(duration: 0.7))
        prompt2.applyVADState(vad2.state)
        print("Paused → moving: \(prompt2.isMoving), cursor: \(prompt2.cursor.sentenceIndex)")

        // 6. Summary
        print("\n==============================================")
        print("Phase 0 Smoke Tests Complete")
        print("==============================================")
        print("\nNext steps:")
        print("1. Build and run on your Mac with Xcode")
        print("2. Grant camera, mic, and speech recognition permissions")
        print("3. Run full Phase0Validator.runAllExperiments() with your script")
        print("4. Review the gate report to decide GO / NO-GO")
    }

    // MARK: - Audio generation helpers

    static func generateSilence(duration: TimeInterval) -> [Float] {
        let samples = Int(duration * 16000)
        return [Float](repeating: 0.005, count: samples)
    }

    static func generateSpeech(duration: TimeInterval, amplitude: Float) -> [Float] {
        let sampleRate: Double = 16000.0
        let samples = Int(duration * sampleRate)
        var buffer = [Float](repeating: 0, count: samples)
        for i in 0..<samples {
            let t = Double(i) / sampleRate
            let wave: Float = Float(
                sin(2.0 * .pi * 200.0 * t) * 0.5 +
                sin(2.0 * .pi * 500.0 * t) * 0.3 +
                sin(2.0 * .pi * 800.0 * t) * 0.2
            )
            buffer[i] = amplitude * wave
        }
        return buffer
    }

    static let defaultScript = """
大家好，我是老K。

今天想跟大家聊一聊数字信用这个话题。

很多朋友问我，什么是数字信用？简单来说，就是在数字世界里建立信任。

传统的信用体系依赖于纸质凭证、担保、抵押物，但数字信用不一样。

它基于数据——交易数据、行为数据、履约记录。

通过技术手段把这些数据变成可验证、可追溯的信用凭证。

这就是我们"金订单"在做的事情。

听起来很简单对吧？但实际上要打通产业链、金融机构、监管三方，非常复杂。

我们花了三年时间才把第一个闭环跑通。

这中间踩了很多坑，也学到了很多。

今天我就来分享一下我们的经验和思考。

如果你对这个方向有兴趣，或者正在做相关的事情，欢迎来找我聊。

我是老K，我们下次再见。
"""
}
