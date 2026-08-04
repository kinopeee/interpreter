import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var onSave: (() -> Void)?

    var body: some View {
        Form {
            Section("処理方式") {
                LabeledContent("音声認識", value: "Apple SpeechAnalyzer（端末内）")
                LabeledContent("翻訳", value: "Apple Translation（端末内）")
                LabeledContent("翻訳方向", value: "自動（日本語 ↔ 英語）")
                LabeledContent("字幕表示", value: "原文＋翻訳")
                Text("初回のみ、macOSが日英モデルのダウンロード許可を求めることがあります。音声と字幕は外部へ送信されません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("字幕") {
                Stepper(value: $settings.fontSize, in: 18...48, step: 2) {
                    Text("フォントサイズ: \(Int(settings.fontSize))pt")
                }
            }

            Section("操作") {
                Text("字幕上の「録音開始」「録音終了」ボタン、または Control + Option + Space を使用します。")
                    .font(.callout)
            }
        }
        .padding(20)
        .frame(width: 520, height: 340)
        .onDisappear {
            onSave?()
        }
    }
}
