import SwiftUI

struct NativeStreamView: View {
    let game: CloudGame
    let accountName: String?
    let controllerNames: [String]
    @ObservedObject var streamController: XboxCloudStreamController
    let onClose: () -> Void

    @State private var isHUDVisible = true
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .onTapGesture { isHUDVisible.toggle() }

            GeometryReader { proxy in
                let size = StreamDisplayLayout.size(in: proxy.size, source: streamController.videoDimensions,
                    ratio: settings.values.displayRatio, scaling: settings.values.displayScaling)
                StreamVideoView(track: streamController.videoTrack)
                    .frame(width: size.width, height: size.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .clipped().ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)

            if settings.values.showStatistics && streamController.videoTrack != nil {
                VStack { Spacer(); HStack {
                    Text(streamController.statisticsSummary).font(.caption.monospaced())
                        .padding(9).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
                    Spacer()
                }.padding(18) }.allowsHitTesting(false)
            }

            if streamController.phase != .playing {
                connectionState
                    .transition(.opacity)
            }

            if streamController.phase == .playing && !streamController.statusMessage.isEmpty {
                VStack {
                    Text(streamController.statusMessage).font(.caption)
                        .padding(12).background(.black.opacity(0.75), in: Capsule())
                        .padding(.top, 18)
                    Spacer()
                }.allowsHitTesting(false)
            }

            if isHUDVisible && !streamController.isGuideVisible && streamController.videoTrack != nil {
                VStack {
                    HStack(spacing: 10) {
                        Image(systemName: "gamecontroller.fill")
                            .foregroundStyle(CloudPalette.accent)
                        Text(game.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        StreamMicrophoneControl(microphone: streamController.microphone)
                        SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings")
                        Button("⌘G  Guide", action: streamController.toggleGuide).buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.12), lineWidth: 1))
                    .padding(18)

                    Spacer()

                    if !controllerNames.isEmpty {
                        HStack(spacing: 7) {
                            Image(systemName: "gamecontroller.fill")
                            Text(controllerNames.joined(separator: ", "))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 16)
                    }
                }
                .transition(.opacity)
            }

            if !isHUDVisible && !streamController.isGuideVisible && streamController.videoTrack != nil {
                VStack {
                    HStack {
                        Spacer()
                        StreamMicrophoneControl(microphone: streamController.microphone, compact: true)
                    }.padding(18)
                    Spacer()
                }
            }

            if streamController.isGuideVisible {
                guideOverlay
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(4)
            }
        }
        // Avoid SwiftUI's macOS 27 hover responder path around the native
        // renderer. Click toggles the HUD; Command-G always opens the Guide.
        .task(id: "\(streamController.videoTrack?.trackId ?? "none")-\(settings.values.overlaySeconds)") {
            isHUDVisible = true
            guard streamController.videoTrack != nil, settings.values.overlaySeconds > 0 else { return }
            do { try await Task.sleep(for: .seconds(settings.values.overlaySeconds)) } catch { return }
            isHUDVisible = false
        }
        .onExitCommand {
            if streamController.isGuideVisible { streamController.toggleGuide() }
        }
        .animation(.easeInOut(duration: 0.18), value: streamController.isGuideVisible)
        .animation(.easeInOut(duration: 0.2), value: streamController.videoTrack != nil)
        .accessibilityIdentifier("native-stream")
    }

    private var connectionState: some View {
        VStack(spacing: 15) {
            if streamController.phase == .failed {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(CloudPalette.accent)
                    .frame(width: 66, height: 66)
                    .background(CloudPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 19))
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(CloudPalette.accent)
                    .frame(width: 66, height: 66)
                    .background(CloudPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 19))
            }

            Text(game.title)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(streamController.errorMessage ?? streamController.statusMessage)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: 8) {
                AccountAvatar(accountName: accountName, size: 20)
                Text(accountName ?? "Guest")
                Text("·")
                Label(controllerNames.first ?? "No controller", systemImage: "gamecontroller")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))

            if streamController.phase == .failed {
                Button(action: onClose) {
                    Label("Return to catalog", systemImage: "arrow.left")
                }
                .buttonStyle(AccentButtonStyle())
                .padding(.top, 3)
            } else {
                Button("Cancel launch", action: onClose)
                    .buttonStyle(QuietButtonStyle())
                    .padding(.top, 3)
            }
        }
        .padding(34)
        .frame(maxWidth: 620)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.09), lineWidth: 1))
        .padding(28)
    }

    private var guideOverlay: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture { streamController.toggleGuide() }

            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    AccountAvatar(accountName: accountName, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("XBOX GUIDE")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.6)
                            .foregroundStyle(CloudPalette.accent)
                        Text(accountName ?? "Xbox Cloud Gaming")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 25)

                Text(game.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 5)

                Text(streamController.phase.label.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(streamController.phase == .playing ? CloudPalette.accent : .white.opacity(0.52))
                    .padding(.bottom, 22)

                Rectangle()
                    .fill(.white.opacity(0.12))
                    .frame(height: 1)
                    .padding(.bottom, 18)

                guideRow(
                    symbol: streamController.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    title: streamController.isMuted ? "Unmute game audio" : "Mute game audio",
                    subtitle: "Toggle this Mac's game audio"
                ) {
                    streamController.toggleMute()
                }

                HStack {
                    StreamMicrophoneControl(microphone: streamController.microphone)
                    Spacer(minLength: 0)
                }.padding(.vertical, 12)

                VStack(alignment: .leading, spacing: 12) {
                    Picker("Aspect ratio", selection: $settings.values.displayRatio) {
                        ForEach(DisplayRatio.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Scaling", selection: $settings.values.displayScaling) {
                        ForEach(DisplayScaling.allCases) { Text($0.title).tag($0) }
                    }
                    SettingsLink { Label("All settings…", systemImage: "gearshape") }
                    Text("\(streamController.inputReportsSent) input reports queued").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 10)

                guideRow(
                    symbol: "gamecontroller.fill",
                    title: controllerNames.first ?? "Connect a controller",
                    subtitle: controllerNames.isEmpty ? "Pair a controller in macOS Settings" : "Controller input is active"
                ) {}
                .disabled(controllerNames.isEmpty)

                Text("KEYBOARD GAMEPAD")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 18)
                Text("WASD  Move · Arrows  D-pad\nSpace / J  A · K / Delete  B\nU  X · I  Y · Q / E  LB / RB\nZ / C  LT / RT · Return  Menu · V  View")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineSpacing(5)
                    .padding(.top, 8)

                    }
                }
                .scrollIndicators(.hidden)
                .padding(.bottom, 20)

                Button(action: streamController.toggleGuide) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Resume game")
                        Spacer()
                        Text("⌘G")
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(CloudPalette.raised, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)

                Button(action: onClose) {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("End stream")
                        Spacer()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .frame(width: 350, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(.ultraThinMaterial)
            .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.1)).frame(width: 1) }
            .shadow(color: .black.opacity(0.35), radius: 35, x: 10, y: 0)
        }
    }

    private func guideRow(
        symbol: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CloudPalette.accent)
                    .frame(width: 34, height: 34)
                    .background(CloudPalette.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
