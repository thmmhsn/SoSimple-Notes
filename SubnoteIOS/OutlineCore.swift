import Foundation
import Combine
import SwiftUI

let supportedTags = ["i", "l"]
let taskRootTitle = "Tasks"
let inboxTaskTitle = "Inbox"
let laterTaskTitle = "Later"
let subnoteICloudContainerIdentifier = "iCloud.com.th.SoSimple"

private let hashtagRegex = try? NSRegularExpression(pattern: #"(?<!\S)#([A-Za-z0-9_-]+)"#)

func hashtagMatches(in title: String) -> [NSTextCheckingResult] {
    guard let hashtagRegex else { return [] }
    let text = title as NSString
    return hashtagRegex.matches(in: title, range: NSRange(location: 0, length: text.length))
}

func sidebarDisplayTitle(_ title: String) -> String {
    let cleaned = title
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "Untitled" : cleaned
}

func titleHidingSupportedTags(_ title: String) -> String {
    let text = title as NSString
    var cleaned = title
    for match in hashtagMatches(in: title).reversed() {
        guard match.numberOfRanges > 1 else { continue }
        let tag = text.substring(with: match.range(at: 1))
        guard supportedTags.contains(tag.lowercased()) else { continue }
        cleaned = (cleaned as NSString).replacingCharacters(in: match.range, with: "")
    }
    return sidebarDisplayTitle(cleaned)
}

func titleHidingSidebarMarkers(_ title: String) -> String {
    sidebarDisplayTitle(title
        .replacingOccurrences(of: "*", with: "")
        .replacingOccurrences(of: "~", with: "")
    )
}

func taskSidebarDisplayTitle(_ title: String) -> String {
    titleHidingSidebarMarkers(titleHidingSupportedTags(title))
}

func outlinePlainText(from items: [OutlineItem]) -> String {
    var lines: [String] = []
    appendPlainTextLines(from: items, depth: 0, to: &lines)
    return lines.joined(separator: "\n")
}

private func appendPlainTextLines(from items: [OutlineItem], depth: Int, to lines: inout [String]) {
    for item in items {
        lines.append(String(repeating: "\t", count: depth) + item.title)
        appendPlainTextLines(from: item.children, depth: depth + 1, to: &lines)
    }
}

func outlineItemsFromPlainText(_ text: String) -> [OutlineItem] {
    let normalizedText = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    guard normalizedText.contains("\n") else { return [] }

    let rows = normalizedText
        .components(separatedBy: "\n")
        .compactMap { rawLine -> (columns: Int, title: String)? in
            let indent = leadingIndentColumns(in: rawLine)
            let content = rawLine.dropFirst(indent.characterCount)
            let title = stripOutlineBullet(from: String(content))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return (indent.columns, title)
        }

    return outlineItems(from: rows.map { ($0.columns, $0.title) })
}

private func outlineItems(from rows: [(levelKey: Int, title: String)]) -> [OutlineItem] {
    guard !rows.isEmpty else { return [] }
    let sortedLevels = Array(Set(rows.map(\.levelKey))).sorted()
    var roots: [OutlineItem] = []
    var levelPaths: [[Int]] = []

    for row in rows {
        let rawLevel = sortedLevels.firstIndex(of: row.levelKey) ?? 0
        let level = min(rawLevel, levelPaths.count)
        let item = OutlineItem(title: row.title)
        let path: [Int]

        if level == 0 {
            roots.append(item)
            path = [roots.index(before: roots.endIndex)]
        } else {
            let parentPath = levelPaths[level - 1]
            path = append(item, toChildrenOf: parentPath, in: &roots)
        }

        if levelPaths.count > level {
            levelPaths.removeSubrange(level..<levelPaths.count)
        }
        levelPaths.append(path)
    }

    return roots
}

private func leadingIndentColumns(in line: String) -> (columns: Int, characterCount: Int) {
    var columns = 0
    var characterCount = 0
    for character in line {
        if character == "\t" {
            columns += 4
            characterCount += 1
        } else if character == " " || character == "\u{00a0}" || character == "\u{2003}" {
            columns += 1
            characterCount += 1
        } else {
            break
        }
    }
    return (columns, characterCount)
}

private func stripOutlineBullet(from line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let bullets = ["•", "◦", "▪", "‣", "⁃", "-", "–", "—"]
    for bullet in bullets where trimmed.hasPrefix(bullet) {
        let remainder = trimmed.dropFirst(bullet.count)
        if remainder.first?.isWhitespace == true {
            return String(remainder)
        }
    }
    return trimmed
}

private func append(_ item: OutlineItem, toChildrenOf path: [Int], in source: inout [OutlineItem]) -> [Int] {
    guard let firstIndex = path.first else {
        source.append(item)
        return [source.index(before: source.endIndex)]
    }

    if path.count == 1 {
        source[firstIndex].isExpanded = true
        source[firstIndex].children.append(item)
        return path + [source[firstIndex].children.index(before: source[firstIndex].children.endIndex)]
    }

    let childPath = append(item, toChildrenOf: Array(path.dropFirst()), in: &source[firstIndex].children)
    return [firstIndex] + childPath
}

struct OutlineItem: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var title: String
    var isExpanded = true
    var isComplete = false
    var tags: [String] = []
    var children: [OutlineItem] = []

    init(
        id: UUID = UUID(),
        title: String,
        isExpanded: Bool = true,
        isComplete: Bool = false,
        tags: [String] = [],
        children: [OutlineItem] = []
    ) {
        self.id = id
        self.title = title
        self.isExpanded = isExpanded
        self.isComplete = isComplete
        self.tags = tags
        self.children = children
    }
}

struct VisibleOutlineItem: Identifiable, Hashable {
    let id: UUID
    let depth: Int
}

struct TaggedOutlineItem: Identifiable, Hashable {
    let id: UUID
    let parentID: UUID?
    let title: String
    let tags: [String]
    let path: [String]
    let projectTitle: String?
}

struct OutlineSearchResult: Identifiable, Hashable {
    let id: UUID
    let title: String
    let path: [String]
    let isComplete: Bool
    let searchableText: String
}

enum OutlineDropPlacement: Equatable, Hashable {
    case before
    case after
    case child
}

private struct OutlineItemSummary {
    let title: String
    let isComplete: Bool
    let childCount: Int
}

private struct SidebarCacheSignature: Equatable {
    let supportedTags: Set<String>
    let isPinned: Bool
    let projectTitle: String?
}

@MainActor
final class OutlineStore: ObservableObject {
    @Published private(set) var items: [OutlineItem] = [] {
        didSet {
            if isApplyingIncrementalMutation {
                if shouldInvalidateDerivedCachesAfterIncrementalMutation {
                    invalidateDerivedCaches()
                    shouldInvalidateDerivedCachesAfterIncrementalMutation = false
                }
                if !isLoadingItems {
                    scheduleSave()
                }
                return
            }

            rebuildIndexes()
            invalidateDerivedCaches()
            if !isLoadingItems {
                scheduleSave()
            }
        }
    }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    let isUsingICloud: Bool

    private let fileManager = FileManager.default
    private let storageURL: URL
    private var itemSummaries: [UUID: OutlineItemSummary] = [:]
    private var parentIDs = Set<UUID>()
    private var parentByID: [UUID: UUID] = [:]
    private var childrenByID: [UUID: [OutlineItem]] = [:]
    private var taskItemsCache: [String: [TaggedOutlineItem]] = [:]
    private var pinnedItemsCache: [TaggedOutlineItem]?
    private var searchResultsCache: [OutlineSearchResult]?
    private var pendingSaveTask: Task<Void, Never>?
    private var undoStack: [[OutlineItem]] = []
    private var redoStack: [[OutlineItem]] = []
    private var isLoadingItems = false
    private var isApplyingIncrementalMutation = false
    private var shouldInvalidateDerivedCachesAfterIncrementalMutation = false
    private let historyLimit = 80

    init() {
        let location = Self.makeStorageURL()
        storageURL = location.url
        isUsingICloud = location.isUsingICloud
        isLoadingItems = true
        load()
        ensureTaskBuckets()
        rebuildIndexes()
        invalidateDerivedCaches()
        isLoadingItems = false
    }

    deinit {
        pendingSaveTask?.cancel()
    }

    func visibleItems(focusedItemID: UUID?, hidesCompletedItems: Bool = false) -> [VisibleOutlineItem] {
        let levelItems = focusedItemID.flatMap { childrenByID[$0] } ?? items
        return levelItems.compactMap { item in
            if hidesCompletedItems, isComplete(item.id) {
                return nil
            }
            return VisibleOutlineItem(id: item.id, depth: 0)
        }
    }

    func breadcrumbs(focusedItemID: UUID?) -> [OutlineItem] {
        guard let focusedItemID else { return [] }
        var ids = [UUID]()
        var currentID: UUID? = focusedItemID
        while let id = currentID {
            ids.append(id)
            currentID = parentByID[id]
        }
        return ids.reversed().compactMap { id in
            guard let summary = itemSummaries[id] else { return nil }
            return OutlineItem(id: id, title: summary.title, isComplete: summary.isComplete)
        }
    }

    func focusedItem(focusedItemID: UUID?) -> OutlineItem? {
        guard let focusedItemID, let summary = itemSummaries[focusedItemID] else { return nil }
        return OutlineItem(id: focusedItemID, title: summary.title, isComplete: summary.isComplete)
    }

    func parentID(for id: UUID) -> UUID? {
        parentByID[id]
    }

    func parentItemIDs() -> Set<UUID> {
        parentIDs
    }

    func title(for id: UUID) -> String {
        itemSummaries[id]?.title ?? ""
    }

    func allTags() -> [String] {
        supportedTags
    }

    func taskItems(filteredBy selectedTag: String?) -> [TaggedOutlineItem] {
        let tag = selectedTag == "l" ? "l" : "i"
        if let cachedItems = taskItemsCache[tag] {
            return cachedItems
        }

        let bucketItems: [TaggedOutlineItem]
        if let bucket = taskBucket(for: tag) {
            var rows: [TaggedOutlineItem] = []
            appendTaskItems(in: bucket.children, path: [bucket.title], parentID: bucket.id, inheritedProjectTitle: nil, into: &rows)
            bucketItems = rows
        } else {
            bucketItems = []
        }

        var seenIDs = Set(bucketItems.map(\.id))
        var taggedRows: [TaggedOutlineItem] = []
        appendTaggedItems(in: items, path: [], parentID: nil, inheritedProjectTitle: nil, filteredBy: tag, into: &taggedRows)
        let taggedItems = taggedRows.filter { item in
            guard !seenIDs.contains(item.id) else { return false }
            seenIDs.insert(item.id)
            return true
        }

        let items = bucketItems + taggedItems
        taskItemsCache[tag] = items
        return items
    }

    func taskBucketID(filteredBy selectedTag: String?) -> UUID? {
        let tag = selectedTag == "l" ? "l" : "i"
        return taskBucket(for: tag)?.id
    }

    func pinnedItems() -> [TaggedOutlineItem] {
        if let pinnedItemsCache {
            return pinnedItemsCache
        }
        var items: [TaggedOutlineItem] = []
        appendPinnedItems(in: self.items, path: [], parentID: nil, inheritedProjectTitle: nil, into: &items)
        pinnedItemsCache = items
        return items
    }

    func searchResults(matching query: String, limit: Int = 80) -> [OutlineSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let allItems = allSearchResults()
        guard !trimmedQuery.isEmpty else {
            return Array(allItems.prefix(limit))
        }

        let tokens = trimmedQuery
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else {
            return Array(allItems.prefix(limit))
        }

        return allItems
            .compactMap { result -> (result: OutlineSearchResult, score: Int)? in
                guard tokens.allSatisfy({ result.searchableText.contains($0) }) else {
                    return nil
                }
                let title = result.title.lowercased()
                var score = 0
                if title.hasPrefix(trimmedQuery.lowercased()) {
                    score += 30
                }
                if tokens.contains(where: { title.hasPrefix($0) }) {
                    score += 15
                }
                if tokens.contains(where: { title.contains($0) }) {
                    score += 8
                }
                score -= min(result.path.count, 8)
                return (result, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.result.title.localizedCaseInsensitiveCompare(rhs.result.title) == .orderedAscending
            }
            .prefix(limit)
            .map(\.result)
    }

    func projectOptions(filteredBy selectedTag: String?) -> [String] {
        Array(Set(taskItems(filteredBy: selectedTag).compactMap(\.projectTitle)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func setTitle(_ title: String, for id: UUID) {
        guard var summary = itemSummaries[id], summary.title != title else { return }
        let oldSignature = sidebarCacheSignature(for: summary.title)
        let newSignature = sidebarCacheSignature(for: title)

        isApplyingIncrementalMutation = true
        shouldInvalidateDerivedCachesAfterIncrementalMutation = oldSignature != newSignature || isTaskSystemTitle(summary.title) || isTaskSystemTitle(title)
        let didUpdate = update(id) { item in
            item.title = title
        }
        isApplyingIncrementalMutation = false
        shouldInvalidateDerivedCachesAfterIncrementalMutation = false

        guard didUpdate else { return }
        summary = OutlineItemSummary(
            title: title,
            isComplete: summary.isComplete,
            childCount: summary.childCount
        )
        itemSummaries[id] = summary
        searchResultsCache = nil
    }

    func addTag(_ rawTag: String, to id: UUID) {
        guard let tag = normalizedTag(rawTag) else { return }
        guard let resolvedTag = allTags().first(where: { $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            return
        }
        let currentTitle = title(for: id)
        guard !parsedTags(in: currentTitle).contains(where: { $0.compare(resolvedTag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            return
        }
        setTitle(currentTitle.trimmingCharacters(in: .whitespaces) + " #\(resolvedTag)", for: id)
    }

    func removeTag(_ tag: String, from id: UUID) {
        setTitle(removeHashtag(tag, from: title(for: id)), for: id)
    }

    func isComplete(_ id: UUID) -> Bool {
        itemSummaries[id]?.isComplete ?? false
    }

    func childCount(for id: UUID) -> Int {
        itemSummaries[id]?.childCount ?? 0
    }

    func addRoot() -> UUID {
        let item = OutlineItem(title: "")
        recordUndoSnapshot()
        items.append(item)
        return item.id
    }

    func addSibling(after id: UUID) -> UUID {
        let sibling = OutlineItem(title: "")
        recordUndoSnapshot()
        if insert(sibling, after: id, in: &items) {
            return sibling.id
        }
        items.append(sibling)
        return sibling.id
    }

    func addChild(to id: UUID) -> UUID {
        let child = OutlineItem(title: "")
        guard itemSummaries[id] != nil else { return child.id }
        recordUndoSnapshot()
        update(id) { item in
            item.isExpanded = true
            item.children.append(child)
        }
        return child.id
    }

    func addFirstChild(to id: UUID) -> UUID {
        let child = OutlineItem(title: "")
        guard itemSummaries[id] != nil else { return child.id }
        recordUndoSnapshot()
        update(id) { item in
            item.isExpanded = true
            item.children.insert(child, at: item.children.startIndex)
        }
        return child.id
    }

    func pasteOutline(_ pastedItems: [OutlineItem], at id: UUID) -> UUID? {
        guard !pastedItems.isEmpty else { return nil }
        let copiedItems = pastedItems.map(copyForPaste)
        recordUndoSnapshot()

        if title(for: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var remainingItems = copiedItems
            let firstItem = remainingItems.removeFirst()
            update(id) { item in
                item.title = firstItem.title
                item.isExpanded = firstItem.isExpanded
                item.isComplete = firstItem.isComplete
                item.children = firstItem.children
            }
            if !remainingItems.isEmpty {
                _ = insert(remainingItems, after: id, in: &items)
            }
            return id
        }

        if insert(copiedItems, after: id, in: &items) {
            return copiedItems.first?.id
        }

        items.append(contentsOf: copiedItems)
        return copiedItems.first?.id
    }

    func indent(_ id: UUID, under parentID: UUID) {
        guard itemSummaries[id] != nil, itemSummaries[parentID] != nil else { return }
        recordUndoSnapshot()
        guard let item = remove(id, from: &items) else { return }
        update(parentID) { parent in
            parent.children.append(item)
        }
    }

    func outdent(_ id: UUID) {
        guard parentByID[id] != nil else { return }
        recordUndoSnapshot()
        _ = outdent(id, in: &items)
    }

    func move(_ id: UUID, to placement: OutlineDropPlacement, relativeTo targetID: UUID) -> Bool {
        guard id != targetID else { return false }
        guard !isAncestor(id, of: targetID) else { return false }
        guard itemSummaries[id] != nil, itemSummaries[targetID] != nil else { return false }
        recordUndoSnapshot()
        guard let movedItem = remove(id, from: &items) else { return false }

        let inserted: Bool
        switch placement {
        case .before:
            inserted = insert(movedItem, before: targetID, in: &items)
        case .after:
            inserted = insert(movedItem, after: targetID, in: &items)
        case .child:
            inserted = insertAsChild(movedItem, of: targetID, in: &items)
        }

        if !inserted {
            items.append(movedItem)
        }

        return inserted
    }

    func removeIfEmpty(_ id: UUID) -> Bool {
        guard title(for: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard itemSummaries[id] != nil else { return false }
        recordUndoSnapshot()
        return remove(id, from: &items) != nil
    }

    func removeItem(with id: UUID) -> Bool {
        guard itemSummaries[id] != nil else { return false }
        recordUndoSnapshot()
        return remove(id, from: &items) != nil
    }

    func removeItems(with ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        guard ids.contains(where: { itemSummaries[$0] != nil }) else { return }
        recordUndoSnapshot()
        removeItems(with: ids, from: &items)
    }

    func toggleComplete(_ id: UUID) {
        guard var summary = itemSummaries[id] else { return }
        recordUndoSnapshot()
        isApplyingIncrementalMutation = true
        shouldInvalidateDerivedCachesAfterIncrementalMutation = false
        let didUpdate = update(id) { item in
            item.isComplete.toggle()
        }
        isApplyingIncrementalMutation = false
        shouldInvalidateDerivedCachesAfterIncrementalMutation = false

        guard didUpdate else { return }
        summary = OutlineItemSummary(
            title: summary.title,
            isComplete: !summary.isComplete,
            childCount: summary.childCount
        )
        itemSummaries[id] = summary
        searchResultsCache = nil
    }

    func copyableItems(for ids: Set<UUID>) -> [OutlineItem] {
        guard !ids.isEmpty else { return [] }
        var copiedItems: [OutlineItem] = []
        appendCopyableItems(in: items, selectedIDs: ids, to: &copiedItems)
        return copiedItems
    }

    func loadExternalChanges() {
        isLoadingItems = true
        load()
        rebuildIndexes()
        invalidateDerivedCaches()
        clearHistory()
        isLoadingItems = false
    }

    func flushSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        save()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(items)
        items = snapshot
        trimRedoStackIfNeeded()
        updateHistoryState()
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(items)
        items = snapshot
        trimUndoStackIfNeeded()
        updateHistoryState()
    }

    private func recordUndoSnapshot() {
        guard !isLoadingItems else { return }
        undoStack.append(items)
        trimUndoStackIfNeeded()
        redoStack.removeAll()
        updateHistoryState()
    }

    private func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateHistoryState()
    }

    private func trimUndoStackIfNeeded() {
        if undoStack.count > historyLimit {
            undoStack.removeFirst(undoStack.count - historyLimit)
        }
    }

    private func trimRedoStackIfNeeded() {
        if redoStack.count > historyLimit {
            redoStack.removeFirst(redoStack.count - historyLimit)
        }
    }

    private func updateHistoryState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private static func makeStorageURL() -> (url: URL, isUsingICloud: Bool) {
        let localURL = localStorageURL()
        if
            let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: subnoteICloudContainerIdentifier) ??
                FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            let directory = containerURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Subnote", isDirectory: true)
            let cloudURL = directory.appendingPathComponent("outline.json")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: cloudURL.path),
               FileManager.default.fileExists(atPath: localURL.path) {
                try? FileManager.default.copyItem(at: localURL, to: cloudURL)
            }
            return (cloudURL, true)
        }
        return (localURL, false)
    }

    private static func localStorageURL() -> URL {
        let baseURL = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let appFolderName = Bundle.main.bundleIdentifier ?? "Subnote"
        let appDirectory = (baseURL ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent(appFolderName, isDirectory: true)
        return appDirectory.appendingPathComponent("outline.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else {
            loadDefaultItems()
            return
        }

        if
            let legacyItems = try? JSONDecoder().decode([OutlineItem].self, from: data),
            !legacyItems.isEmpty {
            items = migrateTagsIntoTitles(legacyItems)
            return
        }

        if let temporaryDocument = try? JSONDecoder().decode(TemporaryTabbedDocument.self, from: data),
           let selectedItems = temporaryDocument.selectedItems {
            items = migrateTagsIntoTitles(selectedItems)
            return
        }

        loadDefaultItems()
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            assertionFailure("Unable to save outline: \(error.localizedDescription)")
        }
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.save()
                self?.pendingSaveTask = nil
            }
        }
    }

    private func invalidateDerivedCaches() {
        taskItemsCache.removeAll()
        pinnedItemsCache = nil
        searchResultsCache = nil
    }

    private func rebuildIndexes() {
        var summaries: [UUID: OutlineItemSummary] = [:]
        var parents = Set<UUID>()
        var parentMap: [UUID: UUID] = [:]
        var childMap: [UUID: [OutlineItem]] = [:]
        rebuildIndexes(
            in: items,
            parentID: nil,
            summaries: &summaries,
            parentIDs: &parents,
            parentByID: &parentMap,
            childrenByID: &childMap
        )
        itemSummaries = summaries
        parentIDs = parents
        parentByID = parentMap
        childrenByID = childMap
    }

    private func rebuildIndexes(
        in source: [OutlineItem],
        parentID: UUID?,
        summaries: inout [UUID: OutlineItemSummary],
        parentIDs: inout Set<UUID>,
        parentByID: inout [UUID: UUID],
        childrenByID: inout [UUID: [OutlineItem]]
    ) {
        for item in source {
            summaries[item.id] = OutlineItemSummary(
                title: item.title,
                isComplete: item.isComplete,
                childCount: item.children.count
            )
            childrenByID[item.id] = item.children
            if !item.children.isEmpty {
                parentIDs.insert(item.id)
            }
            if let parentID {
                parentByID[item.id] = parentID
            }
            rebuildIndexes(
                in: item.children,
                parentID: item.id,
                summaries: &summaries,
                parentIDs: &parentIDs,
                parentByID: &parentByID,
                childrenByID: &childrenByID
            )
        }
    }

    private func loadDefaultItems() {
        items = [
            OutlineItem(
                title: "Home",
                children: [
                    OutlineItem(title: "Inbox #i"),
                    OutlineItem(title: "Later #l"),
                    OutlineItem(title: "Projects ~")
                ]
            )
        ]
    }

    private func ensureTaskBuckets() {
        if let taskIndex = items.firstIndex(where: { isTitle($0.title, equalTo: taskRootTitle) }) {
            items[taskIndex].isExpanded = true
            if !items[taskIndex].children.contains(where: { isTitle($0.title, equalTo: inboxTaskTitle) }) {
                items[taskIndex].children.append(OutlineItem(title: inboxTaskTitle))
            }
            if !items[taskIndex].children.contains(where: { isTitle($0.title, equalTo: laterTaskTitle) }) {
                items[taskIndex].children.append(OutlineItem(title: laterTaskTitle))
            }
        } else {
            items.append(
                OutlineItem(
                    title: taskRootTitle,
                    children: [
                        OutlineItem(title: inboxTaskTitle),
                        OutlineItem(title: laterTaskTitle)
                    ]
                )
            )
        }
    }

    private func taskBucket(for selectedTag: String?) -> OutlineItem? {
        guard let taskRoot = items.first(where: { isTitle($0.title, equalTo: taskRootTitle) }) else {
            return nil
        }
        let title = selectedTag == "l" ? laterTaskTitle : inboxTaskTitle
        return taskRoot.children.first { isTitle($0.title, equalTo: title) }
    }

    private func isTitle(_ title: String, equalTo expectedTitle: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(expectedTitle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private func isTaskSystemTitle(_ title: String) -> Bool {
        isTitle(title, equalTo: taskRootTitle)
            || isTitle(title, equalTo: inboxTaskTitle)
            || isTitle(title, equalTo: laterTaskTitle)
    }

    private func isAncestor(_ possibleAncestorID: UUID, of id: UUID) -> Bool {
        var currentID = parentByID[id]
        while let parentID = currentID {
            if parentID == possibleAncestorID {
                return true
            }
            currentID = parentByID[parentID]
        }
        return false
    }

    @discardableResult
    private func update(_ id: UUID, _ change: (inout OutlineItem) -> Void) -> Bool {
        update(id, in: &items, change)
    }

    @discardableResult
    private func update(_ id: UUID, in source: inout [OutlineItem], _ change: (inout OutlineItem) -> Void) -> Bool {
        for index in source.indices {
            if source[index].id == id {
                change(&source[index])
                return true
            }
            if update(id, in: &source[index].children, change) {
                return true
            }
        }
        return false
    }

    private func insert(_ item: OutlineItem, after id: UUID, in source: inout [OutlineItem]) -> Bool {
        for index in source.indices {
            if source[index].id == id {
                source.insert(item, at: source.index(after: index))
                return true
            }
            if insert(item, after: id, in: &source[index].children) {
                return true
            }
        }
        return false
    }

    private func insert(_ item: OutlineItem, before id: UUID, in source: inout [OutlineItem]) -> Bool {
        for index in source.indices {
            if source[index].id == id {
                source.insert(item, at: index)
                return true
            }
            if insert(item, before: id, in: &source[index].children) {
                return true
            }
        }
        return false
    }

    private func insertAsChild(_ item: OutlineItem, of id: UUID, in source: inout [OutlineItem]) -> Bool {
        for index in source.indices {
            if source[index].id == id {
                source[index].isExpanded = true
                source[index].children.append(item)
                return true
            }
            if insertAsChild(item, of: id, in: &source[index].children) {
                return true
            }
        }
        return false
    }

    private func insert(_ newItems: [OutlineItem], after id: UUID, in source: inout [OutlineItem]) -> Bool {
        for index in source.indices {
            if source[index].id == id {
                source.insert(contentsOf: newItems, at: source.index(after: index))
                return true
            }
            if insert(newItems, after: id, in: &source[index].children) {
                return true
            }
        }
        return false
    }

    private func remove(_ id: UUID, from source: inout [OutlineItem]) -> OutlineItem? {
        for index in source.indices {
            if source[index].id == id {
                return source.remove(at: index)
            }
            if let removed = remove(id, from: &source[index].children) {
                return removed
            }
        }
        return nil
    }

    private func removeItems(with ids: Set<UUID>, from source: inout [OutlineItem]) {
        source.removeAll { ids.contains($0.id) }
        for index in source.indices {
            removeItems(with: ids, from: &source[index].children)
        }
    }

    private func appendCopyableItems(in source: [OutlineItem], selectedIDs: Set<UUID>, to copiedItems: inout [OutlineItem]) {
        for item in source {
            if selectedIDs.contains(item.id) {
                copiedItems.append(item)
            } else {
                appendCopyableItems(in: item.children, selectedIDs: selectedIDs, to: &copiedItems)
            }
        }
    }

    private func appendTaggedItems(
        in source: [OutlineItem],
        path: [String],
        parentID: UUID?,
        inheritedProjectTitle: String?,
        filteredBy selectedTag: String?,
        into rows: inout [TaggedOutlineItem]
    ) {
        for item in source {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let tags = parsedTags(in: title)
            let displayTitle = title.isEmpty ? "Untitled" : title
            let currentPath = path + [displayTitle]
            let currentProjectTitle = projectTitle(in: title) ?? inheritedProjectTitle
            let isIncluded = !tags.isEmpty && (
                selectedTag == nil ||
                tags.contains { $0.compare(selectedTag ?? "", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            )

            if isIncluded {
                rows.append(
                    TaggedOutlineItem(
                        id: item.id,
                        parentID: parentID,
                        title: displayTitle,
                        tags: tags,
                        path: path,
                        projectTitle: currentProjectTitle
                    )
                )
            }

            appendTaggedItems(
                in: item.children,
                path: currentPath,
                parentID: item.id,
                inheritedProjectTitle: currentProjectTitle,
                filteredBy: selectedTag,
                into: &rows
            )
        }
    }

    private func appendTaskItems(
        in source: [OutlineItem],
        path: [String],
        parentID: UUID?,
        inheritedProjectTitle: String?,
        into rows: inout [TaggedOutlineItem]
    ) {
        for item in source {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.isEmpty ? "Untitled" : title
            let currentPath = path + [displayTitle]
            let currentProjectTitle = projectTitle(in: title) ?? inheritedProjectTitle
            rows.append(
                TaggedOutlineItem(
                    id: item.id,
                    parentID: parentID,
                    title: displayTitle,
                    tags: [],
                    path: path,
                    projectTitle: currentProjectTitle
                )
            )
            appendTaskItems(
                in: item.children,
                path: currentPath,
                parentID: item.id,
                inheritedProjectTitle: currentProjectTitle,
                into: &rows
            )
        }
    }

    private func appendPinnedItems(
        in source: [OutlineItem],
        path: [String],
        parentID: UUID?,
        inheritedProjectTitle: String?,
        into rows: inout [TaggedOutlineItem]
    ) {
        for item in source {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.isEmpty ? "Untitled" : title
            let currentPath = path + [displayTitle]
            let currentProjectTitle = projectTitle(in: title) ?? inheritedProjectTitle
            if title.contains("*") {
                rows.append(
                    TaggedOutlineItem(
                        id: item.id,
                        parentID: parentID,
                        title: displayTitle,
                        tags: parsedTags(in: title),
                        path: path,
                        projectTitle: currentProjectTitle
                    )
                )
            }
            appendPinnedItems(
                in: item.children,
                path: currentPath,
                parentID: item.id,
                inheritedProjectTitle: currentProjectTitle,
                into: &rows
            )
        }
    }

    private func allSearchResults() -> [OutlineSearchResult] {
        if let searchResultsCache {
            return searchResultsCache
        }

        var results: [OutlineSearchResult] = []
        appendSearchResults(in: items, path: [], into: &results)
        searchResultsCache = results
        return results
    }

    private func appendSearchResults(in source: [OutlineItem], path: [String], into results: inout [OutlineSearchResult]) {
        for item in source {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = taskSidebarDisplayTitle(title)
            let displayPath = path.map(taskSidebarDisplayTitle)
            let searchableText = ([title, displayTitle] + path).joined(separator: " ").lowercased()

            results.append(
                OutlineSearchResult(
                    id: item.id,
                    title: displayTitle,
                    path: displayPath,
                    isComplete: item.isComplete,
                    searchableText: searchableText
                )
            )

            appendSearchResults(
                in: item.children,
                path: path + [title.isEmpty ? "Untitled" : title],
                into: &results
            )
        }
    }

    private func projectTitle(in title: String) -> String? {
        guard title.contains("~") else { return nil }
        var cleaned = title.replacingOccurrences(of: "~", with: " ")
        for match in hashtagMatches(in: title).reversed() {
            cleaned = (cleaned as NSString).replacingCharacters(in: match.range, with: " ")
        }
        let projectTitle = cleaned
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return projectTitle.isEmpty ? nil : projectTitle
    }

    private func sidebarCacheSignature(for title: String) -> SidebarCacheSignature {
        SidebarCacheSignature(
            supportedTags: Set(parsedTags(in: title).filter { supportedTags.contains($0.lowercased()) }),
            isPinned: title.contains("*"),
            projectTitle: projectTitle(in: title)
        )
    }

    private func normalizedTag(_ rawTag: String) -> String? {
        let stripped = rawTag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !stripped.isEmpty else { return nil }
        return stripped
    }

    private func migrateTagsIntoTitles(_ source: [OutlineItem]) -> [OutlineItem] {
        source.map { item in
            var migrated = item
            let existingTags = Set(parsedTags(in: migrated.title).map { $0.lowercased() })
            let missingTags = migrated.tags.filter { !existingTags.contains($0.lowercased()) }
            if !missingTags.isEmpty {
                migrated.title = (migrated.title.trimmingCharacters(in: .whitespaces) + " " + missingTags.map { "#\($0)" }.joined(separator: " "))
                    .trimmingCharacters(in: .whitespaces)
            }
            migrated.tags = []
            migrated.children = migrateTagsIntoTitles(migrated.children)
            return migrated
        }
    }

    private func parsedTags(in title: String) -> [String] {
        let text = title as NSString
        var seen = Set<String>()
        return hashtagMatches(in: title).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let tag = text.substring(with: match.range(at: 1))
            let key = tag.lowercased()
            guard supportedTags.contains(key) else { return nil }
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return key
        }
    }

    private func removeHashtag(_ tag: String, from title: String) -> String {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let pattern = #"(?<!\S)#"# + escapedTag + #"\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return title
        }

        let text = title as NSString
        let range = NSRange(location: 0, length: text.length)
        return regex
            .stringByReplacingMatches(in: title, range: range, withTemplate: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func copyForPaste(_ item: OutlineItem) -> OutlineItem {
        OutlineItem(
            title: item.title,
            isExpanded: item.isExpanded,
            isComplete: item.isComplete,
            tags: item.tags,
            children: item.children.map(copyForPaste)
        )
    }

    private func outdent(_ id: UUID, in source: inout [OutlineItem]) -> Bool {
        for parentIndex in source.indices {
            if let childIndex = source[parentIndex].children.firstIndex(where: { $0.id == id }) {
                let item = source[parentIndex].children.remove(at: childIndex)
                source.insert(item, at: source.index(after: parentIndex))
                return true
            }

            if outdent(id, in: &source[parentIndex].children) {
                return true
            }
        }
        return false
    }

    private func flatten(_ source: [OutlineItem], depth: Int, collapsedItemIDs: Set<UUID>, hidesCompletedItems: Bool) -> [VisibleOutlineItem] {
        var rows: [VisibleOutlineItem] = []
        rows.reserveCapacity(source.count)
        appendVisibleItems(
            from: source,
            depth: depth,
            collapsedItemIDs: collapsedItemIDs,
            hidesCompletedItems: hidesCompletedItems,
            into: &rows
        )
        return rows
    }

    private func appendVisibleItems(
        from source: [OutlineItem],
        depth: Int,
        collapsedItemIDs: Set<UUID>,
        hidesCompletedItems: Bool,
        into rows: inout [VisibleOutlineItem]
    ) {
        for item in source {
            let isHidden = hidesCompletedItems && isComplete(item.id)
            if !isHidden {
                rows.append(VisibleOutlineItem(id: item.id, depth: depth))
            }
            if isHidden || !collapsedItemIDs.contains(item.id) {
                appendVisibleItems(
                    from: childrenByID[item.id] ?? item.children,
                    depth: isHidden ? depth : depth + 1,
                    collapsedItemIDs: collapsedItemIDs,
                    hidesCompletedItems: hidesCompletedItems,
                    into: &rows
                )
            }
        }
    }
}

private struct TemporaryTabbedDocument: Decodable {
    var selectedTabID: UUID?
    var tabs: [TemporaryTab]

    var selectedItems: [OutlineItem]? {
        if let selectedTabID, let tab = tabs.first(where: { $0.id == selectedTabID }) {
            return tab.items
        }
        return tabs.first?.items
    }
}

private struct TemporaryTab: Decodable {
    var id: UUID
    var items: [OutlineItem]
}
