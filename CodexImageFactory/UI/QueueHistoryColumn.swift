import SwiftUI

/// 中央の列: 上がキュー（待機中・実行中）、下が履歴（完了済み）。
struct QueueHistoryColumn: View {
    let model: AppModel

    var body: some View {
        VSplitView {
            QueuePane(model: model)
                .frame(minHeight: 170, idealHeight: 420, maxHeight: .infinity)
            HistoryPane(model: model)
                .frame(minHeight: 150, idealHeight: 380, maxHeight: .infinity)
        }
    }
}

// MARK: - キュー

private struct QueuePane: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("キュー").font(.title3.weight(.semibold))
                    Spacer()
                    Button("すべて一時停止") { Task { await model.pauseAll() } }
                        .disabled(model.isPaused && !model.isResumePending)
                        .axControl("すべて一時停止", id: "queue.pauseAll")
                    Button("再開") { Task { await model.resumeAll() } }
                        .disabled(!model.isPaused || model.isResumePending)
                        .axControl("キューを再開", id: "queue.resumeAll")
                }
                Text(model.queueSummaryText)
                    .monospacedDigit()
                    .accessibilityIdentifier("queue.summary")
                Text(model.queueStateText)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("queue.state")
                if let message = model.queueMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("queue.message")
                }
            }
            .padding(12)
            Divider()
            if model.running.isEmpty && model.queued.isEmpty {
                EmptyPaneText(
                    text: "待機中・実行中のジョブはありません。左の「生成（キューに追加）」で追加すると、ここに並んで自動で実行されます。",
                    identifier: "queue.empty"
                )
            } else {
                // 画面外の行もアクセシビリティツリーに出すため、Lazy でない VStack で全部作る。
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.running.enumerated()), id: \.element.id) { index, job in
                            QueueRowView(job: job, ordinal: index, waiting: nil, model: model)
                        }
                        let offset = model.running.count
                        ForEach(Array(model.queued.enumerated()), id: \.element.id) { index, job in
                            QueueRowView(job: job, ordinal: offset + index, waiting: (index, model.queued.count), model: model)
                        }
                    }
                }
            }
        }
    }
}

/// キューの 1 行。「2 番目」「待機中 · kina-mascot · 0:42」の 1 行と、常に見えるボタン。
private struct QueueRowView: View {
    let job: JobRecord
    /// ペインの中の通し番号（0 始まり。実行中の行から数える）。
    let ordinal: Int
    /// 待機中のときの（待機中の中の順番, 待機中の件数）。
    let waiting: (index: Int, count: Int)?
    let model: AppModel

    var body: some View {
        let id = job.id.uuidString
        let isSelected = model.selectedJobID == job.id
        let position = UIDisplayFormat.queuePosition(ordinal)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(position)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("queue.row.\(id).position")
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(job.queueLine(now: context.date))
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                        .accessibilityIdentifier("queue.row.\(id).status")
                }
                if job.status == .running {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("実行中: \(position) \(job.slug)")
                }
                Spacer(minLength: 4)
                if model.editingJobID == job.id {
                    RowTag(text: "編集中")
                }
                if isSelected {
                    RowTag(text: "詳細に表示中")
                }
            }
            Text(UIDisplayFormat.firstLine(job.prompt))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if job.status == .running {
                    Button("中止") { Task { await model.cancel(job.id) } }
                        .axControl(label("中止", position), id: "queue.row.\(id).cancel")
                } else {
                    Button("上へ") { Task { await model.moveUp(job.id) } }
                        .disabled((waiting?.index ?? 0) == 0)
                        .axControl(label("上へ", position), id: "queue.row.\(id).up")
                    Button("下へ") { Task { await model.moveDown(job.id) } }
                        .disabled(waiting.map { $0.index >= $0.count - 1 } ?? true)
                        .axControl(label("下へ", position), id: "queue.row.\(id).down")
                    Button("編集") { model.beginEditing(job.id) }
                        .axControl(label("編集", position), id: "queue.row.\(id).edit")
                    Button("削除") { Task { await model.removeQueued(job.id) } }
                        .axControl(label("削除", position), id: "queue.row.\(id).delete")
                }
                Button("詳細") { model.select(job.id) }
                    .axControl(label("詳細", position), id: "queue.row.\(id).detail")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(position) \(job.status.label)のジョブ: \(job.slug)")
        .accessibilityIdentifier("queue.row.\(id)")
    }

    private func label(_ action: String, _ position: String) -> String {
        UIDisplayFormat.rowControlLabel(action, position: position, slug: job.slug)
    }
}

// MARK: - 履歴

private struct HistoryPane: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("履歴").font(.title3.weight(.semibold))
                    Text(verbatim: "\(model.history.count) 件")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("history.count")
                    Spacer()
                    Button("履歴を再読み込み") { model.reloadHistory() }
                        .axControl("履歴を再読み込み", id: "history.reload")
                }
                if model.isLoadingHistory {
                    Text("履歴を読み込んでいます…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("history.loading")
                }
            }
            .padding(12)
            Divider()
            if model.history.isEmpty {
                EmptyPaneText(
                    text: model.isLoadingHistory ? "履歴を読み込んでいます…" : "履歴はまだありません。終わったジョブが新しい順に並びます。",
                    identifier: "history.empty"
                )
            } else {
                // 画面外の行もアクセシビリティツリーに出すため Lazy でない VStack にする。
                // 件数が多いと重くなるので、新しい順に AppModel.historyPageSize 件ずつ並べる。
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.visibleHistory.enumerated()), id: \.element.id) { index, record in
                            HistoryRowView(record: record, ordinal: index, model: model)
                        }
                        let hidden = model.hiddenHistoryCount
                        if hidden > 0 {
                            Button("さらに表示（残り \(hidden) 件）") { model.showMoreHistory() }
                                .axControl("履歴をさらに表示（残り \(hidden) 件）", id: "history.showMore")
                                .padding(12)
                        }
                    }
                }
            }
        }
    }
}

/// 履歴の 1 行。「完了 · kina-mascot · 1:02 · 2 枚 · 10/24 15:30」
private struct HistoryRowView: View {
    let record: JobRecord
    /// 新しい順の番号（0 始まり）。
    let ordinal: Int
    let model: AppModel

    var body: some View {
        let id = record.id.uuidString
        let isSelected = model.selectedJobID == record.id
        let canRetry = record.status == .failed || record.status == .cancelled
        let position = UIDisplayFormat.historyPosition(ordinal)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(UIDisplayFormat.ordinal(ordinal))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("history.row.\(id).position")
                Text(UIDisplayFormat.historyLine(record))
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                    .accessibilityIdentifier("history.row.\(id).status")
                Spacer(minLength: 4)
                if isSelected {
                    RowTag(text: "詳細に表示中")
                }
            }
            Text(UIDisplayFormat.firstLine(record.prompt))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
            if canRetry, let summary = record.errorSummary, !summary.isEmpty {
                Text("理由: \(UIDisplayFormat.firstLine(summary))")
                    .font(.caption)
                    .lineLimit(2)
                    .accessibilityIdentifier("history.row.\(id).error")
            }
            HStack(spacing: 6) {
                Button("詳細") { model.select(record.id) }
                    .axControl(label("詳細", position), id: "history.row.\(id).detail")
                if canRetry {
                    Button("再試行") { Task { await model.retry(record) } }
                        .axControl(label("再試行", position), id: "history.row.\(id).retry")
                }
                Button("削除") { Task { await model.deleteHistory(record) } }
                    .axControl(label("履歴から削除（画像は残す）", position), id: "history.row.\(id).delete")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(position): \(record.status.label) · \(record.slug)")
        .accessibilityIdentifier("history.row.\(id)")
    }

    private func label(_ action: String, _ position: String) -> String {
        UIDisplayFormat.rowControlLabel(action, position: position, slug: record.slug)
    }
}
