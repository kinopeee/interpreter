import AppKit
import SwiftUI

@MainActor
final class SubtitleWindowController: NSObject {
    private let panel: SubtitlePanel
    private let controlPanel: SubtitlePanel
    private let hostingView: NSHostingView<SubtitleView>
    private let controlHostingView: NSHostingView<RecordingControlView>
    private let translationHostingView: NSHostingView<LocalTranslationHostView>
    private let controlContainerView = NSView()
    private var snapshot = SubtitleSnapshot.empty
    private var displayMode: SubtitleDisplayMode = .both
    private var fontSize: Double = 32
    private var translationState: TranslationState = .idle
    private var onToggleRecording: () -> Void = {}
    private var isEditingPosition = false
    private var screenObserver: NSObjectProtocol?
    private var customOrigin: CGPoint?
    private var dragStartPanelOrigin: NSPoint?
    private var dragStartMouseLocation: NSPoint?

    init(translationService: LocalTranslationService) {
        let initialFrame = Self.defaultFrame(for: NSScreen.main)
        panel = SubtitlePanel(contentRect: initialFrame)
        controlPanel = SubtitlePanel(contentRect: Self.controlFrame(for: initialFrame))
        controlPanel.ignoresMouseEvents = false
        hostingView = NSHostingView(
            rootView: SubtitleView(
                snapshot: .empty,
                displayMode: .both,
                fontSize: 32,
                isEditingPosition: false
            )
        )
        controlHostingView = NSHostingView(
            rootView: RecordingControlView(state: .idle, onToggleRecording: {})
        )
        translationHostingView = NSHostingView(
            rootView: LocalTranslationHostView(service: translationService)
        )
        super.init()
        hostingView.frame = panel.contentView?.bounds ?? initialFrame
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.setFrame(initialFrame, display: false)
        panel.orderFrontRegardless()
        controlContainerView.frame = controlPanel.contentView?.bounds ?? .zero
        controlContainerView.autoresizingMask = [.width, .height]
        controlHostingView.frame = controlContainerView.bounds
        controlHostingView.autoresizingMask = [.width, .height]
        translationHostingView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        translationHostingView.alphaValue = 0.01
        controlContainerView.addSubview(controlHostingView)
        controlContainerView.addSubview(translationHostingView)
        controlPanel.contentView = controlContainerView
        controlPanel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.relayoutIfNeeded()
            }
        }
    }

    func tearDown() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        removeDragMonitor()
        panel.orderOut(nil)
        controlPanel.orderOut(nil)
    }

    func show() {
        panel.orderFrontRegardless()
        controlPanel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        controlPanel.orderOut(nil)
    }

    func update(
        snapshot: SubtitleSnapshot,
        displayMode: SubtitleDisplayMode,
        fontSize: Double,
        translationState: TranslationState
    ) {
        self.snapshot = snapshot
        self.displayMode = displayMode
        self.fontSize = fontSize
        self.translationState = translationState
        render()
        relayoutIfNeeded()
    }

    func setRecordingHandler(_ handler: @escaping () -> Void) {
        onToggleRecording = handler
        render()
    }

    func applySavedOrigin(_ origin: CGPoint?) {
        customOrigin = origin
        if let origin {
            var frame = panel.frame
            frame.origin = origin
            panel.setFrame(frame, display: true)
            layoutControlPanel(relativeTo: frame)
        } else {
            relayoutIfNeeded(forceDefault: true)
        }
    }

    func setPositionEditingEnabled(_ enabled: Bool) {
        isEditingPosition = enabled
        panel.ignoresMouseEvents = !enabled
        if enabled {
            panel.makeKeyAndOrderFront(nil)
            installDragMonitor()
        } else {
            removeDragMonitor()
        }
        render()
    }

    var currentOrigin: CGPoint {
        panel.frame.origin
    }

    private var dragMonitor: Any?

    private func installDragMonitor() {
        removeDragMonitor()
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleDrag(event)
            return event
        }
    }

    private func removeDragMonitor() {
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
        dragStartPanelOrigin = nil
        dragStartMouseLocation = nil
    }

    private func handleDrag(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStartPanelOrigin = panel.frame.origin
            dragStartMouseLocation = NSEvent.mouseLocation
        case .leftMouseDragged:
            guard
                let startOrigin = dragStartPanelOrigin,
                let startMouse = dragStartMouseLocation
            else { return }
            let current = NSEvent.mouseLocation
            let delta = NSPoint(x: current.x - startMouse.x, y: current.y - startMouse.y)
            var frame = panel.frame
            frame.origin = NSPoint(x: startOrigin.x + delta.x, y: startOrigin.y + delta.y)
            panel.setFrame(frame, display: true)
            customOrigin = frame.origin
            layoutControlPanel(relativeTo: frame)
        case .leftMouseUp:
            customOrigin = panel.frame.origin
            dragStartPanelOrigin = nil
            dragStartMouseLocation = nil
        default:
            break
        }
    }

    private func render() {
        hostingView.rootView = SubtitleView(
            snapshot: snapshot,
            displayMode: displayMode,
            fontSize: fontSize,
            isEditingPosition: isEditingPosition
        )
        controlHostingView.rootView = RecordingControlView(
            state: translationState,
            onToggleRecording: onToggleRecording
        )
    }

    private func relayoutIfNeeded(forceDefault: Bool = false) {
        let target = Self.defaultFrame(for: NSScreen.main)
        var frame = panel.frame
        frame.size = target.size

        if forceDefault || customOrigin == nil {
            frame.origin = target.origin
        } else if let customOrigin {
            frame.origin = customOrigin
        }

        // Keep panel on the visible screen.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
        layoutControlPanel(relativeTo: frame)
    }

    private func layoutControlPanel(relativeTo subtitleFrame: NSRect) {
        controlPanel.setFrame(Self.controlFrame(for: subtitleFrame), display: true)
    }

    private static func controlFrame(for subtitleFrame: NSRect) -> NSRect {
        let size = NSSize(width: 160, height: 48)
        return NSRect(
            x: subtitleFrame.midX - size.width / 2,
            y: subtitleFrame.maxY + 8,
            width: size.width,
            height: size.height
        )
    }

    private static func defaultFrame(for screen: NSScreen?) -> NSRect {
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(screenFrame.width * 0.70, 1200)
        // Two paired subtitle blocks can each wrap to multiple lines. The panel is transparent,
        // so reserve enough vertical layout space to avoid clipping the current translation.
        let height: CGFloat = 280
        let x = screenFrame.midX - width / 2
        let y = screenFrame.minY + 48
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
