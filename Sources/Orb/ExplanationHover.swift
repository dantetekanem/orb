import Foundation

struct ExplanationKey: Hashable {
    let questionID: UUID
    let answerID: String
}

@MainActor
final class ExplanationHover {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void
    private(set) var current: ExplanationKey?
    private var questionID: UUID?
    private var approaching: ExplanationKey?
    private var revision = 0
    private var cancelHide: (() -> Void)?
    private let schedule: Schedule
    private let hide: () -> Void

    init(schedule: @escaping Schedule = { delay, action in
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }, hide: @escaping () -> Void) {
        self.schedule = schedule; self.hide = hide
    }

    func setQuestion(_ id: UUID?) {
        guard questionID != id else { return }
        questionID = id
        clear()
    }

    @discardableResult func enter(_ key: ExplanationKey) -> Bool {
        guard questionID == key.questionID else { return false }
        cancelPendingHide()
        current = key
        return true
    }

    func approach(_ key: ExplanationKey, show: @escaping (Bool) -> Void) {
        guard questionID == key.questionID else { return }
        let retained = current == key
        if current == nil || retained { _ = enter(key); show(retained); return }
        cancelPendingHide()
        approaching = key
        let expected = revision
        cancelHide = schedule(0.24) { [weak self] in
            guard let self, self.revision == expected, self.enter(key) else { return }
            show(false)
        }
    }

    func leave(_ key: ExplanationKey) {
        guard current == key || approaching == key else { return }
        cancelPendingHide()
        guard let key = current else { return }
        let expected = revision
        cancelHide = schedule(0.16) { [weak self] in
            guard let self, self.revision == expected, self.current == key else { return }
            self.clear(key)
        }
    }

    func bubbleHover(_ inside: Bool) {
        guard let current else { return }
        if inside { cancelPendingHide() } else { leave(current) }
    }

    func clear(_ key: ExplanationKey? = nil) {
        guard key == nil || key == current else {
            if key == approaching { cancelPendingHide() }
            return
        }
        cancelPendingHide()
        let wasVisible = current != nil
        current = nil
        if wasVisible { hide() }
    }

    private func cancelPendingHide() {
        revision += 1
        approaching = nil
        cancelHide?(); cancelHide = nil
    }

    deinit { cancelHide?() }
}

struct ExplanationPlacement {
    let frame: CGRect
    let pointsLeft: Bool
    let arrowY: CGFloat

    static func screenAnchor(card: CGRect, in window: CGRect, sideInset: CGFloat) -> CGRect {
        CGRect(x: window.minX + sideInset, y: window.maxY - card.maxY,
               width: window.width - sideInset * 2, height: card.height)
    }

    static func make(anchor: CGRect, screen: CGRect, contentHeight: CGFloat) -> Self? {
        let bounds = screen.insetBy(dx: 8, dy: 8)
        let right = bounds.maxX - anchor.maxX - 4
        let left = anchor.minX - bounds.minX - 4
        let pointsLeft = right >= 200 || right >= left
        let width = min(304, pointsLeft ? right : left)
        guard width >= 180, bounds.height >= 80, anchor.intersects(screen) else { return nil }
        let height = min(max(80, contentHeight), min(320, bounds.height))
        let x = pointsLeft ? anchor.maxX + 4 : anchor.minX - width - 4
        let y = max(bounds.minY, min(anchor.midY + 32 - height, bounds.maxY - height))
        let frame = CGRect(x: x, y: y, width: width, height: height)
        return Self(frame: frame, pointsLeft: pointsLeft, arrowY: max(24, min(height - 24, frame.maxY - anchor.midY)))
    }
}
