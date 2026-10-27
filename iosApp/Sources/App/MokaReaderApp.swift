import SwiftUI

@main
struct MokaReaderApp: App {
    @StateObject private var extensions = ExtensionManager.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var engine = EngineStatus.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var updater = LibraryUpdater.shared

    init() {
        // MokaReader is a reading app; its titles are set in a book face.
        let large = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .largeTitle)
        if let serif = large.withDesign(.serif) {
            let bold = serif.withSymbolicTraits(.traitBold) ?? serif
            UINavigationBar.appearance().largeTitleTextAttributes = [
                .font: UIFont(descriptor: bold, size: 0)
            ]
        }
        let inline = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .headline)
        if let serifInline = inline.withDesign(.serif) {
            UINavigationBar.appearance().titleTextAttributes = [
                .font: UIFont(descriptor: serifInline, size: 0)
            ]
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(extensions)
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(engine)
                .environmentObject(downloads)
                .environmentObject(updater)
                .tint(.moka)
                .preferredColorScheme(settings.appTheme.colorScheme)
        }
    }
}

/// Signals from the tab bar: tapping a tab that is already selected triggers its shortcut.
@MainActor
final class TabShortcuts: ObservableObject {
    static let shared = TabShortcuts()
    /// Bumped when Actividad is tapped while already open; Actividad then shows the downloads.
    @Published var activityReselected = 0
    private init() {}
}

struct RootView: View {
    @EnvironmentObject private var extensions: ExtensionManager
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    /// The app opens where it was left.
    @AppStorage("lastTab") private var selectedTab = 0

    /// Re-selecting the current tab reaches the setter with the same value.
    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { value in
                if value == 2 && selectedTab == 2 {
                    TabShortcuts.shared.activityReselected += 1
                }
                selectedTab = value
            }
        )
    }

    /// Opt-in library refresh on launch, throttled so quick app switches do not re-run it.
    private func updateOnLaunchIfDue() {
        guard AppSettings.shared.updateOnLaunch else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: "lastLaunchUpdate") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 6 * 3600 else { return }
        defaults.set(Date(), forKey: "lastLaunchUpdate")
        LibraryUpdater.shared.refreshAll(
            library: LibraryStore.shared, extensions: ExtensionManager.shared
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            NavigationStack { LibraryView() }
                .tabItem { Label("Biblioteca", systemImage: "books.vertical") }
                .tag(0)
            NavigationStack { ActivityView() }
                .tabItem { Label("Actividad", systemImage: "bolt") }
                .tag(2)
            NavigationStack { BrowseView() }
                .tabItem { Label("Explorar", systemImage: "safari") }
                .tag(1)
            NavigationStack { ExtensionsView() }
                .tabItem { Label("Extensiones", systemImage: "puzzlepiece.extension") }
                .badge(extensions.updateCount)
                .tag(3)
            NavigationStack { SettingsView() }
                .tabItem { Label("Ajustes", systemImage: "gearshape") }
                .tag(4)
        }
        .onAppear {
            // The bundled guide comic, so a fresh install has something to read.
            LocalStore.shared.seedSampleIfNeeded(library: library)
            updateOnLaunchIfDue()
            // A fresh catalog keeps the Extensiones update badge honest.
            Task { await extensions.refreshCatalogIfStale() }
            // Cold start is not guaranteed to pass through the .active transition.
            Task { await SyncManager.shared.sync(library: library, extensions: extensions) }
        }
        .onChange(of: scenePhase) { phase in
            // Folder sync: merge what other devices left when coming forward; on the
            // way out only export — iOS grants the background a short window.
            switch phase {
                case .active:
                    Task { await SyncManager.shared.sync(library: library, extensions: extensions) }
                case .inactive:
                    // Pending JSON writes go out before iOS can suspend or kill the app.
                    Storage.flush()
                case .background:
                    Storage.flush()
                    Task {
                        await SyncManager.shared.sync(
                            library: library, extensions: extensions, exportOnly: true
                        )
                    }
                default:
                    break
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
        ) { _ in
            Storage.flush()
        }
        .alert(
            "Algo salió mal",
            isPresented: Binding(
                get: { extensions.lastError != nil },
                set: { if !$0 { extensions.lastError = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(extensions.lastError ?? "") }
        )
    }
}
