import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// 操作部品に AX のラベルと識別子を付ける。エージェントはラベル名で部品を探す。
    /// 文字列リテラル（補間を含む）を渡すと、Localizable.xcstrings で翻訳される。
    func axControl(_ label: LocalizedStringKey, id: String) -> some View {
        accessibilityLabel(Text(label))
            .accessibilityIdentifier(id)
    }

    /// すでに翻訳済みの文字列（String(localized:) で作ったものなど）を渡す版。
    /// SwiftUI の Text と同じく総称型にしておかないと、文字列リテラルまでこちらに来て翻訳されなくなる。
    @_disfavoredOverload
    func axControl<S: StringProtocol>(_ label: S, id: String) -> some View {
        accessibilityLabel(Text(verbatim: String(label)))
            .accessibilityIdentifier(id)
    }
}

/// 項目名（小見出し）。
struct FieldTitle: View {
    let text: Text

    init(_ key: LocalizedStringKey) {
        text = Text(key)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ string: S) {
        text = Text(verbatim: String(string))
    }

    var body: some View {
        text
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// 枠付きの標準 TextEditor。AX で文字を入れられるよう、中身は素の TextEditor のまま。
struct BorderedTextEditor: View {
    @Binding var text: String
    let label: LocalizedStringKey
    let identifier: String
    var height: CGFloat
    var monospaced = false

    var body: some View {
        TextEditor(text: $text)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .scrollContentBackground(.hidden)
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier(identifier)
            .padding(6)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
    }
}

/// 選択できる文字の欄（パス・プロンプト・コマンドなど）。中身（value）は翻訳しない。
struct SelectableField: View {
    let title: LocalizedStringKey
    let value: String
    let identifier: String
    var monospaced = false
    var placeholder: LocalizedStringKey = "（なし）"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldTitle(title)
            Group {
                if value.isEmpty {
                    Text(placeholder)
                } else {
                    Text(verbatim: value)
                }
            }
            .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
            .foregroundStyle(value.isEmpty ? .secondary : .primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
        }
    }
}

/// 行の右側に出す小さな状態の文字（「編集中」「詳細に表示中」など）。
struct RowTag: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }
}

/// 空のペインに出す説明。
struct EmptyPaneText: View {
    let text: LocalizedStringKey
    let identifier: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(identifier)
    }
}

/// ファイル・フォルダ選択ダイアログ。テキスト欄の補助としてだけ使う。
@MainActor
enum FilePanels {
    static func chooseReferenceImages(_ completion: @escaping @MainActor ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.message = String(localized: "参照画像を選んでください（png / jpg / jpeg / webp、最大 \(ReferenceImageLimit.max) 枚）")
        panel.prompt = String(localized: "追加", comment: "Open panel confirm button for adding reference images")
        panel.begin { response in
            guard response == .OK else { return }
            completion(panel.urls)
        }
    }

    static func chooseFolder(startingAt directory: URL?, _ completion: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.message = String(localized: "生成画像を保存するフォルダを選んでください")
        panel.prompt = String(localized: "選択", comment: "Open panel confirm button for choosing the output folder")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }
}
