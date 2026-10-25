import SwiftUI

@main
struct CodexImageFactoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // ウィンドウは 1 枚だけ（モデルも 1 つ）。
        Window("Codex Image Factory", id: "main") {
            if let model = appDelegate.model {
                ContentView(model: model)
            } else {
                // ユニットテストのホストとして起動したとき・2 つ目として起動したときは、キューも codex も通知も動かさない。
                Text(RuntimeEnvironment.isRunningTests
                     ? "テスト実行中"
                     : "Codex Image Factory はすでに起動しています。そちらのウィンドウを使ってください。")
                    .padding()
                    .frame(minWidth: 320, minHeight: 200)
                    .accessibilityIdentifier("app.placeholder")
            }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(model: appDelegate.model)
        }
    }
}

/// メニューのコマンド。どれも画面のボタンでもできる操作の補助。
private struct AppCommands: Commands {
    let model: AppModel?

    var body: some Commands {
        // ウィンドウは 1 枚なので「新規」は出さない。
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appSettings) {
            Button("設定を表示") {
                model?.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(model == nil)
        }
    }
}
