import AppKit
import SwiftUI
import XCTest
@testable import RealtimeTranslator

@MainActor
final class SubtitlePresentationTests: XCTestCase {
    func testMetadataOnlyChangesKeepSamePresentation() {
        // Given: 表示文字が同じで、更新時刻・状態・freshnessだけが異なる字幕
        let first = snapshot(
            current: subtitle(
                source: "同じ原文",
                translation: "Same translation",
                isTranslationCurrent: false,
                state: .live,
                updatedAt: .distantPast
            )
        )
        let second = snapshot(
            current: subtitle(
                source: "同じ原文",
                translation: "Same translation",
                isTranslationCurrent: true,
                state: .finalized,
                updatedAt: Date()
            )
        )

        // When: 描画に必要な表示状態へ変換する
        let firstPresentation = first.presentation
        let secondPresentation = second.presentation

        // Then: 意味メタデータだけでは再描画対象にしない
        XCTAssertEqual(firstPresentation, secondPresentation)
    }

    func testSourceTextChangeChangesPresentation() {
        // Given: 訳文は同じで原文だけが更新された字幕
        let first = snapshot(
            current: subtitle(source: "短い", translation: "Translation")
        )
        let second = snapshot(
            current: subtitle(source: "短い原文", translation: "Translation")
        )

        // When: 表示状態を比較する
        // Then: 読者に見える原文変更を再描画対象にする
        XCTAssertNotEqual(first.presentation, second.presentation)
    }

    func testTranslationTextChangeChangesPresentation() {
        // Given: 原文は同じで訳文だけが更新された字幕
        let first = snapshot(
            current: subtitle(source: "原文", translation: "Old translation")
        )
        let second = snapshot(
            current: subtitle(source: "原文", translation: "New translation")
        )

        // When: 表示状態を比較する
        // Then: 読者に見える訳文変更を再描画対象にする
        XCTAssertNotEqual(first.presentation, second.presentation)
    }

    func testPreviousFadeOpacityChangeChangesPresentation() {
        // Given: 表示文字が同じで前文のfade値だけが異なるsnapshot
        let previous = subtitle(source: "前文", translation: "Previous")
        let first = snapshot(
            current: .empty,
            previous: previous,
            previousOpacity: 1
        )
        let second = snapshot(
            current: .empty,
            previous: previous,
            previousOpacity: 0.5
        )

        // When: 表示状態を比較する
        // Then: 意図したfadeは再描画対象にする
        XCTAssertNotEqual(first.presentation, second.presentation)
    }

    func testTranslationFreshnessDoesNotChangeVisibleOpacity() {
        // Given: 同じ非空訳文を持つ更新待ち字幕と最新字幕
        let stale = subtitle(
            source: "原文",
            translation: "Readable translation",
            isTranslationCurrent: false
        )
        let current = subtitle(
            source: "原文",
            translation: "Readable translation",
            isTranslationCurrent: true
        )

        // When: 訳文の表示opacityを算出する
        let staleOpacity = SubtitleVisualStyle.translatedTextOpacity(for: stale)
        let currentOpacity = SubtitleVisualStyle.translatedTextOpacity(for: current)

        // Then: freshness更新で明滅させず、どちらも完全表示する
        XCTAssertEqual(staleOpacity, 1)
        XCTAssertEqual(currentOpacity, 1)
    }

    func testEmptyTranslationRemainsHidden() {
        // Given: 翻訳結果がまだ空の字幕
        let subtitle = subtitle(source: "原文", translation: "")

        // When: 訳文の表示opacityを算出する
        let opacity = SubtitleVisualStyle.translatedTextOpacity(for: subtitle)

        // Then: 空のプレースホルダー文字は表示しない
        XCTAssertEqual(opacity, 0)
    }

    func testPreviousBlockRemainsFullOpacityUntilFadeStarts() {
        // Given: 保持時間内でopacityが1の確定済み前文
        let snapshot = snapshot(
            current: .empty,
            previous: subtitle(source: "前文", translation: "Previous"),
            previousOpacity: 1
        )

        // When: 前文ブロックの表示opacityを算出する
        let opacity = SubtitleVisualStyle.previousBlockOpacity(for: snapshot)

        // Then: currentからpreviousへの移動だけでは暗くしない
        XCTAssertEqual(opacity, 1)
    }

    func testTextLayoutUsesCompactLimitsAndKeepsSentenceEnd() {
        // Given: 行数を超える現在文と前文を同時に表示する字幕
        // When: 各ブロックの最大行数と省略位置の設定を確認する
        let currentLineLimit = SubtitleTextLayout.currentLineLimit
        let previousLineLimit = SubtitleTextLayout.previousLineLimit
        let truncationMode = SubtitleTextLayout.truncationMode

        // Then: 行数を抑えつつ文頭を省略し、必要な文末を残す
        XCTAssertEqual(currentLineLimit, 2)
        XCTAssertEqual(previousLineLimit, 1)
        XCTAssertLessThan(SubtitleTextLayout.previousFontScale, 1)
        XCTAssertEqual(truncationMode, .head)
    }

    func testLongTranslationHeightIsBoundedByLineLimit() {
        // Given: 1行の訳文と、同じ幅で何行にも折り返す長文訳
        let shortView = SubtitleView(
            snapshot: snapshot(
                current: subtitle(source: "", translation: "Short translation")
            ),
            displayMode: .both,
            fontSize: 32,
            isEditingPosition: false
        )
        let longText = Array(
            repeating: "This translation should remain fully readable.",
            count: 30
        ).joined(separator: " ")
        let longView = SubtitleView(
            snapshot: snapshot(
                current: subtitle(source: "", translation: longText)
            ),
            displayMode: .both,
            fontSize: 32,
            isEditingPosition: false
        )

        // When: 同じ600pt幅でSwiftUIの固有高を計測する
        let shortHeight = measuredHeight(of: shortView, width: 600)
        let longHeight = measuredHeight(of: longView, width: 600)

        // Then: 長文でも2行分を超えてパネルを縦に拡大しない
        XCTAssertGreaterThan(longHeight, shortHeight)
        XCTAssertLessThan(longHeight, shortHeight + 80)
    }

    func testControllerKeepsLongSubtitlePanelInsideScreen() throws {
        // Given: 字幕ウィンドウ作成前のパネル一覧と、画面高を超える長文字幕
        let existingPanels = Set(
            NSApp.windows
                .compactMap { $0 as? SubtitlePanel }
                .map(ObjectIdentifier.init)
        )
        let controller = SubtitleWindowController(
            translationService: LocalTranslationService()
        )
        defer { controller.tearDown() }
        let longText = Array(
            repeating: "画面外へ押し出されない長文字幕を表示します。",
            count: 100
        ).joined()

        // When: 長文字幕を描画してAppKitのレイアウト更新を処理する
        controller.update(
            snapshot: snapshot(
                current: subtitle(source: longText, translation: longText)
            ),
            displayMode: .both,
            fontSize: 32,
            translationState: .listening
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let subtitlePanel = try XCTUnwrap(
            createdPanels(excluding: existingPanels).max {
                $0.frame.width < $1.frame.width
            }
        )
        let visibleFrame = try XCTUnwrap(
            subtitlePanel.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? NSScreen.screens.first?.visibleFrame
        )

        // Then: SwiftUIの固有高に再拡大されず、操作パネル分を残して画面内に収まる
        XCTAssertNil(subtitlePanel.contentViewController)
        XCTAssertLessThanOrEqual(
            subtitlePanel.frame.height,
            visibleFrame.height
                - SubtitleWindowGeometry.controlSize.height
                - SubtitleWindowGeometry.controlSpacing
        )
        XCTAssertTrue(visibleFrame.contains(subtitlePanel.frame))
    }

    func testControllerKeepsControlPositionWhileSubtitleGrows() throws {
        // Given: 短文字幕を表示した字幕・操作パネル
        let existingPanels = Set(
            NSApp.windows
                .compactMap { $0 as? SubtitlePanel }
                .map(ObjectIdentifier.init)
        )
        let controller = SubtitleWindowController(
            translationService: LocalTranslationService()
        )
        defer { controller.tearDown() }
        controller.update(
            snapshot: snapshot(
                current: subtitle(source: "短い原文", translation: "Short translation")
            ),
            displayMode: .both,
            fontSize: 32,
            translationState: .listening
        )
        let controlPanel = try XCTUnwrap(
            createdPanels(excluding: existingPanels).min {
                $0.frame.width < $1.frame.width
            }
        )
        let shortOrigin = controlPanel.frame.origin
        let longerText = Array(
            repeating: "通常の発話で字幕行が増えても操作位置を固定します。",
            count: 8
        ).joined()

        // When: 画面内に収まる範囲で字幕の行数だけを増やす
        controller.update(
            snapshot: snapshot(
                current: subtitle(source: longerText, translation: longerText)
            ),
            displayMode: .both,
            fontSize: 32,
            translationState: .listening
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Then: 録音終了ボタンのパネル位置は変化しない
        XCTAssertEqual(controlPanel.frame.origin.x, shortOrigin.x, accuracy: 0.5)
        XCTAssertEqual(controlPanel.frame.origin.y, shortOrigin.y, accuracy: 0.5)
    }

    private func snapshot(
        current: LiveSubtitle,
        previous: LiveSubtitle? = nil,
        previousOpacity: Double = 1
    ) -> SubtitleSnapshot {
        SubtitleSnapshot(
            current: current,
            previous: previous,
            statusBanner: nil,
            previousOpacity: previousOpacity
        )
    }

    private func subtitle(
        source: String,
        translation: String,
        isTranslationCurrent: Bool = true,
        state: SubtitleBlockState = .live,
        updatedAt: Date = Date()
    ) -> LiveSubtitle {
        LiveSubtitle(
            sourceText: source,
            translatedText: translation,
            lastUpdatedAt: updatedAt,
            state: state,
            isTranslationCurrent: isTranslationCurrent,
            canFinalize: isTranslationCurrent
        )
    }

    private func measuredHeight(of view: SubtitleView, width: CGFloat) -> CGFloat {
        let hostingController = NSHostingController(rootView: view)
        return hostingController.sizeThatFits(
            in: NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
        ).height
    }

    private func createdPanels(
        excluding existingPanels: Set<ObjectIdentifier>
    ) -> [SubtitlePanel] {
        NSApp.windows
            .compactMap { $0 as? SubtitlePanel }
            .filter { !existingPanels.contains(ObjectIdentifier($0)) }
    }
}
