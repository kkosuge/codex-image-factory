import Foundation

/// AppSettings を UserDefaults に保存する。項目ごとに 1 キー。
struct SettingsStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    enum Key {
        static let outputDirectory = "settings.outputDirectory"
        static let codexPath = "settings.codexPath"
        static let concurrency = "settings.concurrency"
        static let timeoutSeconds = "settings.timeoutSeconds"
        static let stylePreset = "settings.stylePreset"
        static let instructionTemplate = "settings.instructionTemplate"
        static let model = "settings.model"
        static let reasoningEffort = "settings.reasoningEffort"
        static let useEphemeral = "settings.useEphemeral"

        static let all = [
            outputDirectory, codexPath, concurrency, timeoutSeconds, stylePreset,
            instructionTemplate, model, reasoningEffort, useEphemeral,
        ]
    }

    /// 保存済みの設定。無い項目・型の合わない項目は既定値にして、範囲外の値は丸める。
    func load() -> AppSettings {
        var s = AppSettings.defaults
        if let v = defaults.object(forKey: Key.outputDirectory) as? String { s.outputDirectory = v }
        if let v = defaults.object(forKey: Key.codexPath) as? String { s.codexPath = v }
        if let v = integer(Key.concurrency) { s.concurrency = v }
        if let v = integer(Key.timeoutSeconds) { s.timeoutSeconds = v }
        if let v = defaults.object(forKey: Key.stylePreset) as? String { s.stylePreset = v }
        if let v = defaults.object(forKey: Key.instructionTemplate) as? String { s.instructionTemplate = v }
        if let v = defaults.object(forKey: Key.model) as? String { s.model = v }
        if let raw = defaults.object(forKey: Key.reasoningEffort) as? String,
           let effort = ReasoningEffort(rawValue: raw) {
            s.reasoningEffort = effort
        }
        if let v = defaults.object(forKey: Key.useEphemeral) as? NSNumber, !isString(Key.useEphemeral) {
            s.useEphemeral = v.boolValue
        }
        return s.normalized()
    }

    /// 入力途中の値（空の出力ディレクトリなど）もそのまま保存する。丸めは load() でする。
    func save(_ s: AppSettings) {
        defaults.set(s.outputDirectory, forKey: Key.outputDirectory)
        defaults.set(s.codexPath, forKey: Key.codexPath)
        defaults.set(s.concurrency, forKey: Key.concurrency)
        defaults.set(s.timeoutSeconds, forKey: Key.timeoutSeconds)
        defaults.set(s.stylePreset, forKey: Key.stylePreset)
        defaults.set(s.instructionTemplate, forKey: Key.instructionTemplate)
        defaults.set(s.model, forKey: Key.model)
        defaults.set(s.reasoningEffort.rawValue, forKey: Key.reasoningEffort)
        defaults.set(s.useEphemeral, forKey: Key.useEphemeral)
    }

    /// 整数として読めるときだけ返す（文字列や小数は無視する）。
    private func integer(_ key: String) -> Int? {
        guard let number = defaults.object(forKey: key) as? NSNumber, !isString(key) else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value == value.rounded(), abs(value) < Double(Int32.max) else { return nil }
        return number.intValue
    }

    private func isString(_ key: String) -> Bool {
        defaults.object(forKey: key) is String
    }
}
