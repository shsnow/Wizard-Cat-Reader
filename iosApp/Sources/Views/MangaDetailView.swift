import PhotosUI
import SwiftUI

struct MangaDetailView: View {
    @State private var manga: MangaItem

    @EnvironmentObject private var extensions: ExtensionManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloads: DownloadManager

    @State private var chapters: [ChapterItem] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var expanded = false
    @State private var reader: ReaderContext?
    @State private var newestFirst = true
    @State private var editingNote = false
    @State private var noteDraft = ""
    @State private var selectingChapters = false
    @State private var selectedChapters: Set<String> = []
    @State private var chapterQuery = ""
    @State private var siteURL: URL?
    @State private var migrating = false
    /// Long-pressed chapter while selecting: anchors the "este y anteriores" range actions.
    @State private var rangeAnchor: ChapterItem?
    @State private var pickingCover = false
    @State private var coverItem: PhotosPickerItem?
    /// Shown as an alert; `error` only renders while the chapter list is empty.
    @State private var actionError: String?
    @State private var confirmingDeleteDownloads = false
    @State private var confirmingRemoval = false
    @State private var showingWebLogin = false

    init(manga: MangaItem) {
        _manga = State(initialValue: manga)
    }

    private var installed: InstalledExtension? {
        extensions.extensionFor(sourceId: manga.sourceId)
    }

    /// The chapter list after the scanlator preference drops duplicate releases.
    private var effectiveChapters: [ChapterItem] {
        LibraryStore.applyScanlatorPreference(
            chapters, preferred: library.preferredScanlator(for: manga)
        )
    }

    /// Groups that released chapters for this series, for the preference picker.
    private var scanlators: [String] {
        var seen = Set<String>()
        return chapters
            .compactMap(\.scanlator)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted()
    }

    /// Sources list chapters newest first, the same convention as Mihon.
    private var ascending: [ChapterItem] { Array(effectiveChapters.reversed()) }

    private var displayed: [ChapterItem] {
        let ordered = newestFirst ? effectiveChapters : ascending
        let query = chapterQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return ordered }
        return ordered.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.number.map { number in String(format: "%g", number).contains(query) } == true
        }
    }

    private var unread: [ChapterItem] {
        ascending.filter { !library.isRead($0, in: manga) }
    }

    /// The selected chapters, oldest first, so batch downloads queue in reading order.
    private var selectedItems: [ChapterItem] {
        ascending.filter { selectedChapters.contains($0.url) }
    }

    private var continueTarget: ChapterItem? {
        let ordered = ascending
        guard !ordered.isEmpty else { return nil }
        if let last = library.lastRead(in: manga),
           let index = ordered.firstIndex(where: { $0.url == last }) {
            if library.isRead(ordered[index], in: manga), index + 1 < ordered.count {
                return ordered[index + 1]
            }
            return ordered[index]
        }
        return ordered.first { !library.isRead($0, in: manga) } ?? ordered.first
    }

    var body: some View {
        Group {
            if ContentFilter.isAllowed(manga) {
                content
            } else {
                EmptyStateView(
                    symbol: "hand.raised",
                    title: "Contenido no disponible",
                    message: "Wizard Cat Reader es una app para toda la familia y no muestra contenido para adultos."
                )
            }
        }
        .navigationTitle(manga.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if chapters.isEmpty, let entry = library.entry(for: manga) {
                manga = entry.manga
                chapters = entry.chapters
            }
            await refresh()
        }
        .fullScreenCover(item: $reader) { context in
            ReaderView(context: context)
        }
    }

    private var content: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))

            aboutRows
            chapterSection
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Modo de lectura", selection: modeBinding) {
                        ForEach(ReadingMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbol).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: modeBinding.wrappedValue.symbol)
                }
                .accessibilityLabel("Modo de lectura")
                if !manga.isLocal {
                    downloadMenu
                }
                if library.contains(manga) {
                    Button {
                        noteDraft = library.note(for: manga)
                        editingNote = true
                    } label: {
                        Image(systemName: library.note(for: manga).isEmpty ? "note.text.badge.plus" : "note.text")
                    }
                    .accessibilityLabel("Nota de la serie")
                }
                Button {
                    toggleLibrary()
                } label: {
                    Image(systemName: library.contains(manga) ? "bookmark.fill" : "bookmark")
                }
                .accessibilityLabel(
                    library.contains(manga)
                        ? Text("Quitar de la biblioteca")
                        : Text("Guardar en la biblioteca")
                )
                if siteURL != nil || library.contains(manga) || (installed != nil && !manga.isLocal) {
                    Menu {
                        if scanlators.count >= 2 {
                            Picker("Scanlator preferido", selection: scanlatorBinding) {
                                Text("Todos los grupos").tag(String?.none)
                                ForEach(scanlators, id: \.self) { group in
                                    Text(group).tag(String?.some(group))
                                }
                            }
                        }
                        if library.contains(manga) {
                            Button {
                                pickingCover = true
                            } label: {
                                Label("Cambiar portada", systemImage: "photo")
                            }
                            if library.customCoverURL(for: manga) != nil {
                                Button(role: .destructive) {
                                    library.removeCustomCover(for: manga)
                                } label: {
                                    Label("Quitar portada personalizada", systemImage: "photo.on.rectangle.angled")
                                }
                            }
                            if !manga.isLocal {
                                Divider()
                                Button {
                                    migrating = true
                                } label: {
                                    Label("Migrar de fuente", systemImage: "arrow.left.arrow.right")
                                }
                            }
                        }
                        if installed != nil && !manga.isLocal {
                            Button {
                                showingWebLogin = true
                            } label: {
                                Label("Abrir en WebView", systemImage: "globe")
                            }
                        }
                        if let siteURL {
                            Link(destination: siteURL) {
                                Label("Abrir en el sitio", systemImage: "safari")
                            }
                            ShareLink(item: siteURL) {
                                Label("Compartir enlace", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Más opciones")
                }
            }
        }
        .refreshable { await refresh(manual: true) }
        .searchable(
            text: $chapterQuery,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Buscar capítulo"
        )
        .safeAreaInset(edge: .bottom) {
            if selectingChapters {
                chapterSelectionBar
            }
        }
        .sheet(isPresented: $editingNote) {
            NavigationStack {
                TextEditor(text: $noteDraft)
                    .padding(12)
                    .navigationTitle("Nota")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancelar") { editingNote = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Guardar") {
                                library.setNote(noteDraft, for: manga)
                                editingNote = false
                            }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingWebLogin) {
            if let installed {
                WebLoginSheet(
                    sourceId: manga.sourceId,
                    displayName: installed.name,
                    installed: installed,
                    startURL: siteURL
                ) {
                    Task { await refresh() }
                }
            }
        }
        .sheet(isPresented: $migrating) {
            MigrateSourceView(manga: manga) { newManga, newChapters in
                manga = newManga
                chapters = newChapters
                siteURL = nil
                selectingChapters = false
                selectedChapters = []
            }
        }
        .confirmationDialog(
            "Desde este capítulo",
            isPresented: Binding(
                get: { rangeAnchor != nil },
                set: { if !$0 { rangeAnchor = nil } }
            ),
            titleVisibility: .visible,
            presenting: rangeAnchor
        ) { anchor in
            rangeActions(for: anchor)
        } message: { anchor in
            Text(anchor.name)
        }
        .confirmationDialog(
            "¿Borrar las descargas de esta serie?",
            isPresented: $confirmingDeleteDownloads,
            titleVisibility: .visible
        ) {
            Button("Borrar descargas", role: .destructive) {
                downloads.deleteAll(mangaId: manga.id)
            }
        }
        .confirmationDialog(
            "¿Quitar de la biblioteca?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Quitar", role: .destructive) { library.remove(manga) }
        } message: {
            Text(manga.isLocal
                ? LocalizedStringKey("Se borran también los archivos CBZ importados de esta serie. Esto no se puede deshacer.")
                : "Se pierden la nota y las categorías de esta serie.")
        }
        .alert(
            "No se puede abrir",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(actionError ?? "") }
        )
        .photosPicker(isPresented: $pickingCover, selection: $coverItem, matching: .images)
        .onChange(of: coverItem) { item in
            guard let item else { return }
            Task {
                defer { coverItem = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                // A photo can be 48 MP; decode and resize off the main actor.
                let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
                    guard let picked = UIImage(data: data) else { return nil }
                    // A cover never needs more than ~900 px of width.
                    let scale = min(1, 900 / max(picked.size.width, 1))
                    let size = CGSize(
                        width: picked.size.width * scale,
                        height: picked.size.height * scale
                    )
                    let renderer = UIGraphicsImageRenderer(size: size)
                    let resized = renderer.image { _ in
                        picked.draw(in: CGRect(origin: .zero, size: size))
                    }
                    return resized.jpegData(compressionQuality: 0.85)
                }.value
                guard let jpeg else { return }
                library.setCustomCover(jpeg, for: manga)
            }
        }
    }

    private var scanlatorBinding: Binding<String?> {
        Binding(
            get: { library.preferredScanlator(for: manga) },
            set: { library.setPreferredScanlator($0, for: manga) }
        )
    }

    @ViewBuilder
    private func rangeActions(for anchor: ChapterItem) -> some View {
        let through = chaptersThrough(anchor)
        let pending = through.filter { !downloads.isDownloaded(manga: manga, chapter: $0) }
        Button("Marcar leídos este y anteriores (\(through.count))") {
            library.setRead(true, chapterURLs: through.map(\.url), in: manga)
        }
        Button("Marcar no leídos este y anteriores") {
            library.setRead(false, chapterURLs: through.map(\.url), in: manga)
        }
        if !pending.isEmpty && installed != nil && !manga.isLocal {
            Button("Descargar este y anteriores (\(pending.count))") {
                download(pending)
            }
        }
        Button("Seleccionar este y anteriores") {
            selectedChapters.formUnion(through.map(\.url))
        }
        Button("Seleccionar este y siguientes") {
            selectedChapters.formUnion(chaptersFrom(anchor).map(\.url))
        }
        Button("Cancelar", role: .cancel) {}
    }

    /// The anchor and every older chapter, oldest first.
    private func chaptersThrough(_ anchor: ChapterItem) -> [ChapterItem] {
        let ordered = ascending
        guard let index = ordered.firstIndex(where: { $0.url == anchor.url }) else { return [] }
        return Array(ordered[...index])
    }

    /// The anchor and every newer chapter, oldest first.
    private func chaptersFrom(_ anchor: ChapterItem) -> [ChapterItem] {
        let ordered = ascending
        guard let index = ordered.firstIndex(where: { $0.url == anchor.url }) else { return [] }
        return Array(ordered[index...])
    }

    // Split into small views on purpose: as one List closure, the Swift
    // type-checker gives up on this screen ("unable to type-check in
    // reasonable time").

    @ViewBuilder
    private var aboutRows: some View {
        if let summary = manga.summary, !summary.isEmpty {
            summaryRow(summary)
        }
        if !manga.genres.isEmpty {
            genreRow
        }
        if library.contains(manga), !library.note(for: manga).isEmpty {
            noteRow
        }
        if let target = continueTarget {
            continueButton(target)
        }
    }

    private func summaryRow(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
            Button(expanded ? LocalizedStringKey("Ver menos") : "Ver más") {
                withAnimation { expanded.toggle() }
            }
            .font(.footnote.weight(.semibold))
        }
        .listRowSeparator(.hidden)
    }

    private var genreRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(manga.genres, id: \.self) { genre in
                    Text(genre)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
            }
        }
        .listRowSeparator(.hidden)
    }

    private var noteRow: some View {
        Text(library.note(for: manga))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.moka.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .listRowSeparator(.hidden)
    }

    private func continueButton(_ target: ChapterItem) -> some View {
        let title = buttonTitle(for: target)
        return Button {
            open(target)
        } label: {
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Color.moka,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
    }

    private var chapterSection: some View {
        Section {
            if chapters.isEmpty && isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if chapters.isEmpty, let error {
                VStack(spacing: 8) {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Reintentar") { Task { await refresh() } }
                }
                .frame(maxWidth: .infinity)
            }
            ForEach(displayed) { chapter in
                chapterRow(chapter)
            }
        } header: {
            chapterSectionHeader
        }
    }

    @ViewBuilder
    private var chapterSectionHeader: some View {
        HStack {
            if selectingChapters {
                Text("\(selectedChapters.count) seleccionados")
                Spacer()
                Button(selectedChapters.count == effectiveChapters.count ? LocalizedStringKey("Ninguno") : "Todos") {
                    selectedChapters = selectedChapters.count == effectiveChapters.count
                        ? []
                        : Set(effectiveChapters.map(\.url))
                }
                Button("Listo") {
                    selectingChapters = false
                    selectedChapters = []
                }
                .fontWeight(.semibold)
            } else {
                Text(effectiveChapters.count == 1
                    ? LocalizedStringKey("1 capítulo")
                    : "\(effectiveChapters.count) capítulos")
                Spacer()
                Button {
                    newestFirst.toggle()
                } label: {
                    Image(systemName: newestFirst ? "arrow.down" : "arrow.up")
                }
                .accessibilityLabel("Invertir orden")
            }
        }
    }

    private var downloadMenu: some View {
        Menu {
            Button {
                download(Array(unread.prefix(5)))
            } label: {
                Label("Siguientes 5 sin leer", systemImage: "arrow.down.circle")
            }
            Button {
                download(unread)
            } label: {
                Label("Todos los sin leer (\(unread.count))", systemImage: "arrow.down.circle")
            }
            Button {
                download(ascending)
            } label: {
                Label("Todos los capítulos", systemImage: "arrow.down.to.line")
            }
            Divider()
            Button {
                selectingChapters = true
            } label: {
                Label("Seleccionar capítulos", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
                confirmingDeleteDownloads = true
            } label: {
                Label("Borrar descargas de esta serie", systemImage: "trash")
            }
        } label: {
            Image(systemName: "arrow.down.circle")
        }
        .disabled(chapters.isEmpty || installed == nil)
        .accessibilityLabel("Descargas")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(manga: manga)
                .frame(width: 110, height: 165)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08))
                )
            VStack(alignment: .leading, spacing: 6) {
                Text(manga.title)
                    .font(.system(.title3, design: .serif).bold())
                    .lineLimit(4)
                if let author = manga.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let status = manga.statusText {
                    Text(status)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                }
                if let source = extensions.source(id: manga.sourceId) {
                    Text("\(source.name) · \(Language.displayName(source.lang))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let time = library.readingTimeText(for: manga) {
                    Label(time, systemImage: "book")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func chapterRow(_ chapter: ChapterItem) -> some View {
        let read = library.isRead(chapter, in: manga)
        let bookmarked = library.isBookmarked(chapter, in: manga)
        let state = downloads.state(manga: manga, chapter: chapter)
        let isSelected = selectedChapters.contains(chapter.url)
        return Button {
            if selectingChapters {
                if isSelected {
                    selectedChapters.remove(chapter.url)
                } else {
                    selectedChapters.insert(chapter.url)
                }
            } else {
                open(chapter)
            }
        } label: {
            HStack(spacing: 10) {
                if selectingChapters {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.moka : Color.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(chapter.name)
                        .font(.subheadline.weight(read ? .regular : .medium))
                        .foregroundStyle(read ? .secondary : .primary)
                    HStack(spacing: 6) {
                        if let date = chapter.date { Text(date.shortText) }
                        if let scanlator = chapter.scanlator, !scanlator.isEmpty { Text("· \(scanlator)") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if bookmarked {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if state == .none, !selectingChapters, installed != nil, !manga.isLocal {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture { download([chapter]) }
                        .accessibilityLabel("Descargar capítulo")
                } else {
                    downloadIndicator(state)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if selectingChapters {
                    // A second long press anchors the range actions on this chapter.
                    rangeAnchor = chapter
                } else {
                    selectingChapters = true
                    selectedChapters = [chapter.url]
                }
            }
        )
        .swipeActions(edge: .trailing) {
            if !selectingChapters {
                Button(read ? LocalizedStringKey("No leído") : "Leído") {
                    library.setRead(!read, chapter: chapter, in: manga)
                }
                .tint(read ? .gray : .moka)
                if state == .downloaded {
                    Button("Borrar descarga", role: .destructive) {
                        downloads.delete(manga: manga, chapter: chapter)
                    }
                }
            }
        }
        .swipeActions(edge: .leading) {
            if !selectingChapters {
                Button(bookmarked ? LocalizedStringKey("Quitar") : "Favorito") {
                    library.toggleBookmark(chapterURLs: [chapter.url], in: manga)
                }
                .tint(.orange)
            }
        }
    }

    private var chapterSelectionBar: some View {
        HStack(spacing: 4) {
            if !manga.isLocal {
                selectionBarButton("Bajar", symbol: "arrow.down.circle") {
                    download(selectedItems.filter { !downloads.isDownloaded(manga: manga, chapter: $0) })
                }
            }
            selectionBarButton("Favorito", symbol: "star") {
                library.toggleBookmark(chapterURLs: selectedItems.map(\.url), in: manga)
            }
            selectionBarButton("Leído", symbol: "checkmark.circle") {
                library.setRead(true, chapterURLs: selectedItems.map(\.url), in: manga)
            }
            selectionBarButton("No leído", symbol: "circle") {
                library.setRead(false, chapterURLs: selectedItems.map(\.url), in: manga)
            }
            if !manga.isLocal {
                selectionBarButton("Borrar", symbol: "trash", role: .destructive) {
                    for chapter in selectedItems {
                        downloads.delete(manga: manga, chapter: chapter)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
        .disabled(selectedChapters.isEmpty)
    }

    private func selectionBarButton(
        _ title: String,
        symbol: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.body)
                Text(LocalizedStringKey(title))
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func downloadIndicator(_ state: DownloadState) -> some View {
        switch state {
            case .none:
                EmptyView()
            case .queued:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            case .downloading(let value):
                Text("\(Int(value * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.moka)
            case .downloaded:
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
        }
    }

    private func buttonTitle(for target: ChapterItem) -> String {
        if library.lastRead(in: manga) == nil {
            return NSLocalizedString("Empezar a leer", comment: "")
        }
        if unread.isEmpty {
            return String(format: NSLocalizedString("Releer: %@", comment: ""), target.name)
        }
        return String(format: NSLocalizedString("Continuar: %@", comment: ""), target.name)
    }

    private var modeBinding: Binding<ReadingMode> {
        Binding(
            get: { library.readingMode(for: manga, fallback: settings.defaultReadingMode) },
            set: { library.setReadingMode($0, for: manga) }
        )
    }

    private func toggleLibrary() {
        if library.contains(manga) {
            // Removing silently would also discard the note and categories — and for an
            // imported series, its files: that always deserves a confirmation.
            let entry = library.entry(for: manga)
            if manga.isLocal || entry?.note != nil || !(entry?.categories ?? []).isEmpty {
                confirmingRemoval = true
            } else {
                library.remove(manga)
            }
        } else {
            library.add(manga, chapters: chapters)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func download(_ items: [ChapterItem]) {
        guard let installed, !items.isEmpty else { return }
        guard !manga.isLocal else { return }
        downloads.enqueue(items, manga: manga, installed: installed)
    }

    private func open(_ chapter: ChapterItem) {
        guard let installed else {
            actionError = NSLocalizedString(
                "Instala la extensión de esta fuente (pestaña Extensiones) para leer sus capítulos.",
                comment: ""
            )
            return
        }
        let ordered = ascending
        guard let index = ordered.firstIndex(of: chapter) else { return }
        reader = ReaderContext(manga: manga, installed: installed, chapters: ordered, startIndex: index)
    }

    /// `manual` is the user's pull-to-refresh: it also downloads the cover again, for
    /// sources that replace the image behind the same address.
    private func refresh(manual: Bool = false) async {
        if manga.isLocal {
            let loaded = LocalStore.chapters(for: manga)
            chapters = loaded
            error = loaded.isEmpty
                ? NSLocalizedString(
                    "Esta serie ya no tiene archivos. Importa sus CBZ otra vez desde la Biblioteca.",
                    comment: ""
                )
                : nil
            if library.contains(manga) { library.refresh(manga, chapters: loaded) }
            return
        }
        guard let installed else {
            error = NSLocalizedString(
                "Instala la extensión de esta fuente para ver sus capítulos.",
                comment: ""
            )
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await JVMEngine.shared.details(of: manga, installed: installed)
            // The URL is the identity that progress, categories and the library key hang
            // off. A source that rotates its slugs (Asura does) must not detach them —
            // and the old URL keeps working: it is the one this request just used.
            var fresh = result.manga
            fresh.url = manga.url
            // Assign only on change: replacing equal values rebuilds the whole List and
            // reloads the cover, which reads as the screen loading twice.
            if fresh != manga { manga = fresh }
            if result.chapters != chapters { chapters = result.chapters }
            error = nil
            library.refresh(fresh, chapters: result.chapters)
            if manual {
                // Detached from the pull: the spinner waits for the chapters, not the cover.
                Task { await ImagePipeline.shared.refreshCover(for: fresh, installed: installed) }
            }
            if siteURL == nil {
                // From the source's CURRENT slug: a rotated old one would 404 in Safari.
                siteURL = try? await JVMEngine.shared.siteURL(of: result.manga, installed: installed)
            }
        } catch {
            // Offline with a saved copy: keep showing it instead of an error.
            if chapters.isEmpty { self.error = error.localizedDescription }
        }
    }
}
