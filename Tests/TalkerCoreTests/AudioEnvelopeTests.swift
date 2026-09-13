import XCTest
@testable import TalkerCore

final class AudioEnvelopeTests: XCTestCase {
    let rate = 22050.0
    func tone(_ frequency: Double, seconds: Double = 0.4) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(sin(Double($0) * 2 * .pi * frequency / rate) * 0.5) }
    }
    func testSpeechEnergyAndSilenceDriveAnimation() {
        let samples = tone(200) + [Float](repeating: 0, count: 22050)
        let envelope = AudioEnvelope(samples: samples, sampleRate: rate)
        XCTAssertGreaterThan(envelope.level(at: 0.2).energy, 0.4)
        XCTAssertLessThan(envelope.level(at: 1.2).energy, 0.01)
        XCTAssertEqual(envelope.level(at: -1), .quiet)
        XCTAssertEqual(envelope.level(at: 10), .quiet)
    }
    func testVoiceBandsRespondToDifferentFrequencies() {
        let low = AudioEnvelope(samples: tone(100), sampleRate: rate).level(at: 0.2)
        let high = AudioEnvelope(samples: tone(5000), sampleRate: rate).level(at: 0.2)
        XCTAssertGreaterThan(low.bass, high.bass * 3)
        XCTAssertGreaterThan(high.air, low.air * 3)
    }
    func testEmptyAndInvalidAudioStayQuiet() {
        for rate in [0.0, -1, .nan, .infinity, 22050] {
            XCTAssertEqual(AudioEnvelope(samples: [], sampleRate: rate).level(at: 0), .quiet)
        }
        let envelope = AudioEnvelope(samples: [.nan, .infinity, -1, 1], sampleRate: 22050)
        XCTAssertTrue(envelope.level(at: 0).energy.isFinite)
    }
}
