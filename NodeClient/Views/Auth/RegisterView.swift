//  RegisterView SwiftUI.
//  Form de registro + autologin transparente.
//
//  El backend `POST /auth/register` devuelve `{username, quotaMb}` HTTP 201
//  pero **sin token**. `RegisterViewModel.register(...)` encadena un
//  `login(...)` con las mismas credenciales y persiste el token resultante
//  en `SessionStore`. UX: el usuario rellena el form y, al confirmar,
//  entra directamente a FilesView sin segundo paso.
//
//  Body platform-agnostic. Chrome (NavigationBar iOS vs panel fijo macOS)
//  vive en `RegisterView+iOS.swift` / `RegisterView+macOS.swift`.

import SwiftUI

struct RegisterView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @StateObject var viewModel: RegisterViewModel
    @Environment(\.dismiss)
    var dismiss

    init(baseURL: String) {
        _viewModel = StateObject(wrappedValue: RegisterViewModel(baseURL: baseURL))
    }

    var body: some View {
        platformRegisterShell
    }

    /// Cuerpo del Form sin chrome de navegación. Reusable por ambas
    /// plataformas; cada extensión añade su envoltura visual.
    var registerFormContent: some View {
        Form {
            Section("Node") {
                TextField("Base URL", text: $viewModel.baseURL)
                    .platformIdentifierField(.url)
            }

            Section("Código de invitación") {
                TextField("Código de invitación", text: $viewModel.invitationCode)
                    .platformIdentifierField()
            }

            Section("Credenciales") {
                TextField("Username", text: $viewModel.username)
                    .platformIdentifierField()
                SecureField("Password", text: $viewModel.password)
                SecureField("Confirmar contraseña", text: $viewModel.confirmPassword)
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                createAccountButton
            }
        }
    }

    var createAccountButton: some View {
        Button {
            Task {
                await viewModel.register(sessionStore: sessionStore)
                if viewModel.errorMessage == nil && sessionStore.sessionToken?.isEmpty == false {
                    dismiss()
                }
            }
        } label: {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Text("Crear cuenta")
                    .frame(maxWidth: .infinity)
            }
        }
        .disabled(viewModel.isLoading)
        .accessibilityHint("Registra el usuario con el código de invitación e inicia sesión automáticamente.")
    }
}

#Preview {
    RegisterView(baseURL: "http://localhost:8081")
        .environmentObject(SessionStore())
}
