import SwiftUI

/// Center-screen usage alert shown when a quota crosses a warning or critical
/// threshold. Same overlay host as the reset celebration, but a plain alert
/// card (no fireworks). Auto-dismisses after a short dwell.
struct UsageAlertView: View {
    let payload: UsageAlertPayload
    let onFinished: () -> Void

    @State private var visible = false

    private var accentColor: Color {
        payload.severity == .critical ? .red : .orange
    }

    private var iconName: String {
        payload.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(accentColor)

            Text(payload.title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)

            Text(payload.message)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(maxWidth: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(accentColor.opacity(0.5), lineWidth: 1)
        )
        .shadow(radius: 26, y: 10)
        .scaleEffect(visible ? 1 : 0.9)
        .opacity(visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear { runAnimation() }
    }

    private func runAnimation() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) { visible = true }
        withAnimation(.easeIn(duration: 0.4).delay(4.2)) { visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.7) { onFinished() }
    }
}
