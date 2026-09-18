import SwiftUI

struct SidebarView: View {
    @Environment(KindStore.self) private var store

    var body: some View {
        @Bindable var store = store

        List(selection: $store.sidebarSelection) {
            Section {
                Label("Split", systemImage: "exclamationmark.triangle")
                    .badge(store.unresolvedSplitCount)
                    .tag(SidebarItem.split)
                Label("Common", systemImage: "star")
                    .badge(store.commonKinds.count)
                    .tag(SidebarItem.common)
            }

            Section("Categories") {
                ForEach(store.categoriesWithKinds, id: \.self) { category in
                    Label(category.title, systemImage: category.systemImage)
                        .tag(SidebarItem.category(category))
                }
                Label("All Types", systemImage: "square.grid.3x3")
                    .tag(SidebarItem.all)
            }

            Section {
                Label("Applications", systemImage: "app")
                    .tag(SidebarItem.applications)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    }
}

#Preview {
    let store = KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview)
    SidebarView()
        .environment(store)
        .task { await store.refresh() }
        .frame(width: 220, height: 480)
}
