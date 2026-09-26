// Generates the protocol section of testdata/protocol-v1.json from fixed inputs,
// following docs/ja/protocol.ja.md §4.2–4.4 literally with CryptoKit.
//
// Written separately from Sources/PanelCore on purpose: the tests check that the
// implementation reproduces what this straightforward reading of the
// specification produces, and the panel checks the same values with mbedTLS.
//
// Run: swift scripts/gen-protocol-vectors.swift > /tmp/protocol-section.json
import CryptoKit
import Foundation

func bytes(_ range: ClosedRange<UInt8>) -> [UInt8] { Array(range) }
func hex(_ data: some DataProtocol) -> String { data.map { String(format: "%02x", $0) }.joined() }
func keyBytes(_ key: SymmetricKey) -> [UInt8] { key.withUnsafeBytes { Array($0) } }

let k = bytes(0x00...0x1f)                 // 32 bytes
let deviceID = "3F2A"
let np = bytes(0xa0...0xaf)                // 16 bytes
let nc = bytes(0xb0...0xbf)                // 16 bytes
let aad = Array("m5-system-panel/1".utf8)

let ctx = Array(deviceID.utf8) + np + nc
let kcp = HKDF<SHA256>.expand(pseudoRandomKey: k, info: Array("m5-system-panel/1 c2p".utf8) + ctx, outputByteCount: 32)
let kpc = HKDF<SHA256>.expand(pseudoRandomKey: k, info: Array("m5-system-panel/1 p2c".utf8) + ctx, outputByteCount: 32)

func nonce(_ ctr: UInt64) -> AES.GCM.Nonce {
    var n = [UInt8](repeating: 0, count: 4)
    for shift in stride(from: 56, through: 0, by: -8) { n.append(UInt8((ctr >> UInt64(shift)) & 0xff)) }
    return try! AES.GCM.Nonce(data: n)
}

func frameLine(_ key: SymmetricKey, _ ctr: UInt64, _ plaintext: String) -> String {
    let box = try! AES.GCM.seal(Array(plaintext.utf8), using: key, nonce: nonce(ctr), authenticating: aad)
    return "F " + (box.ciphertext + box.tag).base64EncodedString()
}

let measurement0 = "M seq=0 cpu=23.4 cores=45,12,3,0 gpu=8.0 mem=12884901888/34359738368 app=6442450944 wired=2147483648 comp=1073741824 swap=0 press=0 if=en0 rx=1250000 tx=48000"
let measurement1 = "M seq=1 cpu=100.0 cores=100,7 gpu=- mem=1/2 app=0 wired=0 comp=0 swap=0 press=2 if=- rx=0 tx=0"
let ack0 = "A seq=- up=4508"
let ack1 = "A seq=0 up=5510"

let big = String(Int64.max)                   // 2^63 - 1: the largest <n>, 19 digits
let cores64 = Array(repeating: "100", count: 64).joined(separator: ",")
let longest = "M seq=\(big) cpu=100.0 cores=\(cores64) gpu=100.0 mem=\(big)/\(big) app=\(big) wired=\(big) comp=\(big) swap=\(big) press=2 if=\(String(repeating: "a", count: 15)) rx=\(big) tx=\(big)"
precondition(longest.utf8.count == 524, "longest plaintext is \(longest.utf8.count) bytes, spec says 524")

let out: [String: Any] = [
    "inputs": ["K": hex(k), "device_id": deviceID, "Np": hex(np), "Nc": hex(nc)],
    "hello_line": "HELLO 1 \(deviceID) \(Data(np).base64EncodedString())",
    "auth_line": "AUTH \(Data(nc).base64EncodedString())",
    "K_cp": hex(keyBytes(kcp)),
    "K_pc": hex(keyBytes(kpc)),
    "frames_c2p": [
        ["ctr": 0, "plaintext": measurement0, "line": frameLine(kcp, 0, measurement0)],
        ["ctr": 1, "plaintext": measurement1, "line": frameLine(kcp, 1, measurement1)],
        ["ctr": 2, "plaintext": longest, "line": frameLine(kcp, 2, longest)],
    ],
    "frames_p2c": [
        ["ctr": 0, "plaintext": ack0, "line": frameLine(kpc, 0, ack0)],
        ["ctr": 1, "plaintext": ack1, "line": frameLine(kpc, 1, ack1)],
    ],
]
let json = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: json, as: UTF8.self))
