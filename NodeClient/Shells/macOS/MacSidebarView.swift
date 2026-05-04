//  Sidebar macOS — lista de destinos + footer con usuario, cuota y logout.

#if os(macOS)
import SwiftUI

struct MacSidebarView: View {
    @Binding var selection: SidebarDestination?
    let username: String?
    let quotaMb: Int?
    let usedBytes: Int64
    let role: String?
    let isLoggingOut: Bool
    let logoutMessage: String?
    let onLogout: () async -> Void
    let onDismissLogoutMessage: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(SidebarSection.allCases) { section in
                    Section(section.title) {
                        ForEach(section.destinations) { destination in
                            Label(destination.title, systemImage: destination.systemImage)
                                .tag(destination)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            footer
        }
        .navigationTitle("NodeClient")
        .frame(minWidth: 220, idealWidth: 240)
        .alert(
            "Sign Out",
            isPresented: Binding(
                get: { logoutMessage != nil },
                set: { newValue in
                    if !newValue { onDismissLogoutMessage() }
                }
            ),
            actions: {
                Button("OK", role: .cancel) { onDismissLogoutMessage() }
            },
            message: {
                Text(logoutMessage ?? "")
            }
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let username {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(username)
                            .font(.callout.bold())
                            .lineLimit(1)
                        if let role {
                            Text(role)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Text(quotaText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let progress = quotaProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }

            Button(role: .destructive) {
                Task { await onLogout() }
            } label: {
                if isLoggingOut {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Signing Out…")
                    }
                } else {
                    Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            .controlSize(.small)
            .disabled(isLoggingOut)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quotaText: String {
        guard let quotaMb else { return "Cuota desconocida" }
        let totalBytes = Int64(quotaMb) * 1_024 * 1_024
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        if usedBytes > 0 {
            return "\(formatter.string(fromByteCount: usedBytes)) / \(formatter.string(fromByteCount: totalBytes))"
        }
        return "Total: \(formatter.string(fromByteCount: totalBytes))"
    }

    private var quotaProgress: Double? {
        guard let quotaMb, quotaMb > 0, usedBytes > 0 else { return nil }
        let totalBytes = Int64(quotaMb) * 1_024 * 1_024
        return min(1.0, Double(usedBytes) / Double(totalBytes))
    }
}
#endif
