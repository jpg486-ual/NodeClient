//  Extensión macOS de LoginView — panel fijo de tamaño acotado, sin
//  NavigationStack (que en macOS inflaba el form al ancho completo de
//  la ventana y mostraba un toolbar fantasma). El acceso a registro va
//  como sheet modal en lugar de push.

#if os(macOS)
import SwiftUI

extension LoginView {
    var platformLoginShell: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("NodeClient")
                    .font(.title.bold())
                Text("Inicia sesión en tu nodo")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            loginFormContent
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
        .frame(width: 460, height: 620)
        .sheet(isPresented: $isRegisterSheetPresented) {
            registerSheet
        }
    }

    var platformRegisterAccess: some View {
        Button {
            isRegisterSheetPresented = true
        } label: {
            HStack {
                Text("¿No tienes cuenta?")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Crear cuenta")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Abre el formulario de creación de cuenta con código de invitación.")
    }

    private var registerSheet: some View {
        // RegisterView+macOS provee su propio chrome (header + footer
        // con Cancelar). No envolvemos en NavigationStack para evitar
        // toolbar fantasma encima del panel.
        RegisterView(baseURL: viewModel.baseURL)
            .environmentObject(sessionStore)
    }
}
#endif
