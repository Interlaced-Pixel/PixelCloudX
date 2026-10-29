import SwiftUI
import AppKit

@main
struct PixelCloudXApp: App {
    @NSApplicationDelegateAdaptor(PixelCloudXApplicationDelegate.self) private var applicationDelegate
    @State private var coordinator = AppCoordinator()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var gravatar = GravatarStore()
    @StateObject private var updater = AppUpdater.shared

    var body: some Scene {
        Window("PixelCloudX", id: "main") {
            AppRootView()
                .environment(coordinator)
                .environmentObject(settings)
                .environmentObject(gravatar)
                .frame(minWidth: 1_080, minHeight: 700)
                .preferredColorScheme(.dark)
                .task {
                    applicationDelegate.coordinator = coordinator
                    updater.start(stream: coordinator.streamController)
                    await coordinator.onAppear()
                }
        }
        .commands {
            PixelCloudXCommands(stream: coordinator.streamController, settings: settings, updater: updater)
            CommandGroup(replacing: .appTermination) {
                Button("Quit PixelCloudX") {
                    coordinator.requestQuit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .defaultSize(width: 1_320, height: 860)
        .windowResizability(.contentMinSize)

        Settings {
            PixelCloudXSettingsView()
                .environment(coordinator)
                .environmentObject(settings)
                .environmentObject(gravatar)
        }
    }
}

@MainActor
final class PixelCloudXApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: AppCoordinator?
    private var isTerminating = false
    private var mainWindowCloseObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { StreamMicrophoneShortcut.reserve(in: NSApp.mainMenu) }
        mainWindowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: nil, queue: .main) { notification in
                guard let window = notification.object as? NSWindow, window.title == "PixelCloudX" else { return }
                // Settings or updater windows must not keep the app alive after
                // its main window closes. Leave any Swift task before AppKit quit.
                DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
            }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            await coordinator.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
