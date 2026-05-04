//  Formato del archivo cifrado — NCE3 streaming chunked.
//
//  Header de 28 bytes:
//    [4 magic "NCE3"][1 version=1][1 flags][2 reserved]
//    [4 chunkPlainSize BE][8 totalPlainSize BE][8 nonceBase].
//  Tras el header, N frames de [chunkPlainSize bytes ciphertext]
//  [16 bytes tag], excepto el último frame cuyo ciphertext puede ser
//  menor. Nonce per-chunk = nonceBase || chunkIndex (12 bytes total).
//  Permite encrypt/decrypt streaming desde FileHandle sin cargar el
//  archivo en memoria.
//  
//  Implementación detallada en `Nce3StreamingCipher.swift`.

import CryptoKit
import Foundation

enum EncryptedFile {
    static let magicV3: [UInt8] = [0x4E, 0x43, 0x45, 0x33] // "NCE3"
    static let magicLength = 4
    static let nonceLength = 12
    static let v3HeaderLength = 28
    // v3 layout offsets (relativos al inicio del header):
    //   0..3   magic "NCE3"
    //   4      version (uint8 = 1)
    //   5      flags (uint8, reserved 0)
    //   6..7   reserved (zeros)
    //   8..11  chunkPlainSize (uint32 BE)
    //   12..19 totalPlainSize (uint64 BE)
    //   20..27 nonceBase (8 bytes random)

    /// Indica si los primeros 4 bytes son el magic NCE3 (chunked streaming).
    /// Único formato cifrado soportado por el cliente.
    static func isV3Magic(_ data: Data) -> Bool {
        guard data.count >= magicLength else { return false }
        return Array(data.prefix(magicLength)) == magicV3
    }

    /// Alias semántico de `isV3Magic`. Mantenido por compatibilidad de
    /// callers que comprueban si los bytes empiezan con un wire NCE.
    static func hasMagic(_ data: Data) -> Bool {
        isV3Magic(data)
    }
}
