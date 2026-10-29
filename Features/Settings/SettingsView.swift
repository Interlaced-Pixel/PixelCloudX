import AppKit
import SwiftUI

extension Notification.Name {
    static let catalogRefreshRequested = Notification.Name("PixelCloudX.catalogRefreshRequested")
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", display = "Display", audio = "Audio & Input", accessibility = "Xbox Accessibility"
    case catalog = "Catalogue", account = "Account", updates = "Updates"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"; case .display: "display"; case .audio: "gamecontroller"
        case .accessibility: "accessibility"; case .catalog: "square.grid.2x2"
        case .account: "person.crop.circle"; case .updates: "arrow.down.circle"
        }
    }
}

struct PixelCloudXSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var gravatar: GravatarStore
    @Environment(AppCoordinator.self) private var coordinator
    @ObservedObject private var updater = AppUpdater.shared
    @AppStorage("PixelCloudX.settingsSection") private var selection = SettingsSection.general
    @State private var confirmReset = false
    @State private var confirmClear = false
    @State private var artworkBytes = 0
    @State private var cacheBusy = false
    @State private var cacheMessage: String?
    @State private var catalogBusy = false
    @State private var catalogMessage: String?

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(185)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                Text(selection.rawValue).font(.title2.bold()).padding(.horizontal, 24).padding(.top, 22)
                if selection == .account {
                    accountContent.padding(24)
                } else {
                    Form {
                        switch selection {
                        case .general: generalContent
                        case .display: displayContent
                        case .audio: audioContent
                        case .accessibility: accessibilityContent
                        case .catalog: catalogContent
                        case .updates: updatesContent
                        case .account: EmptyView()
                        }
                    }.formStyle(.grouped)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 800, height: 650)
        .tint(CloudPalette.accent)
        .preferredColorScheme(.dark)
        .onAppear {
            if coordinator.streamController.isActive && !coordinator.streamController.isGuideVisible {
                coordinator.streamController.toggleGuide()
            }
        }
        .task { artworkBytes = await CatalogArtworkCache.shared.diskUsage() }
        .confirmationDialog("Reset playback and catalogue preferences?", isPresented: $confirmReset) {
            Button("Reset preferences", role: .destructive) { settings.reset() }
        } message: { Text("Your Microsoft login, Gravatar, saved games, and downloaded catalogue remain available.") }
        .confirmationDialog("Clear downloaded cover artwork?", isPresented: $confirmClear) {
            Button("Clear artwork", role: .destructive) { clearArtwork() }
        } message: { Text("Covers will download again as you browse. Game metadata, saved games, and account data are kept.") }
        .accessibilityIdentifier("pixelcloudx-settings")
    }

    private var generalContent: some View {
        Group {
            Section("Startup") {
                Toggle("Open the catalogue after sign-in", isOn: $settings.values.startInCatalog)
                Text("Closing the main window quits PixelCloudX and ends its cloud session.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Stream overlay") {
                Picker("Hide controls after", selection: $settings.values.overlaySeconds) {
                    Text("Keep visible").tag(0)
                    ForEach([2, 4, 6, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Toggle("Show stream statistics", isOn: $settings.values.showStatistics)
                Text("Command-G opens the Guide. Command-M toggles microphone input.").font(.caption).foregroundStyle(.secondary)
            }
            Section("PixelCloudX") {
                LabeledContent("Version", value: Self.version)
                Text("Native Xbox cloud streaming for Apple silicon. Xbox endpoints are private and may change; PixelCloudX is not affiliated with Microsoft.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("Project website", destination: AppLinks.website)
                    Spacer()
                    Link("Source & issues", destination: AppLinks.repository)
                }
                Button("Reset playback and catalogue preferences…") { confirmReset = true }
            }
        }
    }
    private var displayContent: some View {
        Group {
            Section("Xbox video") {
                choice("Requested resolution", selection: $settings.values.resolution)
                Text("Sent to Xbox during streaming. Actual resolution depends on your account, title, service capacity, and network.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Display on this Mac") {
                choice("Aspect ratio", selection: $settings.values.displayRatio)
                choice("Scaling", selection: $settings.values.displayScaling)
                Text("Fit preserves the selected ratio with borders. Fill crops it to cover the window. Stretch fills the entire window. Choosing a ratio changes the picture's proportions; Original video preserves the source.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Control-Command-F toggles full screen. Display options are also in the View menu and stream Guide.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var audioContent: some View {
        Group {
            Section("Game audio") {
                Toggle("Mute game audio", isOn: $settings.values.muted)
                LabeledContent("Volume") {
                    Slider(value: $settings.values.volume, in: 0...1).frame(width: 190)
                    Text(settings.values.volume, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 42)
                }
            }
            Section("Microphone") {
                Toggle("Echo cancellation", isOn: $settings.values.echoCancellation)
                Toggle("Noise suppression", isOn: $settings.values.noiseSuppression)
                Toggle("Automatic gain control", isOn: $settings.values.automaticGain)
                Text("Uses the macOS default input device. Processing changes apply the next time you enable the mic. Capture starts off for each stream; Command-M or the overlay turns it on.").font(.caption).foregroundStyle(.secondary)
                Button("Open macOS microphone permissions") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
            }
            Section("Controller & keyboard") {
                Toggle("Enable keyboard gamepad", isOn: $settings.values.keyboardEnabled)
                Toggle("Allow controller input while PixelCloudX is in the background", isOn: $settings.values.backgroundController)
                LabeledContent("Additional stick deadzone") {
                    Slider(value: $settings.values.deadzone, in: 0...0.3, step: 0.01).frame(width: 170)
                    Text(settings.values.deadzone, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 40)
                }
                Text("WASD: move · Arrows: D-pad · Space/J: A · K/Delete: B · U: X · I: Y · Q/E: shoulders · Z/C: triggers · Return: Menu · V: View.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var accessibilityContent: some View {
        Section("Xbox console preferences") {
            Toggle("Text to speech", isOn: $settings.values.xbox.textToSpeech)
            Toggle("Magnifier", isOn: $settings.values.xbox.magnifier)
            Picker("High contrast", selection: $settings.values.xbox.highContrast) {
                Text("Off").tag(0); Text("White").tag(1); Text("Black").tag(2)
            }
            Picker("Console language", selection: $settings.values.xbox.locale) {
                ForEach(AppPreferences.locales, id: \.0) { Text($0.1).tag($0.0) }
            }
            Text("Saved on this Mac and sent in your next Xbox cloud-session request. These preferences do not change your Microsoft account profile or other devices.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var catalogContent: some View {
        Group {
            Section("Browsing") {
                Toggle("Show sidebar", isOn: $settings.values.sidebarVisible)
                Toggle("Sort games A–Z", isOn: $settings.values.sortAscending)
                Toggle("Show NEW and UPDATED cover badges", isOn: $settings.values.showCatalogChanges)
            }
            Section("Background updates") {
                Toggle("Silently refresh the catalogue", isOn: $settings.values.automaticCatalogRefresh)
                Picker("Check while browsing", selection: $settings.values.catalogRefreshMinutes) {
                    ForEach([15, 30, 60], id: \.self) { Text("Every \($0) minutes").tag($0) }
                }.disabled(!settings.values.automaticCatalogRefresh)
                Button(catalogBusy ? "Refreshing…" : "Refresh catalogue now", action: refreshCatalog)
                    .disabled(catalogBusy || coordinator.streamController.isActive)
                if let catalogMessage { Text(catalogMessage).font(.caption).foregroundStyle(.secondary) }
                Text("Saved titles load first. Refreshes run while browsing, and changed titles appear in Catalogue updates. Use Mark seen to clear their markers.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Cached artwork") {
                LabeledContent("Disk usage", value: ByteCountFormatter.string(fromByteCount: Int64(artworkBytes), countStyle: .file))
                Text("Up to 192 MiB on disk and 32 MiB of decoded covers in memory. Catalogue metadata and account credentials use separate storage.").font(.caption).foregroundStyle(.secondary)
                Button(cacheBusy ? "Clearing…" : "Clear downloaded artwork…") { confirmClear = true }.disabled(cacheBusy)
                if let cacheMessage { Text(cacheMessage).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private var updatesContent: some View {
        Section("Software updates") {
            LabeledContent("Installed version", value: Self.version)
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
            Toggle("Automatically download updates", isOn: $updater.automaticallyDownloads)
                .disabled(!updater.automaticallyChecks)
            LabeledContent("Last check", value: updater.lastCheck?.formatted(date: .abbreviated, time: .shortened) ?? "Not checked yet")
            Button("Check for Updates…", action: updater.check)
                .disabled(!updater.canCheck || coordinator.streamController.isActive)
            if updater.installationWaiting { Text("An update is ready. Installation will continue after your stream ends.").font(.caption) }
            Text("Updates are checked through Interlaced Pixel and verified with PixelCloudX's Sparkle signing key. Checks wait while a game is active; a pending installation waits for the stream to end.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Release notes and downloads", destination: AppLinks.releases)
        }
    }
    @ViewBuilder private var accountContent: some View {
        if coordinator.isSignedIn {
            AccountProfileView(accountName: coordinator.accountName, serviceSummary: coordinator.cloudServiceSummary,
                               serviceError: coordinator.xboxServiceErrorMessage,
                               onReconnect: { Task { await coordinator.reconnectXboxServices() } },
                               onSignOut: { Task { await coordinator.signOut() } })
        } else {
            ContentUnavailableView {
                Label("Sign in to Xbox", systemImage: "person.crop.circle")
            } description: { Text("Microsoft sign-in persists between app launches. Connect Gravatar from the account menu after signing in.")
            } actions: { Button("Sign in with Microsoft", action: coordinator.beginSignIn) }
        }
    }
    private func choice<T: SettingsChoice>(_ title: String, selection: Binding<T>) -> some View {
        Picker(title, selection: selection) { ForEach(Array(T.allCases)) { Text($0.title).tag($0) } }
    }
    private func clearArtwork() {
        cacheBusy = true; cacheMessage = nil
        Task {
            do { try await CatalogArtworkCache.shared.clear(); cacheMessage = "Downloaded artwork cleared." }
            catch { cacheMessage = error.localizedDescription }
            artworkBytes = await CatalogArtworkCache.shared.diskUsage()
            cacheBusy = false
        }
    }
    private func refreshCatalog() {
        catalogBusy = true; catalogMessage = nil
        Task {
            do {
                let result = try await CatalogRepository.shared.refresh(accountIDs: coordinator.accountCatalogProductIDs, force: true)
                catalogMessage = result.warning ?? "Catalogue refreshed."
                NotificationCenter.default.post(name: .catalogRefreshRequested, object: nil)
            } catch { catalogMessage = error.localizedDescription }
            catalogBusy = false
        }
    }
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "1.0") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
}

enum AppLinks {
    static let website = URL(string: "https://interlacedpixel.com/PixelCloudX/")!
    static let repository = URL(string: "https://github.com/Interlaced-Pixel/PixelCloudX")!
    static let releases = repository.appendingPathComponent("releases")
    static let issues = repository.appendingPathComponent("issues")
}
