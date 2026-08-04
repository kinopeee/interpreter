import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private weak var coordinator: AppCoordinator?
    private var startStopItem: NSMenuItem?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        rebuildMenu()
    }

    func refresh() {
        rebuildMenu()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "captions.bubble",
                accessibilityDescription: "Realtime Translator"
            )
            button.image?.isTemplate = true
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let startStop = NSMenuItem(
            title: startStopTitle(),
            action: #selector(toggleStartStop),
            keyEquivalent: ""
        )
        startStop.target = self
        startStopItem = startStop
        menu.addItem(startStop)
        menu.addItem(.separator())

        let directionItem = NSMenuItem(
            title: "翻訳方向: 自動（日本語 ↔ 英語）",
            action: nil,
            keyEquivalent: ""
        )
        directionItem.isEnabled = false
        menu.addItem(directionItem)

        let displayItem = NSMenuItem(
            title: "字幕表示: 原文＋翻訳",
            action: nil,
            keyEquivalent: ""
        )
        displayItem.isEnabled = false
        menu.addItem(displayItem)

        let audioRoot = NSMenuItem(title: "翻訳音声", action: nil, keyEquivalent: "")
        let audioMenu = NSMenu(title: "翻訳音声")
        let muteItem = NSMenuItem(title: "ミュート", action: nil, keyEquivalent: "")
        muteItem.state = .on
        let playItem = NSMenuItem(title: "再生（MVP未対応）", action: nil, keyEquivalent: "")
        playItem.isEnabled = false
        audioMenu.addItem(muteItem)
        audioMenu.addItem(playItem)
        menu.setSubmenu(audioMenu, for: audioRoot)
        menu.addItem(audioRoot)

        menu.addItem(.separator())
        let editPositionItem = NSMenuItem(
            title: "字幕位置を編集",
            action: #selector(togglePositionEditing),
            keyEquivalent: ""
        )
        editPositionItem.target = self
        editPositionItem.state = coordinator?.isEditingSubtitlePosition == true ? .on : .off
        menu.addItem(editPositionItem)

        let settingsItem = NSMenuItem(
            title: "設定…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "終了",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateIcon()
    }

    private func startStopTitle() -> String {
        switch coordinator?.translationState {
        case .connecting, .listening, .closing:
            return "翻訳を停止"
        case .idle, .error, .none:
            return "翻訳を開始"
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let state = coordinator?.translationState ?? .idle
        let symbolName: String
        switch state {
        case .idle:
            symbolName = "captions.bubble"
        case .connecting, .closing:
            symbolName = "ellipsis.bubble"
        case .listening:
            symbolName = "waveform.badge.mic"
        case .error:
            symbolName = "exclamationmark.bubble"
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: state.rawValue)
        button.image?.isTemplate = true
        button.toolTip = "Realtime Translator (\(state.rawValue))"
    }

    @objc private func toggleStartStop() {
        coordinator?.toggleTranslation()
    }

    @objc private func togglePositionEditing() {
        coordinator?.toggleSubtitlePositionEditing()
    }

    @objc private func openSettings() {
        coordinator?.openSettings()
    }

    @objc private func quit() {
        coordinator?.quit()
    }
}
