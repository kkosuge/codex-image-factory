import SwiftUI

/// 右の列: 選んだジョブの詳細（上）とログ（下）。
struct DetailColumn: View {
    let model: AppModel

    var body: some View {
        if let job = model.selectedJob {
            VSplitView {
                ScrollView {
                    DetailInfoView(job: job, model: model)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 選ぶジョブが変わったら作り直す。選択できる文字の欄は使い回すと
                        // アクセシビリティの値が前のジョブのまま残ることがあるため。
                        .id(job.id)
                }
                .frame(minHeight: 180, idealHeight: 500, maxHeight: .infinity)
                DetailLogPane(job: job, model: model)
                    .frame(minHeight: 140, idealHeight: 320, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 8) {
                Text("詳細").font(.title3.weight(.semibold))
                Text("キューか履歴の行で「詳細」を押すと、ここにプロンプト・コマンド・ログ・生成画像を表示します。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("detail.empty")
        }
    }
}

private struct DetailInfoView: View {
    let job: JobRecord
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            actions
            if let message = model.detailMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("detail.message")
            }
            if job.status != .done, let summary = job.errorSummary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    FieldTitle("エラーの要約")
                    Text(summary)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("detail.errorSummary")
                }
            }
            images
            SelectableField(
                title: "フォルダ",
                value: job.outputDir,
                identifier: "detail.folderPath",
                monospaced: true,
                placeholder: "（実行が始まると作られます）"
            )
            SelectableField(title: "プロンプト", value: job.prompt, identifier: "detail.prompt")
            if !job.preset.isEmpty {
                SelectableField(title: "スタイルプリセット（追加時点）", value: job.preset, identifier: "detail.preset")
            }
            if !job.referenceImages.isEmpty {
                SelectableField(
                    title: "参照画像",
                    value: job.referenceImages.joined(separator: "\n"),
                    identifier: "detail.referenceImages",
                    monospaced: true
                )
            }
            SelectableField(
                title: job.status == .queued ? "Codex に渡すプロンプト（見込み）" : "Codex に渡したプロンプト",
                value: job.fullPrompt,
                identifier: "detail.fullPrompt"
            )
            command
            times
            SelectableField(title: "最終メッセージ", value: job.lastMessage, identifier: "detail.lastMessage")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("詳細").font(.title3.weight(.semibold))
            if job.status.isFinished {
                Text(UIDisplayFormat.historyLine(job))
                    .font(.headline)
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .accessibilityIdentifier("detail.status")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(job.queueLine(now: context.date))
                        .font(.headline)
                        .monospacedDigit()
                        .accessibilityIdentifier("detail.status")
                }
            }
            switch job.status {
            case .running:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("実行中: \(job.slug)")
                    Text("codex exec を実行中です。ログは下に流れます。")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("中止") { Task { await model.cancel(job.id) } }
                        .axControl("中止: \(job.slug)", id: "detail.cancel")
                }
            case .queued:
                HStack(spacing: 8) {
                    Text("待機中です。実行が始まるとログが下に流れます。")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("編集") { model.beginEditing(job.id) }
                        .axControl("編集: \(job.slug)", id: "detail.edit")
                    Button("削除") { Task { await model.removeQueued(job.id) } }
                        .axControl("削除: \(job.slug)", id: "detail.delete")
                }
            case .done, .failed, .cancelled:
                EmptyView()
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Finder で表示") { model.revealInFinder(job) }
                .disabled(job.outputDir.isEmpty)
                .axControl("Finder で表示: \(job.slug)", id: "detail.revealInFinder")
            Button("このプロンプトを再利用") { model.reusePrompt(job) }
                .axControl("このプロンプトを再利用: \(job.slug)", id: "detail.reusePrompt")
            if job.status == .failed || job.status == .cancelled {
                Button("再試行") { Task { await model.retry(job) } }
                    .axControl("再試行: \(job.slug)", id: "detail.retry")
            }
        }
    }

    private var images: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldTitle("生成画像（\(job.images.count) 枚）")
            if job.images.isEmpty {
                Text(job.status.isFinished ? "生成画像はありません。" : "実行が終わると、ここに生成画像とパスを表示します。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.images.empty")
            } else {
                ForEach(Array(job.images.enumerated()), id: \.element) { index, path in
                    DetailImageTile(path: path, index: index, model: model)
                }
            }
        }
    }

    private var command: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FieldTitle("コマンド")
                Spacer()
                Button("コマンドをコピー") { model.copyCommand(job) }
                    .disabled(job.commandLine.isEmpty)
                    .controlSize(.small)
                    .axControl("コマンドをコピー: \(job.slug)", id: "detail.copyCommand")
            }
            Text(job.commandLine.isEmpty ? "（実行が始まると組み立てます）" : job.commandLine)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(job.commandLine.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("detail.command")
        }
    }

    private var times: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                FieldTitle("追加")
                Text(UIDisplayFormat.fullDate(job.createdAt))
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .accessibilityIdentifier("detail.createdAt")
            }
            GridRow {
                FieldTitle("開始")
                Text(UIDisplayFormat.fullDate(job.startedAt))
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .accessibilityIdentifier("detail.startedAt")
            }
            GridRow {
                FieldTitle("終了")
                Text(UIDisplayFormat.fullDate(job.finishedAt))
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .accessibilityIdentifier("detail.finishedAt")
            }
            GridRow {
                FieldTitle("終了コード")
                Text(job.exitCode.map { String($0) } ?? "—")
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .accessibilityIdentifier("detail.exitCode")
            }
            if let threadId = job.codexThreadId, !threadId.isEmpty {
                GridRow {
                    FieldTitle("スレッド ID")
                    Text(threadId)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("detail.threadId")
                }
            }
        }
    }
}

/// 生成画像 1 枚: サムネイルと、選択できるフルパス、開く・パスをコピー。
private struct DetailImageTile: View {
    let path: String
    let index: Int
    let model: AppModel
    @State private var thumbnail: CGImage?
    @State private var loadFailed = false

    var body: some View {
        let name = (path as NSString).lastPathComponent
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                CheckerboardBackground()
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else if loadFailed {
                    Text("読み込めません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .accessibilityElement()
            .accessibilityLabel("生成画像 \(index + 1) のサムネイル: \(name)")
            .accessibilityIdentifier("detail.image.\(index)")

            VStack(alignment: .leading, spacing: 6) {
                Text(path)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("detail.imagePath.\(index)")
                HStack(spacing: 6) {
                    Button("開く") { model.openImage(path) }
                        .axControl("画像を開く: \(name)", id: "detail.openImage.\(index)")
                    Button("パスをコピー") { model.copyPath(path) }
                        .axControl("画像のパスをコピー: \(name)", id: "detail.copyImagePath.\(index)")
                }
                .controlSize(.small)
                if loadFailed {
                    Text("画像を読み込めませんでした（移動・削除された可能性があります）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: path) {
            loadFailed = false
            let image = await ThumbnailLoader.shared.thumbnail(for: path)
            guard !Task.isCancelled else { return }
            thumbnail = image
            loadFailed = image == nil
        }
    }
}

/// 透過画像の下に敷く市松模様（飾り）。
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.94)))
            let rows = Int((size.height / cell).rounded(.up))
            let columns = Int((size.width / cell).rounded(.up))
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(Color(white: 0.82)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - ログ

private struct DetailLogPane: View {
    let job: JobRecord
    @Bindable var model: AppModel
    @State private var loaded: LoadedRunLog?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("ログ").font(.headline)
                Picker("ログの表示形式", selection: $model.logDisplayMode) {
                    ForEach(LogDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .axControl("ログの表示形式（整形 / 生データ）", id: "detail.logMode")
                Spacer()
                Text(sourceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.logSource")
            }
            content
        }
        .padding(12)
        .task(id: loadKey) {
            loaded = nil
            guard job.status.isFinished, model.liveLog(for: job.id) == nil else { return }
            let log = await model.loadRunLog(for: job)
            guard !Task.isCancelled else { return }
            loaded = log
        }
    }

    /// ライブログが捨てられたときも読み直すよう、その有無もキーに入れる。
    private var loadKey: String {
        "\(job.id.uuidString)|\(job.status.rawValue)|\(job.outputDir)|\(model.liveLog(for: job.id) != nil)"
    }

    private var sourceText: String {
        if model.liveLog(for: job.id) != nil {
            return job.status == .running ? "リアルタイム表示中" : "この起動中に受け取ったログ"
        }
        if job.status.isFinished {
            return "stdout.jsonl / stderr.log から読み込み"
        }
        return "まだ実行していません"
    }

    @ViewBuilder
    private var content: some View {
        if let live = model.liveLog(for: job.id) {
            LiveLogText(log: live, mode: model.logDisplayMode, autoScroll: job.status == .running)
        } else if job.status.isFinished {
            if let loaded {
                LogTextView(display: loaded.display(model.logDisplayMode), autoScroll: false)
            } else {
                Text("ログを読み込んでいます…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("detail.log")
            }
        } else {
            Text("実行が始まると、ここに stdout（JSONL）と stderr が流れます。")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("detail.log")
        }
    }
}

/// 実行中ジョブのログ。LiveJobLog だけを見るので、他のジョブの行では描き直さない。
private struct LiveLogText: View {
    let log: LiveJobLog
    let mode: LogDisplayMode
    let autoScroll: Bool

    var body: some View {
        LogTextView(display: log.display(mode), autoScroll: autoScroll)
    }
}

/// 等幅・選択できるログ。実行中は末尾へ自動でスクロールする。
private struct LogTextView: View {
    let display: LogDisplayText
    let autoScroll: Bool
    private let bottomID = "detail.log.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let note = display.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("detail.log.note")
                    }
                    Text(display.text.isEmpty ? "（ログはまだありません）" : display.text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("detail.log")
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: display.shownLines + display.omittedLines) {
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard autoScroll else { return }
        proxy.scrollTo(bottomID, anchor: .bottom)
    }
}
