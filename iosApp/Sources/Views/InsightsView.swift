import SwiftUI

/// How much has been read, in total and by series, from the time MokaReader tracks on-device.
struct InsightsView: View {
    @EnvironmentObject private var library: LibraryStore

    private var ranking: [(manga: MangaItem, seconds: Double)] {
        library.readingRanking
    }

    private var maxSeconds: Double {
        ranking.first?.seconds ?? 1
    }

    var body: some View {
        Group {
            if ranking.isEmpty {
                EmptyStateView(
                    symbol: "chart.bar",
                    title: "Todavía no hay datos",
                    message: "El tiempo de lectura se cuenta mientras tienes un capítulo abierto."
                )
            } else {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(LibraryStore.timeText(library.totalReadSeconds))
                                .font(.system(.largeTitle, design: .serif).bold())
                            if let since = library.readingSince {
                                Text("Tiempo de lectura desde el \(since.shortText).")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .listRowSeparator(.hidden)
                    }

                    Section("Por serie") {
                        ForEach(ranking, id: \.manga.id) { item in
                            NavigationLink(value: item.manga) {
                                row(item.manga, seconds: item.seconds)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Estadísticas")
        .navigationDestination(for: MangaItem.self) { manga in
            MangaDetailView(manga: manga)
        }
    }

    private func row(_ manga: MangaItem, seconds: Double) -> some View {
        HStack(spacing: 12) {
            CoverImage(manga: manga)
                .frame(width: 40, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(manga.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.secondarySystemBackground))
                        Capsule()
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(width: max(8, geometry.size.width * seconds / maxSeconds))
                    }
                }
                .frame(height: 6)
                Text(LibraryStore.timeText(seconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
