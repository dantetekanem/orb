import AppKit
import SwiftUI
import TalkerCore

@MainActor
final class ExplanationBubbleController {
    lazy var hover = ExplanationHover { [weak self] in self?.hide() }
    private var panel: IslandPanel?

    func show(_ answer: Question.Answer, key: ExplanationKey, anchor: NSView, card: CGRect) {
        guard !card.isEmpty else { return }
        hover.approach(key) { [weak self, weak anchor] retained in
            guard let self, let anchor else { return }
            self.present(answer, key: key, anchor: anchor, card: card, retained: retained)
        }
    }

    private func present(_ answer: Question.Answer, key: ExplanationKey, anchor: NSView, card: CGRect, retained: Bool) {
        guard hover.current == key, let parent = anchor.window, parent.isVisible, let screen = parent.screen else { return }
        guard !answer.summary.isEmpty || !answer.detail.isEmpty else { hover.clear(key); return }
        // Use rendered SwiftUI bounds; keep the compact sibling outside the bubble.
        let sideInset = (parent.frame.width - AnswerPresentation.width) / 2 + AnswerPresentation.inset
        let rect = ExplanationPlacement.screenAnchor(card: card, in: parent.frame, sideInset: sideInset)
        guard let proposed = ExplanationPlacement.make(anchor: rect, screen: screen.visibleFrame, contentHeight: 320) else {
            hover.clear(key); return
        }
        let text = [answer.label, answer.summary, answer.detail].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let height = (text as NSString).boundingRect(with: NSSize(width: proposed.frame.width - 58, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 13)]).height + 62
        guard let placement = ExplanationPlacement.make(anchor: rect, screen: screen.visibleFrame, contentHeight: height) else {
            hover.clear(key); return
        }
        let panel = self.panel ?? makePanel()
        if !retained || !panel.isVisible {
            panel.contentView = NSHostingView(rootView: ExplanationBubbleView(answer: answer, placement: placement) { [weak self] in
                self?.hover.bubbleHover($0)
            })
            panel.setFrame(placement.frame, display: true)
        }
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func shutdown() {
        hover.setQuestion(nil)
        panel?.orderOut(nil)
        if let panel { panel.parent?.removeChildWindow(panel) }
    }

    private func makePanel() -> IslandPanel {
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isMovable = false; panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.acceptsMouseMovedEvents = true
        panel.title = "Answer explanation"
        self.panel = panel
        return panel
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, self.hover.current == nil, let panel else { return }
                panel.orderOut(nil)
                panel.parent?.removeChildWindow(panel)
            }
        }
    }
}

struct ExplanationAnchor: NSViewRepresentable {
    let changed: (NSView, Bool) -> Void
    var removed: () -> Void = {}
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.changed = changed; view.removed = removed }
    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { view.removed(); view.changed = nil }

    final class TrackingView: NSView {
        var changed: ((NSView, Bool) -> Void)?
        var removed: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) { changed?(self, true) }
        override func mouseExited(with event: NSEvent) { changed?(self, false) }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { removed() } }
    }
}

private struct ExplanationBubbleView: View {
    let answer: Question.Answer
    let placement: ExplanationPlacement
    let hovered: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var appeared = false

    var body: some View {
        let shape = BubbleShape(pointsLeft: placement.pointsLeft, arrowY: placement.arrowY - 8)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: answer.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                if !answer.summary.isEmpty { Text(verbatim: answer.summary).foregroundStyle(.white.opacity(0.9)) }
                if !answer.detail.isEmpty { Text(verbatim: answer.detail).foregroundStyle(.white.opacity(0.8)) }
            }
            .font(.system(size: 13)).lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .scrollIndicators(.visible)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom).frame(height: 8)
                Rectangle()
                LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom).frame(height: 8)
            }
        }
        .padding(.vertical, 12)
        .padding(placement.pointsLeft ? .leading : .trailing, 10)
        .background {
            if reduceTransparency { Color(red: 0.04, green: 0.045, blue: 0.06) }
            else { CardGlass().overlay(.black.opacity(0.32)).allowsHitTesting(false) }
        }
        .clipShape(shape)
        .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 0.5).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.25), radius: 5)
        .padding(8)
        .background(ExplanationAnchor(changed: { _, inside in hovered(inside) }))
        .scaleEffect(reduceMotion || appeared ? 1 : 0.97, anchor: placement.pointsLeft ? .leading : .trailing)
        .offset(x: reduceMotion || appeared ? 0 : (placement.pointsLeft ? -4 : 4))
        .onAppear { withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.9)) { appeared = true } }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain).accessibilityLabel("Answer explanation")
    }
}

private struct BubbleShape: Shape {
    let pointsLeft: Bool
    let arrowY: CGFloat
    func path(in rect: CGRect) -> Path {
        let x: CGFloat = 10, r: CGFloat = 16, w = rect.width, h = rect.height
        let y = max(24, min(h - 24, arrowY))
        var path = Path()
        path.move(to: CGPoint(x: x + r, y: 0))
        path.addLine(to: CGPoint(x: w - r, y: 0)); path.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: h - r)); path.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: x + r, y: h)); path.addQuadCurve(to: CGPoint(x: x, y: h - r), control: CGPoint(x: x, y: h))
        path.addLine(to: CGPoint(x: x, y: y + 7)); path.addLine(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: x, y: y - 7))
        path.addLine(to: CGPoint(x: x, y: r)); path.addQuadCurve(to: CGPoint(x: x + r, y: 0), control: CGPoint(x: x, y: 0))
        path.closeSubpath()
        return pointsLeft ? path : path.applying(CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1))
    }
}
