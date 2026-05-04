//  Detail panel macOS — enruta el destino seleccionado a la View concreta.
//
//  Reusa los `body` existentes (FilesView, FavoritesView, EncryptionSettingsView)
//  sin duplicación. Las ViewModels vienen del root shell y se mantienen vivas
//  mientras la ventana exista.

#if os(macOS)
import SwiftUI

struct MacDetailHost: View {
    let destination: SidebarDestination
    @ObservedObject var filesViewModel: FilesViewModel
    @ObservedObject var favoritesViewModel: FavoritesViewModel
    @ObservedObject var moreViewModel: MoreViewModel
    @Binding var filesFolderStack: [String]
    @EnvironmentObject private var sessionStore: SessionStore

    var body: some View {
        Group {
            switch destination {
            case .files:
                FilesView(
                    viewModel: filesViewModel,
                    favoritesViewModel: favoritesViewModel,
                    folderStack: $filesFolderStack
                )

            case .favorites:
                FavoritesView(
                    filesViewModel: filesViewModel,
                    favoritesViewModel: favoritesViewModel
                )

            case .encryption:
                EncryptionSettingsView(viewModel: makeEncryptionSettingsViewModel())
                    .formStyle(.grouped)

#if DEBUG
            case .diagnostics:
                MacDiagnosticsPanel(moreViewModel: moreViewModel)
#endif
            }
        }
    }

    /// Mismo factory que MoreView usaba en iOS — aquí lo replicamos en
    /// el host macOS para que la sidebar destination "Cifrado" pueda
    /// vivir como panel raíz sin pasar por MoreView.
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

#if DEBUG
/// Panel de diagnóstico — solo se compila en builds DEBUG. En release el
/// case `.diagnostics` ni siquiera existe en `SidebarDestination`, así que
/// no hay riesgo de alcanzar este panel ni de que se filtren strings al
/// binario. Expone las métricas de telemetría de sync.
private struct MacDiagnosticsPanel: View {
    @ObservedObject var moreViewModel: MoreViewModel

    var body: some View {
        Form {
            Section("Debug Sync Metrics") {
                ForEach(moreViewModel.debugTelemetryRows, id: \.eventName) { row in
                    HStack {
                        Text(row.eventName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(row.value)")
                            .font(.body.monospacedDigit())
                    }
                }

                HStack {
                    Button("Refresh") { moreViewModel.refreshDebugTelemetry() }
                    Button("Reset Metrics", role: .destructive) {
                        moreViewModel.resetDebugTelemetry()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnóstico")
    }
}
#endif
#endif
