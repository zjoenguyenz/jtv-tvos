import SwiftUI

/// Settings skeleton (Phase 1) — survey §3.3.
///
/// Under the owner's bundling ruling every credential arrives
/// inside the build, so there are NO editable credential fields
/// here at all: each row is status-only, read from the
/// corresponding `BundledSecrets` value, and no part of any
/// secret value is ever displayed. Per the owner's standing
/// Settings design ruling there is no white outer frame around
/// rows, and a configured row carries a green dot/tick.
///
/// The one value read for the About section comes from the
/// bundle (never hardcoded); the app presents under its
/// disguised display name, "Media Service".
struct TVSettingsView: View {
    @EnvironmentObject private var session: PinSession

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        NavigationStack {
            List {
                credentialsSection
                if BundledSecrets.pinConfigured {
                    securitySection
                }
                diagnosticsSection
                aboutSection
            }
            .navigationTitle("Cài đặt")
        }
        .onAppear { session.touch() }
    }

    // MARK: - Credential status (bundled, status-only)

    private var credentialsSection: some View {
        Section {
            statusRow(label: "Real-Debrid",
                      configured: Self.isConfigured(BundledSecrets.rdToken))
            statusRow(label: "TorBox",
                      configured: Self.isConfigured(BundledSecrets.torboxToken))
            statusRow(label: "Premiumize",
                      configured: Self.isConfigured(BundledSecrets.premiumizeToken))
            statusRow(label: "MediaFusion",
                      configured: Self.isConfigured(BundledSecrets.mfURL))
        } header: {
            Text("Dịch vụ đã nạp sẵn")
        } footer: {
            Text("Mọi thông tin đăng nhập được nạp sẵn trong bản cài đặt — không cần nhập trên TV và không mất khi cài lại.")
        }
    }

    /// One status row: label on the left; on the right either a
    /// green dot + "Đã cấu hình ✓" or "Chưa cấu hình". The
    /// secret value itself never appears, in whole or in part.
    private func statusRow(label: String, configured: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            if configured {
                Circle()
                    .fill(Color.green)
                    .frame(width: 12, height: 12)
                Text("Đã cấu hình ✓")
                    .foregroundStyle(.secondary)
            } else {
                Text("Chưa cấu hình")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func isConfigured(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - App lock

    private var securitySection: some View {
        Section {
            NavigationLink {
                PinChangeView()
            } label: {
                Label("Đổi mã khóa app", systemImage: "lock.rotation")
            }
        } header: {
            Text("Khóa app")
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                LogExportView()
            } label: {
                Label("Gửi log chẩn đoán", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("Chẩn đoán")
        } footer: {
            Text("Khi app gặp lỗi, mở màn hình này và tải file log về iPhone để gửi lại. Log không chứa token hay link đã ký.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Ứng dụng")
                Spacer()
                Text("Media Service")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Phiên bản")
                Spacer()
                Text("\(appVersion) (\(appBuild))")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Giới thiệu")
        }
    }
}
