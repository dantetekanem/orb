import AppKit
import AVFoundation
import Combine
import TalkerCore

struct PanelPresentation: Equatable {
    let expanded: Bool
    let question: Question?
    let questionID: UUID?
    let silent: Bool
}

struct RecentMessage: Identifiable {
    let id: UUID
    let message: Message
}

@MainActor
final class OrbModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playback = Playback()
    @Published private(set) var presentationMessage: Message?
    @Published private(set) var pendingQuestion: PendingQuestion?
    @Published private(set) var errorMessage: String?
    @Published var apiState = "API starting"
    @Published var notchHeight: CGFloat = 32
    @Published var collapsedWidth: CGFloat = 190
    @Published var hasNotch = true
    @Published var answerDeckHeight: CGFloat = 0
    @Published var settings: VoiceSettings {
        didSet { defaults.set(settings.data, forKey: "voiceSettings") }
    }
    @Published var meetingMode: Bool {
        didSet { defaults.set(meetingMode, forKey: "meetingMode"); enforceQuiet() }
    }
    @Published private(set) var inputActivity: InputActivity
    @Published private(set) var silentPresentation = false
    private(set) var presentationIsQuestion = false
    private(set) var recentMessages: [RecentMessage] = []
    private let defaults: UserDefaults
    private let inputMonitor: InputActivityMonitoring
    private let makeJob: (VoiceSettings) throws -> SpeechJob
    private let loadAudio: (URL) async throws -> (Data, AudioEnvelope)
    private let makePlayer: (Data) throws -> SpeechPlayer
    private var inputScan: Timer?
    private var activeSettings = VoiceSettings()
    private var job: SpeechJob?
    private var player: SpeechPlayer?
    private var envelope = AudioEnvelope(samples: [], sampleRate: 22050)
    private var preparation: Task<Void, Never>?
    let runtime: URL

    init(inputMonitor: InputActivityMonitoring? = nil, defaults: UserDefaults = .standard,
         makeJob: ((VoiceSettings) throws -> SpeechJob)? = nil,
         loadAudio: @escaping (URL) async throws -> (Data, AudioEnvelope) = SpeechAudio.load,
         makePlayer: @escaping (Data) throws -> SpeechPlayer = { try AVAudioPlayer(data: $0) }) {
        self.defaults = defaults
        self.inputMonitor = inputMonitor ?? InputActivityMonitor()
        _inputActivity = Published(initialValue: self.inputMonitor.activity)
        _meetingMode = Published(initialValue: defaults.bool(forKey: "meetingMode"))
        _settings = Published(initialValue: VoiceSettings.load(defaults.data(forKey: "voiceSettings")))
        if let path = ProcessInfo.processInfo.environment["ORB_RUNTIME"] {
            runtime = URL(fileURLWithPath: path)
        } else if Bundle.main.bundleURL.pathExtension == "app" {
            runtime = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".runtime")
        } else {
            runtime = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".runtime")
        }
        let runtime = self.runtime
        self.makeJob = makeJob ?? { settings in
            let executable = runtime.appendingPathComponent("venv/bin/piper")
            guard FileManager.default.isExecutableFile(atPath: executable.path), settings.voice.isAvailable(in: runtime) else {
                throw APIError(503, "The selected voice is missing. Run the voice setup from the Orb folder.")
            }
            return PiperJob(executable: executable, model: settings.voice.modelURL(in: runtime), settings: settings)
        }
        self.loadAudio = loadAudio; self.makePlayer = makePlayer
        super.init()
        self.inputMonitor.onChange = { [weak self] activity in
            self?.inputActivity = activity
            self?.enforceQuiet()
        }
    }

    let islandScale: CGFloat = 0.75
    var islandHeight: CGFloat { presentationHeight(silent: silentPresentation) }
    var presentationScale: CGFloat { silentPresentation ? 1 : islandScale }
    func presentationHeight(silent: Bool) -> CGFloat {
        silent ? notchHeight + (presentationIsQuestion ? 44 : 92) : (notchHeight + 176) * islandScale
    }
    var expanded: Bool { playback.phase != .idle }
    var panelPresentation: AnyPublisher<PanelPresentation, Never> {
        $playback.combineLatest($pendingQuestion, $silentPresentation)
            // Read committed state after @Published completes; never replay stale queued window updates.
            .receive(on: DispatchQueue.main)
            .compactMap { [weak self] _ -> PanelPresentation? in
                guard let self else { return nil }
                let choosing = self.playback.phase == .choosing
                return PanelPresentation(expanded: self.expanded, question: self.readyQuestion,
                                         questionID: choosing ? self.pendingQuestion?.id : nil, silent: self.silentPresentation)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    var readyQuestion: Question? { playback.phase == .choosing ? pendingQuestion?.question : nil }
    var voiceLevel: VoiceLevel {
        guard let player, playback.phase == .speaking else { return .quiet }
        return envelope.level(at: player.currentTime)
    }
    var statusLabel: String {
        switch playback.phase {
        case .idle: "Ready"
        case .preparing: "Preparing voice"
        case .speaking: "Speaking"
        case .choosing: "Waiting for your answer"
        case .notifying: "Silent notice"
        case .settling: "Finished"
        case .failed: "Voice unavailable"
        }
    }

    func handle(_ command: Command, reply: @escaping (Reply) -> Void) -> ((RequestEnd) -> Void)? {
        switch command {
        case .status:
            let profile = expanded ? activeSettings : settings.validated
            var body = ["state": playback.phase.rawValue, "voice": profile.voice.label,
                        "speed": String(profile.speed), "pause": String(profile.pause), "rhythm": String(profile.rhythm),
                        "meeting_mode": String(meetingMode), "input_activity": inputActivity.rawValue,
                        "delivery": expanded ? (silentPresentation ? "silent" : "voice") : "none"]
            if let id = playback.id { body["id"] = id.uuidString }
            if let errorMessage { body["error"] = errorMessage }
            reply(Reply(200, body))
        case .stop:
            stop()
            reply(Reply(200, ["state": "idle"]))
        case .speak(let message): reply(speak(message))
        case .ask(let question): return ask(question, reply: reply)
        }
        return nil
    }

    @discardableResult func speak(_ message: Message) -> Reply {
        stop(reason: "replaced")
        let id = playback.begin(message)
        remember(message, id: id)
        return generate(message, id: id)
    }

    func demonstrate() {
        stop(reason: "replaced")
        let message = Message(text: "Your work is ready. Take a look when you have a moment.", source: "Orb")
        _ = generate(message, id: playback.begin(message))
    }

    func replay(_ entryID: UUID) {
        guard let entry = recentMessages.first(where: { $0.id == entryID }) else { return }
        stop(reason: "replaced")
        _ = generate(entry.message, id: playback.begin(entry.message))
    }

    private func remember(_ message: Message, id: UUID) {
        recentMessages.insert(RecentMessage(id: id, message: message), at: 0)
        if recentMessages.count > 10 { recentMessages.removeLast() }
    }

    private func ask(_ question: Question, reply: @escaping (Reply) -> Void) -> (RequestEnd) -> Void {
        stop(reason: "replaced")
        let id = playback.begin(question.message)
        remember(question.message, id: id)
        pendingQuestion = PendingQuestion(id: id, question: question, completion: reply)
        _ = generate(question.message, id: id)
        return { [weak self] reason in
            guard let self, let pending = self.pendingQuestion, pending.id == id else { return }
            if case .timedOut = reason {
                let state = self.playback
                _ = self.clearPlayback()
                pending.expire(during: state)
            } else {
                pending.abandon()
                self.stop()
            }
        }
    }

    func chooseAnswer(_ answerID: String, questionID: UUID) {
        guard let pending = pendingQuestion, pending.id == questionID,
              pending.canAnswer(answerID, during: playback) else { return }
        let state = playback
        _ = clearPlayback()
        pending.answer(answerID, during: state)
    }

    private func generate(_ message: Message, id: UUID) -> Reply {
        presentationIsQuestion = pendingQuestion != nil
        presentationMessage = message
        silentPresentation = false
        activeSettings = settings.validated
        guard maySpeak(), playback.phase == .preparing else {
            presentSilently()
            return Reply(202, ["id": id.uuidString, "state": playback.phase.rawValue, "delivery": "silent"])
        }
        do {
            let next = try makeJob(activeSettings)
            job = next
            try next.start(text: message.text) { [weak self] result in
                guard let self, self.playback.id == id, self.playback.phase == .preparing else { return }
                switch result {
                case .success(let url): self.prepare(url, id: id)
                case .failure: self.fail(id, "Could not generate speech. Check the local voice runtime.")
                }
            }
        } catch {
            fail(id, (error as? APIError)?.reason ?? "Could not start the local voice runtime.")
            return Reply(503, ["error": "Voice runtime could not start"])
        }
        return Reply(202, ["id": id.uuidString, "state": "preparing", "delivery": "voice"])
    }

    private func prepare(_ url: URL, id: UUID) {
        let loadAudio = self.loadAudio
        preparation = Task { [weak self] in
            do {
                let (data, envelope) = try await loadAudio(url)
                guard let self, !Task.isCancelled, self.playback.id == id, self.playback.phase == .preparing else { return }
                let player = try self.makePlayer(data)
                player.delegate = self
                self.player = player
                self.envelope = envelope
                self.job?.cancel(); self.job = nil
                guard player.prepareToPlay() else { throw APIError(500, "Audio output unavailable") }
                guard self.maySpeak(), self.playback.id == id, self.playback.phase == .preparing else {
                    self.presentSilently(); return
                }
                guard player.play() else { throw APIError(500, "Audio output unavailable") }
                self.playback.started(id)
                self.inputScan = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.playback.phase == .speaking else { return }
                        if !self.maySpeak() { self.presentSilently() }
                    }
                }
            } catch {
                guard let self, !Task.isCancelled, self.playback.id == id else { return }
                self.fail(id, "Could not play the voice. Check your Mac’s audio output.")
            }
        }
    }

    private func maySpeak() -> Bool {
        guard !meetingMode else { return false }
        inputActivity = inputMonitor.refresh()
        return inputActivity == .inactive
    }

    private func enforceQuiet() {
        if meetingMode || inputActivity != .inactive { presentSilently() }
    }

    private func presentSilently() {
        guard let id = playback.id, playback.phase == .preparing || playback.phase == .speaking else { return }
        silentPresentation = true
        playback.notify(id, awaitingAnswer: pendingQuestion?.id == id)
        cancelAudio()
        if pendingQuestion == nil { dismissLater(id, delay: 5) }
    }

    func stop() { stop(reason: "stopped") }
    func shutdown() { stop(); inputMonitor.stop() }

    private func stop(reason: String) { clearPlayback()?.cancel(reason: reason) }

    private func cancelAudio() {
        inputScan?.invalidate(); inputScan = nil
        preparation?.cancel(); preparation = nil
        player?.stop(); player = nil
        job?.cancel(); job = nil
    }

    private func clearPlayback() -> PendingQuestion? {
        cancelAudio()
        errorMessage = nil
        let pending = pendingQuestion
        playback.stop()
        pendingQuestion = nil
        return pending
    }

    private func fail(_ id: UUID, _ reason: String) {
        guard playback.id == id else { return }
        cancelAudio()
        errorMessage = reason
        playback.fail(id)
        let pending = pendingQuestion
        pendingQuestion = nil
        dismissLater(id, delay: 5)
        pending?.fail(reason)
    }

    private func dismissLater(_ id: UUID, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.playback.dismiss(id) }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, let id = self.playback.id else { return }
            self.player = nil
            self.inputScan?.invalidate(); self.inputScan = nil
            if flag {
                let waiting = self.pendingQuestion?.id == id
                self.playback.finished(id, awaitingAnswer: waiting)
                if !waiting { self.dismissLater(id, delay: ClosingMotion.leadIn) }
            } else { self.fail(id, "Audio playback was interrupted.") }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player, let id = self.playback.id else { return }
            self.fail(id, "Could not decode the voice audio.")
        }
    }
}
