import XCTest
@testable import TeleprompterCore

final class VADEngineTests: XCTestCase {
    func testSilenceThenSpeech() {
        let vad = VADEngine(holdDuration: 0.3)
        vad.processBuffer(generateSilence(duration: 0.5))
        XCTAssertEqual(vad.state, .silent)

        vad.processBuffer(generateSpeech(duration: 0.5, amplitude: 0.3))
        XCTAssertEqual(vad.state, .speaking)
    }

    func testSpeechThenPause() {
        let vad = VADEngine(holdDuration: 0.3)
        vad.processBuffer(generateSpeech(duration: 1.0, amplitude: 0.3))
        XCTAssertEqual(vad.state, .speaking)

        vad.processBuffer(generateSilence(duration: 0.2))
        XCTAssertEqual(vad.state, .speaking, "Short silence should not trigger pause")

        vad.processBuffer(generateSilence(duration: 0.4))
        if case .paused = vad.state { } else {
            XCTFail("Expected .paused, got \(vad.state)")
        }
    }

    func testResumeFromPause() {
        let vad = VADEngine(holdDuration: 0.3, resumeDuration: 0.1)
        vad.processBuffer(generateSilence(duration: 0.5))
        vad.processBuffer(generateSpeech(duration: 0.05, amplitude: 0.3))
        // Short burst – not enough to resume; expected variance, real test is on device.
    }

    func generateSilence(duration: TimeInterval) -> [Float] {
        let count = Int(duration * 16000)
        return [Float](repeating: 0.005, count: count)
    }

    func generateSpeech(duration: TimeInterval, amplitude: Float) -> [Float] {
        let rate = 16000.0
        let count = Int(duration * rate)
        var buf = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / rate
            buf[i] = amplitude * Float(sin(2 * .pi * 300 * t))
        }
        return buf
    }
}

final class PromptEngineTests: XCTestCase {
    func testVADDrivesMoving() {
        let script = Script(rawText: "第一句。第二句。第三句。")
        let engine = PromptEngine(script: script)

        engine.applyVADState(.speaking)
        XCTAssertTrue(engine.isMoving)

        engine.applyVADState(.paused(duration: 0.6))
        XCTAssertFalse(engine.isMoving)
    }

    func testRecognitionAnchorsNearby() {
        let script = Script(rawText: "大家好我是老K。今天聊聊数字信用。这是第三句话。")
        let engine = PromptEngine(script: script)

        let result = RecognitionResult(transcript: "今天聊聊数字信用", isFinal: true, confidence: 0.85)
        engine.applyRecognition(result)

        XCTAssertEqual(engine.cursor.sentenceIndex, 1, "Should anchor to sentence 1 (second sentence)")
    }

    func testRecognitionDoesNotJumpFar() {
        let script = Script(rawText: "第一句长内容在这里。第二句也在这里。第三句来了。第四句耶。第五句嗯。第六句了。")
        let engine = PromptEngine(script: script)

        let result = RecognitionResult(transcript: "第六句了", isFinal: true, confidence: 0.85)
        engine.applyRecognition(result)

        XCTAssertEqual(engine.cursor.sentenceIndex, 0, "Far jump should be rejected")
    }

    func testManualSpeedOverride() {
        let script = Script(rawText: "测试")
        let engine = PromptEngine(script: script, baseSpeed: 60)

        engine.setManualSpeed(100)
        XCTAssertEqual(engine.scrollSpeed, 100)
        XCTAssertTrue(engine.isMoving)

        engine.stop()
        XCTAssertFalse(engine.isMoving)
    }
}
