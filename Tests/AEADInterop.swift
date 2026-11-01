import CryptoKit
import Foundation

// aead-interop seal            → prints "<key hex> <nonce+ciphertext+tag hex>" for a known message
// aead-interop open <key> <box> → opens a box made by the phone page and prints the text
func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
func unhex(_ text: String) -> Data {
    var data = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        data.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return data
}

let arguments = CommandLine.arguments
if arguments.count > 1, arguments[1] == "open" {
    let box = try ChaChaPoly.SealedBox(combined: unhex(arguments[3]))
    print(String(decoding: try ChaChaPoly.open(box, using: SymmetricKey(data: unhex(arguments[2])), authenticating: Data("aad".utf8)), as: UTF8.self))
} else {
    let key = SymmetricKey(size: .bits256)
    let message = Data("from the Mac, longer than one sixty-four byte ChaCha20 block, to cross a boundary".utf8)
    let box = try ChaChaPoly.seal(message, using: key, nonce: ChaChaPoly.Nonce(data: Data(repeating: 9, count: 12)), authenticating: Data("aad".utf8))
    print(hex(key.withUnsafeBytes { Data($0) }), hex(box.combined))
}
