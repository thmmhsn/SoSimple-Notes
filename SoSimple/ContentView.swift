//
//  ContentView.swift
//  SoSimple
//
//  Created by thameemh on 2-6-26.
//

import Combine
import SwiftUI

private let supportedTags = ["i", "l"]
private let taskRootTitle = "Tasks"
private let inboxTaskTitle = "Inbox"
private let laterTaskTitle = "Later"
private let hashtagRegex = try? NSRegularExpression(pattern: #"(?<!\S)#([A-Za-z0-9_-]+)"#)

private func hashtagMatches(in title: String) -> [NSTextCheckingResult] {
    guard let hashtagRegex else { return [] }
    let text = title as NSString
    return hashtagRegex.matches(in: title, range: NSRange(location: 0, length: text.length))
}

private func tagTextColor(for tag: String, isComplete: Bool) -> NSColor {
    let palette: [NSColor] = [
        NSColor.systemBlue,
        NSColor.systemGreen,
        NSColor.systemOrange,
        NSColor.systemPink,
        NSColor.systemPurple,
        NSColor.systemTeal,
        NSColor.systemYellow,
        NSColor.systemIndigo
    ]
    let hash = tag.lowercased().unicodeScalars.reduce(0) { partialResult, scalar in
        (partialResult &* 31 &+ Int(scalar.value)) & 0x7fffffff
    }
    return palette[hash % palette.count].withAlphaComponent(isComplete ? 0.72 : 1)
}

struct OutlineItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var isExpanded = true
    var isComplete = false
    var isPinned = false
    var tags: [String] = []
    var children: [OutlineItem] = []

    init(
        id: UUID = UUID(),
        title: String,
        isExpanded: Bool = true,
        isComplete: Bool = false,
        isPinned: Bool = false,
        tags: [String] = [],
        children: [OutlineItem] = []
    ) {
        self.id = id
        self.title = title
        self.isExpanded = isExpanded
        self.isComplete = isComplete
        self.isPinned = isPinned
        self.tags = tags
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case isExpanded
        case isComplete
        case isPinned
        case tags
        case children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        children = try container.decodeIfPresent([OutlineItem].self, forKey: .children) ?? []
    }
}

struct VisibleOutlineItem: Identifiable {
    let id: UUID
    let depth: Int
}

struct TaggedOutlineItem: Identifiable {
    let id: UUID
    let title: String
    let tags: [String]
    let path: [String]
    let projectTitle: String?
}

private func styledInlineTagText(_ title: String, isComplete: Bool) -> AttributedString {
    var attributed = AttributedString(title.isEmpty ? "Untitled" : title)
    attributed.font = .system(size: 16)
    attributed.foregroundColor = isComplete ? .secondary : .primary
    if isComplete {
        attributed.strikethroughStyle = .single
        attributed.strikethroughColor = NSColor.secondaryLabelColor
    }

    let source = attributed.characters
    let plainText = String(source)
    let nsText = plainText as NSString
    for match in hashtagMatches(in: plainText) {
        guard match.numberOfRanges > 1 else { continue }
        let tag = nsText.substring(with: match.range(at: 1))
        guard supportedTags.contains(tag.lowercased()) else { continue }
        let startOffset = match.range.location
        let endOffset = match.range.location + match.range.length
        guard
            let start = source.index(source.startIndex, offsetBy: startOffset, limitedBy: source.endIndex),
            let end = source.index(source.startIndex, offsetBy: endOffset, limitedBy: source.endIndex)
        else {
            continue
        }

        attributed[start..<end].foregroundColor = Color(nsColor: tagTextColor(for: tag, isComplete: isComplete))
    }

    return attributed
}

private struct RowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
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

@MainActor
final class OutlineStore: ObservableObject {
    @Published private(set) var items: [OutlineItem] = [] {
        didSet { save() }
    }

    private let fileManager = FileManager.default
    private let storageURL: URL

    init() {
        storageURL = Self.makeStorageURL()
        load()
        ensureTaskBuckets()
    }

    func visibleItems(focusedItemID: UUID?) -> [VisibleOutlineItem] {
        visibleItems(focusedItemID: focusedItemID, collapsedItemIDs: [])
    }

    func visibleItems(focusedItemID: UUID?, collapsedItemIDs: Set<UUID>) -> [VisibleOutlineItem] {
        if let focusedItemID, let item = item(with: focusedItemID) {
            return flatten(item.children, depth: 0, collapsedItemIDs: collapsedItemIDs)
        }
        return flatten(items, depth: 0, collapsedItemIDs: collapsedItemIDs)
    }

    func breadcrumbs(focusedItemID: UUID?) -> [OutlineItem] {
        guard let focusedItemID else { return [] }
        return path(to: focusedItemID, in: items) ?? []
    }

    func focusedItem(focusedItemID: UUID?) -> OutlineItem? {
        guard let focusedItemID else { return nil }
        return item(with: focusedItemID)
    }

    func title(for id: UUID) -> String {
        item(with: id)?.title ?? ""
    }

    func tags(for id: UUID) -> [String] {
        parsedTags(in: item(with: id)?.title ?? "")
    }

    func allTags() -> [String] {
        supportedTags
    }

    func taggedItems(filteredBy selectedTag: String?) -> [TaggedOutlineItem] {
        taggedItems(in: items, path: [], inheritedProjectTitle: nil, filteredBy: selectedTag)
    }

    func taskItems(filteredBy selectedTag: String?) -> [TaggedOutlineItem] {
        let tag = selectedTag == "l" ? "l" : "i"
        let bucketItems: [TaggedOutlineItem]
        if let bucket = taskBucket(for: tag) {
            bucketItems = taskItems(in: bucket.children, path: [bucket.title], inheritedProjectTitle: nil)
        } else {
            bucketItems = []
        }

        var seenIDs = Set(bucketItems.map(\.id))
        let taggedItems = taggedItems(filteredBy: tag).filter { item in
            guard !seenIDs.contains(item.id) else { return false }
            seenIDs.insert(item.id)
            return true
        }

        return bucketItems + taggedItems
    }

    func taskBucketID(filteredBy selectedTag: String?) -> UUID? {
        let tag = selectedTag == "l" ? "l" : "i"
        return taskBucket(for: tag)?.id
    }

    func pinnedItems() -> [TaggedOutlineItem] {
        pinnedItems(in: items, path: [], inheritedProjectTitle: nil)
    }

    func setTitle(_ title: String, for id: UUID) {
        update(id) { item in
            item.title = title
        }
    }

    func addTag(_ rawTag: String, to id: UUID) {
        guard let tag = normalizedTag(rawTag) else { return }
        guard let resolvedTag = allTags().first(where: { $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            return
        }

        update(id) { item in
            guard !parsedTags(in: item.title).contains(where: { $0.compare(resolvedTag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
                return
            }
            item.title = item.title.trimmingCharacters(in: .whitespaces) + " #\(resolvedTag)"
        }
    }

    func removeTag(_ tag: String, from id: UUID) {
        update(id) { item in
            item.title = removeHashtag(tag, from: item.title)
        }
    }

    func isExpanded(_ id: UUID) -> Bool {
        item(with: id)?.isExpanded ?? false
    }

    func isComplete(_ id: UUID) -> Bool {
        item(with: id)?.isComplete ?? false
    }

    func isPinned(_ id: UUID) -> Bool {
        item(with: id)?.isPinned ?? false
    }

    func childCount(for id: UUID) -> Int {
        item(with: id)?.children.count ?? 0
    }

    func addRoot() -> UUID {
        let item = OutlineItem(title: "")
        items.append(item)
        return item.id
    }

    func addSibling(after id: UUID) -> UUID {
        let sibling = OutlineItem(title: "")
        if insert(sibling, after: id, in: &items) {
            return sibling.id
        }
        items.append(sibling)
        return sibling.id
    }

    func addChild(to id: UUID) -> UUID {
        let child = OutlineItem(title: "")
        update(id) { item in
            item.isExpanded = true
            item.children.append(child)
        }
        return child.id
    }

    func indent(_ id: UUID, focusedItemID: UUID?) {
        guard let parentID = previousVisibleItem(before: id, focusedItemID: focusedItemID), let item = remove(id, from: &items) else {
            return
        }

        update(parentID) { parent in
            parent.isExpanded = true
            parent.children.append(item)
        }
    }

    func indent(_ id: UUID, under parentID: UUID) {
        guard let item = remove(id, from: &items) else {
            return
        }

        update(parentID) { parent in
            parent.children.append(item)
        }
    }

    func outdent(_ id: UUID) {
        _ = outdent(id, in: &items)
    }

    func removeIfEmpty(_ id: UUID) -> Bool {
        guard title(for: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return remove(id, from: &items) != nil
    }

    func removeItems(with ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        removeItems(with: ids, from: &items)
    }

    func toggleExpanded(_ id: UUID) {
        update(id) { item in
            item.isExpanded.toggle()
        }
    }

    func toggleComplete(_ id: UUID) {
        update(id) { item in
            item.isComplete.toggle()
        }
    }

    func togglePinned(_ id: UUID) {
        update(id) { item in
            item.isPinned.toggle()
        }
    }

    func nextVisibleItem(after id: UUID, focusedItemID: UUID?) -> UUID? {
        let ids = visibleItems(focusedItemID: focusedItemID).map(\.id)
        guard let index = ids.firstIndex(of: id), index < ids.index(before: ids.endIndex) else {
            return nil
        }
        return ids[ids.index(after: index)]
    }

    func previousVisibleItem(before id: UUID, focusedItemID: UUID?) -> UUID? {
        let ids = visibleItems(focusedItemID: focusedItemID).map(\.id)
        guard let index = ids.firstIndex(of: id), index > ids.startIndex else {
            return nil
        }
        return ids[ids.index(before: index)]
    }

    private static func makeStorageURL() -> URL {
        let baseURL = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let appFolderName = Bundle.main.bundleIdentifier ?? "SoSimple"
        let appDirectory = (baseURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent(appFolderName, isDirectory: true)
        return appDirectory.appendingPathComponent("outline.json")
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: storageURL)
        else {
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

    private func loadDefaultItems() {
        items = [
            OutlineItem(
                title: "Home",
                children: [
                    OutlineItem(title: "Work"),
                    OutlineItem(title: "Personal")
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

    private func item(with id: UUID) -> OutlineItem? {
        find(id, in: items)
    }

    private func find(_ id: UUID, in source: [OutlineItem]) -> OutlineItem? {
        for item in source {
            if item.id == id {
                return item
            }
            if let match = find(id, in: item.children) {
                return match
            }
        }
        return nil
    }

    private func update(_ id: UUID, _ change: (inout OutlineItem) -> Void) {
        update(id, in: &items, change)
    }

    private func update(_ id: UUID, in source: inout [OutlineItem], _ change: (inout OutlineItem) -> Void) {
        for index in source.indices {
            if source[index].id == id {
                change(&source[index])
                return
            }
            update(id, in: &source[index].children, change)
        }
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

    private func collectTags(from source: [OutlineItem], into tags: inout Set<String>) {
        for item in source {
            for tag in parsedTags(in: item.title) {
                tags.insert(tag)
            }
            collectTags(from: item.children, into: &tags)
        }
    }

    private func taggedItems(in source: [OutlineItem], path: [String], inheritedProjectTitle: String?, filteredBy selectedTag: String?) -> [TaggedOutlineItem] {
        source.flatMap { item -> [TaggedOutlineItem] in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let tags = parsedTags(in: title)
            let currentPath = path + [title.isEmpty ? "Untitled" : title]
            let currentProjectTitle = projectTitle(in: title) ?? inheritedProjectTitle
            let isIncluded = !tags.isEmpty && (
                selectedTag == nil ||
                tags.contains { $0.compare(selectedTag ?? "", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            )

            var rows: [TaggedOutlineItem] = isIncluded
                ? [TaggedOutlineItem(id: item.id, title: title.isEmpty ? "Untitled" : title, tags: tags, path: path, projectTitle: currentProjectTitle)]
                : []
            rows.append(contentsOf: taggedItems(in: item.children, path: currentPath, inheritedProjectTitle: currentProjectTitle, filteredBy: selectedTag))
            return rows
        }
    }

    private func taskItems(in source: [OutlineItem], path: [String], inheritedProjectTitle: String?) -> [TaggedOutlineItem] {
        source.flatMap { item -> [TaggedOutlineItem] in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.isEmpty ? "Untitled" : title
            let currentPath = path + [displayTitle]
            let currentProjectTitle = projectTitle(in: title) ?? inheritedProjectTitle
            var rows = [
                TaggedOutlineItem(
                    id: item.id,
                    title: displayTitle,
                    tags: [],
                    path: path,
                    projectTitle: currentProjectTitle
                )
            ]
            rows.append(contentsOf: taskItems(in: item.children, path: currentPath, inheritedProjectTitle: currentProjectTitle))
            return rows
        }
    }

    private func pinnedItems(in source: [OutlineItem], path: [String], inheritedProjectTitle: String?) -> [TaggedOutlineItem] {
        source.flatMap { item -> [TaggedOutlineItem] in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.isEmpty ? "Untitled" : title
            let currentPath = path + [displayTitle]
            let currentProjectTitle = projectTitle(in: title) ?? inheritedProjectTitle
            var rows: [TaggedOutlineItem] = item.isPinned
                ? [
                    TaggedOutlineItem(
                        id: item.id,
                        title: displayTitle,
                        tags: parsedTags(in: title),
                        path: path,
                        projectTitle: currentProjectTitle
                    )
                ]
                : []
            rows.append(contentsOf: pinnedItems(in: item.children, path: currentPath, inheritedProjectTitle: currentProjectTitle))
            return rows
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

    private func flatten(_ source: [OutlineItem], depth: Int, collapsedItemIDs: Set<UUID>) -> [VisibleOutlineItem] {
        source.flatMap { item -> [VisibleOutlineItem] in
            var rows = [VisibleOutlineItem(id: item.id, depth: depth)]
            if !collapsedItemIDs.contains(item.id) {
                rows.append(contentsOf: flatten(item.children, depth: depth + 1, collapsedItemIDs: collapsedItemIDs))
            }
            return rows
        }
    }

    private func path(to id: UUID, in source: [OutlineItem]) -> [OutlineItem]? {
        for item in source {
            if item.id == id {
                return [item]
            }
            if let childPath = path(to: id, in: item.children) {
                return [item] + childPath
            }
        }
        return nil
    }
}

struct ContentView: View {
    @ObservedObject var store: OutlineStore
    let minimumWidth: CGFloat
    let updatesWindowTitle: Bool
    @Binding private var focusRequest: UUID?
    @State private var paneID = UUID()
    @State private var editingItemID: UUID?
    @State private var focusedItemID: UUID?
    @State private var collapsedItemIDs = Set<UUID>()
    @State private var selectedItemIDs = Set<UUID>()
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var selectionDragStart: CGPoint?
    @State private var selectionDragCurrent: CGPoint?
    @State private var isShowingDeleteSelectionConfirmation = false
    @State private var pendingDeleteItemIDs = Set<UUID>()
    @FocusState private var isFocusedTitleEditing: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(
        store: OutlineStore,
        minimumWidth: CGFloat = 720,
        updatesWindowTitle: Bool = true,
        focusRequest: Binding<UUID?> = .constant(nil)
    ) {
        self.store = store
        self.minimumWidth = minimumWidth
        self.updatesWindowTitle = updatesWindowTitle
        self._focusRequest = focusRequest
    }

    var body: some View {
        outlineContent
        .background {
            if updatesWindowTitle {
                WindowTabConfigurator(title: tabTitle)
            }
        }
        .background(colorScheme == .dark ? Color(red: 0.08, green: 0.08, blue: 0.09) : Color(nsColor: .textBackgroundColor))
        .overlay {
            ZStack {
                SelectionClearMouseMonitor(
                    hasSelection: !selectedItemIDs.isEmpty,
                    isDraggingSelection: selectionDragStart != nil,
                    onMouseDown: {
                        clearSelection()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                RowKeyboardMonitor(
                    paneID: paneID,
                    editingItemID: $editingItemID,
                    selectedItemIDs: $selectedItemIDs,
                    onMoveUp: { id in
                        if let previousID = previousVisibleItem(before: id) {
                            editingItemID = previousID
                        }
                    },
                    onMoveDown: { id in
                        if let nextID = nextVisibleItem(after: id) {
                            editingItemID = nextID
                        }
                    },
                    onDeleteIfEmpty: { id in
                        deleteIfEmpty(id)
                    },
                    onDeleteSelection: {
                        requestDeleteSelection()
                    }
                )
                .frame(width: 0, height: 0)
            }
        }
        .alert("Delete selected notes?", isPresented: $isShowingDeleteSelectionConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingDeleteItemIDs = []
            }
            Button("Delete", role: .destructive) {
                deletePendingSelection()
            }
        } message: {
            Text("This will delete \(pendingDeleteItemIDs.count) selected notes and their sub-notes.")
        }
        .onChange(of: focusRequest) { _, requestedID in
            guard let requestedID else { return }
            focusItem(requestedID)
            focusRequest = nil
        }
        .frame(minWidth: minimumWidth, minHeight: 520)
    }

    private var outlineContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                ZStack(alignment: .topLeading) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let focusedItem {
                            FocusedTitleTextField(
                                paneID: paneID,
                                text: Binding(
                                    get: { store.title(for: focusedItem.id) },
                                    set: { store.setTitle($0, for: focusedItem.id) }
                                ),
                                onBeginEditing: {
                                    isFocusedTitleEditing = true
                                    editingItemID = nil
                                },
                                onCreateRow: {
                                    addItemForCurrentView()
                                }
                            )
                            .onChange(of: isFocusedTitleEditing) { _, isEditing in
                                if isEditing {
                                    editingItemID = nil
                                }
                            }
                            .frame(height: 34)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 12)
                        }

                        ForEach(visibleItems) { item in
                            OutlineRow(
                                paneID: paneID,
                                item: item,
                                title: Binding(
                                    get: { store.title(for: item.id) },
                                    set: { store.setTitle($0, for: item.id) }
                                ),
                                isExpanded: !collapsedItemIDs.contains(item.id),
                                childCount: store.childCount(for: item.id),
                                isComplete: store.isComplete(item.id),
                                isPinned: store.isPinned(item.id),
                                isSelected: selectedItemIDs.contains(item.id),
                                editingItemID: $editingItemID,
                                onToggleExpanded: {
                                    toggleExpanded(item.id)
                                },
                                onFocus: {
                                    focusAndEditFirstVisible(item.id)
                                },
                                onRowInteraction: {
                                    clearSelection()
                                },
                                onAddChild: {
                                    let childID = store.addChild(to: item.id)
                                    collapsedItemIDs.remove(item.id)
                                    editingItemID = childID
                                },
                                onMoveUp: {
                                    if let previousID = previousVisibleItem(before: item.id) {
                                        editingItemID = previousID
                                    }
                                },
                                onMoveDown: {
                                    if let nextID = nextVisibleItem(after: item.id) {
                                        editingItemID = nextID
                                    }
                                },
                                onCreateRow: {
                                    let newID = store.addSibling(after: item.id)
                                    editingItemID = newID
                                },
                                onIndent: {
                                    if let parentID = previousVisibleItem(before: item.id) {
                                        store.indent(item.id, under: parentID)
                                        collapsedItemIDs.remove(parentID)
                                        editingItemID = item.id
                                    }
                                },
                                onOutdent: {
                                    store.outdent(item.id)
                                    editingItemID = item.id
                                },
                                onToggleComplete: {
                                    store.toggleComplete(item.id)
                                },
                                onTogglePinned: {
                                    store.togglePinned(item.id)
                                },
                                onDeleteIfEmpty: {
                                    deleteIfEmpty(item.id)
                                }
                            )
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: RowFramePreferenceKey.self,
                                        value: [item.id: proxy.frame(in: .named("outlineSelection"))]
                                    )
                                }
                            )
                        }
                    }
                    .padding(24)

                    if let selectionRectangle {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay(
                                Rectangle()
                                    .stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
                            )
                            .frame(width: selectionRectangle.width, height: selectionRectangle.height)
                            .position(x: selectionRectangle.midX, y: selectionRectangle.midY)
                    }
                }
                .coordinateSpace(name: "outlineSelection")
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named("outlineSelection"))
                        .onChanged { value in
                            updateSelectionDrag(to: value.location)
                        }
                        .onEnded { value in
                            updateSelectionDrag(to: value.location)
                            selectionDragStart = nil
                            selectionDragCurrent = nil
                        }
                )
                .onPreferenceChange(RowFramePreferenceKey.self) { frames in
                    rowFrames = frames
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                focusedItemID = nil
                editingItemID = nil
                selectedItemIDs = []
            } label: {
                Image(systemName: "house")
            }
            .buttonStyle(.borderless)
            .help("Show full outline")

            ForEach(breadcrumbs) { item in
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(item.title.isEmpty ? "Untitled" : item.title) {
                    focusAndEditFirstVisible(item.id)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func deleteIfEmpty(_ id: UUID) -> Bool {
        guard store.title(for: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let previousID = previousVisibleItem(before: id)
        let nextID = nextVisibleItem(after: id)
        guard store.removeIfEmpty(id) else {
            return false
        }

        if focusedItemID == id {
            focusedItemID = nil
        }

        editingItemID = previousID ?? nextID
        return true
    }

    private func focusAndEditFirstVisible(_ id: UUID) {
        isFocusedTitleEditing = false
        selectedItemIDs = []
        focusedItemID = id
        editingItemID = visibleItems.first?.id
    }

    private func focusItem(_ id: UUID) {
        isFocusedTitleEditing = false
        selectedItemIDs = []
        focusedItemID = id
        editingItemID = nil
    }

    private func addItemForCurrentView() {
        isFocusedTitleEditing = false
        if let focusedItemID {
            collapsedItemIDs.remove(focusedItemID)
            editingItemID = store.addChild(to: focusedItemID)
        } else {
            editingItemID = store.addRoot()
        }
    }

    private func clearSelection() {
        if !selectedItemIDs.isEmpty {
            selectedItemIDs = []
        }
    }

    private func requestDeleteSelection() {
        guard selectedItemIDs.count > 1 else { return }
        pendingDeleteItemIDs = selectedItemIDs
        isShowingDeleteSelectionConfirmation = true
    }

    private func deletePendingSelection() {
        store.removeItems(with: pendingDeleteItemIDs)
        selectedItemIDs = []
        pendingDeleteItemIDs = []
        editingItemID = nil
    }

    private func updateSelectionDrag(to location: CGPoint) {
        if selectionDragStart == nil {
            selectionDragStart = location
            editingItemID = nil
            isFocusedTitleEditing = false
        }

        selectionDragCurrent = location

        guard let selectionRectangle else {
            selectedItemIDs = []
            return
        }

        let visibleIDs = Set(visibleItems.map(\.id))
        selectedItemIDs = Set(
            rowFrames.compactMap { id, frame in
                guard visibleIDs.contains(id), frame.intersects(selectionRectangle) else {
                    return nil
                }
                return id
            }
        )
    }

    private func toggleExpanded(_ id: UUID) {
        if collapsedItemIDs.contains(id) {
            collapsedItemIDs.remove(id)
        } else {
            collapsedItemIDs.insert(id)
        }
    }

    private func nextVisibleItem(after id: UUID) -> UUID? {
        let ids = visibleItems.map(\.id)
        guard let index = ids.firstIndex(of: id), index < ids.index(before: ids.endIndex) else {
            return nil
        }
        return ids[ids.index(after: index)]
    }

    private func previousVisibleItem(before id: UUID) -> UUID? {
        let ids = visibleItems.map(\.id)
        guard let index = ids.firstIndex(of: id), index > ids.startIndex else {
            return nil
        }
        return ids[ids.index(before: index)]
    }

    private var visibleItems: [VisibleOutlineItem] {
        store.visibleItems(focusedItemID: focusedItemID, collapsedItemIDs: collapsedItemIDs)
    }

    private var breadcrumbs: [OutlineItem] {
        store.breadcrumbs(focusedItemID: focusedItemID)
    }

    private var focusedItem: OutlineItem? {
        store.focusedItem(focusedItemID: focusedItemID)
    }

    private var tabTitle: String {
        if let focusedItem {
            let focusedTitle = focusedItem.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !focusedTitle.isEmpty {
                return focusedTitle
            }
        }

        return "Home"
    }

    private var selectionRectangle: CGRect? {
        guard let selectionDragStart, let selectionDragCurrent else {
            return nil
        }

        let width = abs(selectionDragCurrent.x - selectionDragStart.x)
        let height = abs(selectionDragCurrent.y - selectionDragStart.y)
        guard width > 1 || height > 1 else {
            return nil
        }

        return CGRect(
            x: min(selectionDragStart.x, selectionDragCurrent.x),
            y: min(selectionDragStart.y, selectionDragCurrent.y),
            width: width,
            height: height
        )
    }
}

struct WorkspaceView: View {
    @ObservedObject var store: OutlineStore
    @State private var isSplitViewEnabled = false
    @State private var isPinnedSidebarEnabled = true
    @State private var isTaskSidebarEnabled = true
    @State private var selectedSidebarTag: String?
    @State private var mainFocusRequest: UUID?

    var body: some View {
        HSplitView {
            if isPinnedSidebarEnabled {
                PinnedSidebar(
                    store: store,
                    onOpenItem: { id in
                        mainFocusRequest = id
                    }
                )
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
            }

            Group {
                if isSplitViewEnabled {
                    HSplitView {
                        ContentView(
                            store: store,
                            minimumWidth: 320,
                            updatesWindowTitle: false,
                            focusRequest: $mainFocusRequest
                        )
                        ContentView(store: store, minimumWidth: 320, updatesWindowTitle: false)
                    }
                    .background(WindowTabConfigurator(title: "Split View"))
                } else {
                    ContentView(store: store, focusRequest: $mainFocusRequest)
                }
            }

            if isTaskSidebarEnabled {
                TagSidebar(
                    store: store,
                    selectedTag: $selectedSidebarTag,
                    onOpenItem: { id in
                        mainFocusRequest = id
                    }
                )
                .frame(minWidth: 340, idealWidth: 340, maxWidth: 340)
            }
        }
        .background(
            WorkspaceCommandReceiver(
                onToggleSplitView: {
                    isSplitViewEnabled.toggle()
                },
                onTogglePinnedSidebar: {
                    isPinnedSidebarEnabled.toggle()
                },
                onToggleTaskSidebar: {
                    isTaskSidebarEnabled.toggle()
                }
            )
        )
        .frame(minWidth: 920, minHeight: 520)
        .toolbar {
            Button {
                isPinnedSidebarEnabled.toggle()
            } label: {
                Label(
                    isPinnedSidebarEnabled ? "Hide Pins" : "Show Pins",
                    systemImage: "pin"
                )
            }
            .help(isPinnedSidebarEnabled ? "Hide Pins" : "Show Pins")

            Button {
                isTaskSidebarEnabled.toggle()
            } label: {
                Label(
                    isTaskSidebarEnabled ? "Hide Tasks" : "Show Tasks",
                    systemImage: "checklist"
                )
            }
            .help(isTaskSidebarEnabled ? "Hide Tasks" : "Show Tasks")

            Button {
                isSplitViewEnabled.toggle()
            } label: {
                Label(
                    isSplitViewEnabled ? "Close Split View" : "Open Split View",
                    systemImage: isSplitViewEnabled ? "rectangle" : "rectangle.split.2x1"
                )
            }
            .help(isSplitViewEnabled ? "Close Split View" : "Open Split View")
        }
    }
}

struct PinnedSidebar: View {
    @ObservedObject var store: OutlineStore
    let onOpenItem: (UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Pinned")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        PinnedNoteRow(
                            item: item,
                            title: store.title(for: item.id),
                            isComplete: store.isComplete(item.id),
                            onOpen: {
                                onOpenItem(item.id)
                            }
                        )
                    }
                }
                .padding(14)
            }
        }
        .background(colorScheme == .dark ? Color(red: 0.075, green: 0.075, blue: 0.085) : Color(nsColor: .controlBackgroundColor))
    }

    private var items: [TaggedOutlineItem] {
        store.pinnedItems()
    }
}

struct PinnedNoteRow: View {
    let item: TaggedOutlineItem
    let title: String
    let isComplete: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 20)

                Text(styledInlineTagText(title, isComplete: isComplete))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
            }

            if let projectTitle = item.projectTitle {
                Text(projectTitle)
                    .fontWeight(.semibold)
                    .font(.system(size: 12))
                    .foregroundStyle(.gray.opacity(0.7))
                    .lineLimit(2)
                    .padding(.leading, 26)
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

struct TagSidebar: View {
    @ObservedObject var store: OutlineStore
    @Binding var selectedTag: String?
    let onOpenItem: (UUID) -> Void
    @State private var paneID = UUID()
    @State private var editingItemID: UUID?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(filterOptions, id: \.tag) { option in
                        FilterChip(title: option.title, isSelected: selectedTag == option.tag) {
                            selectedTag = option.tag
                            if NSEvent.modifierFlags.contains(.command),
                               let bucketID = store.taskBucketID(filteredBy: option.tag) {
                                editingItemID = nil
                                onOpenItem(bucketID)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        TaggedTodoRow(
                            paneID: paneID,
                            item: item,
                            title: store.title(for: item.id),
                            isComplete: store.isComplete(item.id),
                            editingItemID: $editingItemID,
                            onOpen: {
                                editingItemID = nil
                                onOpenItem(item.id)
                            },
                            onMoveUp: {
                                if let previousID = previousItem(before: item.id) {
                                    editingItemID = previousID
                                }
                            },
                            onMoveDown: {
                                if let nextID = nextItem(after: item.id) {
                                    editingItemID = nextID
                                }
                            },
                            onToggleComplete: {
                                store.toggleComplete(item.id)
                            },
                            onDeleteIfEmpty: {
                                deleteIfEmpty(item.id)
                            }
                        )
                    }
                }
                .padding(14)
            }
        }
        .background(colorScheme == .dark ? Color(red: 0.075, green: 0.075, blue: 0.085) : Color(nsColor: .controlBackgroundColor))
        .onAppear {
            if selectedTag == nil {
                selectedTag = "i"
            }
        }
    }

    private var tags: [String] {
        store.allTags()
    }

    private var filterOptions: [(title: String, tag: String)] {
        [
            ("Inbox", "i"),
            ("Later", "l")
        ]
    }

    private var items: [TaggedOutlineItem] {
        store.taskItems(filteredBy: selectedTag)
    }

    private func deleteIfEmpty(_ id: UUID) -> Bool {
        guard store.title(for: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let previousID = previousItem(before: id)
        let nextID = nextItem(after: id)
        guard store.removeIfEmpty(id) else {
            return false
        }

        editingItemID = previousID ?? nextID
        return true
    }

    private func nextItem(after id: UUID) -> UUID? {
        let ids = items.map(\.id)
        guard let index = ids.firstIndex(of: id), index < ids.index(before: ids.endIndex) else {
            return nil
        }
        return ids[ids.index(after: index)]
    }

    private func previousItem(before id: UUID) -> UUID? {
        let ids = items.map(\.id)
        guard let index = ids.firstIndex(of: id), index > ids.startIndex else {
            return nil
        }
        return ids[ids.index(before: index)]
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.secondary.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct TaggedTodoRow: View {
    let paneID: UUID
    let item: TaggedOutlineItem
    let title: String
    let isComplete: Bool
    @Binding var editingItemID: UUID?

    let onOpen: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onToggleComplete: () -> Void
    let onDeleteIfEmpty: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 20)

                Text(styledInlineTagText(title, isComplete: isComplete))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
            }

            if let projectTitle = item.projectTitle {
                Text(projectTitle)
                    .fontWeight(.semibold)
                    .font(.system(size: 12))
                    .foregroundStyle(.gray.opacity(0.7))
                    .lineLimit(2)
                    .padding(.leading, 34)
                    .padding(.top, 1)
            }

        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

struct OutlineRow: View {
    let paneID: UUID
    let item: VisibleOutlineItem
    @Binding var title: String
    let isExpanded: Bool
    let childCount: Int
    let isComplete: Bool
    let isPinned: Bool
    let isSelected: Bool
    @Binding var editingItemID: UUID?

    let onToggleExpanded: () -> Void
    let onFocus: () -> Void
    let onRowInteraction: () -> Void
    let onAddChild: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onCreateRow: () -> Void
    let onIndent: () -> Void
    let onOutdent: () -> Void
    let onToggleComplete: () -> Void
    let onTogglePinned: () -> Void
    let onDeleteIfEmpty: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: CGFloat(item.depth) * 28)

                Button {
                    onRowInteraction()
                    if NSEvent.modifierFlags.contains(.command) {
                        onFocus()
                    } else {
                        onToggleExpanded()
                    }
                } label: {
                    Image(systemName: childCount == 0 ? "circle.fill" : isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: childCount == 0 ? 6 : 10))
                        .foregroundStyle(.secondary)
                        .bold()
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(childCount == 0)
                
                OutlineTextField(
                    paneID: paneID,
                    id: item.id,
                    text: $title,
                    editingItemID: $editingItemID,
                    onMoveUp: onMoveUp,
                    onMoveDown: onMoveDown,
                    onCreateRow: onCreateRow,
                    onIndent: onIndent,
                    onOutdent: onOutdent,
                    onToggleComplete: onToggleComplete,
                    onDeleteIfEmpty: onDeleteIfEmpty,
                    onCommandFocus: onFocus,
                    onBeginEditing: onRowInteraction,
                    isComplete: isComplete
                )
                .frame(height: 34)
                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)

                Button {
                    onRowInteraction()
                    onTogglePinned()
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 13))
                        .foregroundStyle(isPinned ? Color.accentColor : Color.secondary.opacity(0.45))
                        .frame(width: 28, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin note" : "Pin note")
            }

//            Button(action: onFocus) {
//                Image(systemName: "scope")
//            }
//            .buttonStyle(.borderless)
//            .help("Focus")
//
//            Button {
//                if NSEvent.modifierFlags.contains(.command) {
//                    onFocus()
//                } else {
//                    onAddChild()
//                }
//            } label: {
//                Image(systemName: "plus")
//            }
//            .buttonStyle(.borderless)
//            .help("Add child")
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                onRowInteraction()
                if NSEvent.modifierFlags.contains(.command) {
                    onFocus()
                }
            }
        )
    }
}

struct OutlineTextField: NSViewRepresentable {
    let paneID: UUID
    let id: UUID
    @Binding var text: String
    @Binding var editingItemID: UUID?
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onCreateRow: () -> Void
    let onIndent: () -> Void
    let onOutdent: () -> Void
    let onToggleComplete: () -> Void
    let onDeleteIfEmpty: () -> Bool
    let onCommandFocus: () -> Void
    let onBeginEditing: () -> Void
    var wrapsText = false
    let isComplete: Bool

    func makeNSView(context: Context) -> KeyHandlingTextView {
        let textView = KeyHandlingTextView()
        textView.paneID = paneID
        textView.representedItemID = id
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = NSSize(width: 0, height: 7)
        textView.textContainer?.lineFragmentPadding = 0
        configureWrapping(for: textView)
        textView.delegate = context.coordinator
        textView.onMoveUp = onMoveUp
        textView.onMoveDown = onMoveDown
        textView.onCreateRow = onCreateRow
        textView.onIndent = onIndent
        textView.onOutdent = onOutdent
        textView.onToggleComplete = onToggleComplete
        textView.onDeleteIfEmpty = onDeleteIfEmpty
        textView.onCommandFocus = onCommandFocus
        textView.onBeginEditing = onBeginEditing
        applyCompletionStyle(to: textView)
        return textView
    }

    func updateNSView(_ textView: KeyHandlingTextView, context: Context) {
        context.coordinator.parent = self
        textView.paneID = paneID
        textView.representedItemID = id

        if textView.string != text {
            textView.string = text
        }

        textView.onMoveUp = onMoveUp
        textView.onMoveDown = onMoveDown
        textView.onCreateRow = onCreateRow
        textView.onIndent = onIndent
        textView.onOutdent = onOutdent
        textView.onToggleComplete = onToggleComplete
        textView.onDeleteIfEmpty = onDeleteIfEmpty
        textView.onCommandFocus = onCommandFocus
        textView.onBeginEditing = onBeginEditing
        textView.delegate = context.coordinator
        configureWrapping(for: textView)
        applyCompletionStyle(to: textView)

        let shouldEdit = editingItemID == id
        let isFirstResponder = textView.window?.firstResponder === textView
        if shouldEdit, !isFirstResponder, canClaimFirstResponder(textView) {
            DispatchQueue.main.async {
                guard canClaimFirstResponder(textView) else { return }
                textView.window?.makeFirstResponder(textView)
                textView.selectedRange = NSRange(location: textView.string.count, length: 0)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func configureWrapping(for textView: NSTextView) {
        if let keyHandlingTextView = textView as? KeyHandlingTextView {
            keyHandlingTextView.wrapsText = wrapsText
        }
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = wrapsText
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = !wrapsText
        textView.textContainer?.maximumNumberOfLines = wrapsText ? 0 : 1
        textView.textContainer?.lineBreakMode = wrapsText ? .byWordWrapping : .byTruncatingTail
    }

    private func applyCompletionStyle(to textView: NSTextView) {
        let textColor = isComplete ? NSColor.secondaryLabelColor : NSColor.labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: textColor,
            .strikethroughStyle: isComplete ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughColor: textColor
        ]
        textView.textColor = textColor
        textView.typingAttributes = attributes

        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        if range.length > 0 {
            textView.textStorage?.setAttributes(attributes, range: range)
            let text = textView.string as NSString
            for match in hashtagMatches(in: textView.string) {
                guard match.numberOfRanges > 1 else { continue }
                let tag = text.substring(with: match.range(at: 1))
                guard supportedTags.contains(tag.lowercased()) else { continue }
                textView.textStorage?.addAttributes(
                    [
                        .foregroundColor: tagTextColor(for: tag, isComplete: isComplete),
                        .strikethroughColor: textColor
                    ],
                    range: match.range
                )
            }
        }
    }

    private func canClaimFirstResponder(_ textView: KeyHandlingTextView) -> Bool {
        guard let firstResponder = textView.window?.firstResponder as? KeyHandlingTextView else {
            return true
        }

        return firstResponder.paneID == paneID
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: OutlineTextField

        init(_ parent: OutlineTextField) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onBeginEditing()
            parent.editingItemID = parent.id
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string.replacingOccurrences(of: "\n", with: "")
        }

        func textViewDidChangeSelection(_ notification: Notification) {
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == NSSelectorFromString("moveUp:") {
                parent.onMoveUp()
                return true
            }

            if commandSelector == NSSelectorFromString("moveDown:") {
                parent.onMoveDown()
                return true
            }

            if commandSelector == NSSelectorFromString("insertTabIgnoringFieldEditor:")
                || commandSelector == NSSelectorFromString("insertTab:") {
                parent.onIndent()
                return true
            }

            if commandSelector == NSSelectorFromString("insertBacktabIgnoringFieldEditor:")
                || commandSelector == NSSelectorFromString("insertBacktab:") {
                parent.onOutdent()
                return true
            }

            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCreateRow()
                return true
            case #selector(NSResponder.insertTab(_:)):
                parent.onIndent()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                parent.onOutdent()
                return true
            default:
                return false
            }
        }

    }
}

struct FocusedTitleTextField: NSViewRepresentable {
    let paneID: UUID
    @Binding var text: String
    let onBeginEditing: () -> Void
    let onCreateRow: () -> Void

    func makeNSView(context: Context) -> KeyHandlingTextView {
        let textView = KeyHandlingTextView()
        textView.paneID = paneID
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 18, weight: .semibold)
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.maximumNumberOfLines = 1
        textView.textContainer?.lineBreakMode = .byTruncatingTail
        textView.delegate = context.coordinator
        textView.onCreateRow = onCreateRow
        return textView
    }

    func updateNSView(_ textView: KeyHandlingTextView, context: Context) {
        context.coordinator.parent = self
        textView.paneID = paneID

        if textView.string != text {
            textView.string = text
        }

        textView.onCreateRow = onCreateRow
        textView.delegate = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FocusedTitleTextField

        init(_ parent: FocusedTitleTextField) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onBeginEditing()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string.replacingOccurrences(of: "\n", with: "")
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == NSSelectorFromString("insertNewline:")
                || commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCreateRow()
                return true
            }

            return false
        }
    }
}

struct SelectionClearMouseMonitor: NSViewRepresentable {
    let hasSelection: Bool
    let isDraggingSelection: Bool
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.install()
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.hasSelection = hasSelection
        view.isDraggingSelection = isDraggingSelection
        view.onMouseDown = onMouseDown
    }

    final class MonitorView: NSView {
        var hasSelection = false
        var isDraggingSelection = false
        var onMouseDown: (() -> Void)?
        private var eventMonitor: Any?

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func install() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard
                    let self,
                    event.window === self.window,
                    self.hasSelection,
                    !self.isDraggingSelection
                else {
                    return event
                }

                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) {
                    self.onMouseDown?()
                }

                return event
            }
        }
    }
}

final class KeyHandlingTextView: NSTextView {
    var paneID: UUID?
    var representedItemID: UUID?
    var wrapsText = false
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onCreateRow: (() -> Void)?
    var onIndent: (() -> Void)?
    var onOutdent: (() -> Void)?
    var onToggleComplete: (() -> Void)?
    var onDeleteIfEmpty: (() -> Bool)?
    var onCommandFocus: (() -> Void)?
    var onBeginEditing: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        guard wrapsText, let textContainer, let layoutManager else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 34)
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let height = ceil(usedRect.height + textContainerInset.height * 2)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(34, height))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if wrapsText {
            invalidateIntrinsicContentSize()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onBeginEditing?()

        if event.modifierFlags.contains(.command) {
            onCommandFocus?()
            return
        }

        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isUpArrow(event) {
            onMoveUp?()
            return
        }

        if isDownArrow(event) {
            onMoveDown?()
            return
        }

        if isDelete(event), string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if onDeleteIfEmpty?() == true {
                return
            }
        }

        if isReturn(event), event.modifierFlags.contains(.command) {
            onToggleComplete?()
        } else if isReturn(event) {
            onCreateRow?()
        } else if isTab(event) {
            handleTab(event)
        } else {
            super.keyDown(with: event)
        }
    }

    private func handleTab(_ event: NSEvent) {
        if event.modifierFlags.contains(.shift) {
            onOutdent?()
        } else {
            onIndent?()
        }
    }

    private func isTab(_ event: NSEvent) -> Bool {
        event.keyCode == 48 || event.charactersIgnoringModifiers == "\t"
    }

    private func isReturn(_ event: NSEvent) -> Bool {
        event.keyCode == 36
    }

    private func isUpArrow(_ event: NSEvent) -> Bool {
        event.specialKey == .upArrow || event.keyCode == 126
    }

    private func isDownArrow(_ event: NSEvent) -> Bool {
        event.specialKey == .downArrow || event.keyCode == 125
    }

    private func isDelete(_ event: NSEvent) -> Bool {
        event.keyCode == 51 || event.keyCode == 117
    }
}

struct RowKeyboardMonitor: NSViewRepresentable {
    let paneID: UUID
    @Binding var editingItemID: UUID?
    @Binding var selectedItemIDs: Set<UUID>
    let onMoveUp: (UUID) -> Void
    let onMoveDown: (UUID) -> Void
    let onDeleteIfEmpty: (UUID) -> Bool
    let onDeleteSelection: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.install()
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.paneID = paneID
        view.editingItemID = editingItemID
        view.selectedItemIDs = selectedItemIDs
        view.onMoveUp = onMoveUp
        view.onMoveDown = onMoveDown
        view.onDeleteIfEmpty = onDeleteIfEmpty
        view.onDeleteSelection = onDeleteSelection
    }

    final class MonitorView: NSView {
        var paneID: UUID?
        var editingItemID: UUID?
        var selectedItemIDs = Set<UUID>()
        var onMoveUp: ((UUID) -> Void)?
        var onMoveDown: ((UUID) -> Void)?
        var onDeleteIfEmpty: ((UUID) -> Bool)?
        var onDeleteSelection: (() -> Void)?
        private var eventMonitor: Any?

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }

        func install() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard
                    let self,
                    event.window === self.window
                else {
                    return event
                }

                guard
                    let firstResponder = self.window?.firstResponder as? KeyHandlingTextView,
                    firstResponder.paneID == self.paneID
                else {
                    return event
                }

                if event.keyCode == 51 || event.keyCode == 117 {
                    if self.selectedItemIDs.count > 1 {
                        self.onDeleteSelection?()
                        return nil
                    }
                }

                guard let editingItemID = self.editingItemID else {
                    return event
                }

                guard
                    firstResponder.representedItemID == editingItemID
                else {
                    return event
                }

                if event.specialKey == .upArrow || event.keyCode == 126 {
                    self.onMoveUp?(editingItemID)
                    return nil
                }

                if event.specialKey == .downArrow || event.keyCode == 125 {
                    self.onMoveDown?(editingItemID)
                    return nil
                }

                if event.keyCode == 51 || event.keyCode == 117 {
                    if self.onDeleteIfEmpty?(editingItemID) == true {
                        return nil
                    }
                }

                return event
            }
        }
    }
}

struct WindowTabConfigurator: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> ConfiguringView {
        ConfiguringView(title: title)
    }

    func updateNSView(_ view: ConfiguringView, context: Context) {
        view.title = title
        view.configureWindow()
    }

    final class ConfiguringView: NSView {
        var title: String

        init(title: String) {
            self.title = title
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.title = title
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.styleMask.remove(.fullSizeContentView)
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "SoSimpleOutlineWindow"
        }
    }
}

struct WorkspaceCommandReceiver: NSViewRepresentable {
    let onToggleSplitView: () -> Void
    let onTogglePinnedSidebar: () -> Void
    let onToggleTaskSidebar: () -> Void

    func makeNSView(context: Context) -> ReceiverView {
        let view = ReceiverView()
        view.onToggleSplitView = onToggleSplitView
        view.onTogglePinnedSidebar = onTogglePinnedSidebar
        view.onToggleTaskSidebar = onToggleTaskSidebar
        view.install()
        return view
    }

    func updateNSView(_ view: ReceiverView, context: Context) {
        view.onToggleSplitView = onToggleSplitView
        view.onTogglePinnedSidebar = onTogglePinnedSidebar
        view.onToggleTaskSidebar = onToggleTaskSidebar
    }

    final class ReceiverView: NSView {
        var onToggleSplitView: (() -> Void)?
        var onTogglePinnedSidebar: (() -> Void)?
        var onToggleTaskSidebar: (() -> Void)?
        private var observers: [NSObjectProtocol] = []

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func install() {
            guard observers.isEmpty else { return }
            observers.append(NotificationCenter.default.addObserver(
                forName: .toggleWorkspaceSplitView,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.isActiveWindow else { return }
                self.onToggleSplitView?()
            })

            observers.append(NotificationCenter.default.addObserver(
                forName: .toggleWorkspacePinnedSidebar,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.isActiveWindow else { return }
                self.onTogglePinnedSidebar?()
            })

            observers.append(NotificationCenter.default.addObserver(
                forName: .toggleWorkspaceTaskSidebar,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.isActiveWindow else { return }
                self.onToggleTaskSidebar?()
            })
        }

        private var isActiveWindow: Bool {
            window === NSApp.keyWindow || window === NSApp.mainWindow
        }
    }
}

extension Notification.Name {
    static let toggleWorkspaceSplitView = Notification.Name("SoSimpleToggleWorkspaceSplitView")
    static let toggleWorkspacePinnedSidebar = Notification.Name("SoSimpleToggleWorkspacePinnedSidebar")
    static let toggleWorkspaceTaskSidebar = Notification.Name("SoSimpleToggleWorkspaceTaskSidebar")
}

#Preview {
    WorkspaceView(store: OutlineStore())
}
