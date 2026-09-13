import XCTest
@testable import TalkerCore

final class VoiceSettingsTests: XCTestCase {
    func testDefaultsPreserveFridayDelivery() {
        XCTAssertEqual(VoiceSettings.load(nil), VoiceSettings(voice: .jenny, speed: 1, pause: 0, rhythm: 0.8))
        XCTAssertEqual(VoiceSettings.load(Data("bad data".utf8)), VoiceSettings())
    }
    func testSettingsSurviveStorageRoundTrip() {
        let settings = VoiceSettings(voice: .lessac, speed: 0.8, pause: 0.25, rhythm: 1.1)
        XCTAssertEqual(VoiceSettings.load(settings.data), settings)
    }
    func testStoredValuesAreValidatedBeforeUse() {
        let data = Data("{\"voice\":\"en_GB-alan-medium\",\"speed\":0,\"pause\":9,\"rhythm\":-5}".utf8)
        let settings = VoiceSettings.load(data)
        XCTAssertEqual(settings.voice, .alan)
        XCTAssertEqual(settings.speed, 0.65)
        XCTAssertEqual(settings.pause, 0.8)
        XCTAssertEqual(settings.rhythm, 0)
        let unknown = Data("{\"voice\":\"../../other\",\"speed\":1,\"pause\":0,\"rhythm\":0.8}".utf8)
        XCTAssertEqual(VoiceSettings.load(unknown), VoiceSettings())
        XCTAssertEqual(VoiceSettings.load(VoiceSettings(speed: .nan, pause: .infinity).data), VoiceSettings())
    }
    func testParametersControlRealPiperKnobs() {
        let settings = VoiceSettings(voice: .alan, speed: 0.8, pause: 0.25, rhythm: 1.1)
        XCTAssertEqual(settings.arguments, ["--length-scale", "1.25", "--sentence-silence", "0.25", "--noise-w-scale", "1.1"])
    }
}
