import SwiftUI

/// Novedades (new chapters across the library) and Historial (what was read, newest first).
struct ActivityView: View {
    enum Section: String, CaseIterable, Identifiable {
        case updates = "Novedades"
        case history = "Historial"
        var id: String { rawValue }
    }

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var extensions: ExtensionManager
    @EnvironmentObject private var updater: LibraryUpdater
    @ObservedObject private var shortcuts = TabShortcuts.shared
    @State private var section: Section = .updates
    @State private var showingDownloads = false
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sección", selection: $section) {
                // LocalizedStringKey: a plain String would skip the translation table.
                ForEach(Section.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch section {
                case .updates: UpdatesList()
                case .history: HistoryList()
            }
        }
        .navigationTitle("Actividad")
        .navigationDestination(for: MangaItem.self) { manga in
            MangaDetailView(manga: manga)
        }
        // Tapping Actividad again in the tab bar jumps to the downloads in progress.
        .navigationDestination(isPresented: $showingDownloads) {
            DownloadsView()
        }
        .onChange(of: shortcuts.activityReselected) { _ in
            showingDownloads = true
        }
        .toolbar {
            if section == .updates {
                if updater.isRefreshing {
                    Button("Detener") { updater.cancel() }
                } else {
                    Button {
                        updater.refreshAll(library: library, extensions: extensions)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(library.entries.isEmpty)
                    .accessibilityLabel("Actualizar biblioteca")
                }
            } else if !library.history.isEmpty {
                Button("Borrar") { confirmingClear = true }
            }
        }
        .confirmationDialog(
            "¿Borrar todo el historial de lectura?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Borrar historial", role: .destructive) { library.clearHistory() }
        }
    }
}

private struct UpdatesList: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var extensions: ExtensionManager
    @EnvironmentObject private var updater: LibraryUpdater
    @EnvironmentObject private var downloads: DownloadManager

    /// A key path cannot reach into a tuple, so the uploads become this struct.
    private struct Update: Identifiable {
        let manga: MangaItem
        let chapter: ChapterItem
        var id: String { "\(manga.id)|\(chapter.url)" }
    }

    /// One release day, newest first, like the history list.
    private struct Day: Identifiable {
        let date: Date
        let items: [Update]
        var id: Date { date }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let updates = library.latestUploads.map { Update(manga: $0.manga, chapter: $0.chapter) }
        return Dictionary(grouping: updates) { update in
            calendar.startOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(update.chapter.dateUpload) / 1000)
            )
        }
        .map { Day(date: $0.key, items: $0.value) }
        .sorted { $0.date > $1.date }
    }

    var body: some View {
        if library.entries.isEmpty {
            EmptyStateView(
                symbol: "bolt",
                title: "Sin novedades",
                message: "Guarda series en tu biblioteca para ver aquí sus capítulos nuevos."
            )
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if !downloads.queue.isEmpty {
                NavigationLink {
                    DownloadsView()
                } label: {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(downloads.queue.count == 1
                            ? LocalizedStringKey("Descargando 1 capítulo…")
                            : "Descargando \(downloads.queue.count) capítulos…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowSeparator(.hidden)
            }
            if updater.isRefreshing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Actualizando \(updater.completed + 1) de \(updater.total)…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden)
            } else if let finished = updater.lastFinished {
                Text(
                    updater.newChapters == 0
                        ? "Sin capítulos nuevos (\(finished.shortText))."
                        : updater.newChapters == 1
                            ? LocalizedStringKey("1 capítulo nuevo.")
                            : "\(updater.newChapters) capítulos nuevos."
                )
                .font(.footnote)
                .foregroundStyle(updater.newChapters == 0 ? .secondary : Color.moka)
                .listRowSeparator(.hidden)
            }

            ForEach(days) { day in
                SwiftUI.Section {
                    ForEach(day.items) { item in
                        NavigationLink(value: item.manga) {
                            row(item.manga, item.chapter)
                        }
                        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 12))
                    }
                } header: {
                    DayHeader(date: day.date)
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await updater.refresh(library: library, extensions: extensions)
        }
    }

    private func row(_ manga: MangaItem, _ chapter: ChapterItem) -> some View {
        let read = library.isRead(chapter, in: manga)
        let isNew = updater.lastNewURLs.contains(chapter.url)
        return HStack(spacing: 12) {
            CoverImage(manga: manga)
                .frame(width: 44, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(manga.title)
                    .font(.subheadline.weight(read ? .regular : .semibold))
                    .foregroundStyle(read ? .secondary : .primary)
                    .lineLimit(1)
                Text(chapter.name)
                    .font(.caption)
                    .foregroundStyle(read ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isNew {
                Text("Nuevo")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.moka.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.moka)
            } else if !read {
                Circle()
                    .fill(Color.moka)
                    .frame(width: 8, height: 8)
            }
        }
    }
}

/// "Hoy", "Ayer" or the date, as the warm serif section heading both activity lists share.
struct DayHeader: View {
    let date: Date

    var body: some View {
        Text(date.relativeDayText)
            .font(.system(.footnote, design: .serif).weight(.semibold))
            .foregroundStyle(Color.moka)
            .textCase(nil)
    }
}

private struct HistoryList: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""

    private struct Day: Identifiable {
        let date: Date
        let records: [ReadingRecord]
        var id: Date { date }
    }

    private var filtered: [ReadingRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return library.history }
        return library.history.filter {
            $0.manga.title.localizedCaseInsensitiveContains(trimmed)
                || $0.chapterName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        return Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
            .map { Day(date: $0.key, records: $0.value) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        Group {
            if library.history.isEmpty {
                EmptyStateView(
                    symbol: "clock",
                    title: "Sin historial",
                    message: "Los capítulos que abras van a aparecer aquí."
                )
            } else {
                List {
                    ForEach(days) { day in
                        SwiftUI.Section {
                            ForEach(day.records) { record in
                                NavigationLink(value: record.manga) {
                                    HStack(spacing: 12) {
                                        CoverImage(manga: record.manga)
                                            .frame(width: 40, height: 56)
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(record.manga.title)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(1)
                                            Text(record.chapterName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text(record.date, style: .time)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .swipeActions {
                                    Button("Borrar", role: .destructive) {
                                        library.deleteHistoryRecord(record)
                                    }
                                }
                            }
                        } header: {
                            DayHeader(date: day.date)
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $query, prompt: "Buscar en el historial")
            }
        }
    }
}
