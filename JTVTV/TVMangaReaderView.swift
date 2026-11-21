import SwiftUI
import UIKit

/// JTV tvOS 1.3.0 (NEXT-B) — the focus-stepped manga reader.
///
/// Replaces the Phase 4 placeholder for the session's `.manga`
/// phase (sayhentai + misskon). It is a CHILD of the player
/// session: dependencies arrive as values (the session itself —
/// no @EnvironmentObject inside the cover subtree, L-T06 rule),
/// chapter state lives here, and chapter switches resolve
/// INSIDE the reader through `MovieService.resolveMangaChapter`
/// — never through session.beginAttempt/switchSource (attempt
/// churn would reset the cover per chapter, NEXT-B §2.1).
///
/// Reading model (NEXT-B §3.2): sayhentai "pages" are intact
/// long strips (~720×10,000 px), so reading is STEPPED, not
/// scrolled. A strip is shown full-width in a screen-height
/// window; one press advances the window by one screen height
/// minus a ~15% overlap; the last window is bottom-aligned. An
/// image that fits the screen is a single page-step.
///
/// Input (NEXT-B §3.3, KS-host precedent): ONE focusable UIKit
/// press surface. Right/Down/Select/PlayPause = forward,
/// Left/Up = back, Menu is NEVER handled here — the cover's
/// single Menu arbiter (FL-048) owns it, and the chapter-end
/// bar is a session panel (`.mangaChapterEnd`) so the arbiter
/// closes it first, exactly like the other panels.
///
/// Images render through the bucketed pipeline at bucket 1920
/// EXPLICITLY (NEXT-B R-2: the `cachedImage(for:)` wrapper
/// silently means bucket 720 and would ship a blurry reader).
struct TVMangaReaderView: View {
    let session: TVPlayerSession
    let initialStream: StreamInfo

    @Environment(\.tvTheme) private var theme

    @State private var currentEpisode: Episode
    @State private var stream: StreamInfo
    @State private var chapterList: [Episode]
    @State private var imageIndex: Int
    @State private var windowIndex: Int = 0

    /// Decoded bitmaps near the reading position (current ±2).
    /// Bounded deliberately (NEXT-B R-1: one strip decodes to
    /// ~28.8 MB; the memory cache is 48–120 MB shared).
    @State private var loadedImages: [Int: UIImage] = [:]
    @State private var failedImages: Set<Int> = []
    /// The last bitmap actually shown — held on screen while a
    /// step's target decodes (hold-last-frame, NEXT-B §3.4).
    @State private var lastShown: UIImage?

    @State private var isLoadingChapter = false
    /// D-1 (owner-approved deviation): a failed chapter resolve
    /// keeps the current chapter readable and offers Thử lại in
    /// the chapter-end bar, instead of iOS's reader-ending
    /// error screen.
    @State private var chapterError = false
    @State private var pendingTarget: Episode?

    /// D-2 (owner-approved deviation): the top chrome auto-hides
    /// after ~3 s (iOS keeps it permanently); it reappears on
    /// reader entry, on chapter change, and when the
    /// chapter-end bar closes.
    @State private var chromeVisible = true
    @State private var chromeHideTask: Task<Void, Never>?

    /// Review-gate fix (1.3.0): "land bottom-aligned when the
    /// bitmap arrives" as EXPLICIT state, replacing the old
    /// windowIndex = Int.max sentinel. True only while the
    /// current image is undecoded and the reader conceptually
    /// sits at its last window; the load completion (or a load
    /// failure, or the user stepping away) resolves it. All
    /// step arithmetic uses ordinary Ints only.
    @State private var pendingBottomAlign = false
    /// Review-gate fix (1.3.0): the chapter-resolve task is
    /// stored so onDisappear can cancel it, and `readerAlive`
    /// gates every post-await publish in resolveChapter — a
    /// dismissed reader writes no history and touches no
    /// session state.
    @State private var chapterTask: Task<Void, Never>?
    @State private var readerAlive = false

    @State private var viewportSize: CGSize = CGSize(width: 1920, height: 1080)
    @FocusState private var surfaceFocused: Bool
    @FocusState private var barFocus: BarButton?

    private enum BarButton: Hashable {
        case prev, next, retry, close, loading
    }

    init(session: TVPlayerSession, initialStream: StreamInfo) {
        self.session = session
        self.initialStream = initialStream
        let request = session.currentRequest
        _currentEpisode = State(initialValue: request.episode)
        _stream = State(initialValue: initialStream)
        _chapterList = State(initialValue: request.allEpisodes.isEmpty
                            ? [request.episode] : request.allEpisodes)
        // Resume (P-6): the saved position is an image INDEX,
        // clamped into the chapter (iOS MangaReaderView:134-139).
        let start = Int(request.startPosition)
        _imageIndex = State(initialValue: initialStream.images.isEmpty
                            ? 0 : min(max(0, start), initialStream.images.count - 1))
    }

    private var request: PlaybackRequest { session.currentRequest }

    // MARK: Chapter order (ported verbatim from iOS MangaReaderView)

    private var orderedEpisodes: [Episode] {
        var seen = Set<String>()
        let unique = chapterList.filter { seen.insert($0.id).inserted }
        let numbered = unique.map { (episode: $0, number: chapterNumber(of: $0)) }
        guard numbered.allSatisfy({ $0.number != nil }) else { return unique }
        return numbered.sorted { $0.number! < $1.number! }.map { $0.episode }
    }

    private func chapterNumber(of episode: Episode) -> Double? {
        var token = ""
        for ch in episode.name {
            if ch.isNumber || (ch == "." && !token.isEmpty) {
                token.append(ch)
            } else if !token.isEmpty {
                break
            }
        }
        return Double(token)
    }

    private var currentPosition: Int {
        orderedEpisodes.firstIndex { $0.id == currentEpisode.id } ?? 0
    }

    private var canGoPrevious: Bool { currentPosition > 0 }
    private var canGoNext: Bool { currentPosition < orderedEpisodes.count - 1 }

    private func chapLabel(for episode: Episode) -> String {
        var name = episode.name
        for prefix in ["chapter ", "chap "] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return "Chap \(name)"
    }

    private var previousChapterTitle: String {
        let idx = currentPosition - 1
        guard orderedEpisodes.indices.contains(idx) else { return "Chap trước" }
        return chapLabel(for: orderedEpisodes[idx])
    }

    private var nextChapterTitle: String {
        let idx = currentPosition + 1
        guard orderedEpisodes.indices.contains(idx) else { return "Chap sau" }
        return chapLabel(for: orderedEpisodes[idx])
    }

    private var chapterDisplayName: String {
        var name = currentEpisode.name
        for prefix in ["chapter ", "chap "] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name
    }

    // MARK: Step geometry (NEXT-B §3.2)

    /// Displayed height of an image at full viewport width.
    private func displayHeight(of image: UIImage) -> CGFloat {
        guard image.size.width > 0 else { return viewportSize.height }
        return image.size.height * (viewportSize.width / image.size.width)
    }

    /// Windows in the current image: 1 for a screen-fitting
    /// page; for a strip, one window per (screen height − 15%
    /// overlap) of remaining height, last window bottom-aligned.
    private var windowCount: Int {
        guard let image = loadedImages[imageIndex] else { return 1 }
        let dispH = displayHeight(of: image)
        let screenH = viewportSize.height
        guard dispH > screenH + 1 else { return 1 }
        let step = screenH * 0.85
        return Int(ceil((dispH - screenH) / step)) + 1
    }

    // MARK: Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pageLayer
            if chromeVisible, session.presentedPanel == nil {
                VStack {
                    topBar
                    Spacer()
                }
                .transition(.opacity)
            }
            if session.presentedPanel == .mangaChapterEnd {
                chapterEndBar
            }
            // Review-gate fix (1.3.0): the loading indicator
            // renders ABOVE the chapter-end bar's dim (it sat
            // under it before), so a chapter resolve in flight
            // is visible.
            if isLoadingChapter {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.4)
            }
            // The press surface sits over the page but under
            // nothing interactive: while the chapter-end bar is
            // presented it is removed so focus lands on the
            // bar's buttons.
            if session.presentedPanel == nil {
                TVMangaPressSurface(onForward: { stepForward() },
                                    onBack: { stepBack() })
                    .focused($surfaceFocused)
                    .ignoresSafeArea()
            }
        }
        .defaultFocus($surfaceFocused, true)
        .onAppear {
            readerAlive = true
            DiagLog.log("manga", "open images=\(stream.images.count) start=\(imageIndex)")
            saveProgress()
            showChrome()
        }
        .onDisappear {
            chromeHideTask?.cancel()
            // The reader's own designed flush (B1) — synchronous,
            // while the reader is still the live surface.
            saveProgress(force: true)
            // Review-gate fix (1.3.0): from here the reader is
            // dead — cancel the chapter task and close the
            // alive gate so no post-await publish can land.
            chapterTask?.cancel()
            chapterTask = nil
            readerAlive = false
        }
        .task { await healChapterListIfNeeded() }
        .task(id: "\(currentEpisode.id)|\(imageIndex)") {
            await loadCurrentAndWarm()
        }
        .onChange(of: imageIndex) { _, _ in
            saveProgress()
        }
        .onChange(of: session.presentedPanel) { _, panel in
            if panel == nil {
                // Bar closed (Menu arbiter or a chapter switch):
                // focus returns to the press surface, chrome
                // reappears briefly (D-2).
                surfaceFocused = true
                showChrome()
            }
        }
    }

    // MARK: Page rendering

    @ViewBuilder
    private var pageLayer: some View {
        GeometryReader { geo in
            ZStack {
                if let image = loadedImages[imageIndex] {
                    stripOrPage(image: image, size: geo.size)
                } else if failedImages.contains(imageIndex) {
                    // A dead page never traps stepping (NEXT-B
                    // §3.4): the failure tile shows, presses
                    // still move on.
                    Rectangle()
                        .fill(theme.cardFill)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 54))
                                .foregroundStyle(theme.textFaint)
                        }
                } else if let lastShown {
                    // Hold-last-frame: the previous bitmap stays
                    // up (whole, fitted) while the step target
                    // decodes — never a black flash.
                    Image(uiImage: lastShown)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { viewportSize = geo.size }
            .onChange(of: geo.size) { _, newSize in viewportSize = newSize }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func stripOrPage(image: UIImage, size: CGSize) -> some View {
        let dispH = displayHeight(of: image)
        if dispH <= size.height + 1 {
            Image(uiImage: image)
                .resizable()
                .frame(width: size.width, height: dispH)
                .frame(width: size.width, height: size.height)
        } else {
            let step = size.height * 0.85
            let maxTop = dispH - size.height
            let top = min(CGFloat(windowIndex) * step, maxTop)
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: size.width, height: dispH)
                    .offset(y: -top)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    // MARK: Chrome (D-2)

    private var topBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.movie.title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text("Chap \(chapterDisplayName) • Trang \(min(imageIndex + 1, max(stream.images.count, 1)))/\(stream.images.count) • ◂ ▸ để lật trang")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.textDim)
            }
            Spacer()
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 26)
        .background(
            LinearGradient(colors: [.black.opacity(0.78), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private func showChrome() {
        chromeVisible = true
        chromeHideTask?.cancel()
        chromeHideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            chromeVisible = false
        }
    }

    // MARK: Chapter-end bar (session panel .mangaChapterEnd)

    private var chapterEndBar: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 26) {
                Text(chapterError
                     ? "Không tải được chương này. Đang giữ chương hiện tại."
                     : "Hết chương")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 18) {
                    if isLoadingChapter {
                        // Review-gate fix (1.3.0): while a
                        // chapter resolve is in flight the bar
                        // keeps a FOCUSABLE, INERT landing, so
                        // focus is never stranded on a bar whose
                        // buttons are all disabled.
                        loadingFocusPad
                    } else {
                        barButton(.prev, title: previousChapterTitle, enabled: canGoPrevious) {
                            goToChapter(offset: -1)
                        }
                        if chapterError {
                            barButton(.retry, title: "Thử lại", enabled: pendingTarget != nil) {
                                if let pendingTarget {
                                    startChapterTask(pendingTarget)
                                }
                            }
                        }
                        barButton(.next, title: nextChapterTitle, enabled: canGoNext) {
                            goToChapter(offset: 1)
                        }
                        if !canGoPrevious && !canGoNext && !chapterError {
                            // Single-chapter title: neither
                            // direction exists, so the bar offers
                            // a focusable Đóng (closes the panel;
                            // the reader stays live underneath).
                            barButton(.close, title: "Đóng", enabled: true) {
                                session.presentedPanel = nil
                            }
                        }
                    }
                }
            }
            .padding(44)
            .frame(width: 980)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(theme.surfaceGradient))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .defaultFocus($barFocus, barDefaultFocus)
    }

    /// Review-gate fix (1.3.0): default focus is the first
    /// ENABLED target in the order Next → Retry → Prev → Đóng —
    /// never a disabled button. While loading, the inert
    /// loading pad is the landing.
    private var barDefaultFocus: BarButton {
        if isLoadingChapter { return .loading }
        if canGoNext { return .next }
        if chapterError && pendingTarget != nil { return .retry }
        if canGoPrevious { return .prev }
        return .close
    }

    /// The inert focusable landing shown while a chapter
    /// resolve is in flight: focusable, ring on focus, no
    /// action — it exists so the bar always has somewhere
    /// focus can legally sit.
    private var loadingFocusPad: some View {
        Text("Đang tải chương…")
            .font(.system(size: 27, weight: .bold))
            .foregroundStyle(theme.textDim)
            .padding(.horizontal, 40)
            .padding(.vertical, 16)
            .background(Capsule().fill(theme.cardFill))
            .overlay(Capsule().strokeBorder(
                barFocus == .loading ? theme.focusRing : .clear,
                lineWidth: barFocus == .loading ? theme.ringWidth : 0))
            .contentShape(Capsule())
            .focusable()
            .focusEffectDisabled()
            .focused($barFocus, equals: BarButton.loading)
    }

    private func barButton(_ id: BarButton, title: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        let isFocused = barFocus == id
        return Button {
            action()
        } label: {
            Text(title)
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(enabled ? theme.textPrimary : theme.textFaint)
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
                .background(Capsule().fill(enabled ? theme.cardFill : Color.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(
                    isFocused && enabled ? theme.focusRing : .clear,
                    lineWidth: isFocused && enabled ? theme.ringWidth : 0))
                .contentShape(Capsule())
        }
        .tvCardButton()
        .focused($barFocus, equals: id)
        .disabled(!enabled || isLoadingChapter)
    }

    // MARK: Stepping

    // Stepping is a total function of (imageIndex, windowIndex,
    // pendingBottomAlign) with ordinary Ints only — the old
    // Int.max sentinel is gone (review-gate fix, 1.3.0).
    // pendingBottomAlign == true means: the current image is
    // undecoded and the reader conceptually sits at its LAST
    // window (windowIndex stays 0 until the bitmap lands and
    // the completion assigns the real last window).

    private func stepForward() {
        guard !isLoadingChapter else { return }
        if pendingBottomAlign {
            // Conceptually at the bottom of an undecoded image:
            // forward leaves it for the next image's top (or
            // the chapter end). The bottom-align intent is
            // consumed by leaving.
            pendingBottomAlign = false
            if imageIndex + 1 < stream.images.count {
                imageIndex += 1
                windowIndex = 0
            } else {
                session.presentedPanel = .mangaChapterEnd
            }
            return
        }
        if windowIndex + 1 < windowCount {
            windowIndex += 1
        } else if imageIndex + 1 < stream.images.count {
            imageIndex += 1
            windowIndex = 0
        } else {
            // Chapter end: no auto-advance (iOS requires an
            // explicit pill tap, P-8) — present the bar as a
            // session panel so Menu closes it first (FL-048).
            session.presentedPanel = .mangaChapterEnd
        }
    }

    private func stepBack() {
        guard !isLoadingChapter else { return }
        if pendingBottomAlign {
            // Conceptually at the bottom of an undecoded image:
            // back leaves it for the previous image's bottom.
            if imageIndex > 0 {
                moveToPreviousImageBottom()
            }
            return
        }
        if windowIndex > 0 {
            windowIndex -= 1
        } else if imageIndex > 0 {
            moveToPreviousImageBottom()
        }
    }

    /// Lands on the previous image's last window: immediately
    /// when its bitmap is already decoded; otherwise as a
    /// pending bottom-align intent the load completion (or a
    /// load failure, which clears it) resolves.
    private func moveToPreviousImageBottom() {
        imageIndex -= 1
        windowIndex = 0
        if loadedImages[imageIndex] != nil {
            windowIndex = windowCount - 1
            pendingBottomAlign = false
        } else {
            pendingBottomAlign = true
        }
    }

    // MARK: Image loading + prefetch (NEXT-B §3.4)

    /// Loads the current image at bucket 1920, then warms the
    /// next one at the same bucket and prefetches the next 3
    /// (iOS's window, P-4) with the chapter headers. A load
    /// failure marks the image failed but never traps stepping.
    private func loadCurrentAndWarm() async {
        // Review-gate fix (1.3.0): every post-await mutation is
        // guarded — the task must not be cancelled AND the
        // captured (episodeId, idx) must still be the reader's
        // current position. A superseded completion writes
        // NOTHING (no loadedImages/failedImages/lastShown
        // writes, no eviction).
        let episodeId = currentEpisode.id
        let idx = imageIndex
        let images = stream.images
        let headers = stream.headers
        guard images.indices.contains(idx) else { return }
        func stillCurrent() -> Bool {
            !Task.isCancelled && currentEpisode.id == episodeId && imageIndex == idx
        }
        if loadedImages[idx] == nil {
            let image = await ImageCacheManager.shared.loadImage(
                urlString: images[idx], headers: headers, bucket: 1920)
            guard stillCurrent() else { return }
            if let image {
                loadedImages[idx] = image
                lastShown = image
                if pendingBottomAlign {
                    // The bitmap landed: assign the real last
                    // window and consume the intent.
                    windowIndex = windowCount - 1
                    pendingBottomAlign = false
                }
            } else {
                failedImages.insert(idx)
                // A failed load also clears the pending
                // bottom-align intent (ordinary state, no
                // sentinel left behind).
                if pendingBottomAlign { pendingBottomAlign = false }
            }
        } else {
            lastShown = loadedImages[idx]
        }
        // Evict far bitmaps (R-1 memory discipline).
        loadedImages = loadedImages.filter { abs($0.key - idx) <= 2 }
        // Prefetch the next 3 with the chapter headers (P-4)…
        let upcoming = Array(images.dropFirst(idx + 1).prefix(3))
        if !upcoming.isEmpty {
            ImageCacheManager.shared.prefetch(urlStrings: upcoming, headers: headers)
        }
        // …and warm image+1 directly at bucket 1920 so the next
        // step's bitmap is memory-warm, not just disk-warm. Its
        // write is guarded the same way.
        let next = idx + 1
        if images.indices.contains(next), loadedImages[next] == nil {
            let image = await ImageCacheManager.shared.loadImage(
                urlString: images[next], headers: headers, bucket: 1920)
            guard stillCurrent() else { return }
            if let image {
                loadedImages[next] = image
            }
        }
    }

    // MARK: Chapter switch (inside the reader — NEXT-B §3.5)

    private func goToChapter(offset: Int) {
        let target = currentPosition + offset
        guard orderedEpisodes.indices.contains(target) else { return }
        startChapterTask(orderedEpisodes[target])
    }

    /// Review-gate fix (1.3.0): the chapter-resolve task is
    /// stored in @State (a new tap supersedes the old one) and
    /// cancelled in onDisappear.
    private func startChapterTask(_ episode: Episode) {
        chapterTask?.cancel()
        chapterTask = Task { await resolveChapter(episode) }
    }

    private func resolveChapter(_ episode: Episode) async {
        pendingTarget = episode
        isLoadingChapter = true
        do {
            let resolved = try await session.mangaService.resolveMangaChapter(
                pluginId: request.pluginId, episode: episode)
            // Review-gate fix (1.3.0): a dismissed or superseded
            // reader publishes NOTHING — no state mutation, no
            // history write, no session-panel or chrome touch.
            guard readerAlive, !Task.isCancelled else { return }
            isLoadingChapter = false
            let from = currentEpisode.name
            currentEpisode = episode
            stream = resolved
            imageIndex = 0
            windowIndex = 0
            pendingBottomAlign = false
            loadedImages = [:]
            failedImages = []
            chapterError = false
            pendingTarget = nil
            session.presentedPanel = nil
            saveProgress(force: true)
            showChrome()
            DiagLog.log("manga", "chapter from=\(from) to=\(episode.name) images=\(resolved.images.count)")
        } catch {
            guard readerAlive, !Task.isCancelled else { return }
            isLoadingChapter = false
            // D-1: keep the current chapter; the bar (already
            // presented) gains the Thử lại affordance.
            chapterError = true
            session.presentedPanel = .mangaChapterEnd
            DiagLog.log("manga", "fail stage=resolve-chapter error=\(TVPlayerSession.errorLabel(error))")
        }
    }

    // MARK: Chapter-list heal (ported from iOS MangaReaderView, P-10)

    private func healChapterListIfNeeded() async {
        let service = session.mangaService
        let movie = request.movie
        let containsCurrent = chapterList.contains { $0.id == currentEpisode.id }
        guard chapterList.count <= 1 || !containsCurrent else { return }
        var detail = (try? await service.detail(pluginId: request.pluginId, movieId: movie.id))?.detail
        if (detail?.servers.flatMap { $0.episodes }.count ?? 0) <= chapterList.count,
           let page = try? await service.search(pluginId: request.pluginId, keyword: movie.title, page: 1),
           !page.items.isEmpty {
            let wanted = movie.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let found = page.items.first {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
            } ?? (movie.id.isEmpty ? page.items[0] : nil)
            if let found, !found.id.isEmpty,
               let healed = try? await service.detail(pluginId: request.pluginId, movieId: found.id) {
                detail = healed.detail
            }
        }
        guard let detail else { return }
        // Gate fix pass (Round 1 on R2, Lens 2 F4): the final
        // publish below — and its heal log line — get the same
        // alive/cancellation guard as resolveChapter's paths:
        // a reader dismissed mid-heal writes nothing.
        guard readerAlive, !Task.isCancelled else { return }
        let server = detail.servers.first { $0.name == request.serverName }
            ?? detail.servers.first { srv in srv.episodes.contains { $0.id == currentEpisode.id } }
            ?? detail.servers.max { $0.episodes.count < $1.episodes.count }
        if let server, server.episodes.count > chapterList.count {
            chapterList = server.episodes
            DiagLog.log("manga", "heal chapters=\(server.episodes.count)")
        }
    }

    // MARK: History (the reader's own records — NEXT-B §3.6)

    /// The iOS record shape verbatim (MangaReaderView:296-313):
    /// isManga, lastPosition = image index, duration = image
    /// count, streamURL = "". Written on imageIndex change and
    /// force-written on disappear (the session's flushHistory
    /// is seconds-shaped and must never see manga indices).
    private func saveProgress(force: Bool = false) {
        let record = HistoryRecord(
            pluginId: request.pluginId,
            pluginName: request.pluginName,
            isManga: true,
            movie: request.movie,
            serverName: request.serverName,
            episodeName: currentEpisode.name,
            episodeId: currentEpisode.id,
            streamURL: "",
            lastPosition: Double(imageIndex),
            duration: Double(max(stream.images.count, 1)),
            updatedAt: Date())
        session.mangaHistory.upsert(record, force: force)
    }
}

// MARK: - Press surface (KS-host pattern, NEXT-B §3.3)

/// One focusable UIKit view owning the reader's presses.
/// Handled presses do not call super (FL-040 one-owner
/// discipline); Menu is deliberately never handled, so it
/// propagates to the cover's single Menu arbiter (FL-048).
private struct TVMangaPressSurface: UIViewRepresentable {
    let onForward: () -> Void
    let onBack: () -> Void

    func makeUIView(context: Context) -> TVMangaPressView {
        let view = TVMangaPressView()
        view.onForward = onForward
        view.onBack = onBack
        return view
    }

    func updateUIView(_ uiView: TVMangaPressView, context: Context) {
        uiView.onForward = onForward
        uiView.onBack = onBack
    }
}

private final class TVMangaPressView: UIView {
    var onForward: (() -> Void)?
    var onBack: (() -> Void)?

    override var canBecomeFocused: Bool { true }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            switch press.type {
            case .rightArrow, .downArrow, .select, .playPause:
                onForward?()
                handled = true
            case .leftArrow, .upArrow:
                onBack?()
                handled = true
            case .menu:
                // Never handled here — Menu propagates to the
                // shell's Menu arbitration (FL-048).
                break
            default:
                break
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }
}
