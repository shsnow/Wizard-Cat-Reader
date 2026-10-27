import SwiftUI

struct BrowseView: View {
    @EnvironmentObject private var extensions: ExtensionManager
    @EnvironmentObject private var settings: AppSettings
    @State private var globalQuery = ""
    @State private var submittedGlobal = ""

    private var visibleSources: [SourceInfo] {
        extensions.installed
            .filter { !$0.nsfw }
            .flatMap(\.sources)
            .filter { settings.shows(language: $0.lang) }
    }

    private struct SourceGroup: Identifiable {
        let lang: String
        let sources: [SourceInfo]
        var id: String { lang }
    }

    private var groups: [SourceGroup] {
        Dictionary(grouping: visibleSources) { $0.lang }
            .map { SourceGroup(lang: $0.key, sources: $0.value.sorted { $0.name < $1.name }) }
            .sorted { Language.displayName($0.lang) < Language.displayName($1.lang) }
    }

    var body: some View {
        Group {
            if extensions.installed.isEmpty {
                EmptyStateView(
                    symbol: "puzzlepiece.extension",
                    title: "No hay fuentes",
                    message: "Agrega un repositorio en la pestaña Extensiones e instala alguna."
                )
            } else if visibleSources.isEmpty {
                EmptyStateView(
                    symbol: "globe",
                    title: "Ninguna fuente en tus idiomas",
                    message: "Cambia los idiomas visibles en Ajustes."
                )
            } else if !submittedGlobal.isEmpty {
                GlobalSearchResults(query: submittedGlobal, sources: visibleSources)
            } else {
                List {
                    ForEach(groups) { group in
                        Section(Language.displayName(group.lang)) {
                            ForEach(group.sources) { source in
                                NavigationLink(value: SourceRef(source: source)) {
                                    HStack(spacing: 12) {
                                        ExtensionIcon(url: extensions.extensionFor(sourceId: source.id)?.iconURL)
                                        Text(source.name)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Explorar")
        .searchable(text: $globalQuery, prompt: "Buscar en todas tus fuentes")
        .onSubmit(of: .search) {
            submittedGlobal = globalQuery.trimmingCharacters(in: .whitespaces)
        }
        .onChange(of: globalQuery) { value in
            if value.isEmpty { submittedGlobal = "" }
        }
        .navigationDestination(for: SourceRef.self) { ref in
            SourceBrowseView(source: ref.source)
        }
        .navigationDestination(for: MangaItem.self) { manga in
            MangaDetailView(manga: manga)
        }
    }
}

struct SourceBrowseView: View {
    let source: SourceInfo

    @EnvironmentObject private var extensions: ExtensionManager
    @State private var mode: Mode = .popular
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var items: [MangaItem] = []
    @State private var page = 0
    @State private var hasNextPage = true
    @State private var isLoading = false
    @State private var error: String?

    @State private var filters: [SourceFilter] = []
    @State private var selections = SourceFilterSelections()
    @State private var appliedFilterStates: String?
    @State private var showingFilters = false
    @State private var showingWebView = false
    /// The Cloudflare sheet opens itself only once per visit to the source.
    @State private var autoOpenedWebView = false

    enum Mode: String, CaseIterable, Identifiable {
        case popular = "Popular"
        case latest = "Recientes"
        var id: String { rawValue }
    }

    private var listing: JVMEngine.Listing {
        if !submittedQuery.isEmpty { return .search(submittedQuery) }
        return mode == .popular ? .popular : .latest
    }

    var body: some View {
        VStack(spacing: 0) {
            EngineBanner()
            if source.supportsLatest && submittedQuery.isEmpty && appliedFilterStates == nil {
                Picker("Lista", selection: $mode) {
                    // LocalizedStringKey: a plain String would skip the translation table.
                    ForEach(Mode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            if appliedFilterStates != nil {
                HStack {
                    Label("Filtros aplicados", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.moka)
                    Spacer()
                    Button("Quitar") {
                        appliedFilterStates = nil
                        selections = SourceFilterSelections()
                        Task { await reload() }
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            if let error, items.isEmpty {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "No se pudo cargar", message: error)
                HStack(spacing: 16) {
                    Button("Reintentar") { Task { await reload() } }
                    if extensions.extensionFor(sourceId: source.id) != nil {
                        Button("Abrir WebView") { showingWebView = true }
                    }
                }
                .padding(.bottom, 40)
            } else if items.isEmpty && isLoading {
                ProgressView("Cargando…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty && page > 0 {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "Sin resultados",
                    message: "Prueba con otra búsqueda u otros filtros."
                )
            } else {
                MangaGrid(
                    items: items,
                    onItemAppear: { manga in
                        if manga.id == items.last?.id { Task { await loadNextPage() } }
                    }
                ) {
                    if isLoading {
                        ProgressView()
                    } else if let error {
                        Text(error).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                    }
                }
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingWebView = true
                } label: {
                    Image(systemName: "globe")
                }
                .disabled(extensions.extensionFor(sourceId: source.id) == nil)
                .accessibilityLabel("Abrir el sitio en WebView")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingFilters = true
                } label: {
                    Image(systemName: appliedFilterStates == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill")
                }
                .disabled(extensions.extensionFor(sourceId: source.id) == nil)
                .accessibilityLabel("Filtros de búsqueda")
            }
        }
        .sheet(isPresented: $showingWebView) {
            if let installed = extensions.extensionFor(sourceId: source.id) {
                WebLoginSheet(
                    sourceId: source.id,
                    displayName: source.name,
                    installed: installed
                ) {
                    if items.isEmpty || error != nil {
                        Task { await reload() }
                    }
                }
            }
        }
        .sheet(isPresented: $showingFilters) {
            if let installed = extensions.extensionFor(sourceId: source.id) {
                SourceFiltersSheet(
                    source: source,
                    installed: installed,
                    filters: $filters,
                    selections: $selections
                ) {
                    appliedFilterStates = selections.encoded(for: filters)
                    Task { await reload() }
                }
            }
        }
        .searchable(text: $query, prompt: "Buscar en \(source.name)")
        .onSubmit(of: .search) {
            submittedQuery = query.trimmingCharacters(in: .whitespaces)
            Task { await reload() }
        }
        .onChange(of: query) { value in
            if value.isEmpty && !submittedQuery.isEmpty {
                submittedQuery = ""
                Task { await reload() }
            }
        }
        .onChange(of: mode) { _ in Task { await reload() } }
        .task { if items.isEmpty { await reload() } }
        .refreshable { await reload() }
    }

    private func reload() async {
        items = []
        page = 0
        hasNextPage = true
        error = nil
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard !isLoading, hasNextPage else { return }
        guard let installed = extensions.extensionFor(sourceId: source.id) else {
            error = NSLocalizedString("La extensión de esta fuente ya no está instalada.", comment: "")
            return
        }
        isLoading = true
        defer { isLoading = false }
        let requested = listing
        let requestedFilters = appliedFilterStates
        do {
            // A page can come back empty after hiding adult series; fetch a few more pages so
            // the infinite scroll does not stall with nothing on screen to trigger it.
            var attempts = 0
            repeat {
                let result: (items: [MangaItem], hasNextPage: Bool)
                if let requestedFilters {
                    result = try await JVMEngine.shared.filteredSearch(
                        query: submittedQuery,
                        filterStates: requestedFilters,
                        source: source,
                        installed: installed,
                        page: page + 1
                    )
                } else {
                    result = try await JVMEngine.shared.mangaPage(
                        requested, source: source, installed: installed, page: page + 1
                    )
                }
                guard requested == listing, requestedFilters == appliedFilterStates else {
                    // The search or filters changed while this page was loading: throw it away
                    // and load the current listing, or the grid would sit empty.
                    isLoading = false
                    await loadNextPage()
                    return
                }
                let known = Set(items.map(\.id))
                let fresh = ContentFilter.allowed(result.items).filter { !known.contains($0.id) }
                items.append(contentsOf: fresh)
                page += 1
                hasNextPage = result.hasNextPage && !result.items.isEmpty
                attempts += 1
                if !fresh.isEmpty { break }
            } while hasNextPage && attempts < 4
            error = nil
        } catch {
            self.error = error.localizedDescription
            hasNextPage = false
            presentWebViewForCloudflare()
        }
    }

    /// Tachimanga-style: the first Cloudflare challenge pops the WebView up on its
    /// own, once per visit; after that the error screen's button takes over.
    private func presentWebViewForCloudflare() {
        guard !autoOpenedWebView, items.isEmpty,
              error?.localizedCaseInsensitiveContains("cloudflare") == true,
              extensions.extensionFor(sourceId: source.id) != nil else { return }
        autoOpenedWebView = true
        showingWebView = true
    }
}

/// One search, every installed source: results arrive source by source, since the extension
/// engine answers one request at a time.
private struct GlobalSearchResults: View {
    let query: String
    let sources: [SourceInfo]

    @EnvironmentObject private var extensions: ExtensionManager

    private enum SourceResult {
        case loading
        case done([MangaItem])
        case failed(String)
    }

    @State private var results: [Int64: SourceResult] = [:]

    /// A dozen sources at ~1–3 s each is already a long wait; beyond that it stops being a search.
    private var searched: [SourceInfo] { Array(sources.prefix(12)) }

    var body: some View {
        List {
            if sources.count > searched.count {
                Text("Buscando en las primeras \(searched.count) fuentes. Filtra idiomas en Ajustes para acotar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(searched) { source in
                Section {
                    row(for: source)
                } header: {
                    HStack(spacing: 8) {
                        ExtensionIcon(url: extensions.extensionFor(sourceId: source.id)?.iconURL)
                            .frame(width: 20, height: 20)
                        Text(source.name)
                        Spacer()
                        NavigationLink(value: SourceRef(source: source)) {
                            Text("Ver más")
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .task(id: query) {
            results = [:]
            for source in searched {
                if Task.isCancelled { return }
                guard let installed = extensions.extensionFor(sourceId: source.id) else { continue }
                results[source.id] = .loading
                do {
                    let page = try await JVMEngine.shared.mangaPage(
                        .search(query), source: source, installed: installed, page: 1
                    )
                    if Task.isCancelled { return }
                    results[source.id] = .done(Array(ContentFilter.allowed(page.items).prefix(9)))
                } catch {
                    if Task.isCancelled { return }
                    results[source.id] = .failed(error.localizedDescription)
                }
            }
        }
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
                            ForEach(items) { manga in
                                NavigationLink(value: manga) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        CoverImage(manga: manga)
                                            .frame(width: 92, height: 138)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        Text(manga.title)
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
}
