//
//  ContentView.swift
//  SoSimple
//
//  Created by thameemh on 2-6-26.
//

import Combine
import SwiftUI

struct OutlineItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var isExpanded = true
    var children: [OutlineItem] = []
}

struct VisibleOutlineItem: Identifiable {
    let id: UUID
    let depth: Int
}

@MainActor
final class OutlineStore: ObservableObject {
    @Published private(set) var items: [OutlineItem] = [] {
        didSet { save() }
    }

    @Published var focusedItemID: UUID?

    private let fileManager = FileManager.default
    private let storageURL: URL

    init() {
        storageURL = Self.makeStorageURL()
        load()
    }

    var visibleItems: [VisibleOutlineItem] {
        if let focusedItemID, let item = item(with: focusedItemID) {
            return flatten([item], depth: 0)
        }
        return flatten(items, depth: 0)
    }

    var breadcrumbs: [OutlineItem] {
        guard let focusedItemID else { return [] }
        return path(to: focusedItemID, in: items) ?? []
    }

    func title(for id: UUID) -> String {
        item(with: id)?.title ?? ""
    }

    func setTitle(_ title: String, for id: UUID) {
        update(id) { item in
            item.title = title
        }
    }

    func isExpanded(_ id: UUID) -> Bool {
        item(with: id)?.isExpanded ?? false
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

    func indent(_ id: UUID) {
        guard let parentID = previousVisibleItem(before: id), let item = remove(id, from: &items) else {
            return
        }

        update(parentID) { parent in
            parent.isExpanded = true
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

        if focusedItemID == id {
            focusedItemID = nil
        }

        return remove(id, from: &items) != nil
    }

    func toggleExpanded(_ id: UUID) {
        update(id) { item in
            item.isExpanded.toggle()
        }
    }

    func focus(_ id: UUID?) {
        focusedItemID = id
    }

    func nextVisibleItem(after id: UUID) -> UUID? {
        let ids = visibleItems.map(\.id)
        guard let index = ids.firstIndex(of: id), index < ids.index(before: ids.endIndex) else {
            return nil
        }
        return ids[ids.index(after: index)]
    }

    func previousVisibleItem(before id: UUID) -> UUID? {
        let ids = visibleItems.map(\.id)
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
            let data = try? Data(contentsOf: storageURL),
            let decoded = try? JSONDecoder().decode([OutlineItem].self, from: data),
            !decoded.isEmpty
        else {
            items = [
                OutlineItem(
                    title: "Home",
                    children: [
                        OutlineItem(title: "Work"),
                        OutlineItem(title: "Personal")
                    ]
                )
            ]
            return
        }

        items = decoded
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

    private func flatten(_ source: [OutlineItem], depth: Int) -> [VisibleOutlineItem] {
        source.flatMap { item -> [VisibleOutlineItem] in
            var rows = [VisibleOutlineItem(id: item.id, depth: depth)]
            if item.isExpanded {
                rows.append(contentsOf: flatten(item.children, depth: depth + 1))
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
    @StateObject private var store = OutlineStore()
    @State private var editingItemID: UUID?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.visibleItems) { item in
                        OutlineRow(
                            item: item,
                            title: Binding(
                                get: { store.title(for: item.id) },
                                set: { store.setTitle($0, for: item.id) }
                            ),
                            isExpanded: store.isExpanded(item.id),
                            childCount: store.childCount(for: item.id),
                            editingItemID: $editingItemID,
                            onToggleExpanded: {
                                store.toggleExpanded(item.id)
                            },
                            onFocus: {
                                store.focus(item.id)
                                editingItemID = item.id
                            },
                            onAddChild: {
                                let childID = store.addChild(to: item.id)
                                editingItemID = childID
                            },
                            onMoveUp: {
                                if let previousID = store.previousVisibleItem(before: item.id) {
                                    editingItemID = previousID
                                }
                            },
                            onMoveDown: {
                                if let nextID = store.nextVisibleItem(after: item.id) {
                                    editingItemID = nextID
                                }
                            },
                            onCreateRow: {
                                let newID = store.addSibling(after: item.id)
                                editingItemID = newID
                            },
                            onIndent: {
                                store.indent(item.id)
                                editingItemID = item.id
                            },
                            onOutdent: {
                                store.outdent(item.id)
                                editingItemID = item.id
                            },
                            onDeleteIfEmpty: {
                                deleteIfEmpty(item.id)
                            }
                        )
                    }
                }
                .padding(24)
            }
        }
        .background(colorScheme == .dark ? Color(red: 0.08, green: 0.08, blue: 0.09) : Color(nsColor: .textBackgroundColor))
        .overlay {
            RowKeyboardMonitor(
                editingItemID: $editingItemID,
                onMoveUp: { id in
                    if let previousID = store.previousVisibleItem(before: id) {
                        editingItemID = previousID
                    }
                },
                onMoveDown: { id in
                    if let nextID = store.nextVisibleItem(after: id) {
                        editingItemID = nextID
                    }
                },
                onDeleteIfEmpty: { id in
                    deleteIfEmpty(id)
                }
            )
            .frame(width: 0, height: 0)
        }
        .frame(minWidth: 720, minHeight: 520)
        .toolbar {
            Button {
                let id = store.addRoot()
                editingItemID = id
            } label: {
                Label("Add Item", systemImage: "plus")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                store.focus(nil)
            } label: {
                Image(systemName: "house")
            }
            .buttonStyle(.borderless)
            .help("Show full outline")

            ForEach(store.breadcrumbs) { item in
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(item.title.isEmpty ? "Untitled" : item.title) {
                    store.focus(item.id)
                    editingItemID = item.id
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

        let previousID = store.previousVisibleItem(before: id)
        let nextID = store.nextVisibleItem(after: id)
        guard store.removeIfEmpty(id) else {
            return false
        }

        editingItemID = previousID ?? nextID
        return true
    }
}

struct OutlineRow: View {
    let item: VisibleOutlineItem
    @Binding var title: String
    let isExpanded: Bool
    let childCount: Int
    @Binding var editingItemID: UUID?

    let onToggleExpanded: () -> Void
    let onFocus: () -> Void
    let onAddChild: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onCreateRow: () -> Void
    let onIndent: () -> Void
    let onOutdent: () -> Void
    let onDeleteIfEmpty: () -> Bool

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: CGFloat(item.depth) * 28)

            Button(action: onToggleExpanded) {
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
                id: item.id,
                text: $title,
                editingItemID: $editingItemID,
                onMoveUp: onMoveUp,
                onMoveDown: onMoveDown,
                onCreateRow: onCreateRow,
                onIndent: onIndent,
                onOutdent: onOutdent,
                onDeleteIfEmpty: onDeleteIfEmpty
            )
            .frame(height: 34)

            Spacer()

            Button(action: onFocus) {
                Image(systemName: "scope")
            }
            .buttonStyle(.borderless)
            .help("Focus")

            Button(action: onAddChild) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add child")
        }
        .frame(height: 15, alignment: .center)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }
}

struct OutlineTextField: NSViewRepresentable {
    let id: UUID
    @Binding var text: String
    @Binding var editingItemID: UUID?
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onCreateRow: () -> Void
    let onIndent: () -> Void
    let onOutdent: () -> Void
    let onDeleteIfEmpty: () -> Bool

    func makeNSView(context: Context) -> KeyHandlingTextView {
        let textView = KeyHandlingTextView()
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = NSSize(width: 0, height: 7)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.maximumNumberOfLines = 1
        textView.textContainer?.lineBreakMode = .byTruncatingTail
        textView.delegate = context.coordinator
        textView.onMoveUp = onMoveUp
        textView.onMoveDown = onMoveDown
        textView.onCreateRow = onCreateRow
        textView.onIndent = onIndent
        textView.onOutdent = onOutdent
        textView.onDeleteIfEmpty = onDeleteIfEmpty
        return textView
    }

    func updateNSView(_ textView: KeyHandlingTextView, context: Context) {
        context.coordinator.parent = self

        if textView.string != text {
            textView.string = text
        }

        textView.onMoveUp = onMoveUp
        textView.onMoveDown = onMoveDown
        textView.onCreateRow = onCreateRow
        textView.onIndent = onIndent
        textView.onOutdent = onOutdent
        textView.onDeleteIfEmpty = onDeleteIfEmpty
        textView.delegate = context.coordinator

        let shouldEdit = editingItemID == id
        let isFirstResponder = textView.window?.firstResponder === textView
        if shouldEdit, !isFirstResponder {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.selectedRange = NSRange(location: textView.string.count, length: 0)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: OutlineTextField

        init(_ parent: OutlineTextField) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.editingItemID = parent.id
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string.replacingOccurrences(of: "\n", with: "")
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

final class KeyHandlingTextView: NSTextView {
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onCreateRow: (() -> Void)?
    var onIndent: (() -> Void)?
    var onOutdent: (() -> Void)?
    var onDeleteIfEmpty: (() -> Bool)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 34)
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

        if event.keyCode == 36 {
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
    @Binding var editingItemID: UUID?
    let onMoveUp: (UUID) -> Void
    let onMoveDown: (UUID) -> Void
    let onDeleteIfEmpty: (UUID) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.install()
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.editingItemID = editingItemID
        view.onMoveUp = onMoveUp
        view.onMoveDown = onMoveDown
        view.onDeleteIfEmpty = onDeleteIfEmpty
    }

    final class MonitorView: NSView {
        var editingItemID: UUID?
        var onMoveUp: ((UUID) -> Void)?
        var onMoveDown: ((UUID) -> Void)?
        var onDeleteIfEmpty: ((UUID) -> Bool)?
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
                    event.window === self.window,
                    let editingItemID = self.editingItemID
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

#Preview {
    ContentView()
}
