import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var sessionStore: SessionStore

    let onLogout: () async -> Void
    let isLoggingOut: Bool
    let logoutMessage: String?
    let onDismissLogoutMessage: () -> Void
    /// Callback para refrescar perfil + usedBytes desde
    /// snapshot. Inyectado por el wrapper `MoreView` desde `MoreViewModel`.
    let role: String?
    let usedBytes: Int64
    let isRefreshingProfile: Bool
    let onRefreshProfile: () async -> Void
#if DEBUG
    let debugTelemetryRows: [DebugTelemetryRow]
    let onRefreshDebugTelemetry: () -> Void
    let onResetDebugTelemetry: () -> Void
#endif

    private let settingsItems: [MoreItem] = [
        MoreItem(title: "Cifrado", systemImage: "lock")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(settingsItems) { item in
                        NavigationLink(value: item.title) {
                            MoreRowView(item: item)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            await onLogout()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            if isLoggingOut {
                                ProgressView()
                            } else {
                                RoundedIconView(systemImage: "rectangle.portrait.and.arrow.right", tint: .red)
                            }
                            Text(isLoggingOut ? "Signing Out..." : "Sign Out")
                        }
                    }
                    .disabled(isLoggingOut)
                }

#if DEBUG
                Section("Debug Sync Metrics") {
                    ForEach(debugTelemetryRows, id: \.eventName) { row in
                        HStack {
                            Text(row.eventName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(row.value)")
                                .font(.body.monospacedDigit())
                        }
                    }

                    Button("Refresh") {
                        onRefreshDebugTelemetry()
                    }

                    Button("Reset Metrics", role: .destructive) {
                        onResetDebugTelemetry()
                    }
                }
#endif
            }
            .platformGroupedListStyle()
            .navigationTitle("Settings")
            .navigationDestination(for: String.self) { value in
                switch value {
                case "Cifrado":
                    EncryptionSettingsView(viewModel: makeEncryptionSettingsViewModel())

                default:
                    EmptyView()
                }
            }
            .safeAreaInset(edge: .bottom) {
                QuotaFooterView(
                    usageText: quotaUsageText,
                    detailText: quotaDetailText,
                    // El cliente puede calcularlo desde el snapshot
                    // SQLite. La barra de progreso refleja
                    // `usedBytes / (quotaMb * 1MB)` cuando ambos están
                    // disponibles.
                    progress: quotaProgress,
                    tint: .accentColor
                )
            }
            .task {
                await onRefreshProfile()
            }
            .refreshable {
                await onRefreshProfile()
            }
            .alert(
                "Sign Out",
                isPresented: Binding(
                    get: { logoutMessage != nil },
                    set: { newValue in
                        if !newValue {
                            onDismissLogoutMessage()
                        }
                    }
                ),
                actions: {
                    Button("OK", role: .cancel) {
                        onDismissLogoutMessage()
                    }
                },
                message: {
                    Text(logoutMessage ?? "")
                }
            )
        }
    }

    /// Copy actualizado: además del límite, mostramos
    /// `usedBytes` derivado del snapshot SQLite cuando hay datos.
    private var quotaUsageText: String {
        guard let quotaMb = sessionStore.quotaMb else {
            return "Quota desconocida"
        }
        if usedBytes > 0 {
            return "\(formattedBytes(usedBytes)) de \(formattedQuota(megabytes: quotaMb)) usados"
        }
        return "\(formattedQuota(megabytes: quotaMb)) disponibles"
    }

    private var quotaDetailText: String {
        if sessionStore.quotaMb == nil {
            return "Inicia sesión para ver tu cuota."
        }
        if let role {
            return "Rol: \(role)"
        }
        return "Cuota actualizada en tiempo real."
    }

    private var quotaProgress: Double? {
        guard let quotaMb = sessionStore.quotaMb, quotaMb > 0, usedBytes > 0 else {
            return nil
        }
        let totalBytes = Int64(quotaMb) * 1_024 * 1_024
        return min(1.0, Double(usedBytes) / Double(totalBytes))
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formattedQuota(megabytes: Int) -> String {
        let bytes = Int64(megabytes) * 1_024 * 1_024
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Factory para el view model del cifrado.
    /// Construye `EncryptionPasswordCoordinator` con el `KeychainEncryptionPasswordStore`
    /// real y
    /// vincula al `username` de la sesión activa. Si no hay sesión, usa
    /// `"anonymous"` como fallback (la View muestra "no configurado").
    private func makeEncryptionSettingsViewModel() -> EncryptionSettingsViewModel {
        let coordinator = EncryptionPasswordCoordinator(
            derivation: PasswordKeyDerivation(),
            store: NodeClientAppGroups.makeSharedEncryptionPasswordStore()
        )
        let username = sessionStore.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EncryptionSettingsViewModel(
            coordinator: coordinator,
            username: username?.isEmpty == false ? username! : "anonymous",
            keyVault: EncryptionKeyVault.shared
        )
    }
}

private struct MoreRowView: View {
    let item: MoreItem

    var body: some View {
        HStack(spacing: 12) {
            RoundedIconView(systemImage: item.systemImage, tint: .accentColor)
            Text(item.title)
                .font(.body)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
#if DEBUG
    MoreView(
        onLogout: {},
        isLoggingOut: false,
        logoutMessage: nil,
        onDismissLogoutMessage: {},
        role: "END_USER",
        usedBytes: 256 * 1_024 * 1_024,
        isRefreshingProfile: false,
        onRefreshProfile: {},
        debugTelemetryRows: [
            DebugTelemetryRow(eventName: "sync.incremental.attempt", value: 3),
            DebugTelemetryRow(eventName: "sync.full.fallback", value: 1)
        ],
        onRefreshDebugTelemetry: {},
        onResetDebugTelemetry: {}
    )
    .environmentObject(SessionStore())
#else
    MoreView(
        onLogout: {},
        isLoggingOut: false,
        logoutMessage: nil,
        onDismissLogoutMessage: {},
        role: "END_USER",
        usedBytes: 256 * 1_024 * 1_024,
        isRefreshingProfile: false,
        onRefreshProfile: {}
    )
    .environmentObject(SessionStore())
#endif
}
