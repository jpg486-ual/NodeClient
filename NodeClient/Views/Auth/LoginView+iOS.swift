//  Extensión iOS de LoginView — NavigationStack como envoltura del Form
//  y NavigationLink hacia RegisterView (push nativo iPhone).

#if os(iOS)
import SwiftUI

extension LoginView {
    var platformLoginShell: some View {
        NavigationStack {
            loginFormContent
                .navigationTitle("Node Login")
        }
    }

    var platformRegisterAccess: some View {
        NavigationLink {
            RegisterView(baseURL: viewModel.baseURL)
                .environmentObject(sessionStore)
        } label: {
            HStack {
                Text("¿No tienes cuenta?")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Crear cuenta")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .accessibilityHint("Crea una cuenta nueva con un código de invitación.")
    }
}
#endif
