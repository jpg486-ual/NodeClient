//  Picker de carpeta destino para `FilesViewModel.moveFile`.
//
//  Sheet SwiftUI que lista carpetas disponibles + raíz "/" como destinos
//  posibles. Los paths se calculan en `FilesView.availableFolders` desde
//  el snapshot SQLite filtrando `entry.entryType == .directory`.
//
//  macOS: chrome propio (header + footer con Cancelar) sin NavigationStack
//  para evitar el toolbar fantasma documentado en `LoginView+macOS.swift`.

import SwiftUI

struct MoveDestinationPickerView: View {
    let item: FileItem
    let availableFolders: [String]
    let onCancel: () -> Void
    let onPick: (String) -> Void

    var body: some View {
#if os(macOS)
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Mover")
                    .font(.title2.bold())
                Text("«\(item.name)»")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.top, 20)
            .padding(.bottom, 12)
            .padding(.horizontal, 20)

            folderList

            Divider()

            HStack {
                Spacer()
                Button("Cancelar", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 480)
#else
        NavigationStack {
            folderList
                .navigationTitle("Mover")
                .platformInlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancelar", action: onCancel)
                    }
                }
        }
#endif
    }

    private var folderList: some View {
        List {
            Section("Destino") {
                if availableFolders.isEmpty {
                    Text("No hay carpetas disponibles. Usa la raíz «/».")
                        .foregroundStyle(.secondary)
                }
                ForEach(availableFolders, id: \.self) { folder in
                    Button {
                        onPick(folder)
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.blue)
                            Text(folder)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
