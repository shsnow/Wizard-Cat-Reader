import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var extensions: ExtensionManager
    @EnvironmentObject private var updater: LibraryUpdater
    @State private var reader: ReaderContext?
    @State private var query = ""
    @State private var selectedCategory: String?
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var addingCategory = false
    @State private var newCategoryName = ""
    @State private var confirmingRemoval = false
    @State private var importingComics = false
    @State private var pendingImports: [URL] = []
    @State private var namingImport = false
    @State private var importTitle = ""
    @State private var importError: String?

    private static let comicTypes: [UTType] =
        [UTType(filenameExtension: "cbz"), .zip].compactMap { $0 }

    private var items: [LibraryEntry] {
        // Series of extensions the content restriction removed stay out of sight.
        var all = library.sortedEntries.filter { !extensions.isRestricted(sourceId: $0.manga.sourceId) }
        if let selectedCategory {
            all = all.filter { $0.categories?.contains(selectedCategory) == true }
        }
        switch settings.librarySort {
            case .recent:
                break
            case .title:
                all.sort {
                    $0.manga.title.localizedCaseInsensitiveCompare($1.manga.title) == .orderedAscending
                }
            case .unread:
                all.sort { library.unreadCount(for: $0) > library.unreadCount(for: $1) }
        }
        guard !query.isEmpty else { return all }
        return all.filter { $0.manga.title.localizedCaseInsensitiveContains(query) }
    }

    /// Series left halfway, most recent first, for the "Seguir leyendo" row.
    private var continueReading: [LibraryEntry] {
        library.sortedEntries
            .filter { !extensions.isRestricted(sourceId: $0.manga.sourceId) }
            .filter {
                library.progress[$0.manga.id]?.lastReadChapter != nil
                    && library.unreadCount(for: $0) > 0
            }
            .prefix(10)
            .map { $0 }
    }

    private var showsContinueRow: Bool {
        settings.showContinueRow && !isSelecting && query.isEmpty && selectedCategory == nil
            && !continueReading.isEmpty
    }

    var body: some View {
        Group {
            if library.entries.isEmpty {
                EmptyStateView(
                    symbol: "books.vertical",
                    title: "Tu biblioteca está vacía",
                    message: "Busca algo en Explorar y toca el marcador para guardarlo aquí."
                )
            } else {
                VStack(spacing: 0) {
                    if !library.categories.isEmpty {
                        categoryChips
                    }
                    if updater.isRefreshing {
                        updateBanner
                    }
                    if items.isEmpty {
                        EmptyStateView(
                            symbol: query.isEmpty ? "tray" : "magnifyingglass",
                            title: query.isEmpty ? "Nada por aquí" : "Sin resultados",
                            message: query.isEmpty
                                ? NSLocalizedString("Esta categoría todavía no tiene series.", comment: "")
                                : String(
                                    format: NSLocalizedString("Nada en tu biblioteca se llama “%@”.", comment: ""),
                                    query
                                )
                        )
                    } else {
                        MangaGrid(
                            items: items.map(\.manga),
                            badge: { manga in
                                guard settings.showUnreadBadges else { return 0 }
                                return library.entry(for: manga).map { library.unreadCount(for: $0) } ?? 0
                            },
                            onItemLongPress: { manga in
                                guard !isSelecting else { return }
                                isSelecting = true
                                selection = [manga.id]
                            },
                            selection: isSelecting ? selectionBinding : nil,
                            // The row scrolls away with the grid and comes back at the top.
                            header: showsContinueRow ? AnyView(continueRow) : nil
                        ) {
                            EmptyView()
                        }
                        // Pull down: updates the category on screen, or everything under "Todas".
                        // It runs in the background (banner above), so the spinner lets go at once.
                        .refreshable { updateVisibleSeries() }
                    }
                }
                .searchable(text: $query, prompt: "Buscar en la biblioteca")
            }
        }
        .navigationTitle(isSelecting ? Text("\(selection.count) seleccionadas") : Text("Biblioteca"))
        .navigationBarTitleDisplayMode(isSelecting ? .inline : .large)
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(selection.count == items.count ? LocalizedStringKey("Ninguna") : "Todas") {
                        selection = selection.count == items.count
                            ? []
                            : Set(items.map(\.manga.id))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Listo") { exitSelection() }
                        .font(.body.weight(.semibold))
                }
            } else {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !library.entries.isEmpty {
                        Button {
                            isSelecting = true
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .accessibilityLabel("Seleccionar series")
                    }
                    Button {
                        importingComics = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Importar cómics (CBZ)")
                    Menu {
                        Picker("Ordenar por", selection: $settings.librarySort) {
                            ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Ordenar biblioteca")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
            }
        }
        .navigationDestination(for: MangaItem.self) { manga in
            MangaDetailView(manga: manga)
        }
        .fullScreenCover(item: $reader) { context in
            ReaderView(context: context)
        }
        .alert("Nueva categoría", isPresented: $addingCategory) {
            TextField("Nombre", text: $newCategoryName)
            Button("Cancelar", role: .cancel) {}
            Button("Crear") {
                if let category = library.addCategory(named: newCategoryName) {
                    if !selection.isEmpty {
                        library.toggleCategory(category.id, forEntries: Array(selection))
                    } else {
                        selectedCategory = category.id
                    }
                }
                newCategoryName = ""
            }
        } message: {
            Text("Por ejemplo: Favoritos, Al día, Pendientes…")
        }
        .confirmationDialog(
            selection.count == 1
                ? Text("¿Quitar 1 serie de la biblioteca?")
                : Text("¿Quitar \(selection.count) series de la biblioteca?"),
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Quitar", role: .destructive) {
                library.removeEntries(ids: Array(selection))
                exitSelection()
            }
        } message: {
            if selection.contains(where: { library.entries[$0]?.manga.isLocal == true }) {
                Text("Las series importadas se quitan junto con sus archivos CBZ. Esto no se puede deshacer.")
            }
        }
        .fileImporter(
            isPresented: $importingComics,
            allowedContentTypes: Self.comicTypes,
            allowsMultipleSelection: true
        ) { result in
            guard let urls = try? result.get(), !urls.isEmpty else { return }
            pendingImports = urls
            importTitle = LocalStore.suggestedTitle(for: urls[0])
            namingImport = true
        }
        .alert("Importar como serie", isPresented: $namingImport) {
            TextField("Título de la serie", text: $importTitle)
            Button("Cancelar", role: .cancel) { pendingImports = [] }
            Button("Importar") { importPendingComics() }
        } message: {
            Text(pendingImports.count == 1
                ? LocalizedStringKey("El CBZ se agrega como capítulo de esta serie.")
                : "Los \(pendingImports.count) CBZ se agregan como capítulos de esta serie.")
        }
        .alert(
            "No se pudo importar",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(importError ?? "") }
        )
    }

    /// Copies the picked archives into the local series and puts it in the library.
    /// The copies, ZIP validation and cover extraction are blocking I/O: off the main actor.
    private func importPendingComics() {
        let urls = pendingImports
        let title = importTitle
        pendingImports = []
        Task {
            do {
                let (manga, chapters) = try await Task.detached {
                    let manga = try LocalStore.importArchives(urls, seriesTitle: title)
                    return (manga, LocalStore.chapters(for: manga))
                }.value
                if library.contains(manga) {
                    library.refresh(manga, chapters: chapters)
                } else {
                    library.add(manga, chapters: chapters)
                }
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    // MARK: - Pieces

    private var selectionBinding: Binding<Set<String>> {
        Binding(get: { selection }, set: { selection = $0 })
    }

    private var continueRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Seguir leyendo")
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(continueReading, id: \.manga.id) { entry in
                        continueCard(entry)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// One tap opens the reader right where the series was left; if the source's extension is
    /// gone, it falls back to the series page.
    @ViewBuilder
    private func continueCard(_ entry: LibraryEntry) -> some View {
        let target = library.continueChapter(in: entry)
        if let target, let installed = extensions.extensionFor(sourceId: entry.manga.sourceId) {
            Button {
                let ordered = Array(library.effectiveChapters(of: entry).reversed())
                guard let index = ordered.firstIndex(where: { $0.url == target.url }) else { return }
                reader = ReaderContext(
                    manga: entry.manga, installed: installed, chapters: ordered, startIndex: index
                )
            } label: {
                continueCardLabel(entry, target: target)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: entry.manga) {
                continueCardLabel(entry, target: target)
            }
            .buttonStyle(.plain)
        }
    }

    private func continueCardLabel(_ entry: LibraryEntry, target: ChapterItem?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverImage(manga: entry.manga)
                .frame(width: 76, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.moka, in: Circle())
                        .padding(4)
                }
            Text(entry.manga.title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(continueCaption(for: target))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 76, alignment: .leading)
    }

    private func continueCaption(for target: ChapterItem?) -> String {
        guard let target else { return "" }
        if let number = target.number {
            return "Cap. \(String(format: "%g", number))"
        }
        return target.name
    }

    /// Updates the series of the selected category, or the whole library under "Todas".
    private func updateVisibleSeries() {
        let ids: Set<String>?
        if let selectedCategory {
            ids = Set(
                library.entries.values
                    .filter { $0.categories?.contains(selectedCategory) == true }
                    .map(\.manga.id)
            )
        } else {
            ids = nil
        }
        updater.refreshAll(library: library, extensions: extensions, only: ids)
    }

    private var updateBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Actualizando \(min(updater.completed + 1, updater.total)) de \(updater.total)…")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Detener") { updater.cancel() }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Todas", isOn: selectedCategory == nil) { selectedCategory = nil }
                ForEach(library.categories) { category in
                    chip(category.name, isOn: selectedCategory == category.id) {
                        selectedCategory = selectedCategory == category.id ? nil : category.id
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    isOn ? Color.moka : Color(.secondarySystemBackground),
                    in: Capsule()
                )
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var selectionBar: some View {
        HStack(spacing: 4) {
            barButton("Leído", symbol: "checkmark.circle") {
                library.bulkSetRead(true, entryIds: Array(selection))
                exitSelection()
            }
            barButton("No leído", symbol: "circle") {
                library.bulkSetRead(false, entryIds: Array(selection))
                exitSelection()
            }
            categoriesMenu
            barButton("Quitar", symbol: "trash", role: .destructive) {
                confirmingRemoval = true
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
        .disabled(selection.isEmpty)
    }

    private var categoriesMenu: some View {
        Menu {
            ForEach(library.categories) { category in
                Button {
                    library.toggleCategory(category.id, forEntries: Array(selection))
                } label: {
                    let allIn = selection.allSatisfy { library.isInCategory($0, category.id) }
                    if allIn && !selection.isEmpty {
                        Label(category.name, systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
            if !library.categories.isEmpty { Divider() }
            Button {
                newCategoryName = ""
                addingCategory = true
            } label: {
                Label("Nueva categoría…", systemImage: "plus")
            }
        } label: {
            barLabel("Categoría", symbol: "folder")
        }
    }

    private func barButton(
        _ title: String,
        symbol: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            barLabel(title, symbol: symbol)
        }
    }

    private func barLabel(_ title: String, symbol: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.body)
            Text(title)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func exitSelection() {
        isSelecting = false
        selection = []
    }
}
