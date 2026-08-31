import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MenuBarController: NSObject, ObservableObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private weak var downloads: DownloadViewModel?
    private var cancellables = Set<AnyCancellable>()
    private var dropView: StatusDropView?
    private var proximityPanel: NSPanel?
    private var globalDragMonitor: Any?
    private var globalMouseUpMonitor: Any?

    func start(with downloads: DownloadViewModel) {
        guard self.downloads == nil else { return }
        self.downloads = downloads

        let view = StatusDropView(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        view.controller = self
        view.registerForDraggedTypes([.URL, .string])
        statusItem.view = view
        dropView = view

        // The drop zone may be opened from the main window as well as from the
        // status item. Application-defined avoids it closing immediately when
        // the initiating click belongs to the main window.
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 360, height: 292)
        popover.contentViewController = NSHostingController(rootView: MenuBarDropView().environmentObject(downloads).environmentObject(self))

        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async { self?.showProximityDropZoneIfNeeded() }
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.hideProximityDropZone() }
        }

        downloads.$isDownloading
            .combineLatest(downloads.$jobs)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refreshAppearance() }
            .store(in: &cancellables)
        refreshAppearance()
    }

    func showDropZone() {
        guard let view = dropView else { return }
        if !popover.isShown {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func hideDropZone() { popover.performClose(nil) }

    private func showProximityDropZoneIfNeeded() {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return }
        // This intentionally activates before the pointer reaches the tiny
        // status item. It mirrors a Dropzone-style top-edge target while only
        // appearing during an active drag near the menu bar.
        guard location.y > screen.frame.maxY - 180 else { return }
        if proximityPanel == nil { createProximityDropZone(on: screen) }
    }

    private func createProximityDropZone(on screen: NSScreen) {
        guard let downloads else { return }
        let size = NSSize(width: 390, height: 292)
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: MenuBarDropView().environmentObject(downloads).environmentObject(self))
        panel.orderFrontRegardless()
        proximityPanel = panel
    }

    func hideProximityDropZone() {
        proximityPanel?.orderOut(nil)
        proximityPanel = nil
    }

    func receiveDrop(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        guard let value = extractURL(from: board) else { return false }
        showDropZone()
        let queued = downloads?.enqueue(value) ?? false
        if queued {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                self?.hideDropZone()
                self?.hideProximityDropZone()
            }
        }
        return queued
    }

    func enqueueDroppedURL(_ rawURL: String) {
        guard downloads?.enqueue(rawURL) == true else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in self?.hideProximityDropZone() }
    }

    func openApplication() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func openSettings() {
        openApplication()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open UniDownloader", action: #selector(openFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit UniDownloader", action: #selector(quitFromMenu), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        guard let view = dropView else { return }
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: view)
    }

    @objc private func openFromMenu() { openApplication() }
    @objc private func settingsFromMenu() { openSettings() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }

    private func refreshAppearance() {
        guard let downloads, let view = dropView else { return }
        let current = downloads.jobs.first(where: { $0.state == .downloading })
        view.progress = current?.progress ?? 0
        view.isDownloading = downloads.isDownloading
        view.toolTip = downloads.isDownloading ? "UniDownloader – \(Int((current?.progress ?? 0) * 100))%" : "UniDownloader – drag a URL here"
        view.needsDisplay = true
    }

    private func extractURL(from board: NSPasteboard) -> String? {
        let candidates = [board.string(forType: .URL), board.string(forType: .string)].compactMap { $0 }
        for candidate in candidates {
            if let direct = URL(string: candidate.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(direct.scheme?.lowercased() ?? "") { return direct.absoluteString }
            if let range = candidate.range(of: "https?://[^\\s]+", options: .regularExpression) {
                let value = String(candidate[range]).trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}.,;\"'"))
                if URL(string: value) != nil { return value }
            }
        }
        return nil
    }
}

private final class StatusDropView: NSView {
    weak var controller: MenuBarController?
    var progress = 0.0
    var isDownloading = false

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.showDropZone()
        return canReadURL(from: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReadURL(from: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.receiveDrop(sender) ?? false
    }

    override func mouseDown(with event: NSEvent) { controller?.showDropZone() }
    override func rightMouseDown(with event: NSEvent) { controller?.showContextMenu() }

    override func draw(_ dirtyRect: NSRect) {
        let symbol = NSImage(systemSymbolName: "arrow.down.to.line.compact", accessibilityDescription: "UniDownloader")
        let base = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let colors = NSImage.SymbolConfiguration(paletteColors: [isDownloading ? .systemGreen : .white])
        let image = symbol?.withSymbolConfiguration(base.applying(colors))
        image?.isTemplate = false
        image?.draw(in: bounds.insetBy(dx: 5, dy: 3), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if isDownloading {
            let width = max(2, bounds.width * min(max(progress, 0.04), 1))
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 1, width: width - 4, height: 1.8), xRadius: 1, yRadius: 1).fill()
        }
    }

    private func canReadURL(from board: NSPasteboard) -> Bool {
        board.canReadItem(withDataConformingToTypes: [UTType.url.identifier, UTType.plainText.identifier])
    }
}
