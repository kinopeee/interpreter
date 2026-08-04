# RealtimeTranslator 開発ガイド

## 目的と不変条件

- macOS 26以降向けの、ローカル完結型リアルタイム日英字幕アプリである。
- 音声・原文・訳文を外部サービスへ送信しない。OpenAI、WebSocket、外部翻訳APIを追加しない。
- 通信は初回のApple製音声認識・翻訳モデル取得に限る。APIキーやネットワーク権限は不要。
- 日本語音声は英語、英語音声は日本語へ自動翻訳し、原文と訳文を常にペア表示する。

## 構成

- `App/`: AppKitライフサイクルと全体調停。SwiftUI `App`へ戻さない。
- `Audio/LocalSpeechRecognitionService.swift`: AVAudioEngine、SpeechAnalyzer、日英2レーン。
- `Audio/SpokenLanguage.swift`: 言語判定と文単位のレーン固定。
- `Translation/LocalTranslationService.swift`: SwiftUI `translationTask`に結び付いた2方向のApple Translation。
- `Realtime/InterpretationSession.swift`: 認識、表示スロットリング、翻訳、状態遷移を統合。
- `Subtitles/`: current/previous字幕集約、透明オーバーレイ、録音コントロール。
- `project.yml`: XcodeGen設定、Info.plist項目、権限説明の正本。

## 並行処理

- UI、AppKit、セッション状態は`@MainActor`で扱う。
- `NSApplicationDelegate`メソッドは`nonisolated`を維持する。SDK既定のMainActor隔離へ戻すとCFRunLoop経由でクラッシュし得る。
- 起動は`DispatchQueue.main.async`と`MainActor.assumeIsolated { AppRuntime.start() }`を使い、delegate通知だけに依存しない。
- Core Audio、TCC、URLSession等のコールバックがMainActor上で呼ばれると仮定しない。
- リアルタイム音声tapではバッファをキューへ渡すだけにし、変換や認識処理を行わない。
- `AVAudioConverter`は状態を持つため、単一feederタスクから直列に呼ぶ。
- 非MainActorコールバックにMainActor継承クロージャを渡さない。明示的な`@Sendable`ヘルパーを使う。
- Swift 6 strict concurrencyを維持し、警告回避目的の`@unchecked Sendable`は境界型だけに限定する。
- importは必ずファイル先頭へ置き、関数内importを追加しない。

## SpeechとTranslationの制約

- `SpeechTranscriber`自体に言語自動判定はない。日英2レーンを同じ`SpeechAnalyzer`で処理する。
- `BilingualSpeechArbiter`で選択したレーンは確定結果まで固定し、表示言語の往復を防ぐ。
- 音声形式を固定値にせず、モデル準備後に`bestAvailableAudioFormat`を取得する。
- 正常停止は入力を閉じてから`finalizeAndFinishThroughEndOfInput()`を呼ぶ。
- `TranslationSession`は非Sendableでビュー寿命に依存する。`LocalTranslationHostView`を破棄・再生成しない。
- `translationTask`内でセッションを使い、キャンセル済みセッションを再利用しない。
- 翻訳結果は世代番号で照合し、発話更新前の古い結果を画面へ反映しない。
- リアルタイム用途ではmacOS 26.4以降の`.lowLatency`を優先する。

## 字幕UIの不変条件

- 字幕本文パネルはクリック透過、録音ボタンの別パネルだけを操作可能にする。
- `.floating`、`.canJoinAllSpaces`、`.fullScreenAuxiliary`を維持し、他アプリやフルスクリーン上の表示を壊さない。
- スライドを隠す全面黒背景へ戻さない。文字周辺の薄い背景と黒いハローで可読性を確保する。
- currentとpreviousを分離し、原文だけを確定しない。
- 更新待ちの旧訳文は`isTranslationCurrent = false`かつ`canFinalize = false`にする。
- 発話途中の原文表示は約160ms間隔に抑え、行高を維持してちらつきを防ぐ。
- パネル高は複数行の2ブロックを収め、下段のベースラインをクリップしない。

## プロジェクト設定

- `RealtimeTranslator.xcodeproj`と`Info.plist`はXcodeGen生成物として扱う。
- 永続的なInfo.plist変更は`project.yml`の`targets.RealtimeTranslator.info.properties`へ追加する。
- `NSMicrophoneUsageDescription`と`NSSpeechRecognitionUsageDescription`を削除しない。
- `RealtimeTranslator.entitlements`へネットワーククライアント権限を追加しない。
- 同一Bundle IDの多重起動を許さない。Xcode実行と`run.sh`を同時に残さない。

## ビルドと検証

```bash
xcodegen generate
xcodebuild -scheme RealtimeTranslator \
  -destination 'platform=macOS' \
  -derivedDataPath ./build/DerivedData build

xcodebuild test -scheme RealtimeTranslator \
  -destination 'platform=macOS' \
  -derivedDataPath ./build/DerivedData \
  -enableCodeCoverage YES
```

- 実行は`./scripts/run.sh`を使い、バイナリを直接起動しない。LaunchServices経由でTCC権限を認識させる。
- 権限、モデル取得、実マイク、オフライン動作はユニットテストだけでは検証できない。
- 手動検証項目は`VALIDATION.md`も参照する。
- 実行状態は`/tmp/realtimetranslator.status`で確認する。
- クラッシュ時は最新のDiagnosticReportsと該当スレッドを確認し、推測だけで修正しない。
- ログへ認識した発話内容を出力しない。

## テスト方針

- 純粋ロジックはXCTestで検証し、各テストに日本語のGiven/When/Thenコメントを付ける。
- 最低限、言語判定、レーン固定と解除、字幕ペア確定、旧訳文での誤確定防止を維持する。
- 非同期境界、空文字、句読点、停止時finalize、多重起動の回帰を優先する。
- UIや音声経路を変更したら、ビルドと全テストに加えて実際に日英を1文ずつ話して確認する。
