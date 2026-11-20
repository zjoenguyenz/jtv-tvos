import SwiftUI

/// JTV tvOS Phase 2 — per-source browse (the iOS CategoryDetailView
/// port), the shared poster grid, the filter sheet, and the shared
/// navigation plumbing (route destinations + the per-tab nav path
/// model) used by every Phase 2 tab stack.
///
/// Construction follows the Phase 2 template (plan §3): ScrollView
/// + LazyVStack bands, each band a `.focusSection()`, element-level
/// focus only, no List anywhere.

// MARK: - Per-tab navigation path model

/// One instance per tab, created by the tab root and injected into
/// the environment, so pushed screens (Detail, Browse) append to
/// the owning stack without needing the path binding threaded
/// through every destination. Sanitised on every mutation (the
/// iOS NavSanitizer discipline — collapses adjacent duplicate
/// .movie routes from the sextop1 push-during-pop race).
@MainActor
@Observable
final class TVNavPath {
    var path: [AppRoute] = [] {
        didSet { NavSanitizer.sanitize(&path) }
    }

    func push(_ route: AppRoute) { path.append(route) }
}

extension View {
    /// The three AppRoute destinations every Phase 2 stack shares
    /// (FL-235 — one shared destination set, no per-tab copies).
    func tvNavigationDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .movie(let r):
                TVDetailView(pluginId: r.pluginId, movie: r.movie, autoResume: r.autoResume)
            case .category(let r):
                TVBrowseView(pluginId: r.pluginId, slug: r.slug, title: r.title, initialFilters: r.filters)
            case .search(let r):
                TVSearchResultsView(query: r.keyword, pluginId: r.pluginId)
            }
        }
    }
}

// MARK: - Shared poster grid

/// The one poster grid for Browse, Search results and Search's
/// cast destination (FL-235). Lives inside the parent's ScrollView
/// (no own ScrollView). Column count is derived from the measured
/// container width (FL-126 — never a hard-coded resolution).
/// Load-more hangs on the bottom sentinel's appearance — a
/// scroll-position signal (FL-234), guarded by the parent.
struct TVPosterGrid: View {
    let items: [Movie]
    let pluginId: String
    let isLoadingMore: Bool
    var onSelect: ((Movie) -> Void)? = nil
    let onLoadMore: () -> Void

    @EnvironmentObject private var favorites: FavoritesManager
    @Environment(TVNavPath.self) private var nav
    @State private var measuredWidth: CGFloat = 0

    private let spacing: CGFloat = 24

    private var columns: [GridItem] {
        let count = TVGridGeometry.columnCount(forWidth: measuredWidth)
        return Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: count)
    }

    private var cellWidth: CGFloat {
        TVGridGeometry.cellWidth(forWidth: measuredWidth, spacing: spacing)
    }

    var body: some View {
        VStack(spacing: 28) {
            LazyVGrid(columns: columns, spacing: 30) {
                ForEach(items) { movie in
                    TVGridPosterCell(
                        movie: movie,
                        width: cellWidth,
                        isFavorite: favorites.isFavorite(pluginId: pluginId, movieId: movie.id),
                        onSelect: {
                            onSelect?(movie)
                            nav.push(.movie(MovieRoute(pluginId: pluginId, movie: movie)))
                        },
                        onLongPress: {
                            favorites.toggle(pluginId: pluginId, movie: movie)
                        }
                    )
                }
            }
            if isLoadingMore {
                ProgressView()
                    .tint(.white)
                    .padding(.vertical, 8)
            }
            // Bottom sentinel: page side-effects hang on scroll
            // position (FL-234). The parent's loadMore guards on
            // its own page state, so an early fire is harmless.
            Color.clear
                .frame(height: 8)
                .onAppear { onLoadMore() }
        }
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: TVWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(TVWidthKey.self) { measuredWidth = $0 }
    }
}

struct TVWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum TVGridGeometry {
    /// Target poster-cell width ≈250pt → 6 columns at the 1920
    /// design width with the screens' 80pt side margins.
    static func columnCount(forWidth width: CGFloat) -> Int {
        guard width > 0 else { return 6 }
        let n = Int((width + 24) / (250 + 24))
        return min(8, max(4, n))
    }

    static func cellWidth(forWidth width: CGFloat, spacing: CGFloat = 24) -> CGFloat {
        guard width > 0 else { return 250 }
        let n = columnCount(forWidth: width)
        return (width - spacing * CGFloat(n - 1)) / CGFloat(n)
    }
}

// MARK: - Browse (per-source listing)

struct TVBrowseView: View {
    let pluginId: String
    let slug: String
    let title: String
    let initialFilters: ListFilters

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
    @State private var filters: ListFilters
    @State private var showFilters = false
    @State private var loadGeneration = 0
    @FocusState private var filterFocused: Bool
    @Namespace private var focusNS

    init(pluginId: String, slug: String, title: String, initialFilters: ListFilters) {
        self.pluginId = pluginId
        self.slug = slug
        self.title = title
        self.initialFilters = initialFilters
        _filters = State(initialValue: initialFilters)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                headerBand
                    .focusSection()
                contentBand
                    .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 36)
        }
        .tvThemedBackground()
        .focusScope(focusNS)
        .onAppear { session.touch() }
        .task { if !didLoad { await reload() } }
        .onChange(of: filters) { _, _ in Task { await reload() } }
        .fullScreenCover(isPresented: $showFilters) {
            TVFilterSheet(pluginId: pluginId, filters: $filters)
        }
    }

    private var headerBand: some View {
        HStack(alignment: .center, spacing: 24) {
            Text(title)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Button {
                showFilters = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: filters.isEmpty
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Bộ lọc")
                        .font(.system(size: 26, weight: .semibold))
                }
                .foregroundStyle(filters.isEmpty ? theme.textPrimary : theme.accent)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
            }
            .tvCardButton()
            .focused($filterFocused)
            .tvFocusInsetRing(isFocused: filterFocused, radius: 999,
                              color: theme.focusRing, width: theme.ringWidth,
                              baseFill: theme.cardFill, focusedFill: Color.white.opacity(0.16))
        }
    }

    @ViewBuilder
    private var contentBand: some View {
        if isLoading && items.isEmpty {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if let loadError, items.isEmpty {
            TVErrorState(message: loadError) { Task { await reload() } }
                .frame(minHeight: 300)
        } else if didLoad && items.isEmpty {
            TVEmptyState(icon: "film.stack", title: "Không có nội dung")
                .frame(minHeight: 300)
        } else {
            TVPosterGrid(items: items, pluginId: pluginId,
                         isLoadingMore: isLoadingMore,
                         onLoadMore: { Task { await loadMore() } })
                .prefersDefaultFocus(true, in: focusNS)
        }
    }

    private func reload() async {
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        loadError = nil
        do {
            let result = try await service.list(pluginId: pluginId, slug: slug, filters: filters, page: 1)
            guard gen == loadGeneration else { return }
            items = result.items
            page = result.pagination.currentPage
            totalPages = max(result.pagination.totalPages, 1)
        } catch {
            guard gen == loadGeneration else { return }
            loadError = "Không tải được danh sách"
            DiagLog.log("browse", "list failed plugin=\(pluginId) slug=\(slug) kind=\((error as NSError).domain)#\((error as NSError).code)")
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
            let result = try await service.list(pluginId: pluginId, slug: slug, filters: filters, page: page + 1)
            guard gen == loadGeneration else { isLoadingMore = false; return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !known.contains($0.id) })
            page = result.pagination.currentPage
            totalPages = max(result.pagination.totalPages, 1)
        } catch {
            // Non-fatal (iOS discipline): keep what's on screen.
            DiagLog.log("browse", "loadMore failed plugin=\(pluginId) slug=\(slug) kind=\((error as NSError).domain)#\((error as NSError).code)")
        }
        isLoadingMore = false
    }
}

// MARK: - Filter sheet

/// The iOS FilterSheet ported to a full-screen cover: draft state,
/// nothing applies until "Áp dụng"; "Đặt lại" clears the draft.
/// Group order is the iOS order exactly (survey §1.2): the three
/// hard-coded groups first, then the plugin's orderedKeys.
struct TVFilterSheet: View {
    let pluginId: String
    @Binding var filters: ListFilters

    @EnvironmentObject private var service: MovieService
    @Environment(\.tvTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ListFilters
    @State private var config = FilterConfig()
    @State private var categories: [NameSlug] = []
    @State private var countries: [NameValue] = []
    @State private var years: [NameValue] = []
    @State private var didLoad = false
    @FocusState private var applyFocused: Bool

    init(pluginId: String, filters: Binding<ListFilters>) {
        self.pluginId = pluginId
        _filters = filters
        _draft = State(initialValue: filters.wrappedValue)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                HStack {
                    Text("Bộ lọc")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                }
                .focusSection()

                groupBand(title: "Thể loại", key: "category",
                          options: categories.map { NameValue(name: $0.name, value: $0.slug) })
                groupBand(title: "Quốc gia", key: "country", options: countries)
                groupBand(title: "Năm", key: "year", options: years)
                ForEach(config.orderedKeys, id: \.self) { key in
                    groupBand(title: Self.title(for: key), key: key,
                              options: config.options(for: key))
                }

                HStack(spacing: 24) {
                    actionButton(title: "Đặt lại", primary: false) {
                        draft = ListFilters()
                    }
                    actionButton(title: "Áp dụng", primary: true) {
                        filters = draft
                        dismiss()
                    }
                    .focused($applyFocused)
                }
                .focusSection()
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .tvThemedBackground()
        .defaultFocus($applyFocused, true)
        .task {
            if !didLoad {
                didLoad = true
                config = await service.filterConfig(pluginId: pluginId)
                categories = await service.categories(pluginId: pluginId)
                countries = await service.countries(pluginId: pluginId)
                years = await service.years(pluginId: pluginId)
            }
        }
    }

    @ViewBuilder
    private func groupBand(title: String, key: String, options: [NameValue]) -> some View {
        if !options.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                TVSectionHeader(title: title)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                    chip(title: "Tất cả", selected: draft.value(for: key).isEmpty) {
                        draft.set(key, value: "")
                    }
                    ForEach(options) { option in
                        chip(title: option.name, selected: draft.value(for: key) == option.value) {
                            draft.set(key, value: option.value)
                        }
                    }
                }
            }
            .focusSection()
        }
    }

    private func chip(title: String, selected: Bool, onTap: @escaping () -> Void) -> some View {
        TVChip(title: title, selected: selected, onSelect: onTap)
    }

    private func actionButton(title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(primary ? theme.onAccent : theme.textPrimary)
                .padding(.horizontal, 44)
                .padding(.vertical, 18)
                .background(Capsule().fill(primary ? theme.accent : theme.cardFill))
        }
        .tvCardButton()
    }

    static func title(for key: String) -> String {
        switch key {
        case "sort": return "Sắp xếp"
        case "category": return "Nhóm"
        default:
            let spaced = key.replacingOccurrences(of: "_", with: " ")
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }
    }
}
