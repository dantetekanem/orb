import Foundation
import TalkerCore

struct OrbMotionClock {
    private var presentationID: UUID?
    private var origin: TimeInterval?
    private var pausedAt: TimeInterval?

    static func isPaused(phase: Playback.Phase, silent: Bool, reduceMotion: Bool) -> Bool {
        reduceMotion || silent || (phase != .preparing && phase != .speaking)
    }

    mutating func update(presentationID next: UUID?, paused: Bool, at now: TimeInterval) {
        if let next, next != presentationID {
            presentationID = next
            origin = now
            pausedAt = nil
        }
        guard let origin else { return }
        if paused {
            if pausedAt == nil { pausedAt = now }
        } else if let pausedAt {
            self.origin = origin + max(0, now - pausedAt)
            self.pausedAt = nil
        }
    }

    func elapsed(at now: TimeInterval) -> TimeInterval {
        guard let origin else { return 0 }
        return max(0, (pausedAt ?? now) - origin)
    }
}

struct OrbMotionFrame: Equatable {
    static let entranceDuration = 1.1
    let time: Double
    let level: VoiceLevel
    let coreScale: Double
    let orbitReveal: Double
    let waveReveal: Double
    let ignition: Double
    let radius: Double
    let radiance: Double

    init(elapsed: Double, level: VoiceLevel, reduceMotion: Bool = false) {
        time = reduceMotion ? 0 : max(0, elapsed)
        self.level = reduceMotion ? .quiet : level
        let growth = Self.progress(reduceMotion ? 1 : time / 0.72)
        coreScale = 0.12 + 0.88 * Self.easeOut(growth) + 0.06 * sin(.pi * growth)
        orbitReveal = Self.easeOut(Self.progress(reduceMotion ? 1 : (time - 0.16) / 0.72))
        waveReveal = Self.easeOut(Self.progress(reduceMotion ? 1 : (time - 0.32) / 0.68))
        let ignitionProgress = Self.progress(time / Self.entranceDuration)
        ignition = reduceMotion || ignitionProgress >= 1 ? 0 : pow(sin(.pi * ignitionProgress), 2) * 0.65
        let breath = sin(time * 1.7) * 1.1 + sin(time * 0.73) * 0.4
        radius = 52 + breath + self.level.bass * 5.5
        radiance = 0.6 + self.level.energy * 0.4
    }

    private static func progress(_ value: Double) -> Double { min(1, max(0, value)) }
    private static func easeOut(_ value: Double) -> Double { 1 - pow(1 - value, 3) }
}
