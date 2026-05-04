import SwiftUI

struct FileRowView: View {
    let item: FileItem
    let isDownloading: Bool
    let downloadProgress: Double
    let onDownload: () -> Void
    let onCancelDownload: () -> Void
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    let onTap: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    private let rowBackground = Color.platformCardBackground

    /// Compone `<detail> · v<N> · hace <X>` apendiendo solo los segmentos
    /// con datos. La fecha relativa se evalúa en cada render para que
    /// "hace 5 min" no se quede congelado.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private var detailLine: String {
        var parts: [String] = [item.detail]
        if item.version > 0 {
            parts.append("v\(item.version)")
        }
        if let updatedAt = item.updatedAt {
            parts.append(Self.relativeFormatter.localizedString(for: updatedAt, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            // Zona izquierda (icono + nombre + spacer) clickable como un
            // todo para navegar dentro de la carpeta. Los Buttons del
            // bloque derecho son leaf hit-targets en SwiftUI y consumen
            // su tap antes de que llegue al `onTapGesture` del HStack
            // contenedor — el split funciona en iOS y macOS sin
            // conflicto. `contentShape(Rectangle())` extiende el área
            // tappable a todo el ancho incluyendo el `Spacer`.
            HStack(spacing: 12) {
                RoundedIconView(systemImage: item.systemImage, tint: item.isFolder ? .blue : .gray)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(detailLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(item.isFolder ? .isButton : [])
            .accessibilityHint(item.isFolder ? "Abre la carpeta." : "Sin acción; usa los botones laterales.")

            HStack(spacing: 6) {
                if !item.isFolder {
                    if isDownloading {
                        HStack(spacing: 6) {
                            ProgressView(value: downloadProgress)
                                .frame(width: 46)
                            Button(action: onCancelDownload) {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Cancelar descarga de \(item.name)")
                        }
                    } else {
                        Button(action: onDownload) {
                            Image(systemName: "arrow.down.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Descargar \(item.name)")
                    }
                }
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                .accessibilityLabel(isFavorite ? "Quitar de favoritos" : "Marcar favorito")
                Button(action: onRename) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Renombrar \(item.name)")
                .accessibilityHint(item.isFolder ? "Cambia el nombre de la carpeta." : "Cambia el nombre del archivo manteniendo la carpeta.")
                Button(action: onMove) {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Mover \(item.name)")
                .accessibilityHint("Mueve el elemento a otra carpeta.")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Eliminar \(item.name)")
                .accessibilityHint("Borra el elemento permanentemente; pedirá confirmación.")
                if item.isShared {
                    TagBadge(title: "Shared", tint: .orange)
                }
                if item.isOffline {
                    TagBadge(title: "Offline", tint: .teal)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(rowBackground)
        )
    }
}
