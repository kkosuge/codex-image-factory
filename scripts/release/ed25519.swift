// Sparkle の EdDSA（Ed25519）鍵の補助。リリース前の確認に使う。
//
//   swift ed25519.swift public-key <秘密鍵ファイル>        公開鍵（SUPublicEDKey に入れる値）を出す
//   swift ed25519.swift verify <公開鍵> <署名> <ファイル>  署名を確かめる（合っていれば終了コード 0）
//
// 秘密鍵ファイルは Sparkle の generate_keys -x で書き出したもの（base64 の 32 バイトの seed）。
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func decode(_ base64: String, what: String) -> Data {
    guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("\(what) を base64 として読めません")
    }
    return data
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("使い方: ed25519.swift public-key <秘密鍵ファイル> | verify <公開鍵> <署名> <ファイル>") }

switch args[1] {
case "public-key":
    guard args.count == 3, let text = try? String(contentsOfFile: args[2], encoding: .utf8) else { fail("秘密鍵ファイルを読めません") }
    var raw = decode(text, what: "秘密鍵")
    // 古い形式（seed + 公開鍵の 64 バイト）でも、先頭 32 バイトが seed。
    if raw.count == 64 { raw = raw.prefix(32) }
    guard raw.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("秘密鍵の長さが違います（\(raw.count) バイト）") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "verify":
    guard args.count == 5 else { fail("使い方: ed25519.swift verify <公開鍵> <署名> <ファイル>") }
    let pub = decode(args[2], what: "公開鍵")
    let sig = decode(args[3], what: "署名")
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { fail("公開鍵の長さが違います") }
    guard let file = FileManager.default.contents(atPath: args[4]) else { fail("ファイルを読めません: \(args[4])") }
    if key.isValidSignature(sig, for: file) {
        print("署名は正しい")
    } else {
        fail("署名が合いません。アプリに入れた公開鍵と、署名に使った秘密鍵が対になっていません")
    }
case "generate-test-key":
    // テスト用。本番の鍵は generate_keys で作り、キーチェーンに入れる。
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString())
default:
    fail("不明な指定: \(args[1])")
}
