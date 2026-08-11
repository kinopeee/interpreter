# Realtime Translator

macOSメニューバー常駐の、ローカル完結型リアルタイム字幕翻訳アプリです。

`SpeechAnalyzer`で音声を文字起こしし、Apple Translationで選択した2言語間を双方向に翻訳します。音声・原文・翻訳は外部サービスへ送信しません。

対応する言語ペアは「日本語 ↔ 英語」「日本語 ↔ スペイン語」「英語 ↔ スペイン語」で、設定から選びます。

## 要件

- macOS 26以降
- Apple Silicon
- Xcode 26 / XcodeGen
- 初回モデル取得時のみインターネット接続

APIキーや有料API契約は不要です。

## セットアップ

```bash
brew install xcodegen   # 未導入の場合
cd /Users/yoo/dev/interpreter
xcodegen generate
open RealtimeTranslator.xcodeproj
```

CLIからビルド・起動する場合:

```bash
./scripts/run.sh
```

## 使い方

1. アプリを起動します。Dockには表示されず、メニューバーと字幕オーバーレイに表示されます。
2. メニューバーの設定から言語ペアを選びます（既定は日本語 ↔ 英語）。
3. 初回はmacOSの案内に従い、マイク使用と選択した言語のモデルのダウンロードを許可します。
4. 字幕上の「録音開始」を押して話します。
5. ペアのどちらの言語で話しても、もう一方の言語へ自動翻訳されます。
6. 「録音終了」で停止します。

言語ペアの変更は次回の録音開始時に反映されます。

開始・停止は `Control + Option + Space` でも切り替えられます。

## アーキテクチャ

```text
マイク
  → AVAudioEngine
  → SpeechAnalyzer（選択ペアの2言語、端末内）
  → 信頼度とテキストの言語証拠による発話言語選択
  → Apple Translation（ペアの反対言語、端末内）
  → 原文＋翻訳のNSPanel字幕
```

## テスト

```bash
xcodegen generate
xcodebuild test \
  -scheme RealtimeTranslator \
  -destination 'platform=macOS' \
  -derivedDataPath ./build/DerivedData \
  -enableCodeCoverage YES
```

## 注意

- 初回のみ、選択した言語ペアの音声認識・翻訳モデルをダウンロードします。
- モデル取得後はオフラインで利用できます。
- 翻訳API料金は発生しません。
- MVPでは翻訳音声の読み上げは行いません。
