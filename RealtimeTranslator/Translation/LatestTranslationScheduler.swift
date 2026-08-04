import Foundation

enum LocalTranslationPriority: Sendable {
    /// 発話途中の暫定訳。常に最新1件だけ保持し、古い依頼は破棄してよい。
    case live
    /// 確定文の訳。取りこぼせないためFIFOで全件処理する(容量上限あり)。
    case final
}

struct TranslationSchedulerEnqueueResult<Item> {
    /// 新しいlive依頼に置き換えられた古いlive依頼。呼び出し側でキャンセルする。
    let supersededLive: Item?
    /// final容量超過で受け付けられなかった依頼。呼び出し側でエラー完了させる。
    let rejectedFinal: Item?
}

/// 翻訳依頼の優先度付きキュー。finalはFIFO、liveは常に最新1件だけを保持する。
///
/// `next()` はfinalを優先して返す。発話途中の訳より確定文の訳を先に届けるため。
struct LatestTranslationScheduler<Item> {
    private let finalCapacity: Int
    private var finalItems: [Item] = []
    private var liveItem: Item?

    init(finalCapacity: Int = 32) {
        precondition(finalCapacity > 0)
        self.finalCapacity = finalCapacity
    }

    var isEmpty: Bool {
        finalItems.isEmpty && liveItem == nil
    }

    var pendingFinalCount: Int {
        finalItems.count
    }

    mutating func enqueue(
        _ item: Item,
        priority: LocalTranslationPriority
    ) -> TranslationSchedulerEnqueueResult<Item> {
        switch priority {
        case .live:
            let superseded = liveItem
            liveItem = item
            return TranslationSchedulerEnqueueResult(
                supersededLive: superseded,
                rejectedFinal: nil
            )
        case .final:
            guard finalItems.count < finalCapacity else {
                return TranslationSchedulerEnqueueResult(
                    supersededLive: nil,
                    rejectedFinal: item
                )
            }
            // finalが来た時点でliveの暫定訳は不要になる(確定文の方が新しい)。
            let superseded = liveItem
            liveItem = nil
            finalItems.append(item)
            return TranslationSchedulerEnqueueResult(
                supersededLive: superseded,
                rejectedFinal: nil
            )
        }
    }

    mutating func next() -> Item? {
        if !finalItems.isEmpty {
            return finalItems.removeFirst()
        }
        defer { liveItem = nil }
        return liveItem
    }

    mutating func removeAll(where shouldRemove: (Item) -> Bool) -> [Item] {
        var removed: [Item] = []
        if let liveItem, shouldRemove(liveItem) {
            removed.append(liveItem)
            self.liveItem = nil
        }

        var retainedFinalItems: [Item] = []
        retainedFinalItems.reserveCapacity(finalItems.count)
        for item in finalItems {
            if shouldRemove(item) {
                removed.append(item)
            } else {
                retainedFinalItems.append(item)
            }
        }
        finalItems = retainedFinalItems
        return removed
    }

    mutating func removeAll() -> [Item] {
        var removed = finalItems
        if let liveItem {
            removed.append(liveItem)
        }
        finalItems.removeAll(keepingCapacity: true)
        liveItem = nil
        return removed
    }
}
