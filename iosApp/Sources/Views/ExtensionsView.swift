import SwiftUI

struct ExtensionsView: View {
    @EnvironmentObject private var extensions: ExtensionManager
    @EnvironmentObject private var settings: AppSettings
    @State private var query = ""
    @State private var showingAddRepository = false
    @State private var repositoryText = ""

    private var available: [CatalogExtension] {
        extensions.visibleCatalog
            .filter { item in item.languages.contains { settings.shows(language: $0) } }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var installedFiltered: [InstalledExtension] {
        extensions.installed.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            EngineBanner()
                .listRowInsets(EdgeInsets())

            if !extensions.updatableExtensions.isEmpty {
                Section {
                    ForEach(extensions.updatableExtensions) { item in
                        catalogRow(item)
                    }
                    Button {
                        Task { await extensions.updateAll() }
                    } label: {
                        Label(
                            extensions.updateCount == 1
                                ? LocalizedStringKey("Actualizar todo (1)")
                                : "Actualizar todo (\(extensions.updateCount))",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .disabled(!extensions.installing.isEmpty)
                } header: {
                    Text("Actualizaciones")
                } footer: {
                    Text("Los repositorios publican versiones nuevas cuando un sitio cambia y la extensión deja de funcionar.")
                }
            }

            Section("Instaladas") {
                if extensions.installed.isEmpty {
                    Text("Todavía no has instalado ninguna extensión.")
                        .foregroundStyle(.secondary)
                }
                ForEach(installedFiltered) { record in
                    installedRow(record)
                }
            }

            Section {
                ForEach(extensions.repositories) { repository in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repository.name)
                        Text(repository.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .swipeActions {
                        Button("Quitar", role: .destructive) {
                            extensions.removeRepository(repository)
                        }
                    }
                }
                Button {
                    repositoryText = ""
                    showingAddRepository = true
                } label: {
                    Label("Agregar repositorio", systemImage: "plus")
                }
            } header: {
                Text("Repositorios")
            } footer: {
                Text("Wizard Cat Reader no incluye ni recomienda repositorios. Agrega solo los que conozcas y en los que confíes.")
            }

            if !extensions.repositories.isEmpty {
                Section("Disponibles") {
                    if extensions.isRefreshing && extensions.catalog.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if available.isEmpty {
                        Text("No hay extensiones para tus idiomas.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(available) { item in
                        catalogRow(item)
                    }
                }
            }
        }
        .navigationTitle("Extensiones")
        .searchable(text: $query, prompt: "Buscar extensiones")
        .refreshable { await extensions.refreshCatalog() }
        .task {
            await extensions.refreshCatalogIfStale()
        }
        .alert("Agregar repositorio", isPresented: $showingAddRepository) {
            TextField("https://…/index.pb", text: $repositoryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Cancelar", role: .cancel) {}
            Button("Agregar") {
                let text = repositoryText
                Task { await extensions.addRepository(text) }
            }
        } message: {
            Text("Pega la URL del repositorio de extensiones de Mihon (index.pb).")
        }
    }

    private func installedRow(_ record: InstalledExtension) -> some View {
        HStack(spacing: 12) {
            ExtensionIcon(url: record.iconURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                Group {
                    if record.sources.count == 1 {
                        Text("v\(record.versionName) · 1 fuente")
                    } else {
                        Text("v\(record.versionName) · \(record.sources.count) fuentes")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let update = extensions.catalog.first(where: { $0.packageName == record.id }),
               extensions.hasUpdate(update) {
                installButton(update, title: "Actualizar")
            }
        }
        .swipeActions {
            Button("Desinstalar", role: .destructive) {
                extensions.uninstall(record)
            }
        }
    }

    private func catalogRow(_ item: CatalogExtension) -> some View {
        HStack(spacing: 12) {
            ExtensionIcon(url: item.iconURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Group {
                    if item.languages.count > 6 {
                        Text("\(item.languages.prefix(6).map(Language.displayName).joined(separator: ", ")) y \(item.languages.count - 6) más")
                    } else {
                        Text(item.languages.map(Language.displayName).joined(separator: ", "))
                    }
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if extensions.installedVersion(of: item.packageName) != nil && !extensions.hasUpdate(item) {
                Text("Instalada")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                installButton(item, title: extensions.hasUpdate(item) ? "Actualizar" : "Obtener")
            }
        }
    }

    private func installButton(_ item: CatalogExtension, title: String) -> some View {
        Group {
            if extensions.installing.contains(item.packageName) {
                ProgressView()
            } else {
                Button(LocalizedStringKey(title)) {
                    Task { await extensions.install(item) }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
    }
}
