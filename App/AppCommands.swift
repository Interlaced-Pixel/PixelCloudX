import SwiftUI

struct PixelCloudXCommands: Commands {
    @ObservedObject var stream: XboxCloudStreamController
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater: AppUpdater
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…", action: updater.check).disabled(!updater.canCheck || stream.isActive)
        }
        CommandGroup(after: .sidebar) {
            Toggle("Show Catalogue Sidebar", isOn: $settings.values.sidebarVisible)
            Divider()
            Menu("Aspect Ratio") {
                Picker("Aspect Ratio", selection: $settings.values.displayRatio) {
                    ForEach(DisplayRatio.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
            }
            Menu("Video Scaling") {
                Picker("Video Scaling", selection: $settings.values.displayScaling) {
                    ForEach(DisplayScaling.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
            }
            Menu("Xbox Resolution") {
                Picker("Xbox Resolution", selection: $settings.values.resolution) {
                    ForEach(StreamResolution.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
            }
            Toggle("Show Stream Statistics", isOn: $settings.values.showStatistics)
        }
        CommandMenu("Stream") {
            MicrophoneMenuItem(microphone: stream.microphone)
            Button(stream.isGuideVisible ? "Close Guide" : "Open Guide", action: stream.toggleGuide)
                .keyboardShortcut("g", modifiers: .command).disabled(!stream.isActive)
            Button(stream.isMuted ? "Unmute Game Audio" : "Mute Game Audio", action: stream.toggleMute)
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Toggle("Enable Keyboard Gamepad", isOn: $settings.values.keyboardEnabled)
            Divider()
            Button("End Stream") { Task { await stream.stop() } }.disabled(!stream.isActive)
        }
        CommandGroup(replacing: .help) {
            Link("PixelCloudX on GitHub", destination: AppLinks.website)
            Link("Report an Issue", destination: AppLinks.issues)
            Link("Source and Documentation", destination: AppLinks.repository)
        }
    }
}

private struct MicrophoneMenuItem: View {
    @ObservedObject var microphone: StreamMicrophoneController
    var body: some View {
        Button(microphone.wantsEnabled ? "Turn Microphone Off" : "Turn Microphone On", action: microphone.toggle)
            .keyboardShortcut("m", modifiers: .command).disabled(!microphone.isAvailable)
    }
}
