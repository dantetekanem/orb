import AppKit
import SwiftUI
import TalkerCore

enum AnswerPresentation {
    static let cardHeight: CGFloat = 44
    static let spacing: CGFloat = 10
    static let inset: CGFloat = 16
    static let gap: CGFloat = 20
    static let exitDuration = 0.12
    static let width: CGFloat = 352

    static func height(question: Question?, limit: CGFloat, showQuestion: Bool = false) -> CGFloat {
        guard let question else { return 0 }
        let count = question.answers.count
        var content = question.isCompact ? cardHeight : CGFloat(count) * cardHeight + CGFloat(count - 1) * spacing
        if question.isCompact || showQuestion {
            let text = (question.message.text as NSString).boundingRect(
                with: NSSize(width: width - inset * 2, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 13)])
            content += spacing + min(48, ceil(text.height) + 2)
        }
        return min(max(0, limit), content + inset * 2)
    }
}

struct AnswerDeck: View {
    let question: Question
    let questionID: UUID
    let explanations: ExplanationBubbleController
    let height: CGFloat
    var showQuestion = false
    let select: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let layout = question.isCompact ? AnyLayout(HStackLayout(spacing: AnswerPresentation.spacing))
            : AnyLayout(VStackLayout(spacing: AnswerPresentation.spacing))
        ScrollView(.vertical) {
            VStack(spacing: AnswerPresentation.spacing) {
                layout {
                    ForEach(Array(question.answers.enumerated()), id: \.element.id) { index, answer in
                        AnswerChoice(answer: answer, key: ExplanationKey(questionID: questionID, answerID: answer.id),
                                     explanations: explanations, centered: question.isCompact) { select(answer.id) }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: reduceMotion || appeared ? 0 : -8)
                        .animation(entrance(delay: question.isCompact ? 0 : Double(index) * 0.045), value: appeared)
                    }
                }
                if question.isCompact || showQuestion {
                    Text(verbatim: question.message.text).font(.system(size: 13)).lineLimit(3)
                        .help(question.message.text)
                        .foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .shadow(color: .black.opacity(0.8), radius: 3)
                        .opacity(appeared ? 1 : 0).offset(y: reduceMotion || appeared ? 0 : -8)
                        .animation(entrance(delay: question.isCompact ? 0.045 : Double(question.answers.count) * 0.045), value: appeared)
                }
            }
            .padding(AnswerPresentation.inset)
        }
        .scrollIndicators(.visible)
        .frame(width: AnswerPresentation.width, height: height)
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answer choices")
    }

    private func entrance(delay: Double) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88).delay(delay)
    }
}

private struct AnswerChoice: View {
    let answer: Question.Answer
    let key: ExplanationKey
    let explanations: ExplanationBubbleController
    let centered: Bool
    let select: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered = false
    @State private var cardFrame = CGRect.zero

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let glow = Color(red: 0.6, green: 0.95, blue: 0.87)
        Button(action: { explanations.hover.clear(key); select() }) {
            Text(verbatim: answer.label).font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.88)).lineLimit(1)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                .frame(height: AnswerPresentation.cardHeight)
                .background {
                    if reduceTransparency { Color(red: 0.04, green: 0.045, blue: 0.06) }
                    else { CardGlass().allowsHitTesting(false) }
                }
                .clipShape(shape)
                .overlay(shape.fill(glow.opacity(hovered ? 0.18 : 0)).allowsHitTesting(false))
                .overlay(shape.strokeBorder(hovered ? glow.opacity(0.65) : .white.opacity(0.12), lineWidth: 0.5).allowsHitTesting(false))
                .shadow(color: glow.opacity(hovered ? 0.25 : 0), radius: 6)
                .contentShape(shape)
        }
        .buttonStyle(AnswerPressStyle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("orb-island")) } action: { frame in
            cardFrame = frame
            explanations.hover.clear(key)
        }
        .background(ExplanationAnchor(changed: { view, inside in
            if inside { explanations.show(answer, key: key, anchor: view, card: cardFrame) }
            else { explanations.hover.leave(key) }
        }, removed: { explanations.hover.clear(key) }))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.18), value: hovered)
        .accessibilityLabel("Choose \(answer.label)")
        .accessibilityHint([answer.summary, answer.detail].filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }
}

struct CardGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct AnswerPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.04 : 0))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
