import Foundation

public struct VoiceLevel: Equatable, Sendable {
    public var energy: Double
    public var bass: Double
    public var air: Double
    public init(energy: Double = 0, bass: Double = 0, air: Double = 0) {
        self.energy = energy; self.bass = bass; self.air = air
    }
    public static let quiet = VoiceLevel()
}

public struct AudioEnvelope: Sendable {
    public let levels: [VoiceLevel]
    public let interval: Double

    // Two one-pole crossovers produce animation bands, not a claimed spectrum analyzer.
    // Analyze off the UI thread once; sample against the player's clock during playback.
    public init(samples: [Float], sampleRate: Double) {
        guard sampleRate.isFinite, (60...384_000).contains(sampleRate), !samples.isEmpty else {
            levels = []; interval = 1 / 60; return
        }
        let hop = max(1, Int(sampleRate / 60))
        interval = Double(hop) / sampleRate
        let lowAlpha = 1 - exp(-2 * .pi * 300 / sampleRate)
        let highAlpha = 1 - exp(-2 * .pi * 2500 / sampleRate)
        var low = 0.0, wide = 0.0
        var previous = VoiceLevel.quiet
        var result: [VoiceLevel] = []
        func compress(_ sum: Double, _ count: Int) -> Double {
            min(1, pow(sqrt(sum / Double(count)) * 2, 0.65))
        }
        func smooth(_ value: Double, _ old: Double) -> Double {
            old + (value - old) * (value > old ? 0.65 : 0.16)
        }
        for start in stride(from: 0, to: samples.count, by: hop) {
            let end = min(start + hop, samples.count)
            var energy = 0.0, bass = 0.0, air = 0.0
            for index in start..<end {
                let raw = samples[index].isFinite ? Double(samples[index]) : 0
                let sample = min(1, max(-1, raw))
                low += lowAlpha * (sample - low)
                wide += highAlpha * (sample - wide)
                energy += sample * sample
                bass += low * low
                air += (sample - wide) * (sample - wide)
            }
            previous = VoiceLevel(energy: smooth(compress(energy, end - start), previous.energy),
                                  bass: smooth(compress(bass, end - start), previous.bass),
                                  air: smooth(compress(air, end - start), previous.air))
            result.append(previous)
        }
        levels = result
    }

    public func level(at time: Double) -> VoiceLevel {
        guard time.isFinite, time >= 0, time < Double(levels.count) * interval else { return .quiet }
        let position = time / interval
        let index = Int(position)
        let a = levels[index], b = levels[min(index + 1, levels.count - 1)]
        let mix = position - Double(index)
        return VoiceLevel(energy: a.energy + (b.energy - a.energy) * mix,
                          bass: a.bass + (b.bass - a.bass) * mix,
                          air: a.air + (b.air - a.air) * mix)
    }
}
