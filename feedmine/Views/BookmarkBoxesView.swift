import SwiftUI

struct BookmarkBoxesView: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(\.dismiss) private var dismiss
    @State private var boxes: [BookmarkList] = []
    @State private var showNewAlert = false
    @State private var newBoxName = ""
    @State private var renameTarget: BookmarkList?
    @State private var renameName = ""
    @State private var reorderEnabled = false

    var body: some View {
        List {
            Section {
                Button {
                    loader.selectedBookmarkListID = nil
                    dismiss()
                } label: {
                    HStack {
                        Label("All Articles", systemImage: "line.3.horizontal")
                        Spacer()
                        if loader.selectedBookmarkListID == nil {
                            Image(systemName: "checkmark").font(.caption).foregroundStyle(.blue)
                        }
                    }
                }

                ForEach(boxes) { box in
                    Button {
                        if !reorderEnabled {
                            loader.selectedBookmarkListID = box.id
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Label(box.name, systemImage: "folder")
                                .fontWeight(box.id == (loader.preferredBookmarkListID ?? boxes.first(where: { $0.isDefault })?.id) ? .bold : .regular)
                            Spacer()
                            Text("\(box.itemCount)").font(.caption).foregroundStyle(.secondary)
                            if loader.selectedBookmarkListID == box.id {
                                Image(systemName: "checkmark").font(.caption).foregroundStyle(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bookmarkBox.row")
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            loader.preferredBookmarkListID = box.id
                        } label: {
                            Label("Default", systemImage: "star.fill")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Rename") {
                            renameTarget = box
                            renameName = box.name
                        }
                        .tint(.blue)
                        Button(role: .destructive) {
                            Task {
                                try? await loader.deleteBookmarkList(box.id)
                                boxes.removeAll { $0.id == box.id }
                                if loader.selectedBookmarkListID == box.id {
                                    loader.selectedBookmarkListID = nil
                                }
                                if loader.preferredBookmarkListID == box.id {
                                    loader.preferredBookmarkListID = nil
                                }
                            }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .onMove { from, to in
                    boxes.move(fromOffsets: from, toOffset: to)
                    Task {
                        for (idx, box) in boxes.enumerated() {
                            try? await loader.reorderBookmarkList(box.id, sortOrder: idx)
                        }
                        await loader.refreshBookmarkLists()
                    }
                }
            } header: { Text("Bookmark Boxes") }

            Section {
                Button {
                    newBoxName = ""
                    showNewAlert = true
                } label: {
                    Label("New Box", systemImage: "plus.circle")
                }
            }
        }
        .alert("New Box", isPresented: $showNewAlert) {
            TextField("Name", text: $newBoxName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newBoxName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    try? await loader.createBookmarkList(name: name)
                    await loadBoxes()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(reorderEnabled ? "Done" : "Reorder") {
                    reorderEnabled.toggle()
                }
            }
        }
        .environment(\.editMode, .constant(reorderEnabled ? .active : .inactive))
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameName)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                guard let box = renameTarget else { return }
                let name = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task {
                    try? await loader.renameBookmarkList(box.id, name: name)
                    if let idx = boxes.firstIndex(where: { $0.id == box.id }) {
                        boxes[idx].name = name
                    }
                }
                renameTarget = nil
            }
        }
        .task { await loadBoxes() }
    }

    private func loadBoxes() async {
        do { boxes = try await loader.loadBookmarkLists() }
        catch {}
    }
}
