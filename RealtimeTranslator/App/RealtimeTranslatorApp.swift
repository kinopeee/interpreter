import AppKit
import Foundation

/// Pure AppKit entry. Avoid SwiftUI `App` lifecycle.
///
/// On macOS 26 + Swift 6, `NSApplicationDelegate` methods are MainActor-isolated by the SDK.
/// AppKit invokes `applicationShouldTerminateAfterLastWindowClosed` from a CFRunLoop timer;
/// the MainActor executor check then null-dereferences. All delegate callbacks are `nonisolated`.
@main
enum RealtimeTranslatorMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.retained = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)

        // Bootstrap from the main queue after `run()` starts — do not rely solely on
        // `applicationDidFinishLaunching` (can race with MainActor isolation on macOS 26).
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AppRuntime.start()
            }
        }

        app.run()
    }
}

enum AppStatusFile {
    static let path = "/tmp/realtimetranslator.status"

    static func write(_ status: String, state: String = "") {
        let body = state.isEmpty ? "\(status)\n" : "\(status)\n\(state)\n"
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

@MainActor
enum AppRuntime {
    private(set) static var coordinator: AppCoordinator?
    private static var keepAliveWindow: NSWindow?
    private static var didStart = false
    private static var duplicateCleanupAttempts = 0

    static func start() {
        guard !didStart else { return }
        guard terminateOtherInstancesIfNeeded() else { return }
        didStart = true
        AppStatusFile.write("boot")
        installKeepAliveWindow()
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    private static func terminateOtherInstancesIfNeeded() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return true }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }

        guard !otherInstances.isEmpty else { return true }
        duplicateCleanupAttempts += 1
        for instance in otherInstances {
            if duplicateCleanupAttempts >= 3 {
                instance.forceTerminate()
            } else {
                instance.terminate()
            }
        }

        AppStatusFile.write("closing_duplicate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            AppRuntime.start()
        }
        return false
    }

    private static func installKeepAliveWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.level = .normal
        window.orderBack(nil)
        keepAliveWindow = window
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var retained: AppDelegate?

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        // Backup bootstrap path.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AppRuntime.start()
            }
        }
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    nonisolated func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }
}
