# ローカル版検証記録

日付: 2026-08-04

## 自動検証

- `xcodegen generate`: 成功
- `xcodebuild build`: `BUILD SUCCEEDED`
- `xcodebuild test`: `TEST SUCCEEDED`
- `SubtitleAggregatorTests`: 原文・翻訳ペア、句読点、アイドル確定、フェード、停止時確定
- `SpokenLanguageDetectorTests`: 日本語、英語、混在、空文字、数字・記号

## 実マイク検証

```bash
cd /Users/yoo/dev/interpreter
./scripts/run.sh
```

1. 初回のマイク権限とモデルダウンロードを許可します。
2. 字幕上の「録音開始」を押します。
3. 日本語を話し、原文と英訳が表示されることを確認します。
4. 英語を話し、原文と和訳が表示されることを確認します。
5. 「録音終了」を押し、待機状態へ戻ることを確認します。

追加確認:

- [ ] Cursor / Chrome / Zoom / Keynoteより前面に表示される
- [ ] フルスクリーン中も字幕が表示される
- [ ] 字幕本文上のクリックが背後アプリへ届く
- [ ] モデル取得後、ネットワークを切っても日英翻訳できる
- [ ] 1時間連続利用で重大なメモリリークがない
- [ ] 固有名詞（Cursor, Composer, MCPなど）の表示を確認する
