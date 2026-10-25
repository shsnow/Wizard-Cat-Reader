import SwiftUI
import UIKit

struct ReaderContext: Identifiable {
    let id = UUID()
    let manga: MangaItem
    let installed: InstalledExtension
    /// Oldest first, so "next chapter" is index + 1.
    let chapters: [ChapterItem]
    let startIndex: Int
}

/// Drives the webtoon's underlying UIScrollView at a steady speed with a display link.
final class AutoScroller: NSObject, ObservableObject {
    weak var scrollView: UIScrollView?
    var pointsPerSecond: Double = 80
    /// Called on the main thread every frame the strip sits at its bottom.
    var onReachEnd: (() -> Void)?

    private var displayLink: CADisplayLink?

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let scrollView else { return }
        // A finger on screen, or a fling still running, takes priority over the motor.
        if scrollView.isTracking || scrollView.isDecelerating { return }
        let limit = scrollView.contentSize.height
            + scrollView.adjustedContentInset.bottom
            - scrollView.bounds.height
        guard limit > 0 else { return }
        let elapsed = link.targetTimestamp - link.timestamp
        var offset = scrollView.contentOffset
        offset.y += CGFloat(pointsPerSecond * elapsed)
        if offset.y >= limit {
            offset.y = limit
            scrollView.setContentOffset(offset, animated: false)
            onReachEnd?()
            return
        }
        scrollView.setContentOffset(offset, animated: false)
    }

    deinit {
        displayLink?.invalidate()
    }
}

/// Invisible view that finds its enclosing UIScrollView, so autoscroll can drive it directly.
private struct ScrollViewGrabber: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeUIView(context: Context) -> Resolver { Resolver(onResolve: onResolve) }
    func updateUIView(_ uiView: Resolver, context: Context) {}

    final class Resolver: UIView {
        private let onResolve: (UIScrollView) -> Void

        init(onResolve: @escaping (UIScrollView) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Detaching also lands here; resolving then could hand back the dying scroll view.
            guard window != nil else { return }
            var view: UIView? = superview
            while let current = view {
                if let scroll = current as? UIScrollView {
                    onResolve(scroll)
                    return
                }
                view = current.superview
            }
        }
    }
}

struct ReaderView: View {
    let context: ReaderContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloads: DownloadManager

    @State private var chapterIndex: Int
    @State private var pages: [PageItem] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var mode: ReadingMode = .webtoon
    @State private var showOverlay = true
    @State private var currentPage = 0
    @State private var isOffline = false

    /// The chapters loaded into the webtoon strip, in reading order. Scrolling past the end of
    /// one chapter loads the next below it, so long strips read without interruption.
    @State private var segments: [WebtoonSegment] = []
    /// Regenerated only on explicit jumps, so appending a chapter never resets the scroll.
    @State private var stripID = UUID()
    @State private var isLoadingNext = false
    @State private var nextError: String?

    @StateObject private var autoScroller = AutoScroller()
    @State private var isAutoScrolling = false

    /// Webtoon zoom: the strip is laid out wider and scrolls in both directions.
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGFloat = 0
    @GestureState private var panDrag: CGFloat = 0
    @State private var sessionStart = Date()

    /// How many pages ahead to load before they come on screen.
    private let prefetchCount = 4

    struct WebtoonSegment: Identifiable {
        let chapterIndex: Int
        let chapterURL: String
        let pages: [PageItem]
        let isOffline: Bool

        var id: String { chapterURL }
    }

    init(context: ReaderContext) {
        self.context = context
        _chapterIndex = State(initialValue: context.startIndex)
    }

    private var chapter: ChapterItem { context.chapters[chapterIndex] }
    private var hasNext: Bool { chapterIndex + 1 < context.chapters.count }
    private var hasPrevious: Bool { chapterIndex > 0 }
    /// True once the strip's last loaded chapter is the series' final one.
    private var stripReachedEnd: Bool {
        (segments.last?.chapterIndex ?? chapterIndex) + 1 >= context.chapters.count
    }

    private var background: Color { settings.readerBackground.color }
    private var isLightBackground: Bool { settings.readerBackground == .white }
    private var controlColor: Color { isLightBackground ? .black : .white }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background.ignoresSafeArea()

                if isLoading && pages.isEmpty {
                    ProgressView("Cargando capítulo…")
                        .tint(controlColor)
                        .foregroundStyle(controlColor)
                } else if let error, pages.isEmpty {
                    VStack(spacing: 14) {
                        Text(error)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(controlColor)
                        Button("Reintentar") { Task { await loadChapter() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(32)
                } else if mode == .webtoon {
                    webtoon(width: geometry.size.width)
                } else {
                    paged(size: geometry.size)
                }

                if showOverlay {
                    overlay
                } else if settings.alwaysShowPageNumber && !pages.isEmpty {
                    // Discreet page counter while the controls are hidden.
                    Text("\(min(currentPage + 1, pages.count)) / \(pages.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(controlColor.opacity(0.65))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (isLightBackground ? Color.white : Color.black).opacity(0.55),
                            in: Capsule()
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 4)
                        .allowsHitTesting(false)
                }
            }
        }
        .statusBarHidden(!showOverlay)
        .task {
            mode = library.readingMode(for: context.manga, fallback: settings.defaultReadingMode)
            await loadChapter()
        }
        .onAppear {
            sessionStart = Date()
            if settings.keepScreenAwake { UIApplication.shared.isIdleTimerDisabled = true }
        }
        .onDisappear {
            stopAutoScroll()
            UIApplication.shared.isIdleTimerDisabled = false
            library.addReadingTime(Date().timeIntervalSince(sessionStart), to: context.manga)
        }
    }

    // MARK: - Webtoon

    private func webtoon(width fullWidth: CGFloat) -> some View {
        // The side margin some long strips read better with.
        let width = fullWidth * (1 - 2 * settings.webtoonPadding)
        let decodeWidth = width * displayScale * 1.5
        let scale = min(max(zoom * pinch, 1), 3)
        // Horizontal room the zoomed strip has on each side.
        let maxPan = width * (scale - 1) / 2
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(segments) { segment in
                    if segment.chapterIndex != segments.first?.chapterIndex {
                        segmentDivider(for: segment)
                    }
                    ForEach(Array(segment.pages.enumerated()), id: \.element.id) { offset, page in
                        ReaderPageView(
                            page: page,
                            manga: context.manga,
                            installed: context.installed,
                            width: width,
                            decodeWidth: decodeWidth,
                            fitHeight: nil,
                            onTap: nil
                        )
                        .onAppear {
                            pageAppeared(segment: segment, offset: offset, decodeWidth: decodeWidth)
                        }
                    }
                }
                stripFooter
            }
            .frame(maxWidth: .infinity)
            .background(ScrollViewGrabber { autoScroller.scrollView = $0 })
        }
        .id(stripID)
        // Zoom scales the visible viewport around the screen centre; the strip keeps its layout,
        // so the reading position never moves and pages still load lazily.
        .scaleEffect(scale, anchor: .center)
        .offset(x: min(max(pan + panDrag, -maxPan), maxPan))
        .clipped()
        .simultaneousGesture(
            MagnificationGesture()
                .updating($pinch) { value, state, _ in state = value }
                .onEnded { value in
                    withAnimation(.easeOut(duration: 0.15)) {
                        zoom = min(max(zoom * value, 1), 3)
                        if zoom <= 1.01 { zoom = 1; pan = 0 }
                        let limit = width * (zoom - 1) / 2
                        pan = min(max(pan, -limit), limit)
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .updating($panDrag) { value, state, _ in
                    if zoom > 1.01 { state = value.translation.width }
                }
                .onEnded { value in
                    guard zoom > 1.01 else { return }
                    let limit = width * (zoom - 1) / 2
                    pan = min(max(pan + value.translation.width, -limit), limit)
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.easeOut(duration: 0.2)) {
                if zoom > 1.05 {
                    zoom = 1
                    pan = 0
                } else {
                    zoom = 2
                }
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
        }
    }

    private func segmentDivider(for segment: WebtoonSegment) -> some View {
        VStack(spacing: 6) {
            Rectangle()
                .fill(controlColor.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, 40)
            Text(context.chapters[segment.chapterIndex].name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(controlColor.opacity(0.7))
                .lineLimit(1)
            Rectangle()
                .fill(controlColor.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, 40)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var stripFooter: some View {
        if isLoadingNext {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(controlColor)
                Text("Cargando el siguiente capítulo…")
                    .font(.footnote)
                    .foregroundStyle(controlColor.opacity(0.7))
            }
            .padding(.vertical, 60)
            .frame(maxWidth: .infinity)
        } else if let nextError {
            VStack(spacing: 12) {
                Text(nextError)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(controlColor.opacity(0.8))
                Button("Reintentar") { Task { await loadNextSegment() } }
                    .buttonStyle(.bordered)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        } else if stripReachedEnd {
            chapterEnd
                .frame(minHeight: 260)
        } else {
            // Room for the trigger when scrolling faster than pages load.
            Color.clear
                .frame(height: 120)
                .onAppear { Task { await loadNextSegment() } }
        }
    }

    private func pageAppeared(segment: WebtoonSegment, offset: Int, decodeWidth: CGFloat) {
        if segment.chapterIndex != chapterIndex {
            // Crossed into another chapter while scrolling.
            chapterIndex = segment.chapterIndex
            pages = segment.pages
            isOffline = segment.isOffline
            library.markOpened(context.chapters[segment.chapterIndex], in: context.manga)
        }
        currentPage = offset
        prefetch(after: offset, in: segment.pages, decodeWidth: decodeWidth)
        if offset >= segment.pages.count - 1 {
            markRead(segment: segment)
        }
        if segment.id == segments.last?.id && offset >= segment.pages.count - 3 {
            Task { await loadNextSegment() }
        }
    }

    private func loadNextSegment() async {
        guard mode == .webtoon, !isLoadingNext, !isLoading else { return }
        guard let last = segments.last else { return }
        let nextIndex = last.chapterIndex + 1
        guard nextIndex < context.chapters.count else { return }
        guard !segments.contains(where: { $0.chapterIndex == nextIndex }) else { return }
        isLoadingNext = true
        nextError = nil
        defer { isLoadingNext = false }
        let target = context.chapters[nextIndex]

        if let local = downloads.localPages(manga: context.manga, chapter: target) {
            segments.append(
                WebtoonSegment(chapterIndex: nextIndex, chapterURL: target.url, pages: local, isOffline: true)
            )
            return
        }
        if context.manga.isLocal {
            do {
                let loaded = try await Task.detached { try LocalStore.pages(for: target) }.value
                guard mode == .webtoon, segments.last?.chapterIndex == last.chapterIndex else { return }
                segments.append(
                    WebtoonSegment(chapterIndex: nextIndex, chapterURL: target.url, pages: loaded, isOffline: true)
                )
            } catch {
                nextError = error.localizedDescription
            }
            return
        }
        do {
            let loaded = try await JVMEngine.shared.pages(
                of: target, manga: context.manga, installed: context.installed
            )
            // The strip may have been rebuilt (mode switch, chapter jump) while this loaded.
            guard mode == .webtoon, segments.last?.chapterIndex == last.chapterIndex else { return }
            guard !loaded.isEmpty else {
                nextError = String(
                    format: NSLocalizedString("%@ no tiene páginas.", comment: ""), target.name
                )
                return
            }
            segments.append(
                WebtoonSegment(chapterIndex: nextIndex, chapterURL: target.url, pages: loaded, isOffline: false)
            )
        } catch {
            nextError = error.localizedDescription
        }
    }

    // MARK: - Autoscroll

    private func toggleAutoScroll() {
        if isAutoScrolling {
            stopAutoScroll()
        } else {
            startAutoScroll()
        }
    }

    private func startAutoScroll() {
        guard mode == .webtoon else { return }
        autoScroller.pointsPerSecond = settings.autoScrollSpeed
        autoScroller.onReachEnd = {
            // At the true end of the series — or if the next chapter failed to load — the motor
            // stops; while the next chapter is still loading it waits and resumes on its own.
            if !isLoadingNext && (stripReachedEnd || nextError != nil) {
                stopAutoScroll()
            }
        }
        autoScroller.start()
        isAutoScrolling = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func stopAutoScroll() {
        // Clearing the callback also breaks the reference loop through the captured view copy.
        autoScroller.onReachEnd = nil
        autoScroller.stop()
        guard isAutoScrolling else { return }
        isAutoScrolling = false
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake
    }

    // MARK: - Paged

    private func layoutIsDouble(_ size: CGSize) -> Bool {
        switch settings.doublePageMode {
            case .off: return false
            case .always: return true
            case .landscape: return size.width > size.height
        }
    }

    /// Page indices grouped per screen. In double layout the first page stands alone (it is
    /// usually the cover), then pages pair up like an open book.
    private func spreadGroups(double: Bool) -> [[Int]] {
        guard double, pages.count > 1 else {
            return pages.indices.map { [$0] }
        }
        var groups: [[Int]] = [[0]]
        var index = 1
        while index < pages.count {
            if index + 1 < pages.count {
                groups.append([index, index + 1])
                index += 2
            } else {
                groups.append([index])
                index += 1
            }
        }
        return groups
    }

    /// TabView selects spreads, the rest of the reader thinks in pages.
    private func spreadSelection(_ spreads: [[Int]]) -> Binding<Int> {
        Binding(
            get: {
                if currentPage >= pages.count { return spreads.count }
                return spreads.firstIndex(where: { $0.contains(currentPage) }) ?? 0
            },
            set: { index in
                currentPage = index >= spreads.count
                    ? pages.count
                    : (spreads[index].first ?? 0)
            }
        )
    }

    private func paged(size: CGSize) -> some View {
        let double = layoutIsDouble(size)
        let spreads = spreadGroups(double: double)
        // In double mode each page only fills half the screen; decoding at 2x there
        // would quadruple the composite's memory for nothing.
        let decodeWidth = size.width * displayScale * (double ? 1 : 2)
        return TabView(selection: spreadSelection(spreads)) {
            ForEach(Array(spreads.enumerated()), id: \.offset) { offset, group in
                SpreadPageView(
                    pages: group.map { pages[$0] },
                    manga: context.manga,
                    installed: context.installed,
                    size: size,
                    decodeWidth: decodeWidth,
                    rightToLeft: mode == .rightToLeft,
                    trimBorders: settings.trimPageBorders,
                    onTap: { position in handlePagedTap(position, spreads: spreads) }
                )
                .tag(offset)
            }
            chapterEnd
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() } }
                .tag(spreads.count)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .environment(\.layoutDirection, mode == .rightToLeft ? .rightToLeft : .leftToRight)
        .id("\(chapter.url)-\(mode.rawValue)-\(double)-\(settings.trimPageBorders)")
        .onChange(of: currentPage) { value in
            prefetch(after: value, in: pages, decodeWidth: decodeWidth)
            if !pages.isEmpty, value >= pages.count || spreads.last?.contains(value) == true { markRead() }
        }
        .onAppear {
            prefetch(after: currentPage, in: pages, decodeWidth: decodeWidth)
        }
    }

    /// Edge taps turn pages; the middle of the screen shows or hides the controls.
    /// In right-to-left mode the left edge moves forward, like a printed manga.
    private func handlePagedTap(_ position: CGFloat, spreads: [[Int]]) {
        guard settings.tapZonesEnabled else {
            withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
            return
        }
        var forward: Bool
        if position < 0.3 {
            forward = mode == .rightToLeft
        } else if position > 0.7 {
            forward = mode != .rightToLeft
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() }
            return
        }
        // For reading with the other hand.
        if settings.invertTapZones { forward.toggle() }
        let current = currentPage >= pages.count
            ? spreads.count
            : (spreads.firstIndex(where: { $0.contains(currentPage) }) ?? 0)
        let target = current + (forward ? 1 : -1)
        guard target >= 0, target <= spreads.count else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            currentPage = target == spreads.count ? pages.count : (spreads[target].first ?? 0)
        }
    }

    private func prefetch(after index: Int, in pages: [PageItem], decodeWidth: CGFloat) {
        guard !pages.isEmpty else { return }
        let start = index + 1
        let end = min(index + prefetchCount, pages.count - 1)
        guard start <= end else { return }
        let upcoming = Array(pages[start...end])
        let manga = context.manga
        let installed = context.installed
        Task {
            await ImagePipeline.shared.prefetch(
                upcoming, sourceId: manga.sourceId, installed: installed, maxWidth: decodeWidth
            )
        }
    }

    // MARK: - Pieces

    private var chapterEnd: some View {
        VStack(spacing: 16) {
            Text("Terminaste \(chapter.name)")
                .font(.headline)
                .foregroundStyle(controlColor)
            if hasNext {
                Button {
                    Task { await go(to: chapterIndex + 1) }
                } label: {
                    Label("Siguiente: \(context.chapters[chapterIndex + 1].name)", systemImage: "forward.end")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("No hay más capítulos por ahora.")
                    .font(.subheadline)
                    .foregroundStyle(controlColor.opacity(0.7))
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var overlay: some View {
        VStack {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Cerrar lector")
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.manga.title)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(chapter.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if isOffline {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                Spacer()
                if mode == .webtoon && zoom > 1.05 {
                    Button {
                        withAnimation { zoom = 1; pan = 0 }
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(.black.opacity(0.75))

            Spacer()

            VStack(spacing: 0) {
                if isAutoScrolling {
                    HStack(spacing: 12) {
                        Image(systemName: "tortoise")
                            .font(.caption)
                        Slider(value: speedBinding, in: 20...300)
                        Image(systemName: "hare")
                            .font(.caption)
                    }
                    .tint(.moka)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                }

                HStack(spacing: 18) {
                    Button {
                        Task { await go(to: chapterIndex - 1) }
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .disabled(!hasPrevious)
                    .accessibilityLabel("Capítulo anterior")

                    Spacer()

                    if mode == .webtoon {
                        Button {
                            toggleAutoScroll()
                        } label: {
                            Image(systemName: isAutoScrolling ? "pause.circle.fill" : "play.circle")
                        }
                        .accessibilityLabel(
                            isAutoScrolling
                                ? Text("Pausar autodesplazamiento")
                                : Text("Autodesplazamiento")
                        )
                    }

                    if !pages.isEmpty {
                        Text("\(min(currentPage + 1, pages.count)) / \(pages.count)")
                            .font(.footnote.monospacedDigit())
                    }

                    Spacer()

                    Menu {
                        Picker("Modo de lectura", selection: modeBinding) {
                            ForEach(ReadingMode.allCases) { item in
                                Label(item.title, systemImage: item.symbol).tag(item)
                            }
                        }
                        if mode != .webtoon {
                            Divider()
                            Picker("Doble página", selection: $settings.doublePageMode) {
                                ForEach(DoublePageMode.allCases) { Text($0.title).tag($0) }
                            }
                            Toggle("Recortar bordes", isOn: $settings.trimPageBorders)
                        }
                    } label: {
                        Image(systemName: mode.symbol)
                    }
                    .accessibilityLabel("Modo de lectura")

                    Button {
                        Task { await go(to: chapterIndex + 1) }
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .disabled(!hasNext)
                    .accessibilityLabel("Capítulo siguiente")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
            .font(.title3)
            .foregroundStyle(.white)
            .background(.black.opacity(0.75))
        }
        .transition(.opacity)
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { settings.autoScrollSpeed },
            set: { value in
                settings.autoScrollSpeed = value
                autoScroller.pointsPerSecond = value
            }
        )
    }

    private var modeBinding: Binding<ReadingMode> {
        Binding(
            get: { mode },
            set: { value in
                let position = currentPage
                stopAutoScroll()
                mode = value
                zoom = 1
                pan = 0
                // Keep the reading position across mode changes.
                currentPage = pages.isEmpty ? 0 : min(position, pages.count - 1)
                // The strip restarts from the chapter being read.
                segments = pages.isEmpty ? [] : [
                    WebtoonSegment(
                        chapterIndex: chapterIndex,
                        chapterURL: chapter.url,
                        pages: pages,
                        isOffline: isOffline
                    )
                ]
                nextError = nil
                stripID = UUID()
                library.setReadingMode(value, for: context.manga)
            }
        )
    }

    // MARK: - Loading

    private func go(to index: Int) async {
        guard context.chapters.indices.contains(index) else { return }
        chapterIndex = index
        await loadChapter()
    }

    private func loadChapter() async {
        isLoading = true
        error = nil
        nextError = nil
        pages = []
        segments = []
        currentPage = 0
        zoom = 1
        pan = 0
        stripID = UUID()
        stopAutoScroll()
        defer { isLoading = false }
        let target = chapter
        library.markOpened(target, in: context.manga)

        // Downloaded chapters open from disk, without the network or the extension engine.
        if let local = downloads.localPages(manga: context.manga, chapter: target) {
            isOffline = true
            pages = local
            segments = [
                WebtoonSegment(chapterIndex: chapterIndex, chapterURL: target.url, pages: local, isOffline: true)
            ]
            return
        }
        // Imported chapters: list and extract from the archive, never the engine.
        if context.manga.isLocal {
            isOffline = true
            do {
                let loaded = try await Task.detached { try LocalStore.pages(for: target) }.value
                guard target == chapter else { return }
                pages = loaded
                segments = [
                    WebtoonSegment(chapterIndex: chapterIndex, chapterURL: target.url, pages: loaded, isOffline: true)
                ]
            } catch {
                self.error = error.localizedDescription
            }
            return
        }
        isOffline = false
        do {
            let loaded = try await JVMEngine.shared.pages(
                of: target, manga: context.manga, installed: context.installed
            )
            guard target == chapter else { return }
            if loaded.isEmpty {
                error = NSLocalizedString("Este capítulo no tiene páginas.", comment: "")
            }
            pages = loaded
            segments = loaded.isEmpty ? [] : [
                WebtoonSegment(chapterIndex: chapterIndex, chapterURL: target.url, pages: loaded, isOffline: false)
            ]
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Paged mode: the chapter on screen was finished.
    private func markRead() {
        library.setRead(true, chapter: chapter, in: context.manga)
        if settings.deleteAfterReading && isOffline {
            downloads.delete(manga: context.manga, chapter: chapter)
        }
    }

    /// Webtoon strip: one of the loaded chapters was finished.
    private func markRead(segment: WebtoonSegment) {
        let finished = context.chapters[segment.chapterIndex]
        library.setRead(true, chapter: finished, in: context.manga)
        if settings.deleteAfterReading && segment.isOffline {
            downloads.delete(manga: context.manga, chapter: finished)
        }
    }
}

/// One paged-mode screen: a single page, or two pages merged into an open-book spread.
struct SpreadPageView: View {
    let pages: [PageItem]
    let manga: MangaItem
    let installed: InstalledExtension
    let size: CGSize
    let decodeWidth: CGFloat
    let rightToLeft: Bool
    let trimBorders: Bool
    let onTap: ((CGFloat) -> Void)?

    @State private var image: UIImage?
    @State private var failed: String?
    @State private var attempt = 0

    private var loadKey: String {
        "\(attempt)|\(trimBorders)|\(pages.map { String($0.index) }.joined(separator: "-"))"
    }

    var body: some View {
        Group {
            if let image {
                ZoomableImageView(image: image) { position in onTap?(position) }
                    .frame(width: size.width, height: size.height)
            } else if let failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Página \((pages.first?.index ?? 0) + 1): \(failed)")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("Reintentar") { attempt += 1 }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.gray)
                .padding()
                .frame(width: size.width, height: size.height)
            } else {
                ProgressView()
                    .tint(.gray)
                    .frame(width: size.width, height: size.height)
            }
        }
        .task(id: loadKey) { await load() }
    }

    private func load() async {
        failed = nil
        do {
            var loaded: [UIImage] = []
            for page in pages {
                loaded.append(
                    try await ImagePipeline.shared.page(
                        page,
                        sourceId: manga.sourceId,
                        installed: installed,
                        maxWidth: decodeWidth
                    )
                )
            }
            let trim = trimBorders
            let rtl = rightToLeft
            let fetched = loaded
            // Trimming and compositing are CPU work; keep them off the main actor.
            let composed = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                var images = fetched
                if trim {
                    images = images.map { ImagePipeline.trimmingBorders($0) }
                }
                if images.count == 2 {
                    return ImagePipeline.spread(images[0], images[1], rightToLeft: rtl)
                }
                return images.first
            }.value
            if !Task.isCancelled {
                image = composed
            }
        } catch {
            if !Task.isCancelled { failed = error.localizedDescription }
        }
    }
}

/// One page. Webtoon pages fill the width at their natural height; paged pages fit the screen
/// and can be zoomed.
struct ReaderPageView: View {
    let page: PageItem
    let manga: MangaItem
    let installed: InstalledExtension
    let width: CGFloat
    let decodeWidth: CGFloat
    let fitHeight: CGFloat?
    /// Paged mode only: horizontal tap position, 0 (left) to 1 (right).
    let onTap: ((CGFloat) -> Void)?

    @State private var image: UIImage?
    @State private var failed: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                if let fitHeight {
                    ZoomableImageView(image: image) { position in onTap?(position) }
                        .frame(width: width, height: fitHeight)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(image.size, contentMode: .fit)
                        .frame(width: width)
                }
            } else if let failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Página \(page.index + 1): \(failed)")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Button("Reintentar") { attempt += 1 }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.gray)
                .padding()
                .frame(width: width, height: fitHeight ?? width * 1.2)
            } else {
                ProgressView()
                    .tint(.gray)
                    .frame(width: width, height: fitHeight ?? width * 1.4)
            }
        }
        .task(id: attempt) {
            guard image == nil else { return }
            failed = nil
            do {
                image = try await ImagePipeline.shared.page(
                    page,
                    sourceId: manga.sourceId,
                    installed: installed,
                    maxWidth: decodeWidth
                )
            } catch {
                if !Task.isCancelled { failed = error.localizedDescription }
            }
        }
    }
}
