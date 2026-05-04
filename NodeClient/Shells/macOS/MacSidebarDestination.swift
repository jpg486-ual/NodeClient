//  Destinos de la sidebar macOS — equivalentes a las "tabs" de iOS,
//  pero modelados como NavigationSplitView selection. Agrupados en
//  secciones (Contenido / Ajustes / Diagnóstico) que se renderizan
//  como Section headers en la sidebar.

#if os(macOS)
import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable, Hashable {
    case files
    case favorites
    case encryption
#if DEBUG
    case diagnostics
#endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files:
            return "Archivos"

        case .favorites:
            return "Favoritos"

        case .encryption:
            return "Cifrado"

#if DEBUG
        case .diagnostics:
            return "Diagnóstico"
#endif
        }
    }

    var systemImage: String {
        switch self {
        case .files:
            return "folder"

        case .favorites:
            return "star"

        case .encryption:
            return "lock.shield"

#if DEBUG
        case .diagnostics:
            return "stethoscope"
#endif
        }
    }
}

/// Agrupación visual de la sidebar — `Section` headers nativos Mac.
/// La sección de diagnóstico solo se compila en builds DEBUG; en release
/// el case no existe y la sidebar nunca lo enumera.
enum SidebarSection: String, CaseIterable, Identifiable {
    case content
    case settings
#if DEBUG
    case diagnostics
#endif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .content:
            return "Contenido"

        case .settings:
            return "Ajustes"

#if DEBUG
        case .diagnostics:
            return "Diagnóstico"
#endif
        }
    }

    var destinations: [SidebarDestination] {
        switch self {
        case .content:
            return [.files, .favorites]

        case .settings:
            return [.encryption]

#if DEBUG
        case .diagnostics:
            return [.diagnostics]
#endif
        }
    }
}
#endif
