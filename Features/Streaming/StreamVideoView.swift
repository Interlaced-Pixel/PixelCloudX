import AppKit
import SwiftUI
import WebRTC

/// AppKit video surface backed by WebRTC's native Metal renderer.
struct StreamVideoView: NSViewRepresentable {
    let track: RTCVideoTrack?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PassiveMetalVideoView {
        let view = PassiveMetalVideoView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.attach(track, to: view)
        return view
    }

    func updateNSView(_ view: PassiveMetalVideoView, context: Context) {
        context.coordinator.attach(track, to: view)
    }

    static func dismantleNSView(_ view: PassiveMetalVideoView, coordinator: Coordinator) {
        coordinator.attach(nil, to: nil)
    }

    @MainActor
    final class Coordinator {
        // Hold both ends until remove(renderer) finishes. Weak references can
        // disappear before SwiftUI dismantles the registered render surface.
        private var currentTrack: RTCVideoTrack?
        private var currentView: RTCMTLNSVideoView?

        func attach(_ newTrack: RTCVideoTrack?, to view: RTCMTLNSVideoView?) {
            if currentTrack !== newTrack || currentView !== view {
                if let currentTrack, let currentView {
                    NativeRTCExecutor.shared.enqueue { currentTrack.remove(currentView) }
                }
                currentTrack = newTrack
                currentView = view
                if let newTrack, let view {
                    NativeRTCExecutor.shared.enqueue { newTrack.add(view) }
                }
            }
        }
    }
}

/// The render surface never consumes mouse/keyboard input. SwiftUI controls
/// above it own input, keeping this native view out of hover hit-test routing.
final class PassiveMetalVideoView: RTCMTLNSVideoView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
