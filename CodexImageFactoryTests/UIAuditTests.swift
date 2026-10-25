import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexImageFactory

/// 要件「AI エージェントから操作するための UI 制約」の検査。
///
/// 1. メインウィンドウを画面外で組み立て、アクセシビリティツリーから読めるもの（画像パスが文字で出ているか、
///    失敗理由が出るか、メニューを開く部品が無いか）を確かめる。
///    プロセス内からはスクロール内の部品や SwiftUI のボタンの一部がツリーに出てこないので、
///    部品ごとのラベル・識別子は 2. のソース検査で確かめる。
/// 2. UI のソースを走査して、メニュー・シート・アラート・右クリックメニュー・ホバー専用の操作・アイコンだけのボタンが
///    無いこと、操作部品すべてに識別子が付いていることを確かめる。
///
/// 環境変数 `CIF_SNAPSHOT_DIR`（xcodebuild では `TEST_RUNNER_CIF_SNAPSHOT_DIR`）があれば、
/// 画面の PNG とアクセシビリティツリーをそこに書き出す（目視確認用）。
@Suite("UIAudit", .serialized)
@MainActor
struct UIAuditTests {
    struct Node {
        var role: String
        var subrole: String
        var label: String
        var title: String
        var identifier: String
        var value: String
        var depth: Int
    }

    /// メニューを開く部品・シート・ポップオーバー。
    static let forbiddenRoles: Set<String> = [
        NSAccessibility.Role.popUpButton.rawValue,
        NSAccessibility.Role.menuButton.rawValue,
        NSAccessibility.Role.comboBox.rawValue,
        NSAccessibility.Role.menu.rawValue,
        NSAccessibility.Role.sheet.rawValue,
        NSAccessibility.Role.popover.rawValue,
    ]

    // MARK: - 1. 画面

    @Test func mainWindowShowsStatesAndPathsAsText() async throws {
        let h = try UITHarness()
        defer { h.cleanUp() }
        let image1 = try Self.writePNG(in: h.home, name: "kina-mascot-01.png", color: .systemTeal)
        let image2 = try Self.writePNG(in: h.home, name: "kina-mascot-02.png", color: .systemOrange)
        let done = uitRecord(
            status: .done,
            slug: "kina-mascot",
            prompt: "丸いロボットのマスコット。フラットなベクターイラスト。",
            commandLine: "/opt/codex exec -C /tmp/out/kina-mascot -s workspace-write --skip-git-repo-check --json -o /tmp/out/kina-mascot/last-message.md -- '丸いロボット'",
            images: [image1.path, image2.path]
        )
        let failed = uitRecord(
            status: .failed,
            slug: "sea-sunset",
            prompt: "夕焼けの海辺",
            errorSummary: "画像ファイルが見つかりませんでした",
            createdAt: Date(timeIntervalSince1970: 1_792_990_000)
        )
        h.historyRecords = [done, failed]
        let model = h.makeModel()

        let (window, hosting) = Self.makeWindow(ContentView(model: model))
        defer { window.close() }
        #expect(await uitWaitUntil(timeout: .seconds(5)) { model.history.count == 2 })

        // キューに待機中 2 件・実行中 1 件を出す。
        var running = uitRecord(status: .running, slug: "app-icon", prompt: "アプリのアイコン")
        running.startedAt = Date().addingTimeInterval(-42)
        let now = Date()
        let queued = [
            uitRecord(status: .queued, slug: "sticker-cat", prompt: "猫のステッカー", createdAt: now.addingTimeInterval(-30)),
            uitRecord(status: .queued, slug: "hero-bg", prompt: "ヒーロー画像の背景", createdAt: now.addingTimeInterval(-12)),
        ]
        h.queue.emit(.snapshot(QueueSnapshot(queued: queued, running: [running], isPaused: false, concurrency: 3)))
        #expect(await uitWaitUntil(timeout: .seconds(5)) { model.running.count == 1 && model.queued.count == 2 })
        model.select(done.id)
        model.draft.prompt = "ステッカー風の猫\n\n水彩の背景"

        try await Self.settle(hosting)
        let nodes = Self.collect(hosting)
        Self.dump(nodes, image: hosting, name: "main")
        Self.expectNoForbiddenRoles(nodes, context: "メイン画面")
        // 状態は文字で、生成画像のパスは選択できる文字で出ている。
        #expect(Self.value(of: "detail.status", in: nodes).hasPrefix("完了 · kina-mascot"))
        #expect(Self.value(of: "detail.imagePath.0", in: nodes) == image1.path)
        #expect(Self.value(of: "detail.imagePath.1", in: nodes) == image2.path)
        #expect(Self.value(of: "detail.command", in: nodes) == done.commandLine)

        // 設定を開いた状態。
        model.isSettingsVisible = true
        try await Self.settle(hosting)
        let withSettings = Self.collect(hosting)
        Self.dump(withSettings, image: hosting, name: "settings")
        Self.expectNoForbiddenRoles(withSettings, context: "設定を開いた画面")

        // 失敗したジョブの詳細では、失敗の理由が文字で出る。
        model.isSettingsVisible = false
        model.select(failed.id)
        try await Self.settle(hosting)
        let failedNodes = Self.collect(hosting)
        Self.dump(failedNodes, image: hosting, name: "failed")
        Self.expectNoForbiddenRoles(failedNodes, context: "失敗ジョブの詳細")
        #expect(Self.value(of: "detail.status", in: failedNodes).hasPrefix("失敗 · sea-sunset"))
        let texts = failedNodes.map { $0.value + " " + $0.label + " " + $0.title }.joined(separator: "\n")
        #expect(texts.contains("画像ファイルが見つかりませんでした"))
    }

    // MARK: - 2. ソース検査

    /// UI のソース（App/ と UI/）。
    static func uiSources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexImageFactory", isDirectory: true)
        var out: [(String, String)] = []
        for dir in ["UI", "App"] {
            let url = root.appendingPathComponent(dir, isDirectory: true)
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() where name.hasSuffix(".swift") {
                let text = try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
                out.append(("\(dir)/\(name)", Self.stripComments(text)))
            }
        }
        return out
    }

    /// `//` コメントを落とす（説明文に API 名が出てきても誤検知しないように）。
    static func stripComments(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            guard let r = line.range(of: "//") else { return line }
            // 文字列の中の `//`（URL など）は残す。
            let before = line[..<r.lowerBound]
            if before.filter({ $0 == "\"" }).count % 2 == 1 { return line }
            return String(before)
        }.joined(separator: "\n")
    }

    @Test func noMenusModalsOrHoverOnlyControlsInSource() throws {
        let sources = try Self.uiSources()
        #expect(sources.count >= 5)
        let forbidden: [(pattern: String, why: String)] = [
            (#"\bMenu\s*[({]"#, "プルダウンメニュー"),
            (#"\.contextMenu\b"#, "右クリックメニュー"),
            (#"\.sheet\s*\("#, "モーダルシート"),
            (#"\.alert\s*\("#, "アラート"),
            (#"\.popover\s*\("#, "ポップオーバー"),
            (#"\.confirmationDialog\s*\("#, "確認ダイアログ"),
            (#"\.fileImporter\s*\("#, "ファイル選択だけの入力"),
            (#"\.fileExporter\s*\("#, "ファイル保存ダイアログ"),
            (#"\.onHover\b"#, "ホバーでしか出ない操作"),
            (#"\bStepper\s*\("#, "矢印だけの部品"),
            (#"\.labelStyle\(\s*\.iconOnly"#, "アイコンだけのボタン"),
            (#"\.pickerStyle\(\s*\.menu"#, "プルダウン"),
            (#"\bDisclosureGroup\s*\("#, "三角形だけの開閉部品"),
            (#"\bWKWebView\b|\bWebView\b"#, "WebView の入力欄"),
            (#"NSViewRepresentable"#, "独自の AppKit 部品（TextEditor 以外の入力欄）"),
        ]
        var problems: [String] = []
        for (name, text) in sources {
            for rule in forbidden where text.range(of: rule.pattern, options: .regularExpression) != nil {
                problems.append("\(name): \(rule.why)（\(rule.pattern)）")
            }
        }
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test func everyPickerIsRadioOrSegmented() throws {
        for (name, text) in try Self.uiSources() {
            let pickers = Self.controlBodies(of: ["Picker"], in: text)
            for body in pickers {
                let ok = body.range(of: #"\.pickerStyle\(\s*\.(radioGroup|segmented)"#, options: .regularExpression) != nil
                #expect(ok, "\(name): Picker に .radioGroup / .segmented が無い:\n\(body.prefix(300))")
            }
        }
    }

    @Test func everyControlHasLabelAndIdentifier() throws {
        let kinds = ["Button", "TextField", "SecureField", "Toggle", "Picker", "TextEditor", "Slider", "Link"]
        var checked = 0
        for (name, text) in try Self.uiSources() where !name.hasPrefix("App/") {
            for body in Self.controlBodies(of: kinds, in: text) {
                checked += 1
                let hasID = body.contains("axControl(") || body.contains(".accessibilityIdentifier(")
                #expect(hasID, "\(name): 識別子の無い部品:\n\(body.prefix(300))")
            }
            // アイコンだけのボタン: Button のラベルが Image だけ。
            let iconButton = #"Button\s*\{[^{}]*\}\s*label:\s*\{\s*Image\("#
            #expect(text.range(of: iconButton, options: .regularExpression) == nil, "\(name): アイコンだけのボタン")
            let iconButton2 = #"Button\s*\([^)]*systemImage:"#
            #expect(text.range(of: iconButton2, options: .regularExpression) == nil, "\(name): Label にアイコンを使ったボタン（文字が隠れることがある）")
        }
        #expect(checked > 40, "検査した部品が少なすぎる（\(checked) 件）")
    }

    /// 部品の生成から、次の部品の生成までのソース片を返す（識別子が付いているかを見るため）。
    static func controlBodies(of kinds: [String], in text: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9_.])("# + kinds.joined(separator: "|") + #")\s*(\(|\{)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var bodies: [String] = []
        for (i, m) in matches.enumerated() {
            let start = m.range.location
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: start, length: min(end - start, 3000)))
            // BorderedTextEditor の中の TextEditor のように、引数で受け取った識別子を付けるものも含めて検査する。
            bodies.append(body)
        }
        return bodies
    }

    // MARK: - ツリー

    static func expectNoForbiddenRoles(_ nodes: [Node], context: String) {
        #expect(nodes.count > 20, "\(context): アクセシビリティツリーが取れていない（\(nodes.count) 件）")
        let forbidden = nodes.filter { forbiddenRoles.contains($0.role) }
        #expect(forbidden.isEmpty, "\(context): 使ってはいけない部品: \(forbidden.map { "\($0.role)[\($0.identifier)] \($0.label)" })")
    }

    static func value(of identifier: String, in nodes: [Node]) -> String {
        nodes.first { $0.identifier == identifier }?.value ?? ""
    }

    static func collect(_ root: NSView) -> [Node] {
        var out: [Node] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ element: AnyObject, depth: Int) {
            guard depth < 60, visited.insert(ObjectIdentifier(element)).inserted else { return }
            guard let e = element as? NSAccessibilityProtocol else { return }
            let role = e.accessibilityRole()?.rawValue ?? ""
            if !role.isEmpty {
                out.append(Node(
                    role: role,
                    subrole: e.accessibilitySubrole()?.rawValue ?? "",
                    label: e.accessibilityLabel() ?? "",
                    title: e.accessibilityTitle() ?? "",
                    identifier: e.accessibilityIdentifier() ?? "",
                    value: (e.accessibilityValue() as? String) ?? "",
                    depth: depth
                ))
            }
            for child in e.accessibilityChildren() ?? [] {
                walk(child as AnyObject, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return out
    }

    // MARK: - 画面外のウィンドウ

    static func makeWindow<V: View>(_ view: V) -> (NSWindow, NSHostingView<V>) {
        let hosting = NSHostingView(rootView: view)
        let frame = NSRect(x: -20000, y: -20000, width: 1440, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrame(frame, display: false)
        window.orderBack(nil)
        // アクセシビリティ クライアントが来ているときと同じ扱いにして、SwiftUI に要素を作らせる。
        _ = NSApplication.shared.perform(
            NSSelectorFromString("accessibilitySetValue:forAttribute:"),
            with: NSNumber(value: true),
            with: "AXEnhancedUserInterface" as NSString
        )
        return (window, hosting)
    }

    static func settle(_ view: NSView) async throws {
        // SwiftUI は問い合わせが来てから要素を作るので、要素数が増えなくなるまでつついて更新を回す。
        var last = -1
        var stable = 0
        for _ in 0..<80 {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let count = collect(view).count
            stable = count == last ? stable + 1 : 0
            last = count
            if stable >= 5 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func dump(_ nodes: [Node], image view: NSView, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CIF_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: base.appendingPathComponent("\(name).png"))
            }
        }
        let text = nodes.map { n in
            String(repeating: "  ", count: min(n.depth, 30))
                + "\(n.role)\(n.subrole.isEmpty ? "" : "/" + n.subrole) id=\(n.identifier) label=\(n.label) title=\(n.title) value=\(n.value.prefix(80))"
        }.joined(separator: "\n")
        try? text.write(to: base.appendingPathComponent("\(name)-ax.txt"), atomically: true, encoding: .utf8)
    }

    static func writePNG(in dir: URL, name: String, color: NSColor) throws -> URL {
        let size = NSSize(width: 256, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 24, y: 24, width: 208, height: 208)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = dir.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }
}
