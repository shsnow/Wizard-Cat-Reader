import SwiftUI

/// A manga cover: the user's custom one if set, otherwise loaded through the source's
/// own headers.
struct CoverImage: View {
    let manga: MangaItem
    @EnvironmentObject private var extensions: ExtensionManager
    @EnvironmentObject private var library: LibraryStore
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if failed {
                    Image(systemName: "book.closed")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                }
            }
            .clipped()
            .task(id: "\(manga.id)|\(manga.thumbnailURL ?? "")#\(library.coverVersion)") {
                image = nil
                failed = false
                if let custom = library.customCoverURL(for: manga),
                   let data = try? Data(contentsOf: custom),
                   let decoded = ImagePipeline.decode(data, maxWidth: 360) {
                    image = decoded
                    return
                }
                let installed = extensions.extensionFor(sourceId: manga.sourceId)
                do {
                    image = try await ImagePipeline.shared.cover(
                        for: manga,
                        installed: installed,
                        maxWidth: 360
                    )
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
    }
}

struct MangaCell: View {
    let manga: MangaItem
    var badge: Int = 0
    var selected: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(manga: manga)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            selected == true ? Color.moka : Color.primary.opacity(0.08),
                            lineWidth: selected == true ? 2.5 : 1
                        )
                )
                .overlay(alignment: .topLeading) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.moka, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selected ? Color.moka : Color.black.opacity(0.35))
                            .padding(6)
                    }
                }
                .opacity(selected == false ? 0.75 : 1)
            Text(manga.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
    }
}

/// Reports the grid content's vertical offset, so the library can collapse its header rows.
private struct GridOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MangaGrid<Footer: View>: View {
    let items: [MangaItem]
    var badge: (MangaItem) -> Int = { _ in 0 }
    var onItemAppear: (MangaItem) -> Void = { _ in }
    /// Called on a long press when not selecting; the library uses it to start selection.
    var onItemLongPress: ((MangaItem) -> Void)? = nil
    /// Non-nil puts the grid in selection mode: taps toggle membership instead of navigating.
    var selection: Binding<Set<String>>? = nil
    /// Scrolls away with the content, like the library's "Seguir leyendo" row.
    var header: AnyView? = nil
    /// Reports the scroll offset (0 at the top, negative scrolling down).
    var onScroll: ((CGFloat) -> Void)? = nil
    @ViewBuilder var footer: () -> Footer

    @EnvironmentObject private var settings: AppSettings

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: settings.gridColumns)
    }

    var body: some View {
        ScrollView {
            if onScroll != nil {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: GridOffsetKey.self,
                        value: proxy.frame(in: .named("mangaGrid")).minY
                    )
                }
                .frame(height: 0)
            }
            if let header {
                header
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { manga in
                    if let selection {
                        let isSelected = selection.wrappedValue.contains(manga.id)
                        Button {
                            if isSelected {
                                selection.wrappedValue.remove(manga.id)
                            } else {
                                selection.wrappedValue.insert(manga.id)
                            }
                        } label: {
                            MangaCell(manga: manga, badge: badge(manga), selected: isSelected)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: manga) {
                            MangaCell(manga: manga, badge: badge(manga))
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                                guard let onItemLongPress else { return }
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                onItemLongPress(manga)
                            }
                        )
                        .onAppear { onItemAppear(manga) }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            footer()
                .padding(.vertical, 24)
        }
        .coordinateSpace(name: "mangaGrid")
        .onPreferenceChange(GridOffsetKey.self) { value in
            onScroll?(value)
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.moka)
                .frame(width: 76, height: 76)
                .background(Color.moka.opacity(0.12), in: Circle())
            // As keys, so literal call sites hit the translation table; a dynamic
            // message (an error) misses the table and shows as-is.
            Text(LocalizedStringKey(title))
                .font(.system(.title3, design: .serif).weight(.semibold))
            Text(LocalizedStringKey(message))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ExtensionIcon: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(.secondary)
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The engine state as a single row, used where a screen depends on the JVM.
struct EngineBanner: View {
    @EnvironmentObject private var engine: EngineStatus

    var body: some View {
        switch engine.state {
            case .starting:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Iniciando el motor de extensiones…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(10)
            case .failed(let message):
                Text("El motor no pudo iniciar: \(message)")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(10)
            default:
                EmptyView()
        }
    }
}

extension Date {
    var shortText: String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: self)
    }

    /// "Hoy", "Ayer" or a medium date, in the app's language.
    var relativeDayText: String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: self).localizedCapitalized
    }
}
