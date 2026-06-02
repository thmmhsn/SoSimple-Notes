//
//  ContentView.swift
//  SoSimple
//
//  Created by thameemh on 2-6-26.
//

import SwiftUI
import Combine

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
    @FocusState private var editingItemID: UUID?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
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
                            }
                        )
                    }
                }
                .padding(24)
            }
        }
        .background(colorScheme == .dark ? Color.black : Color(nsColor: .textBackgroundColor))
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
}

struct OutlineRow: View {
    let item: VisibleOutlineItem
    @Binding var title: String
    let isExpanded: Bool
    let childCount: Int
    @FocusState.Binding var editingItemID: UUID?

    let onToggleExpanded: () -> Void
    let onFocus: () -> Void
    let onAddChild: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onCreateRow: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: CGFloat(item.depth) * 28)

            Button(action: onToggleExpanded) {
                Image(systemName: childCount == 0 ? "circle.fill" : isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                    .font(.system(size: childCount == 0 ? 6 : 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(childCount == 0)

            TextField("New item", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($editingItemID, equals: item.id)
                .onSubmit(onCreateRow)
                .onKeyPress(.upArrow) {
                    onMoveUp()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    onMoveDown()
                    return .handled
                }

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
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }
}

#Preview {
    ContentView()
}
