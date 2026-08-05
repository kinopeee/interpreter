import CoreGraphics
import Foundation
import Observation

enum TranslationState: String, Sendable {
    case idle
    case connecting
    case listening
    case reconnecting
    case closing
    case error
}

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let fontSize = "subtitleFontSize"
        static let panelOriginX = "panelOriginX"
        static let panelOriginY = "panelOriginY"
        static let hasCustomPanelOrigin = "hasCustomPanelOrigin"
        /// 同意文言が変わったらバージョンを上げ、再同意を求める。
        static let openAIConsentVersion = "openAIConsentVersion"
    }

    /// 現在有効な同意バージョン。文言変更時にインクリメントする。
    static let currentOpenAIConsentVersion = 1

    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }

    var hasCustomPanelOrigin: Bool {
        didSet { UserDefaults.standard.set(hasCustomPanelOrigin, forKey: Keys.hasCustomPanelOrigin) }
    }

    var panelOriginX: Double {
        didSet { UserDefaults.standard.set(panelOriginX, forKey: Keys.panelOriginX) }
    }

    var panelOriginY: Double {
        didSet { UserDefaults.standard.set(panelOriginY, forKey: Keys.panelOriginY) }
    }

    var acceptedOpenAIConsentVersion: Int {
        didSet {
            UserDefaults.standard.set(
                acceptedOpenAIConsentVersion,
                forKey: Keys.openAIConsentVersion
            )
        }
    }

    var hasAcceptedCurrentOpenAIConsent: Bool {
        acceptedOpenAIConsentVersion >= Self.currentOpenAIConsentVersion
    }

    init() {
        let defaults = UserDefaults.standard
        let storedFont = defaults.double(forKey: Keys.fontSize)
        fontSize = storedFont > 0 ? storedFont : 32
        hasCustomPanelOrigin = defaults.bool(forKey: Keys.hasCustomPanelOrigin)
        panelOriginX = defaults.double(forKey: Keys.panelOriginX)
        panelOriginY = defaults.double(forKey: Keys.panelOriginY)
        acceptedOpenAIConsentVersion = defaults.integer(forKey: Keys.openAIConsentVersion)
    }

    func acceptOpenAIConsent() {
        acceptedOpenAIConsentVersion = Self.currentOpenAIConsentVersion
    }

    func customPanelOrigin() -> CGPoint? {
        guard hasCustomPanelOrigin else { return nil }
        return CGPoint(x: panelOriginX, y: panelOriginY)
    }

    func savePanelOrigin(_ origin: CGPoint) {
        panelOriginX = origin.x
        panelOriginY = origin.y
        hasCustomPanelOrigin = true
    }
}
