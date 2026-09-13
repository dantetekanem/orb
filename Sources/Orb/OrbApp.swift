import AppKit
import SwiftUI
import Combine
import TalkerCore

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = OrbModel()
    private let server = LocalServer()
    private let explanations = ExplanationBubbleController()
    private var panel: IslandPanel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var observations: Set<AnyCancellable> = []
    private var pendingHide: DispatchWorkItem?
    private var pendingResize: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: IslandView(model: model, explanations: explanations))
        positionPanel(question: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Orb")
        let menu = NSMenu()
        let apiItem = NSMenuItem(title: model.apiState, action: nil, keyEquivalent: "")
        menu.addItem(apiItem)
        menu.addItem(.separator())
        let demo = NSMenuItem(title: "Try Orb", action: #selector(demonstrate), keyEquivalent: "")
        demo.target = self; menu.addItem(demo)
        let recent = NSMenuItem(title: "Recent messages", action: nil, keyEquivalent: "")
        let history = NSMenu(title: recent.title)
        history.delegate = self
        recent.submenu = history
        menu.addItem(recent)
        let stop = NSMenuItem(title: "Stop speaking", action: #selector(stopSpeaking), keyEquivalent: "")
        stop.target = self; menu.addItem(stop)
        let meeting = NSMenuItem(title: "Meeting mode · silent", action: #selector(toggleMeetingMode), keyEquivalent: "")
        meeting.target = self
        let silentToggle = NSButton(checkboxWithTitle: meeting.title, target: self, action: #selector(toggleMeetingMode))
        silentToggle.controlSize = .small
        silentToggle.font = .menuFont(ofSize: 0)
        silentToggle.frame = NSRect(x: 12, y: 4, width: 220, height: 22)
        silentToggle.autoresizingMask = [.width]
        let toggleRow = NSView(frame: NSRect(x: 0, y: 0, width: 244, height: 30))
        toggleRow.addSubview(silentToggle)
        meeting.view = toggleRow
        menu.addItem(meeting)
        model.$meetingMode.sink { silentToggle.state = $0 ? .on : .off }.store(in: &observations)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Orb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu

        model.$apiState.combineLatest(model.$playback).sink { apiState, playback in
            apiItem.title = playback.phase == .failed ? "Voice unavailable · check /status" : apiState
            stop.title = playback.phase == .choosing ? "Dismiss question" : "Stop speaking"
        }.store(in: &observations)
        model.panelPresentation.sink { [weak self] state in
            self?.updatePanel(expanded: state.expanded, question: state.question, questionID: state.questionID, silent: state.silent)
        }.store(in: &observations)
        server.onState = { [weak self] in self?.model.apiState = $0 }
        do {
            try server.start { [weak self] command, reply in
                guard let self else { reply(Reply(503, ["error": "Orb is closing"])); return nil }
                return self.model.handle(command, reply: reply)
            }
        } catch { model.apiState = "API unavailable · could not listen on port 45821" }
    }

    private func updatePanel(expanded: Bool, question: Question?, questionID: UUID?, silent: Bool) {
        explanations.hover.setQuestion(questionID)
        pendingHide?.cancel(); pendingHide = nil
        pendingResize?.cancel(); pendingResize = nil
        panel.ignoresMouseEvents = !expanded
        guard expanded else {
            let hide = DispatchWorkItem { [weak self] in
                guard let self, !self.model.expanded else { return }
                self.panel.orderOut(nil)
                self.pendingHide = nil
            }
            pendingHide = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + ClosingMotion.duration + 0.05, execute: hide)
            return
        }
        if question != nil || !panel.isVisible || panel.frame.height <= model.islandHeight + max(24, model.islandHeight * CGFloat(ClosingMotion.growth) + 8) {
            positionPanel(question: question, silent: silent)
        } else {
            let resize = DispatchWorkItem { [weak self] in
                guard let self, self.model.expanded, self.model.readyQuestion == nil else { return }
                self.positionPanel(question: nil)
                self.pendingResize = nil
            }
            pendingResize = resize
            DispatchQueue.main.asyncAfter(deadline: .now() + AnswerPresentation.exitDuration + 0.03, execute: resize)
        }
        panel.orderFrontRegardless()
    }

    @objc private func screenParametersChanged() {
        explanations.hover.clear()
        positionPanel(question: model.readyQuestion)
    }

    private func positionPanel(question: Question?, silent: Bool? = nil) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
        model.hasNotch = screen.safeAreaInsets.top > 0
        model.notchHeight = model.hasNotch ? screen.safeAreaInsets.top : 8
        if model.hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.collapsedWidth = max(180, screen.frame.width - left.width - right.width + 12)
        } else { model.collapsedWidth = model.hasNotch ? 190 : 150 }
        let top = model.hasNotch ? screen.frame.maxY : screen.visibleFrame.maxY - 8
        let available = max(0, top - screen.visibleFrame.minY - 12)
        let quiet = silent ?? model.silentPresentation
        let islandHeight = model.presentationHeight(silent: quiet)
        let deckLimit = min(520, max(0, available - islandHeight - AnswerPresentation.gap - 16))
        model.answerDeckHeight = AnswerPresentation.height(question: question, limit: deckLimit, showQuestion: quiet)
        let desired = question != nil ? islandHeight + AnswerPresentation.gap + model.answerDeckHeight + 16
            : islandHeight + max(24, islandHeight * CGFloat(ClosingMotion.growth) + 8)
        let height = min(available, desired)
        let width = 330 * (1 + CGFloat(ClosingMotion.growth)) + 24
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height), display: true)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if model.recentMessages.isEmpty {
            menu.addItem(NSMenuItem(title: "No recent messages", action: nil, keyEquivalent: ""))
        }
        for entry in model.recentMessages {
            let text = entry.message.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let label = "\(entry.message.title ?? entry.message.source): \(text)"
            let item = NSMenuItem(title: String(label.prefix(64)) + (label.count > 64 ? "…" : ""),
                                  action: #selector(replayMessage(_:)), keyEquivalent: "")
            item.representedObject = entry.id
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func replayMessage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.replay(id)
    }

    @objc private func demonstrate() {
        model.speak(Message(text: "Your work is ready. Take a look when you have a moment.", source: "Orb"))
    }
    @objc private func stopSpeaking() { model.stop() }
    @objc private func toggleMeetingMode() { model.meetingMode.toggle() }
    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 540),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Orb Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingHide?.cancel()
        pendingResize?.cancel()
        explanations.shutdown()
        server.stop()
        model.shutdown()
        NotificationCenter.default.removeObserver(self)
    }
}

@main
struct OrbApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
