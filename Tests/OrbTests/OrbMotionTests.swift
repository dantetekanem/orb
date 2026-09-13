import XCTest
import TalkerCore
@testable import Orb

final class OrbMotionTests: XCTestCase {
    func testClockKeepsOneEntranceThroughPlaybackUpdatesAndRestartsForReplacement() {
        var clock = OrbMotionClock()
        let first = UUID()
        clock.update(presentationID: first, paused: false, at: 100)
        XCTAssertEqual(clock.elapsed(at: 100), 0)
        clock.update(presentationID: first, paused: false, at: 101)
        XCTAssertEqual(clock.elapsed(at: 102), 2)
        clock.update(presentationID: UUID(), paused: false, at: 102)
        XCTAssertEqual(clock.elapsed(at: 102), 0)
        XCTAssertEqual(clock.elapsed(at: 102.2), 0.2, accuracy: 0.0001)
    }

    func testPausingFreezesThePoseAndResumingExcludesPausedTime() {
        var clock = OrbMotionClock()
        let id = UUID()
        clock.update(presentationID: id, paused: false, at: 10)
        clock.update(presentationID: id, paused: true, at: 12)
        clock.update(presentationID: id, paused: true, at: 20)
        XCTAssertEqual(clock.elapsed(at: 90), 2)
        clock.update(presentationID: id, paused: false, at: 90)
        XCTAssertEqual(clock.elapsed(at: 90.5), 2.5)
    }

    func testStopRetainsTheClosingPoseAndTheNextPresentationStartsFresh() {
        var clock = OrbMotionClock()
        clock.update(presentationID: nil, paused: true, at: 10)
        XCTAssertEqual(clock.elapsed(at: 11), 0)
        clock.update(presentationID: UUID(), paused: false, at: 12)
        clock.update(presentationID: nil, paused: true, at: 12.3)
        XCTAssertEqual(clock.elapsed(at: 20), 0.3, accuracy: 0.0001)
        clock.update(presentationID: UUID(), paused: true, at: 21)
        XCTAssertEqual(clock.elapsed(at: 30), 0)
    }

    func testOnlyVisibleVoiceActivityRunsTheFrameLoop() {
        for phase in [Playback.Phase.idle, .preparing, .speaking, .choosing, .notifying, .settling, .failed] {
            let active = phase == .preparing || phase == .speaking
            XCTAssertEqual(OrbMotionClock.isPaused(phase: phase, silent: false, reduceMotion: false), !active)
            XCTAssertTrue(OrbMotionClock.isPaused(phase: phase, silent: true, reduceMotion: false))
            XCTAssertTrue(OrbMotionClock.isPaused(phase: phase, silent: false, reduceMotion: true))
        }
    }

    func testEntranceGrowsCoreBeforeOrbitAndWavesThenFinishesWithoutAnOngoingPulse() {
        let start = OrbMotionFrame(elapsed: 0, level: .quiet)
        let ignition = OrbMotionFrame(elapsed: 0.14, level: .quiet)
        let forming = OrbMotionFrame(elapsed: 0.45, level: .quiet)
        let settled = OrbMotionFrame(elapsed: 1.2, level: .quiet)
        XCTAssertLessThan(start.coreScale, ignition.coreScale)
        XCTAssertLessThan(ignition.coreScale, forming.coreScale)
        XCTAssertEqual(ignition.orbitReveal, 0)
        XCTAssertEqual(ignition.waveReveal, 0)
        XCTAssertGreaterThan(forming.orbitReveal, 0)
        XCTAssertGreaterThan(forming.ignition, 0)
        XCTAssertEqual(settled.coreScale, 1)
        XCTAssertEqual(settled.orbitReveal, 1)
        XCTAssertEqual(settled.waveReveal, 1)
        XCTAssertEqual(settled.ignition, 0)
    }

    func testVoiceAddsSizeAndLightWhileAmbientBreathingStaysBounded() {
        for step in 0...240 {
            let time = Double(step) / 20
            let quiet = OrbMotionFrame(elapsed: time, level: .quiet)
            let voice = OrbMotionFrame(elapsed: time, level: VoiceLevel(energy: 1, bass: 1, air: 1))
            XCTAssertTrue((50...60).contains(voice.radius))
            XCTAssertTrue((50...54).contains(quiet.radius))
            XCTAssertLessThanOrEqual(voice.coreScale, 1.06)
            XCTAssertGreaterThan(voice.radius, quiet.radius)
            XCTAssertGreaterThan(voice.radiance, quiet.radiance)
        }
    }

    func testReducedMotionUsesTheSameFinishedPoseRegardlessOfTimeOrAudio() {
        let still = OrbMotionFrame(elapsed: 0, level: .quiet, reduceMotion: true)
        for time in [0.1, 0.5, 2, 100] {
            XCTAssertEqual(OrbMotionFrame(elapsed: time, level: VoiceLevel(energy: 1, bass: 1, air: 1),
                                          reduceMotion: true), still)
        }
        XCTAssertEqual(still.coreScale, 1)
        XCTAssertEqual(still.orbitReveal, 1)
        XCTAssertEqual(still.waveReveal, 1)
        XCTAssertEqual(still.ignition, 0)
    }
}
