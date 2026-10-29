import SwiftUI

/// Finds the same series on another source and moves the library entry there. Read chapters,
/// favorites and the last-read position carry over matched by chapter number; the note and
/// categories move as they are. Useful when a source dies or loses the series.
struct MigrateSourceView: View {
    let manga: MangaItem
    /// Called with the new series and its chapters once the move is done.
    let onMigrated: (MangaItem, [ChapterItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var extensions: ExtensionManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore

    @State private var query: String
    @State private var searchId = UUID()
    @State private var results: [Int64: SearchState] = [:]
    @State private var candidate: MangaItem?
    @State private var isMigrating = false
    @State private var migrationError: String?

    private enum SearchState {
        case loading
        case done([MangaItem])
        case failed(String)
    }

    init(manga: MangaItem, onMigrated: @escaping (MangaItem, [ChapterItem]) -> Void) {
        self.manga = manga
        self.onMigrated = onMigrated
        _query = State(initialValue: manga.title)
    }

    /// Every visible source except the one the series already lives on.
    private var sources: [SourceInfo] {
        extensions.installed
            .flatMap(\.sources)
            .filter { settings.shows(language: $0.lang) }
            .filter { $0.id != manga.sourceId }
    }

    private var searched: [SourceInfo] { Array(sources.prefix(12)) }

    var body: some View {
        NavigationStack {
            Group {
                if searched.isEmpty {
                    EmptyStateView(
                        symbol: "arrow.left.arrow.right",
                        title: "No hay otra fuente",
                        message: "Instala otra extensión en la pestaña Extensiones para poder migrar."
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Migrar de fuente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                        .disabled(isMigrating)
                }
            }
            .overlay {
                if isMigrating {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        ProgressView("Migrando…")
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
            .confirmationDialog(
                "¿Migrar la serie?",
                isPresented: Binding(
                    get: { candidate != nil },
                    set: { if !$0 { candidate = nil } }
                ),
                titleVisibility: .visible,
                presenting: candidate
            ) { item in
                Button("Migrar a “\(item.title)”") {
                    Task { await migrate(to: item) }
                }
                Button("Cancelar", role: .cancel) {}
            } message: { item in
                // One single literal: "A" + "B" would become a String and skip the table.
                Text("""
                Lo leído, los favoritos y las categorías se traspasan empatando los capítulos \
                por número. Pasará a \(sourceName(for: item)). Las descargas de la fuente \
                anterior quedan en Ajustes → Descargas.
                """)
            }
            .alert(
                "No se pudo migrar",
                isPresented: Binding(
                    get: { migrationError != nil },
                    set: { if !$0 { migrationError = nil } }
                ),
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(migrationError ?? "") }
            )
        }
        .interactiveDismissDisabled(isMigrating)
    }

    private var list: some View {
        List {
            Section {
                Text("Elige la misma serie en otra fuente. Toca una portada para migrar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(searched) { source in
                Section {
                    row(for: source)
                } header: {
                    HStack(spacing: 8) {
                        ExtensionIcon(url: extensions.extensionFor(sourceId: source.id)?.iconURL)
                            .frame(width: 20, height: 20)
                        Text(source.name)
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Buscar en otras fuentes")
        .onSubmit(of: .search) { searchId = UUID() }
        .task(id: searchId) { await search() }
    }

    @ViewBuilder
    private func row(for source: SourceInfo) -> some View {
        switch results[source.id] {
            case nil:
                Text("En cola…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Buscando…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            case .done(let items):
                if items.isEmpty {
                    Text("Sin resultados")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(items) { item in
                                Button {
                                    candidate = item
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        CoverImage(manga: item)
                                            .frame(width: 92, height: 138)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        Text(item.title)
                                            .font(.caption2)
                                            .lineLimit(2)
                                            .foregroundStyle(.primary)
                                            .frame(width: 92, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 0))
                }
        }
    }

    private func search() async {
        results = [:]
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        for source in searched {
            if Task.isCancelled { return }
            guard let installed = extensions.extensionFor(sourceId: source.id) else { continue }
            results[source.id] = .loading
            do {
                let page = try await JVMEngine.shared.mangaPage(
                    .search(text), source: source, installed: installed, page: 1
                )
                if Task.isCancelled { return }
                results[source.id] = .done(Array(page.items.prefix(9)))
            } catch {
                if Task.isCancelled { return }
                results[source.id] = .failed(error.localizedDescription)
            }
        }
    }

    private func migrate(to target: MangaItem) async {
        guard let installed = extensions.extensionFor(sourceId: target.sourceId) else { return }
        isMigrating = true
        defer { isMigrating = false }
        do {
            let details = try await JVMEngine.shared.details(of: target, installed: installed)
            library.migrate(from: manga, to: details.manga, chapters: details.chapters)
            onMigrated(details.manga, details.chapters)
            dismiss()
        } catch {
            migrationError = error.localizedDescription
        }
    }

    private func sourceName(for item: MangaItem) -> String {
        extensions.source(id: item.sourceId)?.name ?? "la otra fuente"
    }
}
