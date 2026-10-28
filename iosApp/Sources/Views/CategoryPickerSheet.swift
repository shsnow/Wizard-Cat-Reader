import SwiftUI
import UIKit

/// Chooses the categories of one series. Shown when saving a series to the library (from its
/// page, or with a long press on a cover in Explorar) and to change them later. Confirming
/// saves the series first if it is not in the library yet.
struct CategoryPickerSheet: View {
    let manga: MangaItem
    var chapters: [ChapterItem] = []
    /// Called after confirming; `true` when the series was newly added to the library.
    var onDone: ((Bool) -> Void)? = nil

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var loaded = false
    @State private var addingCategory = false
    @State private var newCategoryName = ""

    private var isInLibrary: Bool { library.contains(manga) }

    var body: some View {
        NavigationStack {
            List {
                HStack(spacing: 12) {
                    CoverImage(manga: manga)
                        .frame(width: 44, height: 66)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(manga.title)
                        .font(.system(.headline, design: .serif))
                        .lineLimit(3)
                }
                .listRowSeparator(.hidden)

                Section {
                    if library.categories.isEmpty {
                        Text("Sin categorías, la serie queda en “Todas”. Crea una para ordenarla.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.categories) { category in
                        Button {
                            if selected.contains(category.id) {
                                selected.remove(category.id)
                            } else {
                                selected.insert(category.id)
                            }
                        } label: {
                            HStack {
                                Text(category.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(category.id) {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Color.moka)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                    Button {
                        newCategoryName = ""
                        addingCategory = true
                    } label: {
                        Label("Nueva categoría", systemImage: "plus")
                    }
                } header: {
                    Text("Categorías")
                }
            }
            .navigationTitle(isInLibrary ? Text("Categorías") : Text("Agregar a la biblioteca"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isInLibrary ? LocalizedStringKey("Guardar") : "Agregar") { confirm() }
                        .font(.body.weight(.semibold))
                }
            }
            .alert("Nueva categoría", isPresented: $addingCategory) {
                TextField("Nombre", text: $newCategoryName)
                Button("Cancelar", role: .cancel) {}
                Button("Crear") {
                    // A new category is meant for this series: it comes checked.
                    if let category = library.addCategory(named: newCategoryName) {
                        selected.insert(category.id)
                    }
                    newCategoryName = ""
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            guard !loaded else { return }
            loaded = true
            selected = Set(library.entry(for: manga)?.categories ?? [])
        }
    }

    private func confirm() {
        let added = !isInLibrary
        if added {
            library.add(manga, chapters: chapters)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        // Kept in the order the categories are listed, not the order they were tapped.
        let ordered = library.categories.map(\.id).filter { selected.contains($0) }
        library.setCategories(ordered, for: manga)
        onDone?(added)
        dismiss()
    }
}
