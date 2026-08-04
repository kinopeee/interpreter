 import AppKit
import Darwin
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

enum AppRuntimeEnvironment {
    static func isRunningXCTest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }
}

enum SingleInstanceLeaseError: Error {
    case applicationSupportDirectoryUnavailable
    case bundleIdentifierUnavailable
    case invalidLockPath
    case openFailed(Int32)
    case ownerMetadataWriteFailed(Int32)
}

final class SingleInstanceLease {
    private var fileDescriptor: Int32?

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquireForCurrentUser() throws -> SingleInstanceLease? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            throw SingleInstanceLeaseError.bundleIdentifierUnavailable
        }
        guard let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SingleInstanceLeaseError.applicationSupportDirectoryUnavailable
        }

        let runtimeDirectory = applicationSupportDirectory.appendingPathComponent(
            bundleIdentifier,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true
        )
        return try acquire(
            at: runtimeDirectory.appendingPathComponent("instance.lock")
        )
    }

    static func acquire(at lockURL: URL) throws -> SingleInstanceLease? {
        let flags = O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        guard let descriptor = lockURL.withUnsafeFileSystemRepresentation({ path -> Int32? in
            guard let path else { return nil }
            return Darwin.open(
                path,
                flags,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }) else {
            throw SingleInstanceLeaseError.invalidLockPath
        }

        guard descriptor >= 0 else {
            let errorNumber = errno
            if errorNumber == EWOULDBLOCK || errorNumber == EAGAIN {
                return nil
            }
            throw SingleInstanceLeaseError.openFailed(errorNumber)
        }
        do {
            try writeOwnerPID(to: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return SingleInstanceLease(fileDescriptor: descriptor)
    }

    func release() {
        guard let fileDescriptor else { return }
        self.fileDescriptor = nil
        _ = Darwin.ftruncate(fileDescriptor, 0)
        Darwin.close(fileDescriptor)
    }

    deinit {
        release()
    }

    private static func writeOwnerPID(to descriptor: Int32) throws {
        guard Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) >= 0
        else {
            throw SingleInstanceLeaseError.ownerMetadataWriteFailed(errno)
        }

        let metadata = "\(Darwin.getpid())\n"
        let bytes = Array(metadata.utf8)
        let written = bytes.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return Darwin.write(descriptor, baseAddress, rawBuffer.count)
        }
        guard written == bytes.count else {
            throw SingleInstanceLeaseError.ownerMetadataWriteFailed(errno)
        }
    }
}

@MainActor
enum AppRuntime {
    private(set) static var coordinator: AppCoordinator?
    private static var keepAliveWindow: NSWindow?
    private static var instanceLease: SingleInstanceLease?
    private static var didAttemptStart = false

    static func start() {
        guard !AppRuntimeEnvironment.isRunningXCTest() else { return }
        guard !didAttemptStart else { return }
        didAttemptStart = true

        do {
            guard let lease = try SingleInstanceLease.acquireForCurrentUser() else {
                AppLogger.general.notice(
                    "Another app instance owns the runtime lock; exiting duplicate"
                )
                NSApp.terminate(nil)
                return
            }
            instanceLease = lease
        } catch {
            AppLogger.general.error(
                "Failed to acquire runtime lock: \(error.localizedDescription, privacy: .public)"
            )
            NSApp.terminate(nil)
            return
        }

        AppStatusFile.write("boot")
        installKeepAliveWindow()
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
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
