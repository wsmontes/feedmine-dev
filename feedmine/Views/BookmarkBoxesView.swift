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
    /// Shown when a write fails. Every mutation below used `try?` and then changed the list anyway, so a
    /// failed delete/rename looked like a success until the next launch showed the box again.
    @State private var errorMessage: String?

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
                            Task { await delete(box) }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .onMove { from, to in
                    boxes.move(fromOffsets: from, toOffset: to)
                    Task { await persistOrder() }
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
                    do { try await loader.createBookmarkList(name: name) }
                    catch { errorMessage = error.localizedDescription }
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
                Task { await rename(box, to: name) }
                renameTarget = nil
            }
        }
        .alert("Couldn’t update bookmark boxes", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await loadBoxes() }
    }

    private func loadBoxes() async {
        do { boxes = try await loader.loadBookmarkLists() }
        catch { errorMessage = error.localizedDescription }
    }

    /// Drops the box from the list only after the store accepted the delete; on failure the list is
    /// reloaded from the store so what is shown is what is persisted.
    private func delete(_ box: BookmarkList) async {
        do {
            try await loader.deleteBookmarkList(box.id)
        } catch {
            errorMessage = error.localizedDescription
            await loadBoxes()
            return
        }
        boxes.removeAll { $0.id == box.id }
        if loader.selectedBookmarkListID == box.id {
            loader.selectedBookmarkListID = nil
        }
        if loader.preferredBookmarkListID == box.id {
            loader.preferredBookmarkListID = nil
        }
    }

    private func rename(_ box: BookmarkList, to name: String) async {
        do {
            try await loader.renameBookmarkList(box.id, name: name)
        } catch {
            errorMessage = error.localizedDescription
            await loadBoxes()
            return
        }
        if let idx = boxes.firstIndex(where: { $0.id == box.id }) {
            boxes[idx].name = name
        }
    }

    /// Persists the order the drag already applied to the list. A failed write reloads the stored
    /// order instead of leaving the screen showing an order the database never received.
    private func persistOrder() async {
        do {
            for (idx, box) in boxes.enumerated() {
                try await loader.reorderBookmarkList(box.id, sortOrder: idx)
            }
            await loader.refreshBookmarkLists()
        } catch {
            errorMessage = error.localizedDescription
            await loadBoxes()
            await loader.refreshBookmarkLists()
        }
    }
}
