import AppKit
import SwiftUI

struct StreamMicrophoneControl: View {
    @ObservedObject var microphone: StreamMicrophoneController
    var compact = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button(action: microphone.toggle) {
                HStack(spacing: 7) {
                    if microphone.state == .requestingPermission || microphone.state == .connecting {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: microphone.state == .live ? "mic.fill" : "mic.slash.fill")
                    }
                    Text(compact ? compactLabel : microphone.state.label)
                        .font(.system(size: 12, weight: .semibold))
                    if !compact { Text("⌘M").font(.system(size: 11)).opacity(0.65) }
                }
                .foregroundStyle(microphone.state == .live ? CloudPalette.accent : .white.opacity(0.85))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.black.opacity(0.75), in: Capsule())
                .overlay(Capsule().stroke(microphone.state == .live ? CloudPalette.accent.opacity(0.6) : .white.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .disabled(!microphone.isAvailable)
            .help(microphone.state.detail ?? "Toggle microphone with Command-M. Game audio has its own mute control.")
            .accessibilityLabel(microphone.wantsEnabled ? "Turn microphone off" : "Turn microphone on")
            .accessibilityValue(microphone.state.label)
            .accessibilityIdentifier("microphone-toggle")

            if let detail = microphone.state.detail {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detail).font(.caption).fixedSize(horizontal: false, vertical: true)
                    if microphone.state == .denied {
                        Button("Open microphone settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }.font(.caption).buttonStyle(.borderless)
                    }
                }
                .padding(12).frame(maxWidth: 290, alignment: .leading)
                .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var compactLabel: String {
        switch microphone.state {
        case .requestingPermission, .connecting: "Mic…"
        case .live: "Mic on"
        default: "Mic off"
        }
    }
}

struct StreamMicrophoneCommands: Commands {
    @ObservedObject var microphone: StreamMicrophoneController
    var body: some Commands {
        CommandGroup(before: .windowSize) {
            Button(microphone.wantsEnabled ? "Turn Microphone Off" : "Turn Microphone On", action: microphone.toggle)
                .keyboardShortcut("m", modifiers: .command)
                .disabled(!microphone.isAvailable)
        }
    }
}

@MainActor enum StreamMicrophoneShortcut {
    static func reserve(in menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            // Command-M is explicitly the microphone shortcut in PixelCloudX.
            // Preserve the native Minimize action, with no conflicting shortcut.
            if item.action == #selector(NSWindow.performMiniaturize(_:)), item.keyEquivalent.lowercased() == "m",
               item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command {
                item.keyEquivalent = ""
            }
            reserve(in: item.submenu)
        }
    }
}
