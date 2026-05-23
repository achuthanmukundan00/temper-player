import AppKit
import SwiftUI
import Combine

final class MenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<MenuBarView>!
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

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
        observePlaybackState()
    }

    private func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // SF Symbol icon sized to match menu bar standard icons
            let image = NSImage(
                systemSymbolName: "play.circle.fill",
                accessibilityDescription: "TemperPlayer"
            )?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))

            button.image = image
            button.imagePosition = .imageOnly
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
        popover.contentSize = NSSize(width: 320, height: 140)
        popover.behavior = .applicationDefined
        popover.delegate = self
        popover.contentViewController = hostingController
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()

            // Close popover when clicking outside
            if eventMonitor == nil {
                eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    self?.closePopover()
                }
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Playback State Observation

    private func observePlaybackState() {
        playerState.$isPlaying
            .sink { [weak self] isPlaying in
                self?.updateStatusIcon(isPlaying: isPlaying)
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon(isPlaying: Bool) {
        guard let button = statusItem.button else { return }
        let symbolName = isPlaying ? "play.circle.fill" : "play.circle"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: isPlaying ? "Playing" : "Paused"
        )?
        .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        button.image = image
    }
}
