# OpenAI Realtime版 検証記録

日付: 2026-08-05

## 自動検証

- `xcodegen generate`: 成功
- `xcodebuild build`: 成功（`platform=macOS` / `./build/DerivedData`）
- `xcodebuild test`: 成功（94 tests, 0 failures, coverage enabled）
- カバーした単体テスト:
  - Keychain / 環境変数取り込み
  - Realtimeイベントcodec
  - 100 ms PCM16 packet化
  - Connection handshake / auth失敗 / close drain / send timeout
  - 専用live transcription・原文送信分離・preroll・翻訳停滞時の原文継続
  - 字幕lane選択・句読点/idle確定
  - InterpretationSessionの開始ゲート・二重stop・再接続・秘密非漏洩

## 実APIスモーク（マイクなし）

同一APIキーで `gpt-live-transcribe`、`target=en`、`target=ja` を同時接続できることを確認済み。専用transcriptionはcommit前から最初の原文deltaを約0.34秒で返すことも確認した。

- 結果: 専用transcription接続・継続delta受信に成功
- 字幕本文・APIキーはログへ未出力

## 実マイク検証（手動）

```bash
cd /Users/yoo/dev/interpreter-openai
# 事前にXcode schemeまたは設定画面でAPIキーをKeychainへ保存する
./scripts/run.sh
```

1. 初回のマイク権限と、設定画面での同意・APIキー保存を完了します。
2. 字幕上の「録音開始」を押します。
3. 日本語を話し、原文と英訳が表示されることを確認します。
4. 続けて英語を話し、原文と和訳が再起動なしで切り替わることを確認します。
5. 「録音終了」を押し、停止直前の発話が完全ペアとして残ることを確認します。

追加確認:

- [ ] Cursor / Chrome / Zoom / Keynoteより前面に表示される
- [ ] フルスクリーン中も字幕が表示される
- [ ] 字幕本文上のクリックが背後アプリへ届く
- [ ] 1語、固有名詞、数字、早口、長文、日英混在で誤lane・重複表示がない
- [ ] 無効キー、ネット切断、片側socket切断、再接続上限を正しく表示する
- [ ] ログ、status file、クラッシュ情報にAPIキー・音声・字幕本文がない
- [ ] 1時間連続でqueue増大、buffer leak、再接続loopがなく、OpenAI usageが想定範囲である
