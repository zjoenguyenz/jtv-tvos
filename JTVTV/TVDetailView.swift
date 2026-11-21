import SwiftUI

private struct TVDetailConditionalFocusSection: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.focusSection()
        } else {
            content
        }
    }
}

private extension View {
    func detailFocusSection(if enabled: Bool) -> some View {
        modifier(TVDetailConditionalFocusSection(enabled: enabled))
    }
}

/// JTV tvOS Phase 2 — title Detail (the iOS MovieDetailView port,
/// survey §1.5) over a FULL-SCREEN backdrop with the theme's
/// Ultra treatment (owner amendment: backdrop full màn hình,
/// edge-to-edge, scrim from the theme tokens). Layout follows
/// mockup 05. Load is the iOS two-stage progressive load with
/// title-recovery healing; identity is navId for every store
/// write. Play actions build the exact iOS PlaybackRequest and
/// hand it to the PlaybackPresenter — the Phase 3 entry point;
/// in Phase 2 the presenter surfaces TVPlaybackPlaceholderView.
/// Detail writes NO history (the player owns history writes,
/// and no playback has happened yet).
struct TVDetailView: View {
    let pluginId: String
    let movie: Movie
    var autoResume: Bool = false

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var favorites: FavoritesManager
    @EnvironmentObject private var history: WatchHistoryManager
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var presenter: PlaybackPresenter
    @EnvironmentObject private var session: PinSession
    @Environment(\.tvTheme) private var theme

    @State private var bundle: MovieService.DetailBundle?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var loadGeneration = 0
    @State private var recoveredId: String?
    @State private var didAutoResume = false
    @State private var selectedServer = 0
    @State private var descExpanded = false
    @FocusState private var playFocused: Bool
    @FocusState private var favFocused: Bool
    @FocusState private var resumeFocused: Bool
    @FocusState private var descFocused: Bool

    private var detail: MovieDetail? { bundle?.detail }
    private var navId: String { recoveredId ?? movie.id }
    private var isManga: Bool { plugins.installedPlugin(id: pluginId)?.manifest.isManga ?? false }
    private var isFavorite: Bool { favorites.isFavorite(pluginId: pluginId, movieId: navId) }
    private var historyRecord: HistoryRecord? { history.record(for: pluginId, movieId: navId) }
    private var hasPlayableEpisode: Bool {
        detail?.servers.contains { !$0.episodes.isEmpty } ?? false
    }

    private var backdropURL: String {
        if let detail {
            if !detail.backdropUrl.isEmpty { return detail.backdropUrl }
            if !detail.posterUrl.isEmpty { return detail.posterUrl }
            return movie.displayBackdrop
        }
        return movie.displayBackdrop
    }

    private func snapshotMovie(for detail: MovieDetail) -> Movie {
        var snap = detail.asMovie
        snap.id = navId
        return snap
    }

    var body: some View {
        // L-T04: the pre-fetch body follows the iOS-proven shape
        // — while the detail has not loaded, NO backdrop is
        // built (iOS MovieDetailView renders background +
        // spinner only until its detail arrives,
        // DetailView.swift:41–52, and mounts its backdrop
        // inside the loaded-content branch, :187). The
        // pre-fetch backdrop load at bucket 1920 was the one
        // item-data-driven subsystem inside the convicted
        // Detail-open crash window; it now enters only with
        // the loaded detail, exactly as on iOS.
        // Breadcrumb D3: this body was reached.
        DiagLog.log("detail", "body plugin=\(pluginId) movie=\(movie.id) backdrop=\(DiagLog.urlForLog(backdropURL))")
        return ZStack {
            if let detail {
                TVBackdropView(urlString: backdropURL, fallbackTitle: movie.title)
                    .ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 36) {
                        headerBand(detail)
                        actionRow(detail)
                            .focusSection()
                        if let record = historyRecord, !record.episodeName.isEmpty {
                            resumeBanner(record: record, detail: detail)
                                .focusSection()
                        }
                        metaBlock(detail)
                        if !detail.description.isEmpty {
                            descBlock(detail)
                                .focusSection()
                        }
                        if !detail.castNames.isEmpty {
                            castsBlock(detail)
                                .focusSection()
                        }
                        serversBlock(detail)
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 40)
                }
                .defaultFocus(hasPlayableEpisode ? $playFocused : $favFocused, true)
            } else if loadError != nil {
                TVErrorState(message: "Không tải được thông tin phim") {
                    Task { await load() }
                }
            } else {
                TVLoadingState(onRetry: { Task { await load() } })
            }
        }
        .tvThemedBackground()
        .onAppear { session.touch() }
        .task(id: movie.id) { await load() }
    }

    // MARK: Bands

    private func headerBand(_ detail: MovieDetail) -> some View {
        HStack(alignment: .bottom, spacing: 34) {
            TVRemoteImage(urlString: detail.posterUrl.isEmpty ? movie.posterUrl : detail.posterUrl,
                          bucket: 960)
                .frame(width: 184, height: 276)
                .clipShape(RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 14) {
                Text(detail.title)
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                if !detail.originName.isEmpty {
                    Text(detail.originName)
                        .font(.system(size: 27))
                        .foregroundStyle(theme.textDim)
                        .lineLimit(1)
                }
                HStack(spacing: 12) {
                    if detail.year > 0 {
                        badge(String(detail.year), background: theme.accent, foreground: theme.onAccent)
                    }
                    if !detail.quality.isEmpty {
                        badge(detail.quality, background: theme.badgeQuality, foreground: .black)
                    }
                    if !detail.lang.isEmpty {
                        badge(detail.lang, background: Color.white.opacity(0.16), foreground: .white)
                    }
                    if detail.rating > 0 {
                        Text("★ \(String(format: "%.1f", detail.rating))")
                            .font(.system(size: 27, weight: .bold))
                            .foregroundStyle(theme.heroMeta)
                    }
                }
            }
            Spacer()
        }
    }

    private func badge(_ text: String, background: Color, foreground: Color) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
    }

    private func actionRow(_ detail: MovieDetail) -> some View {
        HStack(spacing: 20) {
            Button {
                playFirstEpisode(detail)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: isManga ? "book.fill" : "play.fill")
                        .font(.system(size: 27, weight: .bold))
                    Text(isManga ? "Đọc ngay" : "Phát ngay")
                        .font(.system(size: 30, weight: .bold))
                }
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, 46)
                .padding(.vertical, 19)
                .background(Capsule().fill(theme.accent))
                .overlay(Capsule().strokeBorder(playFocused ? theme.focusRing : .clear,
                                                lineWidth: playFocused ? theme.ringWidth : 0))
            }
            .tvCardButton()
            .focused($playFocused)
            .disabled(!hasPlayableEpisode)

            Button {
                favorites.toggle(pluginId: pluginId, movie: snapshotMovie(for: detail))
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(isFavorite ? theme.accent : theme.textPrimary)
                    .frame(width: 78, height: 78)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(theme.cardFill))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(favFocused ? theme.focusRing : theme.cardStroke,
                                      lineWidth: favFocused ? theme.ringWidth : 1))
            }
            .tvCardButton()
            .focused($favFocused)
            Spacer()
        }
    }

    private func resumeBanner(record: HistoryRecord, detail: MovieDetail) -> some View {
        Button {
            resume(record, detail: detail)
        } label: {
            HStack(spacing: 18) {
                Image(systemName: record.isManga ? "book.pages.fill" : "play.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Xem tiếp: \(record.episodeName)")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                    if record.isManga {
                        Text("Đã đọc tới trang \(Int(record.lastPosition) + 1)")
                            .font(.system(size: 22))
                            .foregroundStyle(theme.textDim)
                    } else if record.duration > 0 {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.25))
                            Capsule().fill(theme.accent)
                                .frame(width: 520 * CGFloat(record.progress))
                        }
                        .frame(width: 520, height: 6)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(theme.textFaint)
            }
            .padding(24)
            .contentShape(Rectangle())
        }
        .tvCardButton()
        .focused($resumeFocused)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(resumeFocused ? theme.focusRing : theme.cardStroke,
                          lineWidth: resumeFocused ? theme.ringWidth : 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func metaBlock(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            metaRow("Tiến độ", detail.episode_current)
            metaRow("Thể loại", detail.category)
            metaRow("Quốc gia", detail.country)
            metaRow("Đạo diễn", detail.director)
        }
    }

    @ViewBuilder
    private func metaRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 20) {
                Text(label)
                    .font(.system(size: 26))
                    .foregroundStyle(theme.textFaint)
                    .frame(width: 200, alignment: .leading)
                Text(value)
                    .font(.system(size: 26))
                    .foregroundStyle(theme.textPrimary)
            }
        }
    }

    private func descBlock(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            TVSectionHeader(title: "Nội dung")
            Text(detail.description)
                .font(.system(size: 26))
                .foregroundStyle(theme.textDim)
                .lineLimit(descExpanded ? nil : 4)
            Button {
                descExpanded.toggle()
            } label: {
                Text(descExpanded ? "Thu gọn" : "Xem thêm")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .overlay(Capsule().strokeBorder(descFocused ? theme.focusRing : .clear,
                                                    lineWidth: descFocused ? theme.ringWidth : 0))
            }
            .tvCardButton()
            .focused($descFocused)
        }
    }

    private func castsBlock(_ detail: MovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSectionHeader(title: "Diễn viên")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(detail.castNames, id: \.self) { name in
                        TVChip(title: name, selected: false) {
                            navPushSearch(name)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    @Environment(TVNavPath.self) private var nav

    private func navPushSearch(_ name: String) {
        nav.push(.search(SearchRoute(pluginId: pluginId, keyword: name)))
    }

    @ViewBuilder
    private func serversBlock(_ detail: MovieDetail) -> some View {
        if detail.servers.isEmpty {
            Text(isManga ? "Chưa có chương nào." : "Chưa có tập nào.")
                .font(.system(size: 26))
                .foregroundStyle(theme.textDim)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 22) {
                    TVSectionHeader(title: isManga ? "Danh sách chương" : "Danh sách tập")
                    if detail.servers.count > 1 {
                        HStack(spacing: 14) {
                            ForEach(Array(detail.servers.enumerated()), id: \.offset) { index, server in
                                TVChip(title: server.name, selected: index == selectedServer) {
                                    selectedServer = index
                                }
                            }
                        }
                    }
                }
                let server = detail.servers[min(selectedServer, detail.servers.count - 1)]
                LazyVGrid(columns: [GridItem(.adaptive(minimum: isManga ? 200 : 150), spacing: 16)],
                          spacing: 16) {
                    ForEach(server.episodes) { episode in
                        TVEpisodeChip(name: episode.name,
                                      watched: historyRecord?.episodeId == episode.id) {
                            play(episode: episode, server: server, detail: detail,
                                 startPosition: 0, knownStreamURL: "")
                        }
                    }
                }
            }
            .detailFocusSection(if: detail.servers.count > 1 || !detail.servers[min(selectedServer, detail.servers.count - 1)].episodes.isEmpty)
        }
    }

    // MARK: Load (iOS two-stage + healing)

    /// F-C1: keep the grid's initial server in agreement with
    /// playFirstEpisode. If the clamped selected server has no
    /// episodes but some server does, move the selection to the
    /// first non-empty server (playFirstEpisode's own rule).
    /// A non-empty selection is never overridden, and when no
    /// server has episodes the selection is left untouched.
    private func selectFirstPlayableServerIfNeeded(servers: [EpisodeServer]) {
        guard !servers.isEmpty else { return }
        let sel = min(selectedServer, servers.count - 1)
        guard servers[sel].episodes.isEmpty,
              let firstPlayable = servers.firstIndex(where: { !$0.episodes.isEmpty }) else { return }
        selectedServer = firstPlayable
    }

    private func load() async {
        // L-T04 breadcrumb D5: Detail's load task started.
        DiagLog.log("detail", "load.begin plugin=\(pluginId) movie=\(movie.id)")
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        loadError = nil
        do {
            let first = try await service.detailMeta(pluginId: pluginId, movieId: movie.id)
            guard gen == loadGeneration else { return }
            bundle = first
            selectFirstPlayableServerIfNeeded(servers: first.detail.servers)
            isLoading = false
            warmEmbedPrefetch(detail: first.detail)
            if first.detail.servers.first?.episodes.first?.id.hasPrefix("jtvstreams:") == true {
                let full = await service.detailStreams(pluginId: pluginId, movieId: movie.id,
                                                       detail: first.detail)
                guard gen == loadGeneration else { return }
                if full.servers != first.detail.servers {
                    bundle = MovieService.DetailBundle(detail: full, detailStream: first.detailStream)
                    selectFirstPlayableServerIfNeeded(servers: full.servers)
                }
            }
        } catch {
            guard gen == loadGeneration else { return }
            await recoverByTitle(generation: gen)
        }
        guard gen == loadGeneration else { return }
        if autoResume, !didAutoResume, let detail, let record = historyRecord {
            didAutoResume = true
            resume(record, detail: detail)
        }
    }

    private func recoverByTitle(generation gen: Int) async {
        do {
            let page = try await service.search(pluginId: pluginId, keyword: movie.title, page: 1)
            guard gen == loadGeneration else { return }
            let target = TVSearchText.normalise(movie.title)
            let found = page.items.first { TVSearchText.normalise($0.title) == target }
                ?? (movie.id.isEmpty ? page.items.first : nil)
            guard let found else {
                guard gen == loadGeneration else { return }
                loadError = "Không tải được thông tin phim"
                isLoading = false
                return
            }
            let healed = try await service.detail(pluginId: pluginId, movieId: found.id)
            guard gen == loadGeneration else { return }
            recoveredId = found.id
            bundle = healed
            selectFirstPlayableServerIfNeeded(servers: healed.detail.servers)
            favorites.repairMovieId(pluginId: pluginId, from: movie.id, title: movie.title, to: found.id)
            warmEmbedPrefetch(detail: healed.detail)
        } catch {
            guard gen == loadGeneration else { return }
            loadError = "Không tải được thông tin phim"
            DiagLog.log("detail", "recover failed plugin=\(pluginId) kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        guard gen == loadGeneration else { return }
        isLoading = false
    }

    private func warmEmbedPrefetch(detail: MovieDetail) {
        guard ["123av", "javhd", "avdbapi"].contains(pluginId), !isManga,
              let server = detail.servers.first, let episode = server.episodes.first else { return }
        let request = PlaybackRequest(
            movie: snapshotMovie(for: detail),
            pluginId: pluginId,
            pluginName: plugins.installedPlugin(id: pluginId)?.manifest.name ?? "",
            isManga: isManga,
            serverName: server.name,
            episode: episode,
            allEpisodes: server.episodes
        )
        service.prefetchEmbedResolution(request)
    }

    // MARK: Play intents (iOS §1.5, exact)

    private func playFirstEpisode(_ detail: MovieDetail) {
        guard let serverIndex = detail.servers.firstIndex(where: { !$0.episodes.isEmpty }),
              let episode = detail.servers[serverIndex].episodes.first else { return }
        let server = detail.servers[serverIndex]
        selectedServer = serverIndex
        let known = bundle?.detailStream.url ?? ""
        play(episode: episode, server: server, detail: detail, startPosition: 0,
             knownStreamURL: MediaURL.isDirectMedia(known) ? known : "")
    }

    private func resume(_ record: HistoryRecord, detail: MovieDetail) {
        guard let server = detail.servers.first(where: { $0.name == record.serverName })
                ?? detail.servers.first else { return }
        selectedServer = detail.servers.firstIndex { $0.id == server.id } ?? 0
        let episode = server.episodes.first { $0.id == record.episodeId }
            ?? Episode(id: record.episodeId, name: record.episodeName, slug: record.episodeId)
        play(episode: episode, server: server, detail: detail,
             startPosition: record.lastPosition, knownStreamURL: record.streamURL)
    }

    private func play(episode: Episode, server: EpisodeServer, detail: MovieDetail,
                      startPosition: Double, knownStreamURL: String) {
        let request = PlaybackRequest(
            movie: snapshotMovie(for: detail),
            pluginId: pluginId,
            pluginName: plugins.installedPlugin(id: pluginId)?.manifest.name ?? "",
            isManga: isManga,
            serverName: server.name,
            episode: episode,
            allEpisodes: server.episodes,
            startPosition: startPosition,
            knownStreamURL: knownStreamURL,
            fallbackHeaders: bundle?.detailStream.headers ?? [:],
            switchList: switchShortlist(current: episode, detail: detail)
        )
        // L-T04 probe breadcrumb P0: the tap reached Detail's
        // play entry — the hand-off to the presenter is next.
        DiagLog.log("player", "tap.received plugin=\(pluginId) episode=\(episode.id)")
        presenter.request = request
    }

    /// torrenthub only (iOS §1.5): all servers ranked ⭐-named
    /// first → "MediaFusion" → rest, episodes flattened, deduped
    /// by episode id, [current] + the next four.
    private func switchShortlist(current: Episode, detail: MovieDetail) -> [Episode] {
        guard pluginId == "torrenthub" else { return [] }
        let rankedServers = detail.servers.sorted { a, b in
            func rank(_ s: EpisodeServer) -> Int {
                if s.name.contains("⭐") { return 0 }
                if s.name == "MediaFusion" { return 1 }
                return 2
            }
            return rank(a) < rank(b)
        }
        var seen = Set<String>()
        var merged: [Episode] = []
        for episode in rankedServers.flatMap(\.episodes) where seen.insert(episode.id).inserted {
            merged.append(episode)
        }
        let others = merged.filter { $0.id != current.id }
        return [current] + Array(others.prefix(4))
    }
}

// MARK: - Episode chip

private struct TVEpisodeChip: View {
    let name: String
    let watched: Bool
    let onSelect: () -> Void

    @Environment(\.tvTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            onSelect()
        } label: {
            Text(name)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(watched ? theme.accent : theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .contentShape(Rectangle())
        }
        .tvCardButton()
        .focused($isFocused)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isFocused ? Color.white.opacity(0.14) : theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isFocused ? theme.focusRing : (watched ? theme.accent.opacity(0.6) : theme.cardStroke),
                          lineWidth: isFocused ? theme.ringWidth : 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Phase 3 entry-point placeholder

/// Phase 2's honest stand-in for the player: the PlaybackRequest
/// was built exactly as iOS builds it and handed to the
/// PlaybackPresenter; this surface shows what was requested and
/// closes back to Detail. The real player lands in Phase 3
/// (video) / the reader in Phase 4 (manga).
struct TVPlaybackPlaceholderView: View {
    let request: PlaybackRequest
    /// Close action, passed as a VALUE by the caller (L-T06):
    /// this view is mounted inside the player cover for the
    /// manga phase, and the cover's subtree reads no
    /// @EnvironmentObject — the caller routes the close
    /// through the session's dismiss, which is the same
    /// presenter.request = nil this view used to write itself.
    let onClose: () -> Void

    @Environment(\.tvTheme) private var theme
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(spacing: 26) {
            TVRemoteImage(urlString: request.movie.posterUrl, bucket: 960)
                .frame(width: 184, height: 276)
                .clipShape(RoundedRectangle(cornerRadius: theme.posterRadius, style: .continuous))
            Text(request.movie.title)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text("\(request.serverName) • \(request.episode.name)")
                .font(.system(size: 27))
                .foregroundStyle(theme.textDim)
            if request.startPosition > 0 {
                Text("Bắt đầu tại \(Self.formatTime(request.startPosition))")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.textDim)
            }
            Text(request.isManga
                 ? "Trình đọc truyện sẽ có ở giai đoạn tiếp theo (Phase 4)."
                 : "Trình phát sẽ có ở giai đoạn tiếp theo (Phase 3).")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(theme.heroMeta)
            Button {
                onClose()
            } label: {
                Text("Đóng")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 46)
                    .padding(.vertical, 17)
                    .background(Capsule().fill(theme.accent))
                    .overlay(Capsule().strokeBorder(closeFocused ? theme.focusRing : .clear,
                                                    lineWidth: closeFocused ? theme.ringWidth : 0))
            }
            .tvCardButton()
            .focused($closeFocused)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
        .tvThemedBackground()
        .defaultFocus($closeFocused, true)
    }

    static func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
