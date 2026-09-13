import SwiftUI
import TalkerCore

private enum Light {
    static let ice = Color(red: 0.58, green: 0.85, blue: 1)
    static let mint = Color(red: 0.60, green: 0.95, blue: 0.86)
    static let iris = Color(red: 0.66, green: 0.64, blue: 1)
    static let pearl = Color(red: 0.96, green: 0.98, blue: 1)
}

struct VoiceOrb: View {
    let time: Double
    let level: VoiceLevel

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = 51.0 + level.bass * 4
            let sphere = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
            let halo = Path(ellipseIn: CGRect(x: center.x - 72, y: center.y - 72, width: 144, height: 144))
            context.fill(halo, with: .radialGradient(Gradient(stops: [
                .init(color: Light.mint.opacity(0.24 + level.energy * 0.12), location: 0),
                .init(color: Light.ice.opacity(0.13 + level.energy * 0.06), location: 0.45),
                .init(color: Light.iris.opacity(0.035), location: 0.8),
                .init(color: .clear, location: 1)
            ]), center: center, startRadius: 35, endRadius: 72))
            drawSound(in: &context, size: size, center: center)
            context.fill(sphere, with: .radialGradient(
                Gradient(stops: [.init(color: Color(red: 0.13, green: 0.27, blue: 0.36), location: 0),
                                 .init(color: Color(red: 0.035, green: 0.09, blue: 0.16), location: 0.55),
                                 .init(color: Color(red: 0.018, green: 0.025, blue: 0.065), location: 1)]),
                center: CGPoint(x: center.x - 20, y: center.y - 24), startRadius: 0, endRadius: radius * 1.5))
            context.drawLayer { layer in
                layer.clip(to: sphere)
                // A moving light field gives the ribbons a volume to live inside.
                for index in 0..<3 {
                    let phase = time * 0.38 + Double(index) * 2.1
                    let point = CGPoint(x: center.x + cos(phase) * radius * 0.48,
                                        y: center.y + sin(phase * 0.8) * radius * 0.55)
                    let color = [Light.mint, Light.iris, Light.ice][index]
                    layer.fill(sphere, with: .radialGradient(Gradient(colors: [color.opacity(0.27 + level.energy * 0.13), .clear]),
                                                            center: point, startRadius: 0, endRadius: radius * 1.3))
                }
                drawRibbons(in: &layer, center: center, radius: radius)
            }
            context.stroke(sphere, with: .linearGradient(Gradient(stops: [
                .init(color: Light.pearl.opacity(0.50), location: 0),
                .init(color: Light.ice.opacity(0.08), location: 0.35),
                .init(color: Light.iris.opacity(0.25), location: 0.8),
                .init(color: Light.mint.opacity(0.45), location: 1)
            ]), startPoint: CGPoint(x: center.x - radius, y: center.y - radius),
               endPoint: CGPoint(x: center.x + radius, y: center.y + radius)), lineWidth: 0.65)
        }
        .accessibilityHidden(true)
    }

    private func drawSound(in context: inout GraphicsContext, size: CGSize, center: CGPoint) {
        let gradient = Gradient(stops: [
            .init(color: .clear, location: 0), .init(color: Light.mint.opacity(0.65), location: 0.16),
            .init(color: Light.ice, location: 0.38), .init(color: Light.pearl, location: 0.5),
            .init(color: Light.iris, location: 0.65), .init(color: Light.ice.opacity(0.5), location: 0.85),
            .init(color: .clear, location: 1)
        ])
        let shading = GraphicsContext.Shading.linearGradient(gradient,
            startPoint: CGPoint(x: 10, y: center.y), endPoint: CGPoint(x: size.width - 10, y: center.y))
        for ribbon in 0..<7 {
            let offset = Double(ribbon) - 3
            var path = Path()
            for step in 0...160 {
                let x = Double(step) / 80 - 1
                let taper = pow(max(0, 1 - x * x), 2)
                let frequency = 9 + Double(ribbon) * 0.6 + level.air * 3
                let wave = sin(x * frequency - time * 2.6 + offset * 0.32)
                let overtone = sin(x * 18 + time * 1.4 + offset * 0.5) * level.air * 0.35
                let amplitude = 1.5 + level.energy * 21 + level.bass * 12
                let y = center.y + (wave + overtone) * amplitude * taper + offset * (1.4 + level.energy * 1.7)
                let point = CGPoint(x: center.x + x * (size.width / 2 - 12), y: y)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.drawLayer { glow in
                glow.opacity = 0.08 + level.energy * 0.13
                glow.addFilter(.blur(radius: 4))
                glow.stroke(path, with: shading, lineWidth: 4)
            }
            context.opacity = (0.20 + level.energy * 0.50) * (1 - abs(offset) * 0.12)
            context.stroke(path, with: shading, style: StrokeStyle(lineWidth: ribbon == 3 ? 1.5 : 0.75, lineCap: .round))
        }
        context.opacity = 1
    }

    private func drawRibbons(in context: inout GraphicsContext, center: CGPoint, radius: Double) {
        let tilt = 0.38 + sin(time * 0.31) * 0.2
        for ribbon in 0..<13 {
            let latitude = (Double(ribbon) - 6) * 0.12
            let ring = sqrt(1 - latitude * latitude)
            var front = Path(), back = Path()
            for step in 0...160 {
                let angle = Double(step) / 160 * .pi * 2
                let wave = sin(angle * 3 + time * 1.8 + latitude * 5) * level.energy * 0.12
                let x = cos(angle) * ring
                let y = latitude + wave
                let z = sin(angle) * ring
                let ry = y * cos(tilt) - z * sin(tilt)
                let rz = y * sin(tilt) + z * cos(tilt)
                let rotation = sin(time * 0.22) * 0.28
                let px = x * cos(rotation) - ry * sin(rotation)
                let py = x * sin(rotation) + ry * cos(rotation)
                let perspective = 1 + rz * 0.10
                let point = CGPoint(x: center.x + px * radius * perspective,
                                    y: center.y + py * radius * perspective)
                // Each semicircle stays continuous; dim back faces read as depth.
                if step <= 80 {
                    if step == 0 { front.move(to: point) } else { front.addLine(to: point) }
                } else {
                    if step == 81 { back.move(to: point) } else { back.addLine(to: point) }
                }
            }
            let colors = Gradient(colors: [Light.mint.opacity(0.2), Light.ice, Light.pearl, Light.iris.opacity(0.55)])
            let shading = GraphicsContext.Shading.linearGradient(colors,
                startPoint: CGPoint(x: center.x - radius, y: center.y + radius * 0.3),
                endPoint: CGPoint(x: center.x + radius, y: center.y - radius * 0.3))
            context.opacity = 0.10
            context.stroke(back, with: shading, lineWidth: 0.6)
            context.opacity = 0.35 + level.energy * 0.35
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 2.5))
                glow.opacity = 0.3
                glow.stroke(front, with: shading, lineWidth: 2)
            }
            context.stroke(front, with: shading, style: StrokeStyle(lineWidth: ribbon == 6 ? 1.5 : 0.75, lineCap: .round))
        }
        context.opacity = 1
    }
}
