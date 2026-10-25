import SwiftUI

/// 左の列: 入力・参照画像・スタイルプリセット・設定。上に設定の開閉ボタン、下に追加ボタンを固定する。
struct InputColumn: View {
    @Bindable var model: AppModel

    /// 設定の位置（スクロール先）。
    static let settingsAnchor = "input.settingsAnchor"

    var body: some View {
        VStack(spacing: 0) {
            SettingsToggleBar(model: model)
            Divider()
            ScrollViewReader { proxy in
                scrollContent
                    .onChange(of: model.settingsScrollRequest) {
                        // 開いた設定が並び終わってから、その位置までスクロールする。
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo(Self.settingsAnchor, anchor: .top)
                        }
                    }
            }
            Divider()
            SubmitBar(model: model)
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    PromptInputFields(model: model)
                        .padding(6)
                } label: {
                    Text("入力").font(.headline)
                }
                GroupBox {
                    ReferenceImageFields(model: model)
                        .padding(6)
                } label: {
                    Text("参照画像（最大 \(ReferenceImageLimit.max) 枚）").font(.headline)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        BorderedTextEditor(
                            text: $model.settings.stylePreset,
                            label: "スタイルプリセット",
                            identifier: "input.preset",
                            height: 80
                        )
                        Text("プロンプトの先頭に付ける定型文です。空なら付けません。起動し直しても残ります。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                } label: {
                    Text("スタイルプリセット").font(.headline)
                }
                SettingsSection(model: model)
                    .id(Self.settingsAnchor)
            }
            .padding(16)
        }
    }
}

/// 列の上に固定する設定の開閉。設定は列の下のほうにあるので、どこまでスクロールしていても押せるようにここに置く。
private struct SettingsToggleBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.toggle.status")
            Spacer(minLength: 4)
            Button(toggleTitle) { model.toggleSettings() }
                .axControl(toggleTitle, id: "settings.toggle")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toggleTitle: String {
        model.isSettingsVisible ? String(localized: "設定を隠す") : String(localized: "設定を表示")
    }

    private var statusText: String {
        var text = model.isSettingsVisible
            ? String(localized: "設定: 表示中（この列のいちばん下）")
            : String(localized: "設定: 隠しています")
        if model.hasPendingSettingDrafts {
            text += String(localized: "（まだ反映していない変更があります）")
        }
        return text
    }
}

/// プロンプト・スラッグ・枚数・サイズ・背景。
private struct PromptInputFields: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                FieldTitle("プロンプト")
                BorderedTextEditor(
                    text: $model.draft.prompt,
                    label: "プロンプト",
                    identifier: "input.prompt",
                    height: 180
                )
                Text("空行で区切って複数書くと、「まとめて追加」でそれぞれ 1 件のジョブになります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                FieldTitle("出力ファイル名（スラッグ）")
                TextField("出力ファイル名（スラッグ）", text: $model.draft.slug, prompt: Text("空なら日時（例: 20261024-153012）"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .axControl("出力ファイル名（スラッグ）", id: "input.slug")
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    FieldTitle("枚数").gridColumnAlignment(.trailing)
                    Picker("枚数", selection: $model.draft.count) {
                        ForEach(ImageCount.choices, id: \.self) { n in
                            Text("\(n) 枚").tag(n)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    .axControl("枚数", id: "input.count")
                }
                GridRow {
                    FieldTitle("サイズ")
                    Picker("サイズ", selection: $model.draft.aspect) {
                        ForEach(ImageAspect.allCases) { aspect in
                            Text(aspect.label).tag(aspect)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    .axControl("サイズ", id: "input.aspect")
                }
                GridRow {
                    FieldTitle("背景")
                    Picker("背景", selection: $model.draft.background) {
                        ForEach(ImageBackground.allCases) { background in
                            Text(background.label).tag(background)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                    .labelsHidden()
                    .axControl("背景", id: "input.background")
                }
            }
        }
    }
}

/// 参照画像: ドロップ欄・ファイル選択・パス入力・追加済みの一覧。
private struct ReferenceImageFields: View {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            dropZone

            HStack(spacing: 8) {
                Button("ファイルを選択") {
                    FilePanels.chooseReferenceImages { urls in
                        model.addReferenceURLs(urls)
                    }
                }
                .disabled(isFull)
                .axControl("参照画像のファイルを選択", id: "input.reference.choose")
                Spacer()
                Text("\(model.draft.referenceImages.count) / \(ReferenceImageLimit.max) 枚")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("input.reference.count")
            }

            VStack(alignment: .leading, spacing: 4) {
                FieldTitle("パスを入力")
                HStack(spacing: 8) {
                    TextField("参照画像のパス", text: $model.referencePathInput, prompt: Text("/Users/…/ref.png または ~/…"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit { model.addReferenceFromInput() }
                        .axControl("参照画像のパスを入力", id: "input.reference.pathField")
                    Button("パスを追加") { model.addReferenceFromInput() }
                        .disabled(model.referencePathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .axControl("入力したパスを参照画像に追加", id: "input.reference.addPath")
                }
            }

            if let error = model.referenceError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("input.reference.error")
            }

            if model.draft.referenceImages.isEmpty {
                Text("参照画像はありません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.draft.referenceImages.enumerated()), id: \.offset) { index, path in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "\(index + 1).")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(verbatim: path)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("input.reference.path.\(index)")
                            Button("削除") { model.removeReference(at: index) }
                                .controlSize(.small)
                                .axControl(
                                    "参照画像を削除: \((path as NSString).lastPathComponent)",
                                    id: "input.reference.remove.\(index)"
                                )
                        }
                    }
                }
            }
        }
    }

    private var isFull: Bool {
        model.draft.referenceImages.count >= ReferenceImageLimit.max
    }

    private var dropZone: some View {
        VStack(spacing: 4) {
            Text(
                isDropTargeted
                    ? String(localized: "ここで離すと追加します")
                    : String(localized: "ここに画像ファイルをドラッグ＆ドロップ")
            )
                .font(.callout.weight(.medium))
            Text("png / jpg / jpeg / webp")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            model.addReferenceURLs(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("参照画像のドロップ欄。画像ファイルをここにドラッグ＆ドロップすると追加します")
        .accessibilityIdentifier("input.reference.drop")
    }
}

/// 左の列の下に固定する追加ボタン。編集中は保存・やめるに切り替える。
private struct SubmitBar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = model.editingStatusText {
                Text(status)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("input.editingStatus")
            }
            HStack(spacing: 8) {
                if model.isEditing {
                    // ジョブが待機中でなくなっていても押せる（編集した内容を入力欄に残して編集を終える）。
                    Button("変更を保存") { Task { await model.saveEdit() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSaveEdit)
                        .axControl("変更を保存（編集中の待機中ジョブ）", id: "input.saveEdit")
                    Button("編集をやめる") { model.cancelEditing() }
                        .axControl("編集をやめる", id: "input.cancelEdit")
                } else {
                    Button("生成（キューに追加）") { Task { await model.addSingle() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.draft.canSubmit)
                        .axControl("生成（キューに追加）", id: "input.submit")
                    Button(batchTitle) { Task { await model.addBatch() } }
                        .disabled(model.draft.batchCount == 0)
                        .axControl(batchTitle, id: "input.submitBatch")
                    if model.canRestoreStashedDraft {
                        Button("編集前の入力に戻す") { model.restoreStashedDraft() }
                            .axControl("編集前の入力に戻す（いまの入力は消えます）", id: "input.restoreStashedDraft")
                    }
                }
                Spacer(minLength: 0)
            }
            .controlSize(.large)
            if let message = model.inputMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("input.message")
            } else {
                Text(
                    model.isEditing
                        ? String(localized: "⌘↩ でも保存できます。")
                        : String(localized: "⌘↩ でも「生成（キューに追加）」できます。")
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var batchTitle: String {
        String(localized: "まとめて追加（\(model.draft.batchCount) 件）")
    }
}
