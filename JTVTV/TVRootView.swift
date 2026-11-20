import SwiftUI

/// The post-unlock shell (Phase 1).
///
/// This is deliberately a SHELL, not the catalogue: browse and
/// playback arrive in later phases. What exists now is real and
/// navigable — a TabView with the home placeholder and the
/// Settings tab — over a full-bleed true-black background
/// (register R-10: the root background ignores the safe area
/// from the very first shell, the JoeTV bright-rim fault).
///
/// Activity hooks for the PIN idle rule (survey §4): the
/// shell's appearance and every tab change refresh
/// `PinSession.lastActivity` via `touch()`. Later phases add
/// their own `touch()` calls at their interaction points and
/// drive `setPlaybackActive(_:)` from the players.
struct TVRootView: View {
    @EnvironmentObject private var session: PinSession
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            HomePlaceholderView()
                .tabItem {
                    Label("Trang chủ", systemImage: "house")
                }
                .tag(0)

            TVSettingsView()
                .tabItem {
                    Label("Cài đặt", systemImage: "gearshape")
                }
                .tag(1)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { session.touch() }
        .onChange(of: selection) { _, _ in
            session.touch()
        }
    }
}

/// Phase-1 home placeholder: the disguised display name and one
/// honest line that the catalogue arrives in the next phase.
/// No fake shelves, no stand-in content.
private struct HomePlaceholderView: View {
    @EnvironmentObject private var session: PinSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("Media Service")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(.white)
                Text("Danh mục sẽ có trong giai đoạn tiếp theo.")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .onAppear { session.touch() }
    }
}
