import SwiftUI
import UniformTypeIdentifiers

/// The settings hub: short, with each area on its own page, like the system Settings app.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var extensions: ExtensionManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager

    private let commonLanguages = ["all", "es", "es-419", "en", "pt-BR", "fr", "it", "de", "ja", "ko", "zh"]

    private var languageOptions: [String] {
        var seen = Set<String>()
        let fromSources = extensions.allSources.map(\.lang) + extensions.catalog.flatMap(\.languages)
        return (commonLanguages + fromSources.sorted()).filter { seen.insert($0).inserted }
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ReaderSettingsView()
                } label: {
                    hubRow("Lectura", symbol: "book")
                }
                NavigationLink {
                    LibrarySettingsView()
                } label: {
                    hubRow("Biblioteca", symbol: "books.vertical")
                }
                NavigationLink {
                    DownloadSettingsView()
                } label: {
                    HStack {
                        hubRow("Descargas", symbol: "arrow.down.circle")
                        Spacer()
                        if !downloads.queue.isEmpty {
                            Text("\(downloads.queue.count) en cola")
                                .font(.footnote)
                                .foregroundStyle(Color.moka)
                        }
                    }
                }
                NavigationLink {
                    LanguagePicker(options: languageOptions)
                } label: {
                    HStack {
                        hubRow("Idiomas de fuentes", symbol: "globe")
                        Spacer()
                        Text(settings.languages.isEmpty
                            ? LocalizedStringKey("Todos")
                            : "\(settings.languages.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Picker("Tema", selection: $settings.appTheme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                Picker("Idioma de la app", selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                if UIApplication.shared.supportsAlternateIcons {
                    NavigationLink {
                        AppIconPicker()
                    } label: {
                        HStack {
                            Text("Ícono de la app")
                            Spacer()
                            Text(AppIconChoice.current.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Apariencia")
            } footer: {
                if settings.appLanguage != .system {
                    Text("El idioma se aplica al volver a abrir la app.")
                }
            }

            Section {
                NavigationLink {
                    InsightsView()
                } label: {
                    hubRow("Estadísticas de lectura", symbol: "chart.bar")
                }
                NavigationLink {
                    DataSettingsView()
                } label: {
                    hubRow("Copias de seguridad", symbol: "arrow.triangle.2.circlepath")
                }
                NavigationLink {
                    AdvancedSettingsView()
                } label: {
                    hubRow("Avanzado", symbol: "wrench.and.screwdriver")
                }
            }

            Section {
                HStack {
                    Text("Versión")
                    Spacer()
                    Text(appVersion).foregroundStyle(.secondary)
                }
                if !library.contains(LocalStore.sampleManga) {
                    Button("Restaurar el cómic de guía") {
                        LocalStore.shared.restoreSample(library: library)
                    }
                }
                if let support = URL(string: "https://shsnow.github.io/Wizard-Cat-Reader/") {
                    Link("Sitio de soporte", destination: support)
                }
                if let privacy = URL(string: "https://shsnow.github.io/Wizard-Cat-Reader/privacy.html") {
                    Link("Política de privacidad", destination: privacy)
                }
                NavigationLink("Licencias y créditos") { LicensesView() }
            } header: {
                Text("Acerca de")
            } footer: {
                Label(
                    "Wizard Cat Reader es para toda la familia: las extensiones y series para adultos se bloquean siempre.",
                    systemImage: "checkmark.shield"
                )
            }
        }
        .navigationTitle("Ajustes")
    }

    private func hubRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(Color.moka)
                .frame(width: 26)
            Text(LocalizedStringKey(title))
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

// MARK: - Lectura

struct ReaderSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Modo por defecto", selection: $settings.defaultReadingMode) {
                    ForEach(ReadingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("Fondo del lector", selection: $settings.readerBackground) {
                    ForEach(ReaderBackground.allCases) { Text($0.title).tag($0) }
                }
                Picker("Escala de página", selection: $settings.pagedScaleMode) {
                    ForEach(PageScaleMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Margen lateral en webtoon", selection: $settings.webtoonPadding) {
                    Text("Sin margen").tag(0.0)
                    Text("Pequeño").tag(0.04)
                    Text("Mediano").tag(0.08)
                }
            } header: {
                Text("Página")
            } footer: {
                Text("Manhwa, manhua y webtoons se abren en modo vertical. Puedes cambiar el modo de cada serie desde su ficha o dentro del lector. La escala se aplica al modo paginado.")
            }

            Section {
                Toggle("Saltar capítulos leídos", isOn: $settings.skipReadChapters)
            } header: {
                Text("Capítulos")
            } footer: {
                Text("Al pasar de capítulo, el lector salta los que ya marcaste como leídos.")
            }

            Section {
                Toggle("Zonas de toque para pasar página", isOn: $settings.tapZonesEnabled)
                if settings.tapZonesEnabled {
                    Toggle("Invertir zonas de toque", isOn: $settings.invertTapZones)
                }
                Toggle("Mostrar número de página", isOn: $settings.alwaysShowPageNumber)
                Toggle("Mantener la pantalla encendida", isOn: $settings.keepScreenAwake)
            } header: {
                Text("Controles")
            } footer: {
                Text(
                    settings.tapZonesEnabled
                        ? LocalizedStringKey("Con las zonas invertidas, el borde que avanza queda al otro lado: útil para leer con la otra mano.")
                        : "El número de página se muestra chico en una esquina mientras los controles están ocultos."
                )
            }
        }
        .navigationTitle("Lectura")
    }
}

// MARK: - Biblioteca

struct LibrarySettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Form {
            Section("Cuadrícula") {
                Picker("Series por fila", selection: $settings.gridColumns) {
                    Text("2").tag(2)
                    Text("3").tag(3)
                    Text("4").tag(4)
                }
                .pickerStyle(.segmented)
                Toggle("Insignias de capítulos sin leer", isOn: $settings.showUnreadBadges)
                Toggle("Fila \"Seguir leyendo\"", isOn: $settings.showContinueRow)
            }

            Section {
                NavigationLink {
                    CategoriesView()
                } label: {
                    HStack {
                        Text("Categorías")
                        Spacer()
                        Text(library.categories.isEmpty
                            ? LocalizedStringKey("Ninguna")
                            : "\(library.categories.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle("Actualizar al abrir la app", isOn: $settings.updateOnLaunch)
            } header: {
                Text("Actualización")
            } footer: {
                Text("Busca capítulos nuevos de tus series al abrir Wizard Cat Reader, como mucho cada 6 horas. También puedes actualizar cuando quieras desde Actividad.")
            }
        }
        .navigationTitle("Biblioteca")
    }
}

// MARK: - Descargas

struct DownloadSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloads: DownloadManager

    @State private var cacheBytes: Int64 = 0

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    DownloadsView()
                } label: {
                    HStack {
                        Text("Capítulos descargados")
                        Spacer()
                        if !downloads.queue.isEmpty {
                            Text("\(downloads.queue.count) en cola")
                                .foregroundStyle(Color.moka)
                        } else {
                            Text(downloads.totalBytes.byteText)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Páginas simultáneas", selection: $settings.downloadBatch) {
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }
            }

            Section {
                Toggle("Descargar capítulos nuevos", isOn: $settings.autoDownloadUpdates)
                Toggle("Borrar al terminar de leer", isOn: $settings.deleteAfterReading)
            } footer: {
                Text("Con la descarga automática, al actualizar la biblioteca los capítulos nuevos de tus series se guardan solos para leer sin conexión.")
            }

            Section {
                Button {
                    Task {
                        await ImagePipeline.shared.clearCaches()
                        cacheBytes = await ImagePipeline.shared.diskCacheBytes()
                    }
                } label: {
                    HStack {
                        Text("Limpiar caché de imágenes")
                        Spacer()
                        Text(cacheBytes.byteText).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("La caché guarda portadas y páginas vistas recién para no volver a bajarlas.")
            }
        }
        .navigationTitle("Descargas")
        .task { cacheBytes = await ImagePipeline.shared.diskCacheBytes() }
    }
}

// MARK: - Copias de seguridad

struct DataSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var extensions: ExtensionManager
    @ObservedObject private var sync = SyncManager.shared

    @State private var showingImporter = false
    @State private var importing = false
    @State private var importSummary: MihonImportSummary?
    @State private var importError: String?
    @State private var exportDocument: TachibkDocument?
    @State private var exportError: String?
    @State private var pickingSyncFolder = false

    var body: some View {
        Form {
            Section {
                if !sync.isConfigured {
                    Button("Elegir carpeta de sincronización") {
                        pickingSyncFolder = true
                    }
                    // On its own button: a second fileImporter on the Form's chain
                    // would fight the backup one.
                    .fileImporter(
                        isPresented: $pickingSyncFolder,
                        allowedContentTypes: [.folder],
                        allowsMultipleSelection: false
                    ) { result in
                        guard case .success(let urls) = result, let url = urls.first else { return }
                        sync.setFolder(url)
                        Task { await sync.sync(library: library, extensions: extensions) }
                    }
                    if let message = sync.lastError {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } else {
                    HStack {
                        Text("Carpeta")
                        Spacer()
                        Text(sync.folderName ?? "")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await sync.sync(library: library, extensions: extensions) }
                    } label: {
                        HStack {
                            Text("Sincronizar ahora")
                            Spacer()
                            if sync.isSyncing { ProgressView() }
                        }
                    }
                    .disabled(sync.isSyncing)
                    if let date = sync.lastSync {
                        HStack {
                            Text("Última sincronización")
                            Spacer()
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let message = sync.lastError {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Button("Dejar de sincronizar", role: .destructive) {
                        sync.clearFolder()
                    }
                }
            } header: {
                Text("Sincronización entre dispositivos")
            } footer: {
                // One single literal: "A" + "B" would become a String and skip the table.
                Text("""
                Elige una carpeta en la nube (iCloud Drive, Google Drive, Dropbox…). \
                Wizard Cat Reader deja ahí su copia y combina las copias .tachibk que \
                encuentre, al abrir la app y al salir. Para sincronizar con Mihon en \
                Android, guarda sus copias automáticas en esta misma carpeta.
                """)
            }

            Section {
                Button {
                    showingImporter = true
                } label: {
                    HStack {
                        Text("Restaurar copia de Mihon")
                        Spacer()
                        if importing { ProgressView() }
                    }
                }
                .disabled(importing)
                Button("Exportar copia (.tachibk)") {
                    do {
                        exportDocument = TachibkDocument(
                            data: try MihonBackupExport.make(library: library, extensions: extensions)
                        )
                    } catch {
                        exportError = error.localizedDescription
                    }
                }
                .disabled(library.entries.isEmpty)
            } footer: {
                Text("La copia usa el formato .tachibk: puedes restaurarla aquí o en Mihon. Lo que ya tienes en Wizard Cat Reader se conserva y se combina.")
            }
        }
        .navigationTitle("Copias de seguridad")
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }
            ),
            document: exportDocument,
            contentType: .data,
            defaultFilename: MihonBackupExport.suggestedFileName()
        ) { result in
            if case .failure(let error) = result {
                exportError = error.localizedDescription
            }
        }
        .alert(
            "No se pudo exportar",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(exportError ?? "") }
        )
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            restore(from: url)
        }
        .alert(
            importError == nil ? Text("Copia restaurada") : Text("No se pudo restaurar"),
            isPresented: Binding(
                get: { importSummary != nil || importError != nil },
                set: { if !$0 { importSummary = nil; importError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(importError ?? importSummary?.text ?? "") }
        )
    }

    private func restore(from url: URL) {
        importing = true
        Task {
            defer { importing = false }
            do {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                // The protobuf decode can chew through megabytes; keep it off the main actor.
                let backup = try await Task.detached(priority: .userInitiated) {
                    try MihonBackup.decode(data)
                }.value
                importSummary = try MihonBackupImporter.restore(
                    backup, into: library, extensions: extensions
                )
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

// MARK: - Avanzado

struct AdvancedSettingsView: View {
    @EnvironmentObject private var extensions: ExtensionManager
    @EnvironmentObject private var engine: EngineStatus

    @State private var clearingCookies = false
    @State private var cookiesResult: String?

    var body: some View {
        Form {
            Section {
                Button {
                    clearCookies()
                } label: {
                    HStack {
                        Text("Limpiar cookies de las fuentes")
                        Spacer()
                        if clearingCookies {
                            ProgressView()
                        } else if let cookiesResult {
                            Text(cookiesResult)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(clearingCookies || extensions.installed.isEmpty)
            } footer: {
                Text("Borra inicios de sesión y permisos guardados de los sitios. Útil cuando una fuente se queda pegada.")
            }

            Section("Motor de extensiones") {
                HStack {
                    Text("Estado")
                    Spacer()
                    Text(engineText)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if !engine.state.isReady {
                    Button("Iniciar motor") {
                        Task { _ = try? await JVMEngine.shared.start() }
                    }
                    .disabled(engine.state == .starting)
                }
            }
        }
        .navigationTitle("Avanzado")
    }

    private func clearCookies() {
        clearingCookies = true
        cookiesResult = nil
        Task {
            defer { clearingCookies = false }
            var cleared = 0
            for installed in extensions.installed {
                guard let source = installed.sources.first else { continue }
                if (try? await JVMEngine.shared.clearCookies(source: source, installed: installed)) != nil {
                    cleared += 1
                }
            }
            cookiesResult = cleared == 0
                ? NSLocalizedString("Sin cambios", comment: "")
                : String(format: NSLocalizedString("Listo (%lld)", comment: ""), cleared)
        }
    }

    private var engineText: String {
        switch engine.state {
            case .idle:
                return NSLocalizedString("Detenido (inicia al usar una fuente)", comment: "")
            case .starting:
                return NSLocalizedString("Iniciando…", comment: "")
            case .ready(let description):
                return description
            case .failed(let message):
                return String(format: NSLocalizedString("Error: %@", comment: ""), message)
        }
    }
}

// MARK: - Shared pieces

/// The app icons the user can pick; raw values match the alternate-icon asset names.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case classic = ""
    case night = "AppIconNight"
    case terra = "AppIconTerra"

    var id: String { rawValue }

    var title: String {
        switch self {
            case .classic: return NSLocalizedString("Clásico", comment: "")
            case .night: return NSLocalizedString("Noche", comment: "")
            case .terra: return NSLocalizedString("Terracota", comment: "")
        }
    }

    /// Swatch colors matching each icon's paper and ink.
    var paper: Color {
        switch self {
            case .classic: return Color(red: 0.957, green: 0.910, blue: 0.839)
            case .night: return Color(red: 0.102, green: 0.071, blue: 0.055)
            case .terra: return Color(red: 0.761, green: 0.325, blue: 0.169)
        }
    }

    var ink: Color {
        switch self {
            case .classic: return Color(red: 0.157, green: 0.110, blue: 0.086)
            case .night: return Color(red: 0.957, green: 0.910, blue: 0.839)
            case .terra: return Color(red: 0.157, green: 0.094, blue: 0.063)
        }
    }

    @MainActor static var current: AppIconChoice {
        AppIconChoice(rawValue: UIApplication.shared.alternateIconName ?? "") ?? .classic
    }
}

/// Lets the user switch between the bundled app icons.
struct AppIconPicker: View {
    @State private var selected: AppIconChoice = .classic

    var body: some View {
        List(AppIconChoice.allCases) { choice in
            Button {
                apply(choice)
            } label: {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(choice.paper)
                        .frame(width: 52, height: 52)
                        .overlay {
                            Image(systemName: "book.closed.fill")
                                .font(.title3)
                                .foregroundStyle(choice.ink)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12))
                        )
                    Text(choice.title)
                        .foregroundStyle(.primary)
                    Spacer()
                    if choice == selected {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.moka)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Ícono de la app")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { selected = .current }
    }

    private func apply(_ choice: AppIconChoice) {
        guard choice != selected else { return }
        let previous = selected
        selected = choice
        UIApplication.shared.setAlternateIconName(choice == .classic ? nil : choice.rawValue) { error in
            if error != nil {
                Task { @MainActor in selected = previous }
            }
        }
    }
}

struct LanguagePicker: View {
    let options: [String]
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List {
            Section {
                Button(settings.languages.isEmpty ? LocalizedStringKey("Mostrando todos") : "Mostrar todos") {
                    settings.languages = []
                }
            }
            Section {
                ForEach(options, id: \.self) { code in
                    Button {
                        if settings.languages.contains(code) {
                            settings.languages.remove(code)
                        } else {
                            settings.languages.insert(code)
                        }
                    } label: {
                        HStack {
                            Text(Language.displayName(code))
                                .foregroundStyle(.primary)
                            Spacer()
                            if settings.languages.contains(code) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Idiomas")
    }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            Text(Self.text)
                .font(.footnote)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Licencias")
    }

    static let text = """
    Wizard Cat Reader (antes MokaReader) es software libre (Apache License 2.0).

    Wizard Cat Reader no aloja, incluye ni recomienda contenido ni repositorios. Las extensiones las \
    agrega el usuario desde repositorios que él mismo elige.

    Componentes de terceros:

    • OpenJDK Mobile — GPL v2 con Classpath Exception. La máquina virtual Java que ejecuta las extensiones.
    • Suwayomi-Server (AndroidCompat) — Mozilla Public License 2.0. La capa de compatibilidad con Android.
    • Host de extensiones y núcleo compartido de TachiyomiAZ — Apache License 2.0, © az4521 y colaboradores.
    • WizardJVMRunner — puente Swift/JNI propio de Wizard Cat Reader, Apache License 2.0 \
    (incluye las cabeceras JNI de OpenJDK, GPL v2 con Classpath Exception).
    • Formato de extensiones y backups de Mihon / Tachiyomi — Apache License 2.0.
    • ZIPFoundation — MIT License, © Thomas Zoechling. Lee los cómics CBZ importados.

    Gracias a los equipos de Mihon, Tachiyomi, Suwayomi, Aidoku, TachiyomiAZ y OpenJDK.
    """
}

/// The generated backup, handed to the system "save to Files" sheet.
struct TachibkDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
