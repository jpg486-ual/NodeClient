//  Colores cross-plataforma — `Color.platformCardBackground` es el
//  equivalente semántico al `secondarySystemBackground` de iOS sobre
//  `windowBackgroundColor` de macOS. Concentra el #if os y evita que
//  cada View importe UIKit/AppKit.

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Color {
    /// Fondo de fila / tarjeta — secondarySystemBackground en iOS,
    /// windowBackgroundColor en macOS.
    static var platformCardBackground: Color {
#if os(iOS)
        Color(uiColor: .secondarySystemBackground)
#elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(.gray).opacity(0.1)
#endif
    }
}
