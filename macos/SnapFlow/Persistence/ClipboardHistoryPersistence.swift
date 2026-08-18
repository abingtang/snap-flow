import Foundation
import SwiftData

struct ClipboardHistoryWriteResult: Sendable {
    let itemID: UUID
    let fingerprint: String
    let createdAt: Date
    let copyCount: Int
    let application: String?
    let isUniversalClipboard: Bool
    let removedItemIDs: Set<UUID>
}

/// 自动剪切板记录使用独立模型上下文，避免 save() 占用主线程。
@ModelActor
actor ClipboardHistoryPersistence {
    func insert(
        prepared: ClipboardHistoryPreparedItem,
        application: String?,
        isUniversalClipboard: Bool,
        historyLimit: Int
    ) throws -> ClipboardHistoryWriteResult? {
        guard !prepared.payloads.isEmpty else { return nil }

        let now = Date()
        let fingerprint = prepared.fingerprint
        let descriptor = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.fingerprint == fingerprint }
        )

        if let existing = try modelContext.fetch(descriptor).first {
            existing.createdAt = now
            existing.copyCount += 1
            existing.application = application
            existing.isUniversalClipboard = isUniversalClipboard
            try modelContext.save()
            return makeResult(for: existing, removedItemIDs: [])
        }

        let contents = prepared.payloads.map {
            HistoryItemContent(type: $0.type, value: $0.value)
        }
        let item = HistoryItem(
            fingerprint: prepared.fingerprint,
            title: prepared.title,
            searchText: prepared.searchText,
            application: application,
            isUniversalClipboard: isUniversalClipboard,
            contents: contents
        )
        modelContext.insert(item)

        let limit = max(historyLimit, 10)
        var allItems = try modelContext.fetch(
            FetchDescriptor<HistoryItem>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        )
        if !allItems.contains(where: { $0.id == item.id }) {
            allItems.append(item)
            allItems.sort { $0.createdAt > $1.createdAt }
        }

        let overflow = Array(
            allItems
                .filter { !$0.isPinned && !$0.isFavorite }
                .dropFirst(limit)
        )
        let removedItemIDs = Set(overflow.map(\.id))
        overflow.forEach(modelContext.delete)

        try modelContext.save()
        return makeResult(for: item, removedItemIDs: removedItemIDs)
    }

    private func makeResult(
        for item: HistoryItem,
        removedItemIDs: Set<UUID>
    ) -> ClipboardHistoryWriteResult {
        ClipboardHistoryWriteResult(
            itemID: item.id,
            fingerprint: item.fingerprint,
            createdAt: item.createdAt,
            copyCount: item.copyCount,
            application: item.application,
            isUniversalClipboard: item.isUniversalClipboard,
            removedItemIDs: removedItemIDs
        )
    }
}
