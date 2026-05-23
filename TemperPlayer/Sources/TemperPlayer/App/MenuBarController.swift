import AppKit
import SwiftUI

final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<MenuBarView>!

    private let playerState: PlayerState
    private let audioManager: AudioManager
    private let playback: PlaybackController
    private let library: Database
    private let importService: ImportService

    init(playerState: PlayerState, audioManager: AudioManager, playback: PlaybackController, library: Database, importService: ImportService) {
        self.playerState = playerState
        self.audioManager = audioManager
        self.playback = playback
        self.library = library
        self.importService = importService
        super.init()
        setup()
    }

    private func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "\u{266A}"
            button.font = NSFont.systemFont(ofSize: 13)
            button.action = #selector(togglePopover)
            button.target = self
        }

        let contentView = MenuBarView(
            playerState: playerState,
            audioManager: audioManager,
            playback: playback,
            library: library,
            importService: importService
        )
        hostingController = NSHostingController(rootView: contentView)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 260, height: 100)
        popover.behavior = .transient
        popover.contentViewController = hostingController
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
