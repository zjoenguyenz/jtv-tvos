import SwiftUI

/// JTV tvOS Phase 2 — Category tab (the iOS CategoryBrowseView
/// port, survey §1.3): the four blocks in fixed order — Danh mục,
/// Thể loại, Quốc gia, Năm phát hành — each a focus section of
/// glass chips, each omitted when its list is empty. Routing is
/// the iOS routing exactly: Quốc gia / Năm land on the plugin's
/// default category with that filter pre-applied.
struct TVCategoryView: View {
    @EnvironmentObject private var plugins: PluginManager
    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var session: PinSession
    @Environment(TVNavPath.self) private var nav
    @Environment(\.tvTheme) private var theme

    @State private var primary: [NameSlug] = []
    @State private var categories: [NameSlug] = []
    @State private var countries: [NameValue] = []
    @State private var years: [NameValue] = []
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                if plugins.visiblePlugins.isEmpty {
                    TVEmptyState(icon: "puzzlepiece.extension",
                                 title: "Chưa có nguồn plugin",
                                 actionTitle: "Đồng bộ ngay") {
                        Task { await plugins.syncAll() }
                    }
                    .focusSection()
                } else {
                    if !primary.isEmpty {
                        block(title: "Danh mục") {
                            ForEach(primary) { item in
                                chip(item.name) {
                                    push(CategoryRoute(pluginId: activeId, slug: item.slug,
                                                       title: item.name, filters: ListFilters()))
                                }
                            }
                        }
                    }
                    if !categories.isEmpty {
                        block(title: "Thể loại") {
                            ForEach(categories) { item in
                                chip(item.name) {
                                    push(CategoryRoute(pluginId: activeId, slug: item.slug,
                                                       title: item.name, filters: ListFilters()))
                                }
                            }
                        }
                    }
                    if !countries.isEmpty {
                        block(title: "Quốc gia") {
                            ForEach(countries) { item in
                                chip(item.name) {
                                    var f = ListFilters()
                                    f.country = item.value
                                    push(CategoryRoute(pluginId: activeId, slug: defaultSlug,
                                                       title: item.name, filters: f))
                                }
                            }
                        }
                    }
                    if !years.isEmpty {
                        block(title: "Năm phát hành") {
                            ForEach(years) { item in
                                chip(item.name) {
                                    var f = ListFilters()
                                    f.year = item.value
                                    push(CategoryRoute(pluginId: activeId, slug: defaultSlug,
                                                       title: "Năm \(item.name)", filters: f))
                                }
                            }
                        }
                    }
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 36)
        }
        .tvThemedBackground()
        .onAppear { session.touch() }
        .task(id: plugins.activePluginId) { await load() }
    }

    private var activeId: String { plugins.activePlugin?.id ?? "" }

    private var defaultSlug: String { primary.first?.slug ?? "phim-moi" }

    private func push(_ route: CategoryRoute) {
        nav.push(.category(route))
    }

    private func block<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSectionHeader(title: title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                content()
            }
        }
        .focusSection()
    }

    private func chip(_ title: String, onTap: @escaping () -> Void) -> some View {
        TVCategoryChip(title: title, onTap: onTap)
    }

    private func load() async {
        guard let pid = plugins.activePlugin?.id else { return }
        isLoading = true
        async let primaryResult = service.primaryCategories(pluginId: pid)
        async let categoriesResult = service.categories(pluginId: pid)
        async let countriesResult = service.countries(pluginId: pid)
        async let yearsResult = service.years(pluginId: pid)
        primary = await primaryResult
        categories = await categoriesResult
        countries = await countriesResult
        years = await yearsResult
        isLoading = false
    }
}

/// Glass chip for the Category blocks (mockup 03): name centred
/// on a glass card, inset focus ring at the card's own radius.
private struct TVCategoryChip: View {
    let title: String
    let onTap: () -> Void

    @Environment(\.tvTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            onTap()
        } label: {
            Text(title)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .contentShape(Rectangle())
        }
        .tvCardButton()
        .focused($isFocused)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isFocused ? Color.white.opacity(0.14) : theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isFocused ? theme.focusRing : theme.cardStroke,
                          lineWidth: isFocused ? theme.ringWidth : 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
