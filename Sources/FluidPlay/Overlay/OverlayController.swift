import AppKit
import SwiftUI

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Full-screen overlay above the Remote Play window. It doesn't take focus or the mouse, so the controller
/// and keyboard keep going to the source app.
@MainActor
final class OverlayController {
    let videoView: VideoLayerView
    private let panel: OverlayPanel

    init(core: RenderCore, queue: PresentQueue, hud: some View) {
        videoView = VideoLayerView(core: core, queue: queue, opaque: false)

        panel = OverlayPanel(contentRect: NSScreen.main?.frame ?? .zero,
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // We declare the window as opaque=false: the system then won't consider the source window
        // occluded, and the source app won't stop updating its image.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .none

        let container = NSView()
        container.wantsLayer = true
        videoView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(videoView)

        let hudView = NSHostingView(rootView: hud)
        hudView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hudView)

        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: container.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hudView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            hudView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
        ])
        panel.contentView = container
    }

    var isVisible: Bool { panel.isVisible }

    func show(on screen: NSScreen) {
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
