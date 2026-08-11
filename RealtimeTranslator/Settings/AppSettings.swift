import CoreGraphics
import Foundation
import Observation

enum TranslationState: String, Sendable {
    case idle
    case connecting
    case listening
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
        static let languagePair = "languagePair"
    }

    var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }

    /// 原文と訳文の言語ペア。認識レーンと翻訳セッションを張り直す必要があるため、
    /// 変更は次の録音開始時に反映する。
    var languagePair: LanguagePair {
        didSet {
            UserDefaults.standard.set(languagePair.rawValue, forKey: Keys.languagePair)
        }
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

    init() {
        let defaults = UserDefaults.standard
        let storedFont = defaults.double(forKey: Keys.fontSize)
        fontSize = storedFont > 0 ? storedFont : 32
        languagePair = LanguagePair.from(
            rawValue: defaults.string(forKey: Keys.languagePair)
        )
        hasCustomPanelOrigin = defaults.bool(forKey: Keys.hasCustomPanelOrigin)
        panelOriginX = defaults.double(forKey: Keys.panelOriginX)
        panelOriginY = defaults.double(forKey: Keys.panelOriginY)
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
