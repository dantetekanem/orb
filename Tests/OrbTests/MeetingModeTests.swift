import AVFoundation
import XCTest
@testable import TalkerCore
@testable import Orb

@MainActor
final class MeetingModeTests: XCTestCase {
    func testQueuedPresentationUsesCommittedIdleInsteadOfShowingStoppedMessage() async {
        let fixture = Fixture(.inactive)
        var states: [PanelPresentation] = []
        let observation = fixture.model.panelPresentation.sink { states.append($0) }
        defer { observation.cancel(); fixture.model.shutdown() }
        await drainPresentation()
        XCTAssertEqual(states.count, 1)
        XCTAssertFalse(states[0].expanded)
        let idle = states
        fixture.model.speak(Message(text: "Already stopped"))
        fixture.model.stop()
        await drainPresentation()
        XCTAssertEqual(states, idle)
    }

    func testQueuedPresentationKeepsLatestSilentQuestionAndIdentityTogether() async throws {
        let fixture = Fixture(.active)
        var states: [PanelPresentation] = []
        let observation = fixture.model.panelPresentation.sink { states.append($0) }
        defer { observation.cancel(); fixture.model.shutdown() }
        fixture.model.speak(Message(text: "Replaced"))
        let question = try Question.decode(Data(#"{"question":"Continue?","answers":[{"id":"yes","label":"Yes"},{"id":"no","label":"No"}],"default_answer_id":"no"}"#.utf8))
        _ = fixture.model.handle(.ask(question)) { _ in }
        let id = try XCTUnwrap(fixture.model.playback.id)
        await drainPresentation()
        XCTAssertEqual(states, [PanelPresentation(expanded: true, question: question, questionID: id, silent: true)])
        XCTAssertEqual(fixture.jobsCreated, 0)
    }

    func testIdleMeetingTogglePreservesPresentationBeforeAndAfterMessage() async {
        for previousMessage in [false, true] {
            let fixture = Fixture(.active)
            if previousMessage { fixture.model.speak(Message(text: "Finished")); fixture.model.stop() }
            var states: [PanelPresentation] = []
            let observation = fixture.model.panelPresentation.sink { states.append($0) }
            await drainPresentation()
            let idle = states
            XCTAssertEqual(idle.count, 1)
            XCTAssertFalse(idle[0].expanded)
            fixture.model.meetingMode = true
            fixture.model.meetingMode = false
            await drainPresentation()
            XCTAssertEqual(states, idle)
            XCTAssertEqual(fixture.model.playback.phase, .idle)
            XCTAssertEqual(fixture.jobsCreated, 0)
            XCTAssertEqual(fixture.player.plays, 0)
            observation.cancel(); fixture.model.shutdown()
        }
    }

    func testTryOrbNeverAddsOrEvictsRecentMessagesDuringVoiceOrSilentDelivery() {
        for activity in [InputActivity.inactive, .active, .unknown] {
            let fixture = Fixture(activity)
            defer { fixture.model.shutdown() }
            fixture.model.demonstrate()
            XCTAssertTrue(fixture.model.recentMessages.isEmpty)
            for index in 1...10 { fixture.model.speak(Message(text: "Incoming \(index)")) }
            let history = fixture.model.recentMessages.map(\.id)
            XCTAssertEqual(history.count, 10)
            fixture.model.demonstrate()
            fixture.model.demonstrate()
            XCTAssertEqual(fixture.model.recentMessages.map(\.id), history)
            XCTAssertEqual(fixture.model.playback.phase, activity == .inactive ? .preparing : .notifying)
            XCTAssertEqual(fixture.jobsCreated, activity == .inactive ? 13 : 0)
        }
    }

    func testTryOrbReplacesAQuestionWithoutRecordingTheDemoAndRespectsMeetingMode() throws {
        let fixture = Fixture(.inactive)
        defer { fixture.model.shutdown() }
        fixture.model.meetingMode = true
        let question = try Question.decode(Data(#"{"question":"Continue?","answers":[{"id":"yes","label":"Yes"},{"id":"no","label":"No"}],"default_answer_id":"no"}"#.utf8))
        var replies: [Reply] = []
        _ = fixture.model.handle(.ask(question)) { replies.append($0) }
        let history = fixture.model.recentMessages.map(\.id)
        fixture.model.demonstrate()
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.body["reason"], "replaced")
        XCTAssertNil(fixture.model.pendingQuestion)
        XCTAssertEqual(fixture.model.recentMessages.map(\.id), history)
        XCTAssertEqual(fixture.model.playback.phase, .notifying)
        XCTAssertEqual(fixture.jobsCreated, 0)
    }

    func testRecentMessagesKeepOnlyNewestTenAndIgnoreEvictedReplay() throws {
        let fixture = Fixture(.active)
        defer { fixture.model.shutdown() }
        fixture.model.speak(Message(text: "Message 1"))
        let evicted = try XCTUnwrap(fixture.model.recentMessages.first?.id)
        for index in 2...12 { fixture.model.speak(Message(text: "Message \(index)")) }
        XCTAssertEqual(fixture.model.recentMessages.map(\.message.text), (3...12).reversed().map { "Message \($0)" })
        XCTAssertEqual(Set(fixture.model.recentMessages.map(\.id)).count, 10)
        let current = fixture.model.playback.id
        fixture.model.replay(evicted)
        XCTAssertEqual(fixture.model.playback.id, current)
        XCTAssertTrue(fixture.defaults.saved.isEmpty)
        let restarted = Fixture(.active)
        XCTAssertTrue(restarted.model.recentMessages.isEmpty)
        restarted.model.shutdown()
    }

    func testReplayRetainsMessageUsesCurrentSettingsAndDoesNotDuplicateHistory() throws {
        let fixture = Fixture(.active)
        defer { fixture.model.shutdown() }
        let message = Message(text: "Original text", source: "Pi", title: "Herdr 1:3",
                              sourceContext: SourceContext(kind: "herdr", workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1"))
        fixture.model.speak(message)
        let entry = try XCTUnwrap(fixture.model.recentMessages.first)
        fixture.model.speak(Message(text: "Newest"))
        let ids = fixture.model.recentMessages.map(\.id)
        fixture.monitor.activity = .inactive
        fixture.model.settings = VoiceSettings(voice: .alan, speed: 1.25, pause: 0.2, rhythm: 0.5)
        fixture.model.replay(entry.id)
        XCTAssertEqual(fixture.model.presentationMessage, message)
        XCTAssertNotEqual(fixture.model.playback.id, entry.id)
        XCTAssertEqual(fixture.model.recentMessages.map(\.id), ids)
        XCTAssertEqual(fixture.profiles, [fixture.model.settings])
        XCTAssertEqual(fixture.job.text, message.text)
        XCTAssertEqual(fixture.model.playback.phase, .preparing)
    }

    func testReplayObeysActiveUnknownAndManualQuietPolicy() throws {
        for activity in [InputActivity.active, .unknown, .inactive] {
            let fixture = Fixture(.active)
            fixture.model.speak(Message(text: "Again"))
            let entry = try XCTUnwrap(fixture.model.recentMessages.first)
            fixture.monitor.activity = activity
            fixture.model.meetingMode = activity == .inactive
            fixture.model.replay(entry.id)
            XCTAssertEqual(fixture.model.playback.phase, .notifying)
            XCTAssertTrue(fixture.model.silentPresentation)
            XCTAssertEqual(fixture.jobsCreated, 0)
            XCTAssertEqual(fixture.player.plays, 0)
            fixture.model.shutdown()
        }
    }

    func testReplayingQuestionOnlyTextCancelsOnceWithoutRevivingAnswers() throws {
        let fixture = Fixture(.active)
        defer { fixture.model.shutdown() }
        let question = try Question.decode(Data(#"{"question":"Continue?","answers":[{"id":"yes","label":"Yes"},{"id":"no","label":"No"}],"default_answer_id":"no"}"#.utf8))
        var replies: [Reply] = []
        let end = fixture.model.handle(.ask(question)) { replies.append($0) }
        let entry = try XCTUnwrap(fixture.model.recentMessages.first)
        let questionID = try XCTUnwrap(fixture.model.playback.id)
        fixture.model.replay(entry.id)
        fixture.model.chooseAnswer("yes", questionID: questionID)
        end?(.timedOut)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].body["reason"], "replaced")
        XCTAssertNil(replies[0].body["answer_id"])
        XCTAssertNil(fixture.model.pendingQuestion)
        XCTAssertFalse(fixture.model.presentationIsQuestion)
        XCTAssertEqual(fixture.model.presentationMessage, question.message)
        XCTAssertEqual(fixture.model.playback.phase, .notifying)
        XCTAssertEqual(fixture.model.recentMessages.count, 1)
    }

    private func drainPresentation() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testActiveUnknownAndManualModeDeliverQuietlyWithoutSynthesis() {
        for activity in [InputActivity.active, .unknown, .inactive] {
            let fixture = Fixture(activity)
            if activity == .inactive { fixture.model.meetingMode = true }
            let reply = fixture.model.speak(Message(text: "Ready"))
            XCTAssertEqual(reply.status, 202)
            XCTAssertEqual(fixture.model.playback.phase, .notifying)
            XCTAssertTrue(fixture.model.silentPresentation)
            XCTAssertEqual(fixture.jobsCreated, 0)
            fixture.monitor.emit(.inactive)
            fixture.model.meetingMode = false
            XCTAssertEqual(fixture.model.playback.phase, .notifying)
            XCTAssertEqual(fixture.jobsCreated, 0)
            fixture.model.stop()
            XCTAssertEqual(fixture.model.playback.phase, .idle)
        }
    }

    func testSilentAskCanAnswerOrExpireExactlyOnce() throws {
        let question = try Question.decode(Data(#"{"question":"Continue?","answers":[{"id":"yes","label":"Yes"},{"id":"no","label":"No"}],"default_answer_id":"no","timeout_seconds":10}"#.utf8))
        let fixture = Fixture(.active)
        var replies: [Reply] = []
        let end = fixture.model.handle(.ask(question)) { replies.append($0) }
        let id = try XCTUnwrap(fixture.model.playback.id)
        XCTAssertEqual(fixture.model.playback.phase, .choosing)
        fixture.model.chooseAnswer("yes", questionID: id)
        end?(.timedOut)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.body["answer_id"], "yes")
        XCTAssertNil(replies.first?.body["reason"])
        let expire = fixture.model.handle(.ask(question)) { replies.append($0) }
        expire?(.timedOut); expire?(.timedOut)
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies.last?.body["answer_id"], "no")
        XCTAssertEqual(replies.last?.body["reason"], "timeout")
        XCTAssertEqual(fixture.model.playback.phase, .idle)
        XCTAssertEqual(fixture.jobsCreated, 0)
    }

    func testInputChangeDuringSynthesisCancelsAndRejectsLateCompletion() async {
        let fixture = Fixture(.inactive)
        fixture.model.speak(Message(text: "Ready"))
        XCTAssertEqual(fixture.jobsCreated, 1)
        fixture.monitor.emit(.active)
        XCTAssertTrue(fixture.job.cancelled)
        fixture.job.finish()
        await Task.yield()
        XCTAssertEqual(fixture.loads, 0)
        XCTAssertEqual(fixture.player.plays, 0)
        XCTAssertEqual(fixture.model.playback.phase, .notifying)
        fixture.model.shutdown()
    }

    func testFreshPostSynthesisCheckBlocksBeforePlay() async {
        let fixture = Fixture(.inactive)
        fixture.model.speak(Message(text: "Ready"))
        fixture.monitor.activity = .active // No notification: the mandatory fresh check must catch this.
        fixture.job.finish()
        await fixture.loaded()
        XCTAssertEqual(fixture.player.plays, 0)
        XCTAssertEqual(fixture.model.playback.phase, .notifying)
        fixture.model.shutdown()
    }

    func testPlayingStopsOnUnknownOrOverrideAndNeverResumes() async {
        for manual in [false, true] {
            let fixture = Fixture(.inactive)
            fixture.model.speak(Message(text: "Ready"))
            fixture.job.finish()
            await fixture.loaded()
            XCTAssertEqual(fixture.player.plays, 1)
            XCTAssertEqual(fixture.model.playback.phase, .speaking)
            if manual { fixture.model.meetingMode = true } else { fixture.monitor.emit(.unknown) }
            XCTAssertGreaterThan(fixture.player.stops, 0)
            XCTAssertEqual(fixture.model.playback.phase, .notifying)
            fixture.monitor.emit(.inactive); fixture.model.meetingMode = false
            XCTAssertEqual(fixture.player.plays, 1)
            XCTAssertEqual(fixture.jobsCreated, 1)
            fixture.model.shutdown()
            XCTAssertTrue(fixture.monitor.stopped)
        }
    }

    func testReplacementRejectsOldPreparationAndPreservesSettings() async {
        let fixture = Fixture(.inactive)
        fixture.model.speak(Message(text: "Old"))
        fixture.job.finish()
        fixture.model.meetingMode = true
        fixture.model.speak(Message(text: "New", title: "Herdr 1:3"))
        let current = fixture.model.playback.id
        await Task.yield()
        XCTAssertEqual(fixture.model.playback.id, current)
        XCTAssertEqual(fixture.model.presentationMessage?.text, "New")
        XCTAssertEqual(fixture.player.plays, 0)
        XCTAssertEqual(fixture.defaults.saved.keys.sorted(), ["meetingMode"])
        fixture.model.shutdown()
    }
}

@MainActor
private final class Fixture {
    let monitor: FakeInput
    let job = FakeJob(), player = FakePlayer(), defaults = MemoryDefaults()
    var jobsCreated = 0, loads = 0
    var profiles: [VoiceSettings] = []
    private var loadDone: XCTestExpectation?
    lazy var model = OrbModel(inputMonitor: monitor, defaults: defaults, makeJob: { [unowned self] settings in
        jobsCreated += 1; profiles.append(settings); return job
    }, loadAudio: { [unowned self] _ in
        loads += 1
        defer { loadDone?.fulfill() }
        return (Data(), AudioEnvelope(samples: [], sampleRate: 22050))
    }, makePlayer: { [unowned self] _ in player })
    init(_ activity: InputActivity) { monitor = FakeInput(activity) }
    func loaded() async {
        let done = XCTestExpectation(description: "audio boundary returned")
        loadDone = done
        let result = await XCTWaiter.fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(result, .completed)
        await Task.yield()
    }
}

@MainActor
private final class FakeInput: InputActivityMonitoring {
    var activity: InputActivity
    var onChange: ((InputActivity) -> Void)?
    var stopped = false
    init(_ activity: InputActivity) { self.activity = activity }
    func refresh() -> InputActivity { activity }
    func emit(_ next: InputActivity) { activity = next; onChange?(next) }
    func stop() { stopped = true; onChange = nil }
}
private final class FakeJob: SpeechJob {
    var cancelled = false
    var text: String?
    var completion: ((Result<URL, Error>) -> Void)?
    func start(text: String, completion: @escaping (Result<URL, Error>) -> Void) throws {
        self.text = text; self.completion = completion
    }
    func cancel() { cancelled = true }
    func finish() { completion?(.success(URL(fileURLWithPath: "/not-read.wav"))) }
}
private final class FakePlayer: SpeechPlayer {
    var currentTime: TimeInterval = 0
    var delegate: AVAudioPlayerDelegate?
    var plays = 0, stops = 0
    func prepareToPlay() -> Bool { true }
    func play() -> Bool { plays += 1; return true }
    func stop() { stops += 1 }
}
private final class MemoryDefaults: UserDefaults {
    var saved: [String: Any] = [:]
    override func data(forKey: String) -> Data? { nil }
    override func bool(forKey: String) -> Bool { false }
    override func set(_ value: Any?, forKey key: String) { saved[key] = value }
}
