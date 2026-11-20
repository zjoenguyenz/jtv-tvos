import SwiftUI

/// JTV tvOS Phase 2 — Search (plan §4.4 + the owner's Netflix
/// ruling, mechanism learned from JoeTV — study §3): ONE search
/// surface for every section; as each letter is typed, results
/// paint INSTANTLY from the data already on the device (the
/// active plugin's loaded home pool + favourites + history),
/// and the plugin's server results merge in behind them. 300 ms
/// debounce, request IDs on every publish (FL-232), dedupe by
/// id, exact matches hoisted. No facet/filter panel anywhere.
/// The recent-searches contract is the iOS one exactly
/// (survey §1.4): key `jtv_recent_searches`, max 10.

private let recentSearchesKey = "jtv_recent_searches"

private struct TVConditionalFocusSection: ViewModifier {
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
    func focusSection(if enabled: Bool) -> some View {
        modifier(TVConditionalFocusSection(enabled: enabled))
    }
}

enum TVSearchText {
    static func normalise(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func loadRecents() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? []
    }

    static func recordRecent(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = loadRecents()
        list.removeAll { $0.lowercased() == trimmed.lowercased() }
        list.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: recentSearchesKey)
    }

    static func clearRecents() {
        UserDefaults.standard.removeObject(forKey: recentSearchesKey)
    }
}

struct TVSearchView: View {
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var favorites: FavoritesManager
    @EnvironmentObject private var history: WatchHistoryManager
    @EnvironmentObject private var session: PinSession
    @Environment(TVHomeStore.self) private var store
    @Environment(\.tvTheme) private var theme

    @State private var query = ""
    @State private var recents: [String] = []
    @State private var results: [Movie] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var didSearch = false
    @State private var serverPage = 0
    @State private var serverTotalPages = 1
    @State private var isLoadingMore = false
    @State private var generation = 0
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool
    @FocusState private var clearHistoryFocused: Bool

    private var activeId: String { plugins.activePlugin?.id ?? "" }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            sourceBand
            fieldBand
            content
        }
        .tvThemedBackground()
        .defaultFocus($fieldFocused, true)
        .onAppear {
            session.touch()
            recents = TVSearchText.loadRecents()
        }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onChange(of: plugins.activePluginId) { _, _ in scheduleSearch() }
    }

    // MARK: Bands

    private var sourceBand: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let active = plugins.activePlugin {
                HStack(spacing: 14) {
                    CachedAsyncImage(urlString: active.manifest.iconUrl)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text("Tìm trong nguồn \(active.manifest.name)")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    if isSearching {
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(plugins.visiblePlugins) { plugin in
                        TVChip(title: plugin.manifest.name,
                               iconURL: plugin.manifest.iconUrl,
                               badge18: plugins.isAdult(plugin.id),
                               selected: plugin.id == plugins.activePluginId) {
                            plugins.activePluginId = plugin.id
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 28)
        .focusSection(if: !plugins.visiblePlugins.isEmpty)
    }

    private var fieldBand: some View {
        HStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.textFaint)
            TextField("Tìm phim, truyện…", text: $query)
                .font(.system(size: 30))
                .foregroundStyle(theme.textPrimary)
                .focused($fieldFocused)
                .onSubmit {
                    TVSearchText.recordRecent(trimmedQuery)
                    recents = TVSearchText.loadRecents()
                }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(theme.fieldBar))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(fieldFocused ? theme.focusRing : .clear,
                          lineWidth: fieldFocused ? theme.ringWidth : 0))
        .padding(.horizontal, 80)
        .padding(.top, 22)
        .focusSection()
    }

    // MARK: Content states

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            suggestions
        } else if let searchError, results.isEmpty {
            TVErrorState(message: searchError) { scheduleSearch() }
        } else if didSearch && results.isEmpty && !isSearching {
            TVEmptyState(icon: "magnifyingglass", title: "Không tìm thấy kết quả")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    TVPosterGrid(items: results, pluginId: activeId,
                                 isLoadingMore: isLoadingMore,
                                 onSelect: { _ in
                                     TVSearchText.recordRecent(trimmedQuery)
                                     recents = TVSearchText.loadRecents()
                                 },
                                 onLoadMore: { Task { await loadMoreServer() } })
                        .focusSection(if: !results.isEmpty)
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 30)
            }
        }
    }

    private var suggestions: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if recents.isEmpty {
                    Text("Nhập tên phim hoặc truyện để tìm trong nguồn đang chọn.")
                        .font(.system(size: 26))
                        .foregroundStyle(theme.textDim)
                        .padding(.top, 12)
                } else {
                    TVSectionHeader(title: "Tìm gần đây")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(recents, id: \.self) { term in
                            TVChip(title: term, selected: false) {
                                query = term
                            }
                        }
                    }
                    Button {
                        TVSearchText.clearRecents()
                        recents = []
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "trash")
                            Text("Xoá lịch sử tìm kiếm")
                        }
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 13)
                        .overlay(Capsule().strokeBorder(clearHistoryFocused ? theme.focusRing : .clear,
                                                         lineWidth: clearHistoryFocused ? theme.ringWidth : 0))
                    }
                    .tvCardButton()
                    .focused($clearHistoryFocused)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 30)
            .focusSection(if: !recents.isEmpty)
        }
    }

    // MARK: Search machinery

    private func scheduleSearch() {
        debounceTask?.cancel()
        let term = trimmedQuery
        guard !term.isEmpty else {
            generation += 1
            results = []
            didSearch = false
            searchError = nil
            isSearching = false
            return
        }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await runSearch(term: term)
        }
    }

    private func runSearch(term: String) async {
        generation += 1
        serverPage = 0
        serverTotalPages = 1
        let gen = generation
        let pid = activeId
        guard !pid.isEmpty else { return }

        // 1. Local paint — instant, from what the device holds.
        let needle = TVSearchText.normalise(term)
        var seen = Set<String>()
        var local: [Movie] = []
        let pool = store.pool(for: pid)
            + favorites.records.filter { $0.pluginId == pid }.map(\.movie)
            + history.records.filter { $0.pluginId == pid }.map(\.movie)
        for movie in pool where seen.insert(movie.id).inserted {
            if TVSearchText.normalise(movie.title).contains(needle) {
                local.append(movie)
            }
        }
        results = local
        didSearch = true
        searchError = nil
        isSearching = true

        // 2. Server merge — behind the local results.
        do {
            let page = try await service.search(pluginId: pid, keyword: term, page: 1)
            guard gen == generation else { return }
            serverPage = page.pagination.currentPage
            serverTotalPages = max(page.pagination.totalPages, 1)
            var shown = Set(results.map(\.id))
            var exact: [Movie] = []
            var rest: [Movie] = []
            for movie in page.items where shown.insert(movie.id).inserted {
                if TVSearchText.normalise(movie.title) == needle {
                    exact.append(movie)
                } else {
                    rest.append(movie)
                }
            }
            results.append(contentsOf: exact + rest)
        } catch {
            guard gen == generation else { return }
            if results.isEmpty {
                searchError = "Tìm kiếm thất bại"
            }
            DiagLog.log("search", "server search failed plugin=\(pid) kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        if gen == generation { isSearching = false }
    }

    private func loadMoreServer() async {
        let term = trimmedQuery
        guard !term.isEmpty, !isLoadingMore, serverPage >= 1, serverPage < serverTotalPages else { return }
        let gen = generation
        isLoadingMore = true
        do {
            let page = try await service.search(pluginId: activeId, keyword: term, page: serverPage + 1)
            guard gen == generation else { isLoadingMore = false; return }
            var shown = Set(results.map(\.id))
            results.append(contentsOf: page.items.filter { shown.insert($0.id).inserted })
            serverPage = page.pagination.currentPage
            serverTotalPages = max(page.pagination.totalPages, 1)
        } catch {
            DiagLog.log("search", "loadMore failed kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        isLoadingMore = false
    }
}

// MARK: - Search results (cast destination)

/// The AppRoute.search destination (Detail cast chips) — the
/// iOS SearchResultsView semantics: server search for a fixed
/// keyword in one plugin, the shared grid, the same states.
struct TVSearchResultsView: View {
    let query: String
    let pluginId: String

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var session: PinSession
    @Environment(\.tvTheme) private var theme

    @State private var items: [Movie] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var didLoad = false
    @State private var loadGeneration = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                Text(query)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                contentBand
                    .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 36)
        }
        .tvThemedBackground()
        .onAppear { session.touch() }
        .task(id: query + pluginId) {
            items = []
            didLoad = false
            await reload()
        }
    }

    @ViewBuilder
    private var contentBand: some View {
        if !items.isEmpty {
            TVPosterGrid(items: items, pluginId: pluginId,
                         isLoadingMore: isLoadingMore,
                         onLoadMore: { Task { await loadMore() } })
        } else if loadError != nil {
            TVErrorState(message: "Tìm kiếm thất bại") { Task { await reload() } }
                .frame(minHeight: 300)
        } else if didLoad {
            TVEmptyState(icon: "magnifyingglass", title: "Không tìm thấy kết quả",
                         actionTitle: "Thử lại",
                         action: { Task { await reload() } },
                         actionIsDefaultFocus: true)
                .frame(minHeight: 300)
        } else {
            TVLoadingState(onRetry: { Task { await reload() } })
                .frame(minHeight: 300)
        }
    }

    private func reload() async {
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        loadError = nil
        do {
            let result = try await service.search(pluginId: pluginId, keyword: query, page: 1)
            guard gen == loadGeneration else { return }
            items = result.items.uniquedById()
            page = result.pagination.currentPage
            totalPages = max(result.pagination.totalPages, 1)
        } catch {
            guard gen == loadGeneration else { return }
            loadError = "Tìm kiếm thất bại"
            DiagLog.log("search", "results failed plugin=\(pluginId) kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        guard gen == loadGeneration else { return }
        isLoading = false
        didLoad = true
    }

    private func loadMore() async {
        guard didLoad, !isLoading, !isLoadingMore, page >= 1, page < totalPages else { return }
        let gen = loadGeneration
        isLoadingMore = true
        do {
            let result = try await service.search(pluginId: pluginId, keyword: query, page: page + 1)
            guard gen == loadGeneration else { isLoadingMore = false; return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !known.contains($0.id) })
            page = result.pagination.currentPage
            totalPages = max(result.pagination.totalPages, 1)
        } catch {
            DiagLog.log("search", "results loadMore failed kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        isLoadingMore = false
    }
}
