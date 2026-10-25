import SwiftUI

/// メインウィンドウ。上にバナー、左に入力、中央にキューと履歴、右に詳細。タブやモーダルは使わない。
struct ContentView: View {
    let model: AppModel

    /// ウィンドウの中身の最小サイズ。
    static let minimumSize = CGSize(width: 1200, height: 640)

    var body: some View {
        VStack(spacing: 0) {
            BannerStack(model: model)
            HSplitView {
                InputColumn(model: model)
                    .frame(minWidth: 360, idealWidth: 420, maxWidth: 620, maxHeight: .infinity)
                QueueHistoryColumn(model: model)
                    .frame(minWidth: 380, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                DetailColumn(model: model)
                    .frame(minWidth: 400, idealWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 1440×900 の画面で Dock を出していても収まる大きさ（タイトルバーを足しても 700 pt 未満）。
        .frame(minWidth: ContentView.minimumSize.width, minHeight: ContentView.minimumSize.height)
        .onAppear { model.start() }
    }
}
