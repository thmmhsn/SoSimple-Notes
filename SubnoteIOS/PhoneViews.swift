import SwiftUI
import UIKit

private struct ContainedPhoneListRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(minHeight: 58)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.10))
            )
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private extension View {
    func containedListRow() -> some View {
        modifier(ContainedPhoneListRow())
    }
}

private struct ReturnSubmittingTextView: UIViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let isComplete: Bool
    let onFocus: () -> Void
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.returnKeyType = .next
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        if textView.text != text {
            textView.text = text
        }
        textView.textColor = isComplete ? .secondaryLabel : .label

        if isFocused, !textView.isFirstResponder {
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
            }
        } else if !isFocused, textView.isFirstResponder {
            DispatchQueue.main.async {
                textView.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ReturnSubmittingTextView

        init(parent: ReturnSubmittingTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocus()
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text.contains("\n") else { return true }
            parent.onSubmit()
            return false
        }
    }
}

struct PhoneOutlineView: View {
    @ObservedObject var store: OutlineStore
    @Binding var focusedItemID: UUID?
    let hidesCompletedItems: Bool
    @Binding var globalHideDone: Bool
    @Binding var isSearchPresented: Bool

    @State private var selectedItemIDs = Set<UUID>()
    @State private var isSelecting = false
    @State private var pendingMoveID: UUID?
    @FocusState private var editingItemID: UUID?

    private var visibleItems: [VisibleOutlineItem] {
        store.visibleItems(
            focusedItemID: focusedItemID,
            hidesCompletedItems: hidesCompletedItems
        )
    }

    private var pinnedItems: [TaggedOutlineItem] {
        guard focusedItemID == nil else { return [] }
        let items = store.pinnedItems()
        guard hidesCompletedItems else { return items }
        return items.filter { !store.isComplete($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let focused = store.focusedItem(focusedItemID: focusedItemID) {
                    Section {
                        focusedTitleRow(focused)
                    }
                }

                if !pinnedItems.isEmpty {
                    Section {
                        ForEach(pinnedItems) { item in
                            pinnedRow(item)
                        }
                    } header: {
                        Text("Pinned")
                    }
                }

                Section {
                    ForEach(visibleItems) { item in
                        outlineRow(item)
                    }
                } header: {
                    if focusedItemID == nil {
                        Text("All Notes")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    outlineMenu
                    Button {
                        undoLastChange()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!store.canUndo)
                    .accessibilityLabel("Undo")

                    Button {
                        redoLastChange()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!store.canRedo)
                    .accessibilityLabel("Redo")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isSearchPresented = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }

                    Button {
                        addItemForCurrentView()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    selectionBar
                }
            }
            .sheet(isPresented: Binding(get: {
                pendingMoveID != nil
            }, set: { isPresented in
                if !isPresented {
                    pendingMoveID = nil
                }
            })) {
                if let pendingMoveID {
                    MoveNoteSheet(store: store, movingID: pendingMoveID) {
                        self.pendingMoveID = nil
                    }
                }
            }
        }
    }

    private var navigationTitle: String {
        if let focused = store.focusedItem(focusedItemID: focusedItemID) {
            let title = taskSidebarDisplayTitle(focused.title)
            return title.isEmpty ? "Untitled" : title
        }
        return "Home"
    }

    private var outlineMenu: some View {
        Menu {
            if focusedItemID != nil {
                Button {
                    focusedItemID = nil
                    editingItemID = nil
                    selectedItemIDs = []
                } label: {
                    Label("All Notes", systemImage: "house")
                }
            }

            Button {
                isSelecting.toggle()
                selectedItemIDs = []
            } label: {
                Label(isSelecting ? "Done Selecting" : "Select Notes", systemImage: "checkmark.circle")
            }

            Toggle(isOn: $globalHideDone) {
                Label("Hide Done Globally", systemImage: "checkmark.circle")
            }

            Button {
                store.loadExternalChanges()
            } label: {
                Label("Reload iCloud Data", systemImage: "arrow.clockwise")
            }

            if let focusedItemID {
                Button {
                    copyItems([focusedItemID])
                } label: {
                    Label("Copy Focused Note", systemImage: "doc.on.doc")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func undoLastChange() {
        store.undo()
        editingItemID = nil
        selectedItemIDs = []
    }

    private func redoLastChange() {
        store.redo()
        editingItemID = nil
        selectedItemIDs = []
    }

    private var selectionBar: some View {
        HStack(spacing: 18) {
            Button {
                copyItems(selectedItemIDs)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(selectedItemIDs.isEmpty)

            Spacer()

            Text("\(selectedItemIDs.count) selected")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            Button(role: .destructive) {
                store.removeItems(with: selectedItemIDs)
                selectedItemIDs = []
                isSelecting = false
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectedItemIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func focusedTitleRow(_ focused: OutlineItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !store.breadcrumbs(focusedItemID: focusedItemID).isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button("Home") {
                            focusedItemID = nil
                        }
                        .font(.caption.weight(.semibold))

                        ForEach(store.breadcrumbs(focusedItemID: focusedItemID)) { item in
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button(taskSidebarDisplayTitle(item.title)) {
                                focusedItemID = item.id
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                }
            }

            TextField(
                "Title",
                text: Binding(
                    get: { store.title(for: focused.id) },
                    set: { store.setTitle($0, for: focused.id) }
                ),
                axis: .vertical
            )
            .font(.title3.weight(.semibold))
            .textFieldStyle(.plain)
            .focused($editingItemID, equals: focused.id)
            .submitLabel(.next)
            .onSubmit {
                addItemForCurrentView()
            }
        }
        .padding(.vertical, 4)
        .containedListRow()
    }

    private func pinnedRow(_ item: TaggedOutlineItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(taskSidebarDisplayTitle(store.title(for: item.id)))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(store.isComplete(item.id) ? .secondary : .primary)
                    .strikethrough(store.isComplete(item.id))

                if !item.path.isEmpty {
                    Text(item.path.map(titleHidingSidebarMarkers).joined(separator: " / "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            Button {
                focusedItemID = item.id
                editingItemID = nil
                selectedItemIDs = []
            } label: {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open note")
        }
        .containedListRow()
    }

    private func outlineRow(_ item: VisibleOutlineItem) -> some View {
        let title = Binding(
            get: { store.title(for: item.id) },
            set: { store.setTitle($0, for: item.id) }
        )
        let isComplete = store.isComplete(item.id)

        return HStack(alignment: .top, spacing: 8) {
            if isSelecting {
                Button {
                    toggleSelection(item.id)
                } label: {
                    Image(systemName: selectedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selectedItemIDs.contains(item.id) ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }

            ReturnSubmittingTextView(
                text: title,
                isFocused: editingItemID == item.id,
                isComplete: isComplete,
                onFocus: {
                    editingItemID = item.id
                },
                onSubmit: {
                    submitOutlineRow(item.id)
                }
            )
            .frame(minHeight: 34)
            .strikethrough(isComplete)

            Button {
                focusedItemID = item.id
                editingItemID = nil
                selectedItemIDs = []
            } label: {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open note")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editingItemID = item.id
        }
        .containedListRow()
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                store.toggleComplete(item.id)
            } label: {
                Label(isComplete ? "Mark Open" : "Complete", systemImage: isComplete ? "circle" : "checkmark.circle")
            }
            .tint(.green)

            Button {
                let childID = store.addChild(to: item.id)
                focusedItemID = item.id
                editingItemID = childID
            } label: {
                Label("Child", systemImage: "plus.square.on.square")
            }
            .tint(.blue)

            Button {
                if let previousID = previousVisibleItem(before: item.id) {
                    store.indent(item.id, under: previousID)
                    focusedItemID = previousID
                    editingItemID = item.id
                }
            } label: {
                Label("Indent", systemImage: "increase.indent")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                _ = store.removeItem(with: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Button {
                pendingMoveID = item.id
            } label: {
                Label("Move", systemImage: "arrow.up.arrow.down")
            }
            .tint(.orange)

            Button {
                copyItems([item.id])
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(.gray)
        }
        .contextMenu {
            Button("Focus") {
                focusedItemID = item.id
            }
            Button("Add Child") {
                let childID = store.addChild(to: item.id)
                focusedItemID = item.id
                editingItemID = childID
            }
            Button("Outdent") {
                store.outdent(item.id)
                editingItemID = item.id
            }
            Button("Move") {
                pendingMoveID = item.id
            }
            Button("Copy With Subnotes") {
                copyItems([item.id])
            }
            Button("Paste Outline After") {
                pasteOutline(at: item.id)
            }
            Button("Toggle Done") {
                store.toggleComplete(item.id)
            }
            Button("Delete", role: .destructive) {
                _ = store.removeItem(with: item.id)
            }
        }
    }

    private func addItemForCurrentView() {
        if let focusedItemID {
            let newID = store.addChild(to: focusedItemID)
            editingItemID = newID
        } else {
            let newID = store.addRoot()
            editingItemID = newID
        }
    }

    private func createRow(afterOrInside id: UUID) {
        let newID = store.addSibling(after: id)
        editingItemID = newID
    }

    private func submitOutlineRow(_ id: UUID) {
        if store.title(for: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editingItemID = nil
            return
        }
        createRow(afterOrInside: id)
    }

    private func toggleSelection(_ id: UUID) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }

    private func copyItems(_ ids: Set<UUID>) {
        let items = store.copyableItems(for: ids)
        guard !items.isEmpty else { return }
        UIPasteboard.general.string = outlinePlainText(from: items)
    }

    private func copyItems(_ ids: [UUID]) {
        copyItems(Set(ids))
    }

    private func pasteOutline(at id: UUID) {
        guard let text = UIPasteboard.general.string else { return }
        let pastedItems = outlineItemsFromPlainText(text)
        guard !pastedItems.isEmpty else { return }
        if let pastedID = store.pasteOutline(pastedItems, at: id) {
            editingItemID = pastedID
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
}

struct PhoneTasksView: View {
    @ObservedObject var store: OutlineStore
    let onOpenItem: (UUID) -> Void

    private enum ProjectFilter: Hashable {
        case all
        case noProject
        case project(String)
    }

    @State private var selectedTag = "i"
    @AppStorage("subnote.hideDone.tasks") private var hidesCompletedItems = false
    @State private var selectedProjectFilter = ProjectFilter.all
    @FocusState private var editingItemID: UUID?

    private var items: [TaggedOutlineItem] {
        store.taskItems(filteredBy: selectedTag).filter { item in
            if hidesCompletedItems, store.isComplete(item.id) {
                return false
            }
            switch selectedProjectFilter {
            case .all:
                return true
            case .noProject:
                return item.projectTitle == nil
            case .project(let selectedProjectTitle):
                return item.projectTitle == selectedProjectTitle
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("List", selection: $selectedTag) {
                        Text("Inbox").tag("i")
                        Text("Later").tag("l")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                Section {
                    ForEach(items) { item in
                        taskRow(item)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        store.undo()
                        editingItemID = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!store.canUndo)
                    .accessibilityLabel("Undo")

                    Button {
                        store.redo()
                        editingItemID = nil
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!store.canRedo)
                    .accessibilityLabel("Redo")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Hide Done", isOn: $hidesCompletedItems)

                        Picker("Project", selection: $selectedProjectFilter) {
                            Text("All Projects").tag(ProjectFilter.all)
                            Text("No Project").tag(ProjectFilter.noProject)
                            ForEach(store.projectOptions(filteredBy: selectedTag), id: \.self) { project in
                                Text(titleHidingSidebarMarkers(project)).tag(ProjectFilter.project(project))
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .onChange(of: selectedTag) { _, _ in
                selectedProjectFilter = .all
            }
        }
    }

    private func taskRow(_ item: TaggedOutlineItem) -> some View {
        let title = Binding(
            get: { store.title(for: item.id) },
            set: { store.setTitle($0, for: item.id) }
        )
        let isComplete = store.isComplete(item.id)
        let moveTitle = selectedTag == "l" ? "Inbox" : "Later"
        let moveIcon = selectedTag == "l" ? "tray" : "clock"

        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                ReturnSubmittingTextView(
                    text: title,
                    isFocused: editingItemID == item.id,
                    isComplete: isComplete,
                    onFocus: {
                        editingItemID = item.id
                    },
                    onSubmit: {
                        submitTaskRow(item)
                    }
                )
                .frame(minHeight: 34)
                .strikethrough(isComplete)

                if let project = item.projectTitle {
                    Text(titleHidingSidebarMarkers(project))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                onOpenItem(item.parentID ?? item.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open note")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editingItemID = item.id
        }
        .containedListRow()
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                store.toggleComplete(item.id)
            } label: {
                Label(isComplete ? "Mark Open" : "Complete", systemImage: isComplete ? "circle" : "checkmark.circle")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                _ = store.removeItem(with: item.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }

            Button {
                moveTaskToOtherList(item)
            } label: {
                Label(moveTitle, systemImage: moveIcon)
            }
            .tint(.blue)
        }
        .contextMenu {
            Button("Open Parent") {
                onOpenItem(item.parentID ?? item.id)
            }
            Button("Move to \(moveTitle)") {
                moveTaskToOtherList(item)
            }
            Button("Toggle Done") {
                store.toggleComplete(item.id)
            }
            Button("Copy With Subnotes") {
                let items = store.copyableItems(for: [item.id])
                UIPasteboard.general.string = outlinePlainText(from: items)
            }
        }
    }

    private func isBucketItem(_ item: TaggedOutlineItem) -> Bool {
        guard let bucketTitle = item.path.first else { return false }
        return bucketTitle.compare(inboxTaskTitle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            || bucketTitle.compare(laterTaskTitle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private func submitTaskRow(_ item: TaggedOutlineItem) {
        if store.title(for: item.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editingItemID = nil
            return
        }

        let newID = store.addSibling(after: item.id)
        if !isBucketItem(item) {
            store.addTag(selectedTag, to: newID)
        }
        editingItemID = newID
    }

    private func moveTaskToOtherList(_ item: TaggedOutlineItem) {
        let targetTag = selectedTag == "l" ? "i" : "l"
        if isBucketItem(item), let targetBucketID = store.taskBucketID(filteredBy: targetTag) {
            _ = store.move(item.id, to: .child, relativeTo: targetBucketID)
        } else {
            store.removeTag(selectedTag, from: item.id)
            store.addTag(targetTag, to: item.id)
        }
        editingItemID = nil
    }
}

struct PhonePinsView: View {
    @ObservedObject var store: OutlineStore
    let hidesCompletedItems: Bool
    let onOpenItem: (UUID) -> Void

    private var items: [TaggedOutlineItem] {
        let pinnedItems = store.pinnedItems()
        guard hidesCompletedItems else { return pinnedItems }
        return pinnedItems.filter { !store.isComplete($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    Button {
                        onOpenItem(item.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(taskSidebarDisplayTitle(store.title(for: item.id)))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(store.isComplete(item.id) ? .secondary : .primary)
                                .strikethrough(store.isComplete(item.id))
                            if !item.path.isEmpty {
                                Text(item.path.map(titleHidingSidebarMarkers).joined(separator: " / "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pins")
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("No Pins", systemImage: "pin", description: Text("Add * to a note title to pin it."))
                }
            }
        }
    }
}

struct PhoneSearchView: View {
    @ObservedObject var store: OutlineStore
    let onOpenItem: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [OutlineSearchResult] {
        store.searchResults(matching: query)
    }

    var body: some View {
        NavigationStack {
            List(results) { result in
                Button {
                    onOpenItem(result.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title)
                            .font(.body.weight(.semibold))
                            .strikethrough(result.isComplete)
                            .foregroundStyle(result.isComplete ? .secondary : .primary)
                        if !result.path.isEmpty {
                            Text(result.path.joined(separator: " / "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct MoveNoteSheet: View {
    @ObservedObject var store: OutlineStore
    let movingID: UUID
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var placement: OutlineDropPlacement = .child

    private var results: [OutlineSearchResult] {
        store.searchResults(matching: query)
            .filter { $0.id != movingID }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Placement", selection: $placement) {
                        Text("Inside").tag(OutlineDropPlacement.child)
                        Text("Before").tag(OutlineDropPlacement.before)
                        Text("After").tag(OutlineDropPlacement.after)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    ForEach(results) { result in
                        Button {
                            if store.move(movingID, to: placement, relativeTo: result.id) {
                                onDone()
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title)
                                    .font(.body.weight(.semibold))
                                if !result.path.isEmpty {
                                    Text(result.path.joined(separator: " / "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move Note")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find destination")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onDone()
                        dismiss()
                    }
                }
            }
        }
    }
}
