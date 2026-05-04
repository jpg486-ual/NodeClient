//  Extensión iOS de RegisterView — chrome basado en NavigationStack
//  heredado del padre (LoginView push-based). Title inline para que
//  no ocupe altura excesiva.

#if os(iOS)
import SwiftUI

extension RegisterView {
    var platformRegisterShell: some View {
        registerFormContent
            .navigationTitle("Crear cuenta")
            .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
