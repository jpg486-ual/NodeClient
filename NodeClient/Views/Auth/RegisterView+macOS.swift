//  Extensión macOS de RegisterView — panel fijo con header (icono +
//  título), formStyle(.grouped) Mac-nativo y barra inferior con botón
//  Cancelar. Mismo lenguaje visual que `LoginView+macOS.swift` para que
//  el flujo de auth (login ↔ registro) se sienta coherente.

#if os(macOS)
import SwiftUI

extension RegisterView {
    var platformRegisterShell: some View {
        VStack(spacing: 0) {
            header

            registerFormContent
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)

            Divider()

            footer
        }
        .frame(width: 460, height: 620)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Crear cuenta")
                .font(.title2.bold())
            Text("Con código de invitación")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 28)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancelar") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
#endif
