import SwiftUI

enum CloudPalette {
    static let canvas = Color(red: 0.035, green: 0.038, blue: 0.043)
    static let panel = Color(red: 0.065, green: 0.069, blue: 0.075)
    static let raised = Color(red: 0.12, green: 0.125, blue: 0.135)
    static let accent = Color(red: 0.40, green: 0.90, blue: 0.37)
    static let primaryText = Color(red: 0.94, green: 0.97, blue: 0.95)
    static let secondaryText = Color(red: 0.65, green: 0.66, blue: 0.68)
    static let border = Color.white.opacity(0.085)
    static let ink = Color(red: 0.035, green: 0.075, blue: 0.055)
}

struct XCloudWordmark: View {
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                    .fill(CloudPalette.accent)
                    .frame(width: compact ? 34 : 42, height: compact ? 34 : 42)
                Image(systemName: "xmark")
                    .font(.system(size: compact ? 17 : 21, weight: .black))
                    .foregroundStyle(CloudPalette.ink)
            }

            Text("PixelCloudX")
                .font(.system(size: compact ? 17 : 20, weight: .semibold, design: .rounded))
                .tracking(-0.5)
                .foregroundStyle(CloudPalette.primaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("PixelCloudX")
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(CloudPalette.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(
                CloudPalette.accent.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(CloudPalette.primaryText)
            .padding(.horizontal, 17)
            .padding(.vertical, 12)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.10 : 0.055),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(CloudPalette.border, lineWidth: 1)
            }
    }
}
