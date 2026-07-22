import SwiftUI

/// Center-screen fireworks celebration shown when a tracked quota resets.
/// Rendered in a transparent, click-through overlay window; it animates a few
/// staggered bursts and a headline, then fades out.
struct ResetCelebrationView: View {
    /// Called when the animation finishes so the host window can close.
    let onFinished: () -> Void

    @State private var burstsVisible = false
    @State private var headlineVisible = false
    @State private var overallOpacity = 1.0

    // Fixed burst layout so the scene reads the same every time (Math.random is
    // unavailable and undesirable here). Positions are relative to the center.
    private let bursts: [Burst] = [
        Burst(dx: 0, dy: -40, delay: 0.0, hue: 0.02, particles: 14, radius: 130),
        Burst(dx: -150, dy: 20, delay: 0.18, hue: 0.55, particles: 12, radius: 100),
        Burst(dx: 150, dy: 30, delay: 0.30, hue: 0.14, particles: 12, radius: 105),
        Burst(dx: -70, dy: -120, delay: 0.45, hue: 0.80, particles: 10, radius: 90),
        Burst(dx: 90, dy: -110, delay: 0.58, hue: 0.42, particles: 10, radius: 90),
    ]

    var body: some View {
        ZStack {
            ForEach(Array(bursts.enumerated()), id: \.offset) { _, burst in
                FireworkBurst(burst: burst, isFiring: burstsVisible)
            }

            VStack(spacing: 6) {
                Text("Quota reset")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("You're clear to keep going")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .shadow(radius: 24, y: 8)
            .scaleEffect(headlineVisible ? 1 : 0.85)
            .opacity(headlineVisible ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .opacity(overallOpacity)
        .onAppear { runAnimation() }
    }

    private func runAnimation() {
        withAnimation(.easeOut(duration: 0.9)) { burstsVisible = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.15)) {
            headlineVisible = true
        }
        // Hold, then fade the whole scene and tell the host to close.
        withAnimation(.easeIn(duration: 0.6).delay(3.4)) { overallOpacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) { onFinished() }
    }

    struct Burst: Equatable {
        let dx: CGFloat
        let dy: CGFloat
        let delay: Double
        let hue: Double
        let particles: Int
        let radius: CGFloat
    }
}

/// A single firework: particles shoot outward from a point and fade.
private struct FireworkBurst: View {
    let burst: ResetCelebrationView.Burst
    let isFiring: Bool

    var body: some View {
        ZStack {
            ForEach(0..<burst.particles, id: \.self) { index in
                let angle = Double(index) / Double(burst.particles) * 2 * .pi
                let color = Color(
                    hue: burst.hue,
                    saturation: 0.85,
                    brightness: 1.0
                )
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .offset(
                        x: isFiring ? burst.radius * CGFloat(cos(angle)) : 0,
                        y: isFiring ? burst.radius * CGFloat(sin(angle)) : 0
                    )
                    .opacity(isFiring ? 0 : 1)
                    .animation(
                        .easeOut(duration: 1.1).delay(burst.delay),
                        value: isFiring
                    )
            }
        }
        .offset(x: burst.dx, y: burst.dy)
    }
}
