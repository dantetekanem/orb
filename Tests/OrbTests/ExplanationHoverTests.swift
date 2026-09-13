import XCTest
@testable import Orb

@MainActor
final class ExplanationHoverTests: XCTestCase {
    func testHoverCanCrossIntoBubbleAndLeaveWithoutAnOldDeadlineClosingIt() {
        let clock = Clock()
        var hides = 0
        let hover = ExplanationHover(schedule: clock.schedule) { hides += 1 }
        let key = ExplanationKey(questionID: UUID(), answerID: "yes")
        hover.setQuestion(key.questionID)
        XCTAssertTrue(hover.enter(key))
        hover.leave(key)
        XCTAssertEqual(clock.delays, [0.16])
        hover.bubbleHover(true)
        clock.fire(0) // Deliberately deliver a cancelled callback.
        XCTAssertEqual(hover.current, key)
        XCTAssertEqual(hides, 0)
        hover.bubbleHover(false)
        clock.fire(1); clock.fire(1)
        XCTAssertNil(hover.current)
        XCTAssertEqual(hides, 1)
    }

    func testSwitchingAnswersRejectsDepartingAnchorAndDelayedCallbacks() {
        let clock = Clock()
        var hides = 0
        let hover = ExplanationHover(schedule: clock.schedule) { hides += 1 }
        let questionID = UUID()
        let first = ExplanationKey(questionID: questionID, answerID: "a")
        let next = ExplanationKey(questionID: questionID, answerID: "b")
        hover.setQuestion(questionID)
        XCTAssertTrue(hover.enter(first))
        hover.leave(first)
        XCTAssertTrue(hover.enter(next))
        hover.leave(first); hover.clear(first); clock.fire(0)
        XCTAssertEqual(hover.current, next)
        XCTAssertEqual(hides, 0)
        XCTAssertEqual(clock.cancellations, 1)
    }

    func testQuestionReplacementAndRemovalRejectStaleHoversIncludingReusedAnswerID() {
        let clock = Clock()
        var hides = 0
        let hover = ExplanationHover(schedule: clock.schedule) { hides += 1 }
        let old = ExplanationKey(questionID: UUID(), answerID: "yes")
        let next = ExplanationKey(questionID: UUID(), answerID: "yes")
        XCTAssertFalse(hover.enter(old))
        hover.setQuestion(old.questionID)
        XCTAssertTrue(hover.enter(old)); hover.leave(old)
        hover.setQuestion(next.questionID)
        XCTAssertNil(hover.current)
        XCTAssertFalse(hover.enter(old))
        XCTAssertTrue(hover.enter(next))
        clock.fire(0)
        XCTAssertEqual(hover.current, next)
        hover.setQuestion(nil)
        hover.bubbleHover(true)
        XCTAssertFalse(hover.enter(next))
        XCTAssertNil(hover.current)
        XCTAssertEqual(hides, 2)
    }

    func testCrossingACompactSiblingKeepsTheFirstExplanationUntilTheUserDwells() {
        let clock = Clock()
        let hover = ExplanationHover(schedule: clock.schedule) {}
        let first = ExplanationKey(questionID: UUID(), answerID: "a")
        let next = ExplanationKey(questionID: first.questionID, answerID: "b")
        var shown: [ExplanationKey] = []
        hover.setQuestion(first.questionID)
        hover.approach(first) { _ in shown.append(first) }
        hover.leave(first)
        hover.approach(next) { _ in shown.append(next) }
        hover.leave(next)
        hover.bubbleHover(true)
        clock.fire(0); clock.fire(1); clock.fire(2)
        XCTAssertEqual(hover.current, first)
        XCTAssertEqual(shown, [first])
        hover.approach(first) { retained in XCTAssertTrue(retained) }
        hover.approach(next) { retained in XCTAssertFalse(retained); shown.append(next) }
        XCTAssertEqual(clock.delays.last, 0.24)
        clock.fire(3); clock.fire(3)
        XCTAssertEqual(hover.current, next)
        XCTAssertEqual(shown, [first, next])
    }

    func testRenderedCompactCardAlignsTheArrowAndLeavesBothChoicesUncovered() throws {
        let window = CGRect(x: 674, y: 871, width: 380, height: 246)
        let anchor = ExplanationPlacement.screenAnchor(card: CGRect(x: 30, y: 112, width: 155, height: 44),
                                                       in: window, sideInset: 30)
        XCTAssertEqual(anchor, CGRect(x: 704, y: 961, width: 320, height: 44))
        let placement = try XCTUnwrap(ExplanationPlacement.make(anchor: anchor,
            screen: CGRect(x: 0, y: 0, width: 1728, height: 1085), contentHeight: 320))
        XCTAssertEqual(window.maxY - (placement.frame.maxY - placement.arrowY), 134)
        XCTAssertEqual(placement.frame.minX, 1028)
        XCTAssertEqual(placement.frame.minX + 8 - anchor.maxX, 12) // Visible tip includes its normal shadow gutter.
    }

    func testPlacementPrefersRightAndKeepsArrowAligned() throws {
        let anchor = CGRect(x: 400, y: 450, width: 320, height: 44)
        let placement = try XCTUnwrap(ExplanationPlacement.make(anchor: anchor,
            screen: CGRect(x: 0, y: 0, width: 1440, height: 900), contentHeight: 150))
        XCTAssertTrue(placement.pointsLeft)
        XCTAssertEqual(placement.frame.minX, anchor.maxX + 4)
        XCTAssertEqual(placement.frame.height, 150)
        XCTAssertEqual(placement.frame.maxY - placement.arrowY, anchor.midY)
    }

    func testEdgePlacementFlipsAndBoundsLongContentOnScreen() throws {
        let screen = CGRect(x: -1440, y: 100, width: 1440, height: 800)
        let placement = try XCTUnwrap(ExplanationPlacement.make(
            anchor: CGRect(x: -350, y: 105, width: 320, height: 44), screen: screen, contentHeight: 4000))
        XCTAssertFalse(placement.pointsLeft)
        XCTAssertTrue(screen.contains(placement.frame))
        XCTAssertLessThanOrEqual(placement.frame.height, 320)
        XCTAssertGreaterThanOrEqual(placement.arrowY, 24)
        XCTAssertLessThanOrEqual(placement.arrowY, placement.frame.height - 24)
        XCTAssertNil(ExplanationPlacement.make(anchor: CGRect(x: 0, y: 0, width: 320, height: 44),
            screen: CGRect(x: 0, y: 0, width: 340, height: 80), contentHeight: 150))
    }
}

@MainActor
private final class Clock {
    var callbacks: [() -> Void] = [], delays: [TimeInterval] = []
    var cancellations = 0
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
        delays.append(delay); callbacks.append(action)
        return { self.cancellations += 1 }
    }
    func fire(_ index: Int) { callbacks[index]() }
}
