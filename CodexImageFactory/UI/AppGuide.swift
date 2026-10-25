import SwiftUI

/// ウィンドウのいちばん上に出す使い方の説明。
///
/// このアプリを初めて操作する人や AI エージェントが、画面を見ただけで「何をするアプリか」「どこに何を入れて、
/// どこを押し、結果がどこに出るか」が分かるようにする。起動するたびに開いた状態で出る（閉じた状態は覚えない）。
struct AppGuide: View {
    let model: AppModel
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Codex Image Factory: Codex CLI を使って画像を生成し、フォルダに保存するアプリです。プロンプトを入れて「生成（キューに追加）」を押すだけで、複数のジョブを順に実行します。")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("guide.summary")
                Spacer(minLength: 8)
                Button(isExpanded ? "使い方を隠す" : "使い方を表示") {
                    isExpanded.toggle()
                }
                .axControl(isExpanded ? "使い方の説明を隠す" : "使い方の説明を表示", id: "guide.toggle")
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    step(1, "左の「プロンプト」に作りたい画像の説明を書き、「生成（キューに追加）」を押します。空行で区切って複数書き「まとめて追加」を押すと、1 段落ずつ別のジョブになります。")
                    step(2, "中央の「キュー」で、並列数の範囲で順に実行されます（1 枚およそ 1 分）。各行には「実行中 · スラッグ · 経過時間」のように状態が文字で出ます。")
                    step(3, "終わったジョブは下の「履歴」に移ります。行の「詳細」を押すと、右に生成画像のファイルのパスが文字で出ます（「パスをコピー」でコピーできます）。")
                    HStack(spacing: 4) {
                        Text("保存先:")
                        Text(verbatim: (model.settings.outputDirectoryURL.path as NSString).abbreviatingWithTildeInPath)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("guide.outputDirectory")
                        Text("（左の列のいちばん上の「設定を表示」で変えられます）")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("guide.steps")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("このアプリの使い方"))
        .accessibilityIdentifier("guide")
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("guide.step.\(number)")
    }
}
