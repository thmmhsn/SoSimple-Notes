import SwiftUI

@main
struct SubnoteIOSApp: App {
    @StateObject private var store = OutlineStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneWorkspaceView(store: store)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background || phase == .inactive {
                        store.flushSave()
                    } else if phase == .active {
                        store.loadExternalChanges()
                    }
                }
        }
    }
}

private enum PhoneTab: Hashable {
    case notes
    case tasks
}

struct PhoneWorkspaceView: View {
    @ObservedObject var store: OutlineStore
    @State private var selectedTab: PhoneTab = .notes
    @State private var focusedItemID: UUID?
    @AppStorage("subnote.hideDone.global") private var globalHideDone = false
    @State private var isSearchPresented = false

    var body: some View {
        TabView(selection: $selectedTab) {
            PhoneOutlineView(
                store: store,
                focusedItemID: $focusedItemID,
                hidesCompletedItems: globalHideDone,
                globalHideDone: $globalHideDone,
                isSearchPresented: $isSearchPresented
            )
            .tabItem {
                Label("Notes", systemImage: "list.bullet.indent")
            }
            .tag(PhoneTab.notes)

            PhoneTasksView(
                store: store,
                onOpenItem: openItem
            )
            .tabItem {
                Label("Tasks", systemImage: "checklist")
            }
            .tag(PhoneTab.tasks)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isSearchPresented) {
            PhoneSearchView(store: store) { id in
                openItem(id)
                isSearchPresented = false
            }
        }
    }

    private func openItem(_ id: UUID) {
        focusedItemID = id
        selectedTab = .notes
    }
}
