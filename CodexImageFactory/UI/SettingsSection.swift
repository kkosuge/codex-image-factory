import SwiftUI

/// 左の列の折りたたみ式の設定。開け閉めは列の上の「設定を表示」「設定を隠す」で行う。
struct SettingsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("設定").font(.headline)
            if model.isSettingsVisible {
                GroupBox {
                    SettingsFields(model: model)
                        .padding(6)
                }
            } else {
                Text(
                    "出力ディレクトリ・codex のパス・並列数・タイムアウトなどは、この列のいちばん上の「設定を表示」で開きます。"
                        + (model.hasPendingSettingDrafts ? "まだ反映していない変更があります。" : "")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.hiddenNote")
            }
        }
    }
}

/// 下書きを使う入力欄（ほかの欄へ移ったら反映する）。
private enum SettingsDraftField: Hashable {
    case outputDirectory
    case codexPath
    case model
    case instructionTemplate
}

private struct SettingsFields: View {
    @Bindable var model: AppModel
    @FocusState private var focus: SettingsDraftField?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            applyDrafts
            outputDirectory
            Divider()
            codexPath
            loginStatus
            Divider()
            executionOptions
            Divider()
            instructionTemplate
        }
        // ほかの欄へ移ったら、離れた欄の内容を確かめて反映する。
        .onChange(of: focus) { old, _ in
            commit(old)
        }
        // 設定を閉じるなどで欄ごと消えたときも反映する。
        .onDisappear {
            commit(focus)
        }
    }

    private func commit(_ field: SettingsDraftField?) {
        switch field {
        case .outputDirectory: model.commitOutputDirectoryDraft()
        case .codexPath: model.commitCodexPathDraft()
        case .model: model.commitModelDraft()
        case .instructionTemplate: model.commitInstructionTemplateDraft()
        case nil: break
        }
    }

    private var outputDirectory: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldTitle("出力ディレクトリ")
            TextField("出力ディレクトリ", text: $model.outputDirectoryDraft, prompt: Text(AppSettings.defaultOutputDirectory))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($focus, equals: .outputDirectory)
                .onSubmit { model.commitOutputDirectoryDraft() }
                .axControl("出力ディレクトリ", id: "settings.outputDirectory")
            DraftStatus(
                error: model.outputDirectoryError,
                pending: model.isOutputDirectoryDraftPending,
                identifier: "settings.outputDirectory"
            )
            HStack(spacing: 8) {
                Button("フォルダを選択") {
                    FilePanels.chooseFolder(startingAt: model.settings.normalized().outputDirectoryURL) { url in
                        model.setOutputDirectory(url)
                    }
                }
                .axControl("出力ディレクトリのフォルダを選択", id: "settings.outputDirectory.choose")
                Button("Finder で開く") { model.openOutputDirectory() }
                    .axControl("出力ディレクトリを Finder で開く", id: "settings.outputDirectory.open")
            }
            Text("保存先: \(model.settings.normalized().outputDirectoryURL.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.outputDirectory.resolved")
        }
    }

    private var codexPath: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldTitle("codex のパス")
            TextField(
                "codex のパス",
                text: $model.codexPathDraft,
                prompt: Text(model.detectedCodexPath ?? "空欄なら自動検出したパスを使います")
            )
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .focused($focus, equals: .codexPath)
            .onSubmit { model.commitCodexPathDraft() }
            .axControl("codex のパス（空欄なら自動検出）", id: "settings.codexPath")
            DraftStatus(
                error: model.codexPathError,
                pending: model.isCodexPathDraftPending,
                identifier: "settings.codexPath"
            )
            HStack(spacing: 8) {
                Button("自動検出") { model.autoDetectCodexPath() }
                    .axControl("codex のパスを自動検出（入力欄を空にしてログインシェルで探し直す）", id: "settings.codexPath.detect")
            }
            Text(model.codexPathStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.codexPath.status")
        }
    }

    private var loginStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldTitle("ログイン状態")
            Text(model.codexCheck.label)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.loginStatus")
            Button("ログイン状態を再確認") { model.recheckLogin() }
                .axControl("ログイン状態を再確認", id: "settings.loginStatus.recheck")
            Text("ログインはアプリでは扱いません。未ログインならターミナルで codex login を実行してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var executionOptions: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                FieldTitle("並列数").gridColumnAlignment(.trailing)
                Picker("並列数", selection: $model.settings.concurrency) {
                    ForEach(Array(AppSettings.concurrencyRange), id: \.self) { n in
                        Text(verbatim: "\(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .axControl("並列数（1〜8）", id: "settings.concurrency")
            }
            GridRow(alignment: .firstTextBaseline) {
                FieldTitle("タイムアウト（分）")
                VStack(alignment: .leading, spacing: 4) {
                    TextField("タイムアウト（分）", text: $model.timeoutMinutesText, prompt: Text("10"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 90)
                        .axControl("タイムアウト（分）", id: "settings.timeoutMinutes")
                    if let error = model.timeoutError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings.timeoutMinutes.error")
                    } else {
                        Text(verbatim: "現在の値: \(model.settings.timeoutSeconds) 秒")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.timeoutMinutes.current")
                    }
                }
            }
            GridRow(alignment: .firstTextBaseline) {
                FieldTitle("モデル")
                VStack(alignment: .leading, spacing: 4) {
                    TextField("モデル（-m、空なら既定）", text: $model.modelDraft, prompt: Text("-m に渡す名前（空なら既定）"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($focus, equals: .model)
                        .onSubmit { model.commitModelDraft() }
                        .axControl("モデル（-m、空なら既定）", id: "settings.model")
                    DraftStatus(
                        error: model.modelError,
                        pending: model.isModelDraftPending,
                        identifier: "settings.model"
                    )
                }
            }
            GridRow {
                FieldTitle("推論の強さ")
                Picker("推論の強さ", selection: $model.settings.reasoningEffort) {
                    ForEach(ReasoningEffort.allCases) { effort in
                        Text(effort.label).tag(effort)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .axControl("推論の強さ", id: "settings.reasoningEffort")
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Toggle("--ephemeral を付ける", isOn: $model.settings.useEphemeral)
                    .toggleStyle(.checkbox)
                    .axControl("--ephemeral を付ける（Codex のセッションを残さない）", id: "settings.ephemeral")
            }
        }
    }

    private var instructionTemplate: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldTitle("固定の指示文")
            BorderedTextEditor(
                text: $model.instructionTemplateDraft,
                label: "固定の指示文",
                identifier: "settings.instructionTemplate",
                height: 150
            )
            .focused($focus, equals: .instructionTemplate)
            Text(
                model.isInstructionTemplateDraftPending
                    ? "まだ反映していません。入力が 1 秒止まるか、ほかの欄へ移ると反映します。"
                    : "入力が 1 秒止まるか、ほかの欄へ移ると反映します。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.instructionTemplate.hint")
            HStack {
                Button("既定に戻す") { model.resetInstructionTemplate() }
                    .disabled(
                        model.settings.instructionTemplate == AppSettings.defaultInstructionTemplate
                            && model.instructionTemplateDraft == AppSettings.defaultInstructionTemplate
                    )
                    .axControl("固定の指示文を既定に戻す", id: "settings.instructionTemplate.reset")
            }
            Text(
                "プロンプトの最後に付けます。置き換え: {count}（枚数）、{filenames}（`slug-01.png`、… の並び）、"
                    + "{slug}（スラッグ）、{size}（正方形（1:1）など）、{background}（背景の文。指定なしなら空）。"
                    + "空にすると既定の文を使います。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension SettingsFields {
    /// 入力欄の変更をまとめて反映するボタン。Return やフォーカス移動を送れないエージェントでも反映できるようにする。
    var applyDrafts: some View {
        HStack(spacing: 8) {
            Button("設定の変更を反映") {
                focus = nil
                model.commitSettingDrafts()
            }
            .disabled(!model.hasPendingSettingDrafts)
            .axControl("設定の変更を反映（出力ディレクトリ・codex のパス・モデル・固定の指示文）", id: "settings.applyDrafts")
            Text(model.hasPendingSettingDrafts ? "まだ反映していない変更があります" : "変更はすべて反映済みです")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.applyDrafts.status")
        }
    }
}

/// 下書きを使う入力欄の下に出す状態。だめな値なら理由を赤で、そうでなければ反映の仕方を出す。
private struct DraftStatus: View {
    let error: String?
    let pending: Bool
    let identifier: String

    var body: some View {
        if let error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifier).error")
        } else {
            Text(AppModel.draftHint(pending: pending))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifier).hint")
        }
    }
}
