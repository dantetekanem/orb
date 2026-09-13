import Foundation

public enum VoiceChoice: String, Codable, CaseIterable, Identifiable {
    case jenny = "en_GB-jenny_dioco-medium"
    case alan = "en_GB-alan-medium"
    case lessac = "en_US-lessac-high"
    public var id: String { rawValue }
    public func modelURL(in runtime: URL) -> URL { runtime.appendingPathComponent("voices/\(rawValue).onnx") }
    public func isAvailable(in runtime: URL) -> Bool {
        let path = modelURL(in: runtime).path
        return FileManager.default.isReadableFile(atPath: path) && FileManager.default.isReadableFile(atPath: path + ".json")
    }
    public var label: String {
        switch self {
        case .jenny: "Jenny · British"
        case .alan: "Alan · British"
        case .lessac: "Lessac · American"
        }
    }
}

public struct VoiceSettings: Codable, Equatable {
    public var voice: VoiceChoice
    public var speed: Double
    public var pause: Double
    public var rhythm: Double
    public init(voice: VoiceChoice = .jenny, speed: Double = 1, pause: Double = 0, rhythm: Double = 0.8) {
        self.voice = voice; self.speed = speed; self.pause = pause; self.rhythm = rhythm
    }
    public var validated: VoiceSettings {
        func bound(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        return VoiceSettings(voice: voice, speed: bound(speed, 0.65...1.45, 1),
                             pause: bound(pause, 0...0.8, 0), rhythm: bound(rhythm, 0...1.2, 0.8))
    }
    public static func load(_ data: Data?) -> VoiceSettings {
        guard let data, let settings = try? JSONDecoder().decode(Self.self, from: data) else { return VoiceSettings() }
        return settings.validated
    }
    public var data: Data { (try? JSONEncoder().encode(validated)) ?? Data() }
    public var arguments: [String] {
        let values = validated
        return ["--length-scale", String(1 / values.speed), "--sentence-silence", String(values.pause),
                "--noise-w-scale", String(values.rhythm)]
    }
}
