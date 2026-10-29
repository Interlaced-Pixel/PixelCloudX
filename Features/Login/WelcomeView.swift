import SwiftUI
import AppKit

struct WelcomeView: View {
    let isAuthenticating: Bool
    let isRestoringAccount: Bool
    let accountName: String?
    let challenge: MicrosoftDeviceCodeChallenge?
    let onBrowseCatalog: () -> Void
    let onSignIn: () -> Void
    let onCancelSignIn: () -> Void

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                WelcomeBrandPanel()
                    .frame(width: geometry.size.width * 0.51)

                WelcomeActionsPanel(
                    isAuthenticating: isAuthenticating,
                    isRestoringAccount: isRestoringAccount,
                    accountName: accountName,
                    onBrowseCatalog: onBrowseCatalog,
                    onSignIn: onSignIn
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(18)
            .background(CloudPalette.canvas)
        }
        .sheet(isPresented: Binding(
            get: { challenge != nil },
            set: { if !$0 { onCancelSignIn() } }
        )) {
            if let challenge {
                XboxDeviceCodeSignInView(challenge: challenge, onCancel: onCancelSignIn)
            }
        }
    }
}

private struct WelcomeBrandPanel: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.19, blue: 0.16),
                        Color(red: 0.055, green: 0.10, blue: 0.105),
                        Color(red: 0.08, green: 0.10, blue: 0.15)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(CloudPalette.accent.opacity(0.16))
                    .frame(width: geometry.size.width * 0.68)
                    .blur(radius: 80)
                    .offset(x: geometry.size.width * 0.34, y: geometry.size.height * 0.37)

                Circle()
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
                    .frame(width: 400, height: 400)
                    .offset(x: geometry.size.width - 195, y: -195)

                Circle()
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    .frame(width: 300, height: 300)
                    .offset(x: geometry.size.width - 135, y: -145)

                VStack(alignment: .leading, spacing: 0) {
                    XCloudWordmark()

                    Spacer(minLength: 75)

                    Text("XBOX CLOUD GAMING")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(2.1)
                        .foregroundStyle(CloudPalette.accent)

                    Text("Your next game.\nReady to explore.")
                        .font(.system(size: 47, weight: .semibold, design: .rounded))
                        .tracking(-1.8)
                        .lineSpacing(1)
                        .foregroundStyle(CloudPalette.primaryText)
                        .padding(.top, 17)

                    Text("Browse the Xbox catalog and authorize a Microsoft account. Native cloud streaming is being rebuilt with PixelCloudX-owned code.")
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .foregroundStyle(CloudPalette.secondaryText)
                        .frame(maxWidth: 420, alignment: .leading)
                        .padding(.top, 15)

                    HStack(spacing: 10) {
                        CapabilityPill(symbol: "apple.logo", title: "Apple silicon")
                        CapabilityPill(symbol: "gamecontroller.fill", title: "Controller ready")
                    }
                    .padding(.top, 28)

                    Spacer(minLength: 64)

                    Text("NATIVE MACOS APP  •  APPLE SILICON")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(CloudPalette.secondaryText.opacity(0.8))
                }
                .padding(42)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
        }
    }
}

private struct CapabilityPill: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CloudPalette.accent)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CloudPalette.primaryText.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.055), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct WelcomeActionsPanel: View {
    let isAuthenticating: Bool
    let isRestoringAccount: Bool
    let accountName: String?
    let onBrowseCatalog: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Text("XBOX CLOUD CATALOG")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.3)
                    .foregroundStyle(CloudPalette.secondaryText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.055), in: Capsule())
            }

            Spacer(minLength: 60)

            VStack(alignment: .leading, spacing: 12) {
                Text("Welcome")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(CloudPalette.primaryText)

                Text("Browse the current Xbox catalog feed and authorize your Microsoft account with a one-time code. Xbox cloud streaming is being rebuilt independently.")
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(CloudPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                Button(action: onSignIn) {
                    HStack(spacing: 11) {
                        Group {
                            if isAuthenticating || isRestoringAccount {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                            }
                        }
                        .font(.system(size: 17, weight: .medium))
                        Text(signInButtonTitle)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(isAuthenticating || isRestoringAccount || !isMicrosoftSignInConfigured)

                Button(action: onBrowseCatalog) {
                    HStack {
                        Image(systemName: "square.grid.2x2")
                Text("Browse Xbox catalog")
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(QuietButtonStyle())
            }
            .padding(.top, 30)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(CloudPalette.accent)
                Text("Microsoft authorization stays on this Mac. PixelCloudX includes a native in-app player for Xbox Cloud sessions.")
                    .foregroundStyle(CloudPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .lineSpacing(3)
            .padding(.top, 18)

            Spacer(minLength: 60)

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(CloudPalette.accent)
                Text("Microsoft handles password entry in your browser. PixelCloudX never asks for your password.")
                    .foregroundStyle(CloudPalette.secondaryText)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 54)
        .padding(.vertical, 38)
        .frame(maxWidth: 520)
    }

    private var signInButtonTitle: String {
        if isAuthenticating { return "Waiting for Xbox sign-in…" }
        if isRestoringAccount { return "Checking saved Xbox sign-in…" }
        return accountName.map { "Continue as \($0)" } ?? "Sign in to Xbox"
    }

    private var isMicrosoftSignInConfigured: Bool {
        MicrosoftDeviceCodeAuthService.isConfigured
    }
}

private struct XboxDeviceCodeSignInView: View {
    @Environment(\.dismiss) private var dismiss
    let challenge: MicrosoftDeviceCodeChallenge
    let onCancel: () -> Void
    @State private var didCopyCode = false
    @State private var expiresAt = Date()

    private var verificationURL: URL? {
        URL(string: challenge.verificationURIComplete ?? challenge.verificationURI)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(CloudPalette.accent)
                    .frame(width: 48, height: 48)
                    .background(CloudPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect your Xbox account")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .foregroundStyle(CloudPalette.primaryText)
                    Text("Verify your account with Microsoft")
                        .font(.system(size: 12))
                        .foregroundStyle(CloudPalette.secondaryText)
                }
            }

            Text("Verify with Microsoft in your browser. PixelCloudX then requests your Xbox account and cloud session; session availability is determined by Xbox.")
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(CloudPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Text(challenge.userCode)
                    .font(.system(size: 25, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(CloudPalette.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(challenge.userCode, forType: .string)
                    didCopyCode = true
                } label: {
                    Label(didCopyCode ? "Copied" : "Copy", systemImage: didCopyCode ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(QuietButtonStyle())
            }
            .padding(15)
            .background(CloudPalette.raised, in: RoundedRectangle(cornerRadius: 13))

            HStack {
                if let verificationURL {
                    Link("Open Microsoft device sign-in", destination: verificationURL)
                        .buttonStyle(AccentButtonStyle())
                }
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .buttonStyle(QuietButtonStyle())
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let secondsRemaining = max(0, Int(expiresAt.timeIntervalSince(context.date)))
                HStack(spacing: 8) {
                    if secondsRemaining > 0 {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(secondsRemaining > 0
                         ? "Waiting for Microsoft · code expires in \(formattedTime(secondsRemaining))"
                         : "This code expired. Close this sheet and start sign-in again.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CloudPalette.secondaryText)
                }
            }
        }
        .onAppear { expiresAt = Date().addingTimeInterval(TimeInterval(challenge.expiresIn)) }
        .padding(26)
        .frame(width: 500)
        .background(CloudPalette.panel)
    }

    private func formattedTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
