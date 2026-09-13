import SwiftUI
import TalkerCore

private enum Light {
    static let mint = Color(red: 0.51, green: 0.96, blue: 0.80)
    static let ice = Color(red: 0.65, green: 0.87, blue: 1)
    static let iris = Color(red: 0.65, green: 0.63, blue: 1)
    static let pearl = Color(red: 0.96, green: 0.99, blue: 1)
    static let abyss = Color(red: 0.018, green: 0.035, blue: 0.065)
}

struct VoiceOrb: View {
    let frame: OrbMotionFrame

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = frame.radius * frame.coreScale
            let orbit = Orbit(center: center, radius: radius * (1.48 + (1 - frame.orbitReveal) * 0.24),
                              tilt: -0.36 + sin(frame.time * 0.31) * 0.16,
                              inclination: 0.48 + sin(frame.time * 0.43) * 0.08)
            drawAtmosphere(in: &context, center: center, size: size)
            drawSound(in: &context, size: size, center: center)
            drawOrbit(in: &context, orbit: orbit, front: false)
            drawCore(in: &context, center: center, radius: radius)
            drawOrbit(in: &context, orbit: orbit, front: true)
        }
        .accessibilityHidden(true)
    }

    private func drawAtmosphere(in context: inout GraphicsContext, center: CGPoint, size: CGSize) {
        context.drawLayer { atmosphere in
            atmosphere.translateBy(x: center.x, y: center.y)
            atmosphere.scaleBy(x: 1.65, y: 1)
            aura(in: &atmosphere, at: .zero, radius: size.height * 0.49,
                 color: Light.mint, opacity: (0.12 + frame.radiance * 0.12) * frame.coreScale)
        }
        aura(in: &context, at: center, radius: size.height * 0.49, color: Light.ice,
             opacity: (0.16 + frame.ignition * 0.28) * frame.coreScale)
        if frame.ignition > 0 {
            let radius = 16 + min(1, frame.time / OrbMotionFrame.entranceDuration) * 62
            context.opacity = frame.ignition * 0.3
            context.stroke(circle(at: center, radius: radius), with: .color(Light.mint), lineWidth: 0.8)
            context.opacity = 1
        }
        // A fixed small constellation, not a particle emitter that accumulates work.
        for index in 0..<10 {
            let seed = Double(index)
            let angle = seed * 2.39996 - frame.time * (0.07 + seed * 0.002)
            let x = cos(angle) * (89 + seed * 5)
            let y = sin(angle) * (38 + seed.truncatingRemainder(dividingBy: 3) * 9)
            let point = CGPoint(x: center.x + x, y: center.y + y)
            let shimmer = 0.5 + 0.5 * sin(frame.time * 0.8 + seed * 1.7)
            context.opacity = frame.waveReveal * (0.12 + shimmer * 0.22)
            context.fill(circle(at: point, radius: index.isMultiple(of: 3) ? 0.9 : 0.55), with: .color(Light.ice))
        }
        context.opacity = 1
    }

    private func drawCore(in context: inout GraphicsContext, center: CGPoint, radius: Double) {
        let sphere = circle(at: center, radius: radius)
        context.fill(sphere, with: .radialGradient(Gradient(stops: [
            .init(color: Color(red: 0.09, green: 0.25, blue: 0.29), location: 0),
            .init(color: Light.abyss, location: 0.65),
            .init(color: Color(red: 0.012, green: 0.019, blue: 0.045), location: 1)
        ]), center: CGPoint(x: center.x - radius * 0.32, y: center.y - radius * 0.4),
           startRadius: 0, endRadius: radius * 1.4))
        context.drawLayer { interior in
            interior.clip(to: sphere)
            interior.blendMode = .plusLighter
            for index in 0..<3 {
                let phase = -frame.time * 0.42 + Double(index) * 2.1
                let point = CGPoint(x: center.x + cos(phase) * radius * 0.48,
                                    y: center.y + sin(phase * 0.9) * radius * 0.45)
                aura(in: &interior, at: point, radius: radius * 1.2,
                     color: [Light.mint, Light.iris, Light.ice][index], opacity: 0.36 * frame.radiance)
            }
            drawFilaments(in: &interior, center: center, radius: radius)
            let heart = CGPoint(x: center.x + sin(frame.time * 0.57) * radius * 0.18,
                                y: center.y + cos(frame.time * 0.41) * radius * 0.14)
            aura(in: &interior, at: heart, radius: radius * 0.62, color: Light.mint,
                 opacity: 0.22 + frame.level.energy * 0.16 + frame.ignition * 0.12)
            aura(in: &interior, at: CGPoint(x: center.x - radius * 0.35, y: center.y - radius * 0.58),
                 radius: radius * 0.55, color: Light.pearl, opacity: 0.20)
        }
        let rim = GraphicsContext.Shading.conicGradient(Gradient(stops: [
            .init(color: Light.mint.opacity(0.8), location: 0),
            .init(color: Light.ice.opacity(0.12), location: 0.2),
            .init(color: Light.iris.opacity(0.7), location: 0.43),
            .init(color: Light.pearl.opacity(0.95), location: 0.65),
            .init(color: Light.ice.opacity(0.18), location: 0.82),
            .init(color: Light.mint.opacity(0.8), location: 1)
        ]), center: center, angle: .radians(frame.time * -0.18))
        context.drawLayer { bloom in
            bloom.addFilter(.blur(radius: 3))
            bloom.opacity = 0.45 * frame.radiance
            bloom.stroke(sphere, with: rim, lineWidth: 3)
        }
        context.stroke(sphere, with: rim, lineWidth: 1.1)
        var reflection = Path()
        reflection.addArc(center: center, radius: radius * 0.92,
                          startAngle: .degrees(214), endAngle: .degrees(268), clockwise: false)
        context.stroke(reflection, with: .color(Light.pearl.opacity(0.28)),
                       style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
    }

    private func drawFilaments(in context: inout GraphicsContext, center: CGPoint, radius: Double) {
        var front = Path(), back = Path(), bright = Path()
        let tilt = -0.5 + sin(frame.time * 0.27) * 0.18
        for ribbon in 0..<9 {
            let latitude = (Double(ribbon) - 4) * 0.18
            let ring = sqrt(1 - latitude * latitude)
            var wasFront: Bool?
            for step in 0...112 {
                let angle = Double(step) / 112 * .pi * 2
                let flow = angle * 2 + frame.time * 0.9 + latitude * 5
                let y = latitude + sin(flow) * (0.07 + frame.level.energy * 0.09)
                let rotation = angle - frame.time * 0.36
                let x = cos(rotation) * ring
                let z = sin(rotation) * ring
                let ry = y * cos(0.48) - z * sin(0.48)
                let depth = y * sin(0.48) + z * cos(0.48)
                let point = CGPoint(x: center.x + (x * cos(tilt) - ry * sin(tilt)) * radius,
                                    y: center.y + (x * sin(tilt) + ry * cos(tilt)) * radius)
                let isFront = depth >= 0
                if isFront {
                    if wasFront != true { front.move(to: point) } else { front.addLine(to: point) }
                    if ribbon == 3 || ribbon == 4 {
                        if wasFront != true { bright.move(to: point) } else { bright.addLine(to: point) }
                    }
                } else {
                    if wasFront != false { back.move(to: point) } else { back.addLine(to: point) }
                }
                wasFront = isFront
            }
        }
        let light = GraphicsContext.Shading.linearGradient(Gradient(stops: [
            .init(color: Light.mint.opacity(0.35), location: 0),
            .init(color: Light.mint, location: 0.28),
            .init(color: Light.pearl, location: 0.50),
            .init(color: Light.ice, location: 0.68),
            .init(color: Light.iris.opacity(0.6), location: 1)
        ]), startPoint: CGPoint(x: center.x - radius, y: center.y + radius * 0.7),
           endPoint: CGPoint(x: center.x + radius, y: center.y - radius * 0.7))
        context.opacity = 0.13
        context.stroke(back, with: light, lineWidth: 0.7)
        context.opacity = frame.radiance
        // One shared bloom for the whole light field rather than a blur per ribbon.
        context.drawLayer { bloom in
            bloom.addFilter(.blur(radius: 3.5))
            bloom.opacity = 0.48
            bloom.stroke(front, with: light, lineWidth: 3.5)
        }
        context.opacity = 0.4 + frame.level.energy * 0.22
        context.stroke(front, with: light, lineWidth: 0.85)
        context.stroke(bright, with: light, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        context.opacity = 1
    }

    private func drawOrbit(in context: inout GraphicsContext, orbit: Orbit, front: Bool) {
        let start = front ? 0.0 : Double.pi
        let path = orbit.arc(from: start, to: start + .pi)
        let light = GraphicsContext.Shading.linearGradient(Gradient(colors: [Light.mint, Light.pearl, Light.ice, Light.iris]),
            startPoint: orbit.point(at: .pi), endPoint: orbit.point(at: 0))
        context.opacity = frame.orbitReveal * (front ? 1 : 0.38)
        if front {
            context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 4)
        }
        context.drawLayer { bloom in
            bloom.addFilter(.blur(radius: 4))
            bloom.opacity = front ? 0.55 : 0.3
            bloom.stroke(path, with: light, lineWidth: 5)
        }
        context.stroke(path, with: light, style: StrokeStyle(lineWidth: front ? 1.9 : 1.1, lineCap: .round))
        context.stroke(path, with: .color(Light.pearl.opacity(front ? 0.8 : 0.25)), lineWidth: 0.55)
        var echo = orbit
        echo.radius += 3
        context.stroke(echo.arc(from: start, to: start + .pi), with: .color(Light.ice.opacity(0.22)), lineWidth: 0.5)

        let head = frame.time * 0.95 - 0.7
        var trail = Path()
        var connected = false
        for step in 0...28 {
            let angle = head - 0.85 + Double(step) / 28 * 0.85
            guard (sin(angle) >= 0) == front else { connected = false; continue }
            let point = orbit.point(at: angle)
            if connected { trail.addLine(to: point) } else { trail.move(to: point) }
            connected = true
        }
        let tailLight = GraphicsContext.Shading.linearGradient(Gradient(colors: [Light.mint.opacity(0), Light.pearl]),
            startPoint: orbit.point(at: head - 0.85), endPoint: orbit.point(at: head))
        context.stroke(trail, with: tailLight, style: StrokeStyle(lineWidth: 2.7, lineCap: .round))
        if (sin(head) >= 0) == front {
            let point = orbit.point(at: head)
            aura(in: &context, at: point, radius: 8, color: Light.mint, opacity: 0.65)
            context.fill(circle(at: point, radius: 1.6), with: .color(Light.pearl))
        }
        context.opacity = 1
    }

    private func drawSound(in context: inout GraphicsContext, size: CGSize, center: CGPoint) {
        let light = GraphicsContext.Shading.linearGradient(Gradient(stops: [
            .init(color: .clear, location: 0), .init(color: Light.mint.opacity(0.5), location: 0.18),
            .init(color: Light.ice, location: 0.4), .init(color: Light.pearl, location: 0.5),
            .init(color: Light.iris, location: 0.64), .init(color: Light.ice.opacity(0.4), location: 0.82),
            .init(color: .clear, location: 1)
        ]), startPoint: CGPoint(x: 12, y: center.y), endPoint: CGPoint(x: size.width - 12, y: center.y))
        var ribbons = Path(), spine = Path()
        for ribbon in 0..<5 {
            let offset = Double(ribbon) - 2
            var path = Path()
            for step in 0...128 {
                let x = Double(step) / 64 - 1
                let taper = pow(max(0, 1 - x * x), 2)
                let wave = sin(x * (8 + Double(ribbon) * 0.7) - frame.time * 2.2 + offset * 0.4)
                let overtone = sin(x * 17 + frame.time * 1.3 + offset * 0.6) * frame.level.air * 0.3
                let amplitude = 2 + frame.level.energy * 19 + frame.level.bass * 9
                let y = (wave + overtone) * amplitude * taper + offset * (2 + frame.level.energy * 1.8)
                let point = CGPoint(x: center.x + x * (size.width / 2 - 12) * (0.6 + frame.waveReveal * 0.4),
                                    y: center.y + y)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            ribbons.addPath(path)
            if ribbon == 2 { spine = path }
        }
        context.opacity = frame.waveReveal
        context.drawLayer { bloom in
            bloom.addFilter(.blur(radius: 4))
            bloom.opacity = 0.10 + frame.level.energy * 0.16
            bloom.stroke(ribbons, with: light, lineWidth: 3)
        }
        context.opacity = frame.waveReveal * (0.16 + frame.level.energy * 0.38)
        context.stroke(ribbons, with: light, lineWidth: 0.7)
        context.stroke(spine, with: light, lineWidth: 1.3)
        context.opacity = 1
    }

    private func circle(at center: CGPoint, radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func aura(in context: inout GraphicsContext, at center: CGPoint, radius: Double, color: Color, opacity: Double) {
        context.fill(circle(at: center, radius: radius), with: .radialGradient(Gradient(stops: [
            .init(color: color.opacity(opacity), location: 0),
            .init(color: color.opacity(opacity * 0.55), location: 0.35),
            .init(color: color.opacity(opacity * 0.12), location: 0.7),
            .init(color: .clear, location: 1)
        ]), center: center, startRadius: 0, endRadius: radius))
    }
}

private struct Orbit {
    let center: CGPoint
    var radius: Double
    let tilt: Double
    let inclination: Double

    func point(at angle: Double) -> CGPoint {
        let x = cos(angle) * radius, y = sin(angle) * radius * inclination
        return CGPoint(x: center.x + x * cos(tilt) - y * sin(tilt),
                       y: center.y + x * sin(tilt) + y * cos(tilt))
    }

    func arc(from start: Double, to end: Double) -> Path {
        Path { path in
            for step in 0...72 {
                let point = point(at: start + (end - start) * Double(step) / 72)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}
