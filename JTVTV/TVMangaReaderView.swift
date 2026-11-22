import SwiftUI
import UIKit

/// JTV tvOS manga reader — PAGE MODE (1.3.2 staging, L-T18 /
/// FL-394). Rebuilt from the 1.3.0 stepped-window reader after
/// the owner's device verdict: "Nó hiện là hiển thị dạng cột
/// trang truyện như trên điện thoại nên 1 trang truyện nó sẽ
/// ko kéo đủ trên màn hình tv." The 1.3.0 reader never actually
/// cut anything — it rendered the whole strip as ONE image
/// ~26,667 pt tall and jumped an offset (29 windows per strip,
/// ~320–380 presses per chapter). The owner approved the
/// page-mode proposal verbatim ("Làm theo cách chia trang đó").
///
/// Reading model (page mode): sayhentai "pages" are intact
/// long strips (~720×10,000 px). At chapter load each decoded
/// strip is SLICED into segments whose aspect matches the TV
/// screen exactly, so every segment is one full-screen PAGE.
/// Reading is discrete page turns: one press = one page.
/// A background indexing pass measures every strip in the
/// chapter (segment counts only — bitmaps are not retained
/// beyond the reading window) so the indicator can show the
/// page position across the whole chapter.
///
/// It is a CHILD of the player session: dependencies arrive
/// as values (the session itself — no @EnvironmentObject
/// inside the cover subtree, L-T06 rule), chapter state lives
/// here, and chapter switches resolve INSIDE the reader
/// through `MovieService.resolveMangaChapter` — never through
/// session.beginAttempt/switchSource (attempt churn would
/// reset the cover per chapter, NEXT-B §2.1).
///
/// Input (KS-host precedent): ONE focusable UIKit press
/// surface. Right/Down/Select/PlayPause = forward, Left/Up =
/// back, Menu is NEVER handled here — the cover's single Menu
/// arbiter (FL-048) owns it, and the chapter-end bar is a
/// session panel (`.mangaChapterEnd`) so the arbiter closes
/// it first, exactly like the other panels. Paging back from
/// page 1 of a chapter loads the previous chapter and lands
/// on its LAST page.
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
    /// Page-mode position: the segment (page) within the
    /// current strip. A chapter position is the pair
    /// (imageIndex, segmentIndex); the flat page number is
    /// derived from `segmentCounts`.
    @State private var segmentIndex: Int = 0

    /// Pages per strip, filled as strips decode (position
    /// loads + the background indexing pass). A failed strip
    /// counts as exactly 1 page (its failure tile).
    @State private var segmentCounts: [Int: Int] = [:]
    /// Cropped page bitmaps near the reading position.
    /// Crops share the source strip's pixel data; the cache
    /// is evicted with the ±2 strip window (NEXT-B R-1
    /// memory discipline).
    @State private var pageCache: [String: UIImage] = [:]

    /// Decoded bitmaps near the reading position (current ±2).
    /// Bounded deliberately (NEXT-B R-1: one strip decodes to
    /// ~28.8 MB; the memory cache is 48–120 MB shared).
    @State private var loadedImages: [Int: UIImage] = [:]
    @State private var failedImages: Set<Int> = []
    /// The last PAGE actually shown — held on screen while
    /// the next page's strip decodes (hold-last-frame,
    /// NEXT-B §3.4). Page mode holds the last page crop,
    /// never the whole strip fitted into the screen.
    @State private var lastShownPage: UIImage?

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

    /// Back-stepping into a strip whose segment count is not
    /// known yet (never decoded, indexer has not reached it):
    /// the intent to land on its LAST page, resolved by the
    /// load completion the moment the count exists. Ordinary
    /// state — no sentinel arithmetic anywhere.
    @State private var landOnLastSegment = false
    /// The chapter-resolve task is stored so onDisappear can
    /// cancel it, and `readerAlive` gates every post-await
    /// publish in resolveChapter — a dismissed reader writes
    /// no history and touches no session state (1.3.0 gate fix,
    /// kept verbatim in the page-mode rebuild).
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
        // clamped into the chapter (iOS MangaReaderView:134-139);
        // page mode lands on that strip's first page.
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

    // MARK: Page geometry (page mode)

    /// Height in PIXELS of one page segment of a strip: the
    /// segment's aspect matches the viewport aspect exactly,
    /// so a full segment fills the screen with no letterbox.
    private func segmentPixelHeight(for image: UIImage) -> Int {
        guard let cg = image.cgImage, cg.width > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        let h = Int((Double(cg.width) * Double(viewportSize.height)
                     / Double(viewportSize.width)).rounded())
        return max(1, h)
    }

    /// Pages in one decoded strip: 1 for a screen-fitting
    /// image, ceil(height / segment height) for a strip.
    private func segmentCount(for image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        let segH = segmentPixelHeight(for: image)
        guard segH > 0 else { return 1 }
        return max(1, (cg.height + segH - 1) / segH)
    }

    /// Known page count of a strip (nil while unmeasured).
    private func knownCount(at idx: Int) -> Int? {
        if let image = loadedImages[idx] { return segmentCount(for: image) }
        return segmentCounts[idx]
    }

    /// Total pages in the chapter once every strip is
    /// measured; nil while the indexing pass is incomplete.
    private var totalPages: Int? {
        guard segmentCounts.count == stream.images.count else { return nil }
        return segmentCounts.values.reduce(0, +)
    }

    /// Flat 1-based page number of the current position
    /// across the chapter; nil while an earlier strip is
    /// still unmeasured.
    private var flatPageNumber: Int? {
        var sum = segmentIndex + 1
        for idx in 0..<imageIndex {
            guard let count = segmentCounts[idx] else { return nil }
            sum += count
        }
        return sum
    }

    private var pageIndicatorText: String {
        if let flat = flatPageNumber, let total = totalPages {
            return "Trang \(flat)/\(total)"
        }
        if let count = knownCount(at: imageIndex) {
            return "Trang \(segmentIndex + 1)/\(count) • Ảnh \(imageIndex + 1)/\(max(stream.images.count, 1))"
        }
        return "Ảnh \(imageIndex + 1)/\(max(stream.images.count, 1))"
    }

    /// The current page's bitmap: a crop of the current
    /// strip, cached per (strip, segment). Cropping shares
    /// the strip's pixel data — no re-encode, no copy of the
    /// full bitmap. READ-ONLY: this is called from the view
    /// body, so it never writes state — the load task stores
    /// crops into `pageCache` explicitly (storePage).
    private func pageImage(at idx: Int, segment: Int) -> UIImage? {
        let key = "\(idx):\(segment)"
        if let hit = pageCache[key] { return hit }
        guard let image = loadedImages[idx], let cg = image.cgImage else { return nil }
        let segH = segmentPixelHeight(for: image)
        let y = segment * segH
        guard y < cg.height else { return nil }
        let rect = CGRect(x: 0, y: y, width: cg.width,
                          height: min(segH, cg.height - y))
        guard let crop = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: crop, scale: image.scale,
                       orientation: image.imageOrientation)
    }

    /// Stores the (idx, segment) crop into the page cache
    /// and returns it — called only from load tasks, never
    /// from the view body.
    private func storePage(at idx: Int, segment: Int) -> UIImage? {
        guard let page = pageImage(at: idx, segment: segment) else { return nil }
        pageCache["\(idx):\(segment)"] = page
        return page
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
            // The loading indicator renders ABOVE the
            // chapter-end bar's dim, so a chapter resolve in
            // flight is visible (1.3.0 gate fix, kept).
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
            // From here the reader is dead — cancel the chapter
            // task and close the alive gate so no post-await
            // publish can land (1.3.0 gate fix, kept).
            chapterTask?.cancel()
            chapterTask = nil
            readerAlive = false
        }
        .task { await healChapterListIfNeeded() }
        .task(id: currentEpisode.id) {
            await indexChapterSizes()
        }
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
                if let page = pageImage(at: imageIndex, segment: segmentIndex) {
                    // One page, full width. A full segment's
                    // aspect IS the screen aspect, so it fills
                    // the screen exactly; the tail segment of a
                    // strip is shorter and centres on black.
                    Image(uiImage: page)
                        .resizable()
                        .frame(width: geo.size.width,
                               height: geo.size.width * page.size.height
                                   / max(page.size.width, 1))
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if failedImages.contains(imageIndex) {
                    // A dead page never traps paging (NEXT-B
                    // §3.4): the failure tile shows, presses
                    // still move on.
                    Rectangle()
                        .fill(theme.cardFill)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 54))
                                .foregroundStyle(theme.textFaint)
                        }
                } else if let lastShownPage {
                    // Hold-last-frame: the previous PAGE stays
                    // up (full width, as a page) while the
                    // target strip decodes — never a black
                    // flash, never the whole strip fitted in.
                    Image(uiImage: lastShownPage)
                        .resizable()
                        .frame(width: geo.size.width,
                               height: geo.size.width * lastShownPage.size.height
                                   / max(lastShownPage.size.width, 1))
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { viewportSize = geo.size }
            .onChange(of: geo.size) { _, newSize in
                // Segment geometry is derived from the viewport
                // aspect; a real change invalidates every
                // measured count and crop (in practice the TV
                // viewport is constant 1920×1080).
                if newSize.width > 0, newSize.height > 0,
                   abs(newSize.width / newSize.height
                       - viewportSize.width / max(viewportSize.height, 1)) > 0.001 {
                    segmentCounts = [:]
                    pageCache = [:]
                    segmentIndex = 0
                    Task { await indexChapterSizes() }
                }
                viewportSize = newSize
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Chrome (D-2)

    private var topBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.movie.title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text("Chap \(chapterDisplayName) • \(pageIndicatorText) • ◂ ▸ để lật trang")
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
                        // While a chapter resolve is in flight
                        // the bar keeps a FOCUSABLE, INERT
                        // landing, so focus is never stranded
                        // on a bar whose buttons are all
                        // disabled (1.3.0 gate fix, kept).
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

    /// Default focus is the first ENABLED target in the order
    /// Next → Retry → Prev → Đóng — never a disabled button.
    /// While loading, the inert loading pad is the landing.
    /// (1.3.0 gate fix, kept verbatim.)
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

    // MARK: Paging

    // Paging is a total function of (imageIndex, segmentIndex,
    // landOnLastSegment) with ordinary Ints only. While the
    // current strip is neither decoded nor failed, presses
    // are ignored — the hold/spinner surface is up and the
    // decode lands momentarily (prefetch keeps it warm).

    private func stepForward() {
        guard !isLoadingChapter else { return }
        guard loadedImages[imageIndex] != nil || failedImages.contains(imageIndex)
        else { return }
        if segmentIndex + 1 < (knownCount(at: imageIndex) ?? 1) {
            segmentIndex += 1
        } else if imageIndex + 1 < stream.images.count {
            imageIndex += 1
            segmentIndex = 0
        } else {
            // Chapter end: no auto-advance (iOS requires an
            // explicit pill tap, P-8) — present the bar as a
            // session panel so Menu closes it first (FL-048).
            session.presentedPanel = .mangaChapterEnd
        }
    }

    private func stepBack() {
        guard !isLoadingChapter else { return }
        guard loadedImages[imageIndex] != nil || failedImages.contains(imageIndex)
        else { return }
        if segmentIndex > 0 {
            segmentIndex -= 1
        } else if imageIndex > 0 {
            moveToPreviousStripLastPage()
        } else if canGoPrevious {
            // Page 1 of the chapter: paging up crosses into
            // the previous chapter and lands on its LAST page
            // (owner-approved page-mode behaviour, L-T18).
            let target = orderedEpisodes[currentPosition - 1]
            startChapterTask(target, landAtEnd: true)
        }
    }

    /// Lands on the previous strip's last page: immediately
    /// when its count is already known; otherwise as a
    /// pending last-page intent the load completion resolves
    /// the moment the strip decodes.
    private func moveToPreviousStripLastPage() {
        imageIndex -= 1
        segmentIndex = 0
        if let count = knownCount(at: imageIndex) {
            segmentIndex = count - 1
            landOnLastSegment = false
        } else {
            landOnLastSegment = true
        }
    }

    // MARK: Image loading + prefetch (NEXT-B §3.4)

    /// Loads the current strip at bucket 1920, records its
    /// page count, resolves a pending last-page landing, then
    /// warms the next strip at the same bucket and prefetches
    /// the next 3 (iOS's window, P-4) with the chapter
    /// headers. A load failure marks the strip failed (one
    /// page: its tile) but never traps paging.
    private func loadCurrentAndWarm() async {
        // Every post-await mutation is guarded — the task
        // must not be cancelled AND the captured (episodeId,
        // idx) must still be the reader's current position.
        // A superseded completion writes NOTHING (1.3.0 gate
        // fix, kept).
        let episodeId = currentEpisode.id
        let idx = imageIndex
        let images = stream.images
        let headers = stream.headers
        guard images.indices.contains(idx) else { return }
        func stillCurrent() -> Bool {
            !Task.isCancelled && currentEpisode.id == episodeId && imageIndex == idx
        }
        if loadedImages[idx] == nil && !failedImages.contains(idx) {
            let image = await ImageCacheManager.shared.loadImage(
                urlString: images[idx], headers: headers, bucket: 1920)
            guard stillCurrent() else { return }
            if let image {
                loadedImages[idx] = image
                segmentCounts[idx] = segmentCount(for: image)
                if landOnLastSegment {
                    segmentIndex = (segmentCounts[idx] ?? 1) - 1
                    landOnLastSegment = false
                }
                if let count = segmentCounts[idx], segmentIndex >= count {
                    segmentIndex = count - 1
                }
                if let page = storePage(at: idx, segment: segmentIndex) {
                    lastShownPage = page
                }
            } else {
                failedImages.insert(idx)
                segmentCounts[idx] = 1
                segmentIndex = 0
                landOnLastSegment = false
            }
        } else if loadedImages[idx] != nil {
            if segmentCounts[idx] == nil, let image = loadedImages[idx] {
                segmentCounts[idx] = segmentCount(for: image)
            }
            if let page = storePage(at: idx, segment: segmentIndex) {
                lastShownPage = page
            }
        }
        // Evict far bitmaps + their crops (R-1 discipline).
        loadedImages = loadedImages.filter { abs($0.key - idx) <= 2 }
        pageCache = pageCache.filter { entry in
            guard let strip = Int(entry.key.split(separator: ":").first ?? "") else { return false }
            return abs(strip - idx) <= 2
        }
        // Prefetch the next 3 with the chapter headers (P-4)…
        let upcoming = Array(images.dropFirst(idx + 1).prefix(3))
        if !upcoming.isEmpty {
            ImageCacheManager.shared.prefetch(urlStrings: upcoming, headers: headers)
        }
        // …and warm image+1 directly at bucket 1920 so the
        // next strip's bitmap is memory-warm, not just
        // disk-warm; its page count is recorded on the way.
        let next = idx + 1
        if images.indices.contains(next), loadedImages[next] == nil,
           !failedImages.contains(next) {
            let image = await ImageCacheManager.shared.loadImage(
                urlString: images[next], headers: headers, bucket: 1920)
            guard stillCurrent() else { return }
            if let image {
                loadedImages[next] = image
                if segmentCounts[next] == nil {
                    segmentCounts[next] = segmentCount(for: image)
                }
            }
        }
    }

    /// Background indexing pass: measures every strip in the
    /// chapter ONCE (through the same bucket-1920 pipeline —
    /// in-flight loads dedupe inside the pipeline, and the
    /// disk tier makes later reads cheap) and records only
    /// the page COUNT. Bitmaps are never retained here; the
    /// reading window (±2) is owned by loadCurrentAndWarm.
    /// Runs sequentially so a chapter never bursts.
    private func indexChapterSizes() async {
        let episodeId = currentEpisode.id
        let images = stream.images
        let headers = stream.headers
        for idx in images.indices {
            if Task.isCancelled || !readerAlive || currentEpisode.id != episodeId { return }
            if segmentCounts[idx] != nil { continue }
            if failedImages.contains(idx) {
                segmentCounts[idx] = 1
                continue
            }
            if let image = loadedImages[idx] {
                segmentCounts[idx] = segmentCount(for: image)
                continue
            }
            let image = await ImageCacheManager.shared.loadImage(
                urlString: images[idx], headers: headers, bucket: 1920)
            guard !Task.isCancelled, readerAlive, currentEpisode.id == episodeId
            else { return }
            if let image {
                segmentCounts[idx] = segmentCount(for: image)
            } else {
                failedImages.insert(idx)
                segmentCounts[idx] = 1
            }
        }
        if currentEpisode.id == episodeId, let total = totalPages {
            DiagLog.log("manga", "indexed images=\(images.count) pages=\(total)")
        }
    }

    // MARK: Chapter switch (inside the reader — NEXT-B §3.5)

    private func goToChapter(offset: Int) {
        let target = currentPosition + offset
        guard orderedEpisodes.indices.contains(target) else { return }
        startChapterTask(orderedEpisodes[target])
    }

    /// The chapter-resolve task is stored in @State (a new
    /// tap supersedes the old one) and cancelled in
    /// onDisappear (1.3.0 gate fix, kept).
    private func startChapterTask(_ episode: Episode, landAtEnd: Bool = false) {
        chapterTask?.cancel()
        chapterTask = Task { await resolveChapter(episode, landAtEnd: landAtEnd) }
    }

    private func resolveChapter(_ episode: Episode, landAtEnd: Bool = false) async {
        pendingTarget = episode
        isLoadingChapter = true
        do {
            let resolved = try await session.mangaService.resolveMangaChapter(
                pluginId: request.pluginId, episode: episode)
            // A dismissed or superseded reader publishes
            // NOTHING — no state mutation, no history write,
            // no session-panel or chrome touch (1.3.0 gate
            // fix, kept).
            guard readerAlive, !Task.isCancelled else { return }
            let from = currentEpisode.name
            currentEpisode = episode
            stream = resolved
            imageIndex = 0
            segmentIndex = 0
            landOnLastSegment = false
            loadedImages = [:]
            failedImages = []
            segmentCounts = [:]
            pageCache = [:]
            lastShownPage = nil
            chapterError = false
            pendingTarget = nil
            session.presentedPanel = nil
            if landAtEnd {
                // Page-mode chapter crossing (L-T18): measure
                // the whole chapter first, then land on its
                // very last page. isLoadingChapter stays up
                // (paging is gated) until the landing is set.
                await indexChapterSizes()
                guard readerAlive, !Task.isCancelled,
                      currentEpisode.id == episode.id else { return }
                if !resolved.images.isEmpty {
                    imageIndex = resolved.images.count - 1
                    segmentIndex = (segmentCounts[imageIndex] ?? 1) - 1
                }
            }
            isLoadingChapter = false
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
        // The final publish — and its heal log line — get the
        // same alive/cancellation guard as resolveChapter's
        // paths: a reader dismissed mid-heal writes nothing
        // (gate fix, kept).
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
    /// Page mode keeps this shape: resume lands on the saved
    /// strip's first page.
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
