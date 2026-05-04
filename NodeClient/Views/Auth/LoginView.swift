//  Vista de login — body platform-agnostic. La envoltura visual (NavStack
//  iOS vs panel fijo macOS) y el acceso al registro (NavigationLink iOS
//  vs sheet macOS) viven en `LoginView+iOS.swift` y `LoginView+macOS.swift`.

import SwiftUI

struct LoginView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @StateObject var viewModel: LoginViewModel
    /// Sheet de registro: macOS lo presenta como sheet modal; iOS usa
    /// `NavigationLink` y este flag queda inerte en esa plataforma.
    @State var isRegisterSheetPresented = false

    init() {
        // Lee del App Group shared UserDefaults (mismo store que
        // SessionStore). Fallback a .standard por si en dev hay valor
        // legacy en ese suite.
        let shared = NodeClientAppGroups.sharedUserDefaults()
        let baseURL = shared.string(forKey: SessionStore.baseURLKey)
            ?? UserDefaults.standard.string(forKey: SessionStore.baseURLKey)
            ?? "http://localhost:8081"
        _viewModel = StateObject(wrappedValue: LoginViewModel(baseURL: baseURL))
    }

    var body: some View {
        platformLoginShell
    }

    /// Cuerpo del Form — sin chrome de navegación, reusable por ambos
    /// shells (NavigationStack iOS, panel fijo macOS).
    var loginFormContent: some View {
        Form {
            Section("Node") {
                TextField("Base URL", text: $viewModel.baseURL)
                    .platformIdentifierField(.url)
            }

            Section("Credentials") {
                TextField("Username", text: $viewModel.username)
                    .platformIdentifierField()
                SecureField("Password", text: $viewModel.password)
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                signInButton
            }

            // Link a registro con código de invitación.
            // El access (NavigationLink en iOS, sheet en macOS) lo provee
            // la extensión correspondiente.
            Section {
                platformRegisterAccess
            }
        }
    }

    var signInButton: some View {
        Button {
            Task {
                await viewModel.login(sessionStore: sessionStore)
            }
        } label: {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Text("Sign In")
                    .frame(maxWidth: .infinity)
            }
        }
        .disabled(viewModel.isLoading)
        .accessibilityHint("Connects to your NodeClient server with the credentials above.")
    }
}

#Preview {
    LoginView()
        .environmentObject(SessionStore())
}
