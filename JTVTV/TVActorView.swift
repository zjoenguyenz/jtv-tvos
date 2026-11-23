import SwiftUI

/// JTV tvOS Phase 2 (1.3.5) — the actor filmography screen
/// (L-T26), built to the approved drawing
/// (phase2-actor/PREVIEW-actor-tvos.png): actor header with
/// the no-photo initial-letter slot, the source's own film
/// grid on the left (3 × TVPosterCard 240 in a clipped 596
/// viewport), and the focused film's trailer in the fixed
/// 928×522 frame beside the list. tvOS-native throughout:
/// remote focus only, the SwiftUI focus kit renders focus
/// (element-level focus + focus sections + a focus scope —
/// no hand-drawn focus geometry), Menu is this surface's own
/// arbiter.
///
/// Data: an actor route is a category-shaped slug, so the
/// list rides the same MovieService.list surface TVBrowseView
/// uses, with TVBrowseView's generation-guarded reload /
/// load-more discipline. No fetch machinery is touched.
///
/// Preview: focus-dwell 1.5 s (JTV Detail's own value), one
/// attempt per dwell, the attempt dies on any focus move
/// (the .task identity is the focused film + epoch), and the
/// probe is the ONE implementation Detail uses
/// (TVPreviewProbe) — plus the list-item previewUrl fast
/// path for the plugins that emit one (missav / njav), under
/// the same declared + measured ≥720p gates. The Play latch
/// carries over: opening a film latches the preview off
/// behind the pushed Detail; returning re-arms it for the
/// newly current dwell.
///
/// Back (B-1, owner ruling 2026-11-22 15:56): this screen
/// pops ONE level (to its origin Detail); a film Detail
/// opened from here pops back HERE first (its arbiter reads
/// the route beneath it), and the origin Detail's own
/// arbiter completes the chain to the root.
struct TVActorView: View {
    let pluginId: String
    let name: String
    let route: String

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var favorites: FavoritesManager
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var session: PinSession
    @Environment(\.tvTheme) private var theme
    @Environment(TVNavPath.self) private var nav

    @State private var items: [Movie] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var didLoad = false
    @State private var loadGeneration = 0

    // Focus-dwell preview state (Detail's discipline, scoped
    // to the focused film instead of the page).
    @State private var focusedMovie: Movie?
    @State private var previewStream: StreamInfo?
    @State private var previewGeneration = 0
    @State private var previewEpoch = 0
    @State private var previewVisible = false
    @State private var previewPlaying = false
    @State private var previewNoTrailer = false
    @State private var previewLatched = false
    @AppStorage(TVPreviewSettings.defaultsKey) private var previewEnabled = true

    @Namespace private var focusNS

    private var pluginName: String {
        plugins.installedPlugin(id: pluginId)?.manifest.name ?? pluginId
    }

    private var focusedIndex: Int {
        guard let focusedMovie else { return 0 }
        return items.firstIndex { $0.id == focusedMovie.id } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBand
                .padding(.top, 56)
            Spacer().frame(height: 50)
            HStack(alignment: .top, spacing: 64) {
                leftColumn
                    .frame(width: 768)
                // Drawing: the trailer column starts 8 pt
                // below the section-title line (eyebrow top
                // 336 vs 328) — without this offset the
                // preview frame lands at 378 instead of its
                // drawn 386, and the frame title/meta shift
                // up by the same 8.
                rightColumn
                    .frame(width: 928)
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusScope(focusNS)
        .tvThemedBackground()
        .onAppear {
            session.touch()
            // Returning from a film's Detail: the latch did
            // its job behind the cover — release it and bump
            // the epoch so a fresh dwell can arm for the
            // currently focused card.
            if previewLatched {
                previewLatched = false
                previewEpoch += 1
            }
        }
        .onDisappear {
            // Cancel the dwell/probe (epoch is in its .task
            // identity) and drop the stream: the preview host
            // dismantles and tears its player down.
            previewEpoch += 1
            previewStream = nil
        }
        .task { if !didLoad { await reload() } }
        .task(id: dwellTaskKey) { await runDwell() }
        .onChange(of: focusedMovie?.id) { _, _ in
            // A new focus owner retires the previous film's
            // preview in the same update: the frame falls back
            // to the newly focused film's still while its own
            // dwell runs.
            previewStream = nil
            previewVisible = false
            previewPlaying = false
            previewNoTrailer = false
        }
        // B-1: the actor screen's own Menu step is ONE pop —
        // back to the origin Detail, whose arbiter then owns
        // the next press (its pop-to-root completes the
        // chain actor → origin Detail → menu root).
        .onExitCommand {
            DiagLog.log("menu", "back-one surface=actor plugin=\(pluginId)")
            nav.pop()
        }
    }

    // MARK: Header (drawing: slot 158×222, eyebrow, name,
    // meta, hint; source chip top-right)

    private var headerBand: some View {
        HStack(alignment: .top, spacing: 32) {
            portraitSlot
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("DIỄN VIÊN")
                        .foregroundStyle(theme.accentSoft)
                    Text("·")
                        .foregroundStyle(theme.textFaint)
                    Text("NGUỒN \(pluginName.uppercased())")
                        .foregroundStyle(theme.textFaint)
                }
                .font(.system(size: 17, weight: .bold))
                .tracking(4)
                .padding(.top, 22)
                Text(name)
                    .font(.system(size: 66, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 10)
                metaLine
                    .padding(.top, 26)
                Text("Giữ yên trên một thẻ để xem trailer · Bấm OK để mở phim")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.textFaint)
                    .padding(.top, 14)
            }
            Spacer(minLength: 0)
            sourceChip
                .padding(.top, 8)
        }
        .frame(height: 222)
    }

    /// The no-photo header slot (the default — almost no JTV
    /// source supplies a portrait): the actor's initial over
    /// the Ultra poster-slot colour, exactly as drawn. A fake
    /// photo is never substituted (plan §2.4).
    private var portraitSlot: some View {
        VStack(spacing: 14) {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 76, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.45))
            Text("KHÔNG CÓ ẢNH")
                .font(.system(size: 14, weight: .semibold))
                .tracking(2.5)
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .frame(width: 158, height: 222)
        .background(RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous)
            .fill(theme.isUltra ? Color(red: 0.149, green: 0.149, blue: 0.169) : theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }

    @ViewBuilder
    private var metaLine: some View {
        if didLoad {
            HStack(spacing: 0) {
                Text("\(items.count) phim trong danh sách")
                    .foregroundStyle(theme.textPrimary)
                Text(" · sắp theo thứ tự nguồn trả về")
                    .foregroundStyle(theme.textDim)
            }
            .font(.system(size: 26))
        } else if loadError != nil {
            Text("Không tải được danh sách phim")
                .font(.system(size: 26))
                .foregroundStyle(theme.textPrimary)
        } else {
            Text("Đang tải danh sách…")
                .font(.system(size: 26))
                .foregroundStyle(theme.textPrimary)
        }
    }

    private var sourceChip: some View {
        HStack(spacing: 8) {
            Text("Nguồn")
                .foregroundStyle(theme.textPrimary)
            Text(pluginName)
                .fontWeight(.bold)
                .foregroundStyle(theme.heroMeta)
        }
        .font(.system(size: 24, weight: .semibold))
        .padding(.horizontal, 26)
        .padding(.vertical, 13)
        .background(Capsule().fill(theme.cardFill))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1.5))
    }

    // MARK: Left column — section row, grid, bottom hint

    private var isEmptyResult: Bool { didLoad && loadError == nil && items.isEmpty }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionRow
            Spacer().frame(height: 22)
            gridZone
                .frame(height: 596)
            Spacer().frame(height: 14)
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 768, height: 1)
            Spacer().frame(height: 16)
            Text("↑↓←→ Duyệt danh sách · OK Mở chi tiết · Menu Quay lại")
                .font(.system(size: 20))
                .foregroundStyle(theme.textFaint)
        }
    }

    private var sectionRow: some View {
        HStack(alignment: .center, spacing: 16) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(theme.accent)
                .frame(width: 6, height: 36)
            Text(isEmptyResult ? "Chưa có dữ liệu phim" : "Phim có \(name)")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !items.isEmpty {
                Text(String(format: "%02d / %02d", focusedIndex + 1, items.count))
                    .font(.system(size: 20))
                    .tracking(1)
                    .foregroundStyle(theme.textFaint)
            }
        }
    }

    @ViewBuilder
    private var gridZone: some View {
        if isLoading && items.isEmpty {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, items.isEmpty {
            // Audit P-4: the actor grid's failure uses the
            // shared error surface with the A-9 default-focus
            // opt-in, so the retry is the landing focus.
            TVErrorState(message: loadError, onRetry: { Task { await reload() } },
                         retryIsDefaultFocus: true)
        } else if isEmptyResult {
            // Plan §3: the trailer zone hides and a focusable
            // Quay lại chip holds the initial focus (Menu also
            // exits — this surface's arbiter).
            HStack {
                TVChip(title: "Quay lại", selected: false) { nav.pop() }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .focusSection()
            .prefersDefaultFocus(true, in: focusNS)
        } else {
            ScrollView {
                VStack(spacing: 28) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(240), spacing: 24), count: 3),
                              spacing: 44) {
                        ForEach(items) { movie in
                            TVGridPosterCell(
                                movie: movie,
                                width: 240,
                                isFavorite: favorites.isFavorite(pluginId: pluginId, movieId: movie.id),
                                onSelect: { openFilm(movie) },
                                onLongPress: { favorites.toggle(pluginId: pluginId, movie: movie) },
                                onFocusChange: { focused in
                                    if focused { focusedMovie = movie }
                                },
                                selectOnImageFailure: true
                            )
                        }
                    }
                    if isLoadingMore {
                        ProgressView()
                            .tint(.white)
                            .padding(.vertical, 8)
                    }
                    // Bottom sentinel: load-more hangs on the
                    // scroll position (FL-234), guarded by the
                    // loader's own page state.
                    Color.clear
                        .frame(height: 8)
                        .onAppear { Task { await loadMore() } }
                }
            }
            .clipped()
            .focusSection()
            .prefersDefaultFocus(true, in: focusNS)
        }
    }

    // MARK: Right column — trailer zone (drawing: eyebrow +
    // status, 928×522 frame, frame title + meta)

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("TRAILER THEO TIÊU ĐIỂM")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(4)
                    .foregroundStyle(theme.textFaint)
                Spacer(minLength: 0)
                Text(trailerStatusText)
                    .font(.system(size: 20))
                    .foregroundStyle(theme.textDim)
            }
            .frame(height: 40)
            Spacer().frame(height: 10)
            if isEmptyResult {
                // Plan §3: with an empty filmography the
                // trailer zone hides — the zone keeps its
                // geometry so the composition does not jump.
                Color.clear.frame(width: 928, height: 522)
            } else {
                previewFrame
            }
            Spacer().frame(height: 26)
            if let focusedMovie {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(focusedMovie.title)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    if focusedMovie.year > 0 {
                        Text(String(focusedMovie.year))
                            .font(.system(size: 22))
                            .foregroundStyle(theme.textDim)
                    }
                }
                Text(frameMetaText(focusedMovie))
                    .font(.system(size: 22))
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .padding(.top, 12)
            }
        }
    }

    private var trailerStatusText: String {
        if previewPlaying { return "Đang phát · Tắt tiếng" }
        if previewNoTrailer { return "Không có trailer" }
        return ""
    }

    private func frameMetaText(_ movie: Movie) -> String {
        [movie.episode_current, movie.lang]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The frame's layer stack, in the drawing's fallback
    /// order: the trailer (TVBackdropPreviewHost, fading in
    /// on its first frame exactly as on Detail) → the focused
    /// film's backdrop → its poster (displayBackdrop already
    /// falls back to the poster) → the plain panel + title.
    private var previewFrame: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surfaceBottom)
            if let movie = focusedMovie {
                if movie.displayBackdrop.isEmpty {
                    Text(movie.title)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(theme.textFaint)
                        .multilineTextAlignment(.center)
                        .padding(40)
                } else {
                    TVRemoteImage(urlString: movie.displayBackdrop, bucket: 1920)
                }
                if let previewStream {
                    TVBackdropPreviewHost(
                        stream: previewStream,
                        onFirstFrame: {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                previewVisible = true
                            }
                            previewPlaying = true
                        },
                        onRetire: { _ in
                            // Mirror Detail: fade first, clear
                            // after — clearing in the same
                            // update would dismantle the host
                            // mid-fade. Generation-guarded.
                            let wasShown = previewVisible
                            withAnimation(.easeInOut(duration: 0.6)) {
                                previewVisible = false
                            }
                            previewPlaying = false
                            if !wasShown {
                                // The attempt concluded without
                                // a frame (low quality / failed /
                                // never ready): the frame falls
                                // back to the still + the note.
                                previewNoTrailer = true
                            }
                            let retiredGeneration = previewGeneration
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(700))
                                guard previewGeneration == retiredGeneration else { return }
                                previewStream = nil
                            }
                        })
                        .frame(width: 928, height: 522)
                        .clipped()
                        .opacity(previewVisible ? 1 : 0)
                        .id(previewGeneration)
                }
                if !movie.quality.isEmpty {
                    VStack {
                        HStack {
                            Text(movie.quality)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.badgeQuality))
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(14)
                }
                if previewPlaying {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Trailer · Tắt tiếng")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .foregroundStyle(Color.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                        }
                    }
                    .padding(16)
                }
                if previewNoTrailer && previewStream == nil {
                    VStack {
                        Spacer()
                        HStack {
                            Text("Không có trailer")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.black.opacity(0.45)))
                            Spacer()
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 928, height: 522)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    // MARK: Intents

    /// Card tap → the film's own Detail, pushed over this
    /// screen (FL-057 prevention: the destination carries the
    /// FILM's identity, never the origin context). The push
    /// also sets the play latch so no preview re-arms behind
    /// the Detail.
    private func openFilm(_ movie: Movie) {
        previewLatched = true
        previewEpoch += 1
        previewStream = nil
        DiagLog.log("actor", "open-film plugin=\(pluginId) movie=\(movie.id)")
        nav.push(.movie(MovieRoute(pluginId: pluginId, movie: movie)))
    }

    // MARK: List loading (TVBrowseView's discipline, same
    // service surface — generation-guarded, dedupe by id)

    private func reload() async {
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        loadError = nil
        do {
            let result = try await service.list(pluginId: pluginId, slug: route,
                                                filters: ListFilters(), page: 1)
            guard gen == loadGeneration else { return }
            items = result.items.uniquedById()
            page = result.pagination.currentPage
            totalPages = max(result.pagination.totalPages, 1)
            DiagLog.log("actor", "list plugin=\(pluginId) count=\(items.count) totalPages=\(totalPages)")
        } catch {
            guard gen == loadGeneration else { return }
            loadError = "Không tải được danh sách phim"
            DiagLog.log("actor", "list failed plugin=\(pluginId) kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        if gen == loadGeneration {
            isLoading = false
            didLoad = true
        }
    }

    private func loadMore() async {
        guard didLoad, !isLoading, !isLoadingMore, page >= 1, page < totalPages else { return }
        let gen = loadGeneration
        isLoadingMore = true
        do {
            let result = try await service.list(pluginId: pluginId, slug: route,
                                                filters: ListFilters(), page: page + 1)
            guard gen == loadGeneration else { isLoadingMore = false; return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !known.contains($0.id) })
            page = result.pagination.currentPage
            totalPages = max(result.pagination.totalPages, 1)
            DiagLog.log("actor", "list.more plugin=\(pluginId) count=\(items.count) page=\(page)")
        } catch {
            // Non-fatal (the tree's discipline): keep what is
            // on screen.
            DiagLog.log("actor", "list.more failed plugin=\(pluginId) kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        isLoadingMore = false
    }

    // MARK: Focus-dwell preview

    private var dwellTaskKey: String {
        "\(focusedMovie?.id ?? "-")#\(previewEpoch)#\(previewEnabled)"
    }

    /// One attempt per dwell: sleep 1.5 s (SwiftUI cancels
    /// this task on any focus move — the key changes), resolve,
    /// and publish only if this attempt is still the current
    /// one and the play latch is open (F-B1 discipline: the
    /// latch is re-checked at the publish point, not only at
    /// arming).
    private func runDwell() async {
        guard let movie = focusedMovie, previewEnabled, !previewLatched else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled else { return }
        previewGeneration += 1
        let generation = previewGeneration
        let stream = await resolveActorPreview(movie: movie)
        guard !Task.isCancelled, generation == previewGeneration, !previewLatched else { return }
        if let stream {
            previewNoTrailer = false
            previewStream = stream
        } else {
            previewStream = nil
            previewNoTrailer = true
            DiagLog.log("actor", "preview outcome=no-trailer plugin=\(pluginId) movie=\(movie.id)")
        }
    }

    /// The actor screen's preview resolution: the list-item
    /// previewUrl fast path first (plan §2.5 — the URL
    /// declares no height, so the declared gate here can only
    /// convict a KNOWN-low source; the host's measured gate
    /// decides the rest), otherwise the focused film's detail
    /// through the shared probe, exactly as Detail runs it.
    private func resolveActorPreview(movie: Movie) async -> StreamInfo? {
        if !movie.previewUrl.isEmpty, MediaURL.isDirectMedia(movie.previewUrl) {
            let declaredRank = max(TVPreviewProbe.declaredQualityRank(movie.quality),
                                   TVPreviewProbe.declaredQualityRank(movie.episode_current))
            if declaredRank == 1 {
                DiagLog.log("actor", "preview outcome=low-quality-declared plugin=\(pluginId) movie=\(movie.id)")
                return nil
            }
            DiagLog.log("actor", "preview rung=preview-url host=\(URL(string: movie.previewUrl)?.host ?? "?")")
            return StreamInfo(url: movie.previewUrl, headers: [:])
        }
        guard let bundle = try? await service.detail(pluginId: pluginId, movieId: movie.id) else {
            DiagLog.log("actor", "preview outcome=detail-failed plugin=\(pluginId) movie=\(movie.id)")
            return nil
        }
        var snap = bundle.detail.asMovie
        snap.id = movie.id
        return await TVPreviewProbe.resolve(
            service: service, pluginId: pluginId,
            pluginName: plugins.installedPlugin(id: pluginId)?.manifest.name ?? "",
            isManga: false, detail: bundle.detail,
            detailStream: bundle.detailStream, movie: snap)
    }
}
