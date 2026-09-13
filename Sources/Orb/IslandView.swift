import SwiftUI
import TalkerCore

enum ClosingMotion {
    static let duration = 0.36
    static let leadFraction = 0.15
    static let leadIn = duration * leadFraction
    static let growth = 0.20
}

struct IslandView: View {
    @ObservedObject var model: OrbModel
    let explanations: ExplanationBubbleController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var motionClock = OrbMotionClock()
    private var motionPaused: Bool {
        OrbMotionClock.isPaused(phase: model.playback.phase, silent: model.silentPresentation, reduceMotion: reduceMotion)
    }
    private var closing: Bool { model.playback.phase == .settling || model.playback.phase == .idle }
    private var visibleQuestion: PendingQuestion? { model.playback.phase == .choosing ? model.pendingQuestion : nil }

    var body: some View {
        VStack(spacing: 0) {
            IslandSurface(model: model, progress: closing ? 1 : 0, closing: closing,
                          reduceMotion: reduceMotion, reduceTransparency: reduceTransparency,
                          motionClock: motionClock, motionPaused: motionPaused)
                .animation(reduceMotion ? .linear(duration: 0.15) : (closing
                    ? .linear(duration: ClosingMotion.duration)
                    : .spring(response: 0.44, dampingFraction: 0.86)), value: closing)
                .scaleEffect(model.presentationScale, anchor: .top)
                .frame(width: 330, height: model.islandHeight, alignment: .top)
            Group {
                if let pending = visibleQuestion {
                    AnswerDeck(question: pending.question, questionID: pending.id, explanations: explanations,
                               height: model.answerDeckHeight, showQuestion: model.silentPresentation) { answerID in
                        model.chooseAnswer(answerID, questionID: pending.id)
                    }
                    .id(pending.id)
                    .padding(.top, AnswerPresentation.gap)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: AnswerPresentation.exitDuration), value: visibleQuestion?.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "orb-island")
        .preferredColorScheme(.dark)
        .onChange(of: model.playback.id, initial: true) { _, _ in updateMotionClock() }
        .onChange(of: motionPaused) { _, _ in updateMotionClock() }
    }

    private func updateMotionClock() {
        motionClock.update(presentationID: model.playback.id, paused: motionPaused,
                           at: ProcessInfo.processInfo.systemUptime)
    }
}

private struct IslandSurface: View, Animatable {
    @ObservedObject var model: OrbModel
    var progress: Double
    let closing: Bool
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let motionClock: OrbMotionClock
    let motionPaused: Bool
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let time = min(1, max(0, progress))
        let fade = UnitCurve.easeInOut.value(at: time)
        let contractionTime = max(0, (time - ClosingMotion.leadFraction) / (1 - ClosingMotion.leadFraction))
        let push = ClosingMotion.growth * UnitCurve.easeOut.value(at: min(1, time / ClosingMotion.leadFraction))
        let pull = UnitCurve.easeIn.value(at: contractionTime)
        let contraction = reduceMotion ? (time >= 1 ? 1.0 : 0.0) : pull
        let anticipation = reduceMotion ? 1 : 1 + push * (1 - pull)
        let closedHeight = max(30, model.notchHeight)
        let width = mix(model.silentPresentation ? 330 : 440, model.collapsedWidth, contraction)
        let height = mix(model.silentPresentation ? model.islandHeight : model.notchHeight + 176, closedHeight, contraction)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: model.hasNotch ? 9 : mix(30, 15, contraction),
            bottomLeadingRadius: mix(38, 18, contraction),
            bottomTrailingRadius: mix(38, 18, contraction),
            topTrailingRadius: model.hasNotch ? 9 : mix(30, 15, contraction))

        TimelineView(.animation(minimumInterval: 1 / 60, paused: motionPaused)) { _ in
            let level = model.voiceLevel
            let elapsed = motionClock.elapsed(at: ProcessInfo.processInfo.systemUptime)
            let orbFrame = OrbMotionFrame(elapsed: model.playback.phase == .failed ? OrbMotionFrame.entranceDuration : elapsed,
                                          level: level, reduceMotion: reduceMotion)
            let lift = reduceMotion ? 0 : level.energy
            let stretch = CGSize(width: 1 + lift * 0.004, height: 1 + lift * 0.012)
            let spring: Animation? = reduceMotion ? nil : .interpolatingSpring(stiffness: 400, damping: 24)
            let surface = ZStack(alignment: .topLeading) {
                if model.silentPresentation {
                    VStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.slash").foregroundStyle(.mint.opacity(0.8))
                            Text(verbatim: model.presentationMessage?.title ?? model.presentationMessage?.source ?? "Orb")
                                .foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                        }.font(.system(size: 13, weight: .semibold))
                        if !model.presentationIsQuestion {
                            Text(verbatim: model.presentationMessage?.text ?? "").font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.9)).lineLimit(2).multilineTextAlignment(.center)
                                .help(model.presentationMessage?.text ?? "")
                        }
                    }
                    .frame(width: max(0, width - 64)).opacity(1 - fade)
                    .position(x: width / 2, y: mix(model.notchHeight + (model.presentationIsQuestion ? 22 : 44), closedHeight / 2, contraction))
                } else {
                    VoiceOrb(frame: orbFrame)
                        .frame(width: 412, height: 164)
                        .scaleEffect(mix(1, 0.14, contraction)).opacity(1 - fade)
                        .position(x: width / 2, y: mix(model.notchHeight + 88, closedHeight / 2, contraction))
                    if let title = model.presentationMessage?.title {
                        Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                            .frame(width: max(0, width - 72)).scaleEffect(1 / model.islandScale)
                            .opacity(1 - fade).position(x: width / 2, y: height - 16)
                    }
                }

                Button(action: model.stop) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(QuietButton())
                .scaleEffect(1 / model.presentationScale)
                .opacity(1 - UnitCurve.easeOut.value(at: min(1, time / 0.4)))
                .position(x: width - 32, y: model.notchHeight + 22)
                .allowsHitTesting(!closing && time < 0.5)
                .accessibilityLabel(model.playback.phase == .choosing ? "Dismiss question" : "Stop speaking and close Orb")
                .help(model.playback.phase == .choosing ? "Dismiss question" : "Stop speaking")
            }
            .frame(width: width, height: height)
            .background(reduceTransparency ? Color.black : Color(red: 0.019, green: 0.023, blue: 0.035))
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity((1 - contraction) * 0.09), lineWidth: 0.5)
                .mask(Rectangle().padding(.top, 1)))
            .scaleEffect(anticipation, anchor: .top)

            surface.animation(spring) { $0.scaleEffect(stretch, anchor: .top) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Orb. \(model.statusLabel)")
            .accessibilityValue(model.errorMessage ?? model.playback.message?.text ?? "")
            .accessibilityHidden(closing)
        }
    }

    private func mix(_ from: CGFloat, _ to: CGFloat, _ progress: Double) -> CGFloat {
        from + (to - from) * CGFloat(progress)
    }
}

private struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.1 : 0.035)).padding(6))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
