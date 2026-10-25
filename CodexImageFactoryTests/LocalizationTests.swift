import Foundation
import Testing
@testable import CodexImageFactory

/// 日英対応の検査。カタログのすべてのキーに英語訳があり、書式指定子（%@ / %lld など）がそろっていること。
@Suite("Localization")
struct LocalizationTests {
    static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexImageFactory/Localizable.xcstrings")
    }

    struct Entry {
        var key: String
        var english: String?
        var englishState: String?
        var stale: Bool
        var shouldTranslate: Bool
    }

    static func entries() throws -> [Entry] {
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["sourceLanguage"] as? String == "ja")
        let strings = try #require(root["strings"] as? [String: Any])
        var result: [Entry] = []
        for (key, raw) in strings {
            let dict = raw as? [String: Any] ?? [:]
            let en = (dict["localizations"] as? [String: Any])?["en"] as? [String: Any] ?? [:]
            let stale = dict["extractionState"] as? String == "stale"
            let shouldTranslate = dict["shouldTranslate"] as? Bool ?? true
            // 複数形の訳（variations.plural.one / other …）は、それぞれを 1 件として調べる。
            var units: [[String: Any]] = []
            if let unit = en["stringUnit"] as? [String: Any] {
                units.append(unit)
            }
            if let plural = (en["variations"] as? [String: Any])?["plural"] as? [String: Any] {
                for case let form as [String: Any] in plural.values {
                    if let unit = form["stringUnit"] as? [String: Any] { units.append(unit) }
                }
            }
            if units.isEmpty {
                result.append(Entry(key: key, english: nil, englishState: nil, stale: stale, shouldTranslate: shouldTranslate))
            }
            for unit in units {
                result.append(Entry(
                    key: key,
                    english: unit["value"] as? String,
                    englishState: unit["state"] as? String,
                    stale: stale,
                    shouldTranslate: shouldTranslate
                ))
            }
        }
        return result
    }

    /// 書式指定子の種類（位置指定 `%1$@` は種類だけ見る）。順番を入れ替えた訳でも通るように並べ替えて比べる。
    static func specifiers(_ s: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:lld|ld|lu|llu|d|i|u|@|f|\.\d+f|%)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
            .filter { $0 != "%%" }
            .sorted()
    }

    @Test func everyKeyHasAnEnglishTranslation() throws {
        let live = try Self.entries().filter { !$0.stale && $0.shouldTranslate }
        #expect(live.count > 300, "カタログのキーが少なすぎる（\(live.count) 個）。scripts/l10n/sync-strings.sh を実行したか")
        let missing = live.filter { $0.englishState != "translated" || ($0.english ?? "").isEmpty }.map(\.key).sorted()
        #expect(missing.isEmpty, "英語訳が無いキー（\(missing.count) 個）: \(missing.prefix(20))")
    }

    @Test func placeholdersMatchBetweenJapaneseAndEnglish() throws {
        for entry in try Self.entries() where !entry.stale {
            guard let en = entry.english else { continue }
            #expect(Self.specifiers(entry.key) == Self.specifiers(en), "書式指定子が違う: 「\(entry.key)」→「\(en)」")
        }
    }

    @Test func englishTranslationsContainNoJapanese() throws {
        let japanese = try NSRegularExpression(pattern: "[ぁ-んァ-ヶ一-龯]")
        for entry in try Self.entries() where !entry.stale {
            guard let en = entry.english else { continue }
            let hit = japanese.firstMatch(in: en, range: NSRange(location: 0, length: (en as NSString).length))
            #expect(hit == nil, "英語訳に日本語が残っている: 「\(en)」")
        }
    }

    @Test func defaultInstructionTemplateFollowsTheLanguage() throws {
        // テストは日本語で走るので、既定の指示文は元の文と同じ。
        #expect(AppSettings.defaultInstructionTemplate == AppSettings.defaultInstructionTemplateSource)
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let english = try #require(Bundle(path: path))
            .localizedString(forKey: AppSettings.defaultInstructionTemplateSource, value: nil, table: "Localizable")
        #expect(english.contains("{count}") && english.contains("{filenames}") && english.contains("{size}") && english.contains("{background}"))
        #expect(english != AppSettings.defaultInstructionTemplateSource)
        // どの言語の既定値も「既定」とみなす。手で直した文は違う。
        #expect(AppSettings.isBuiltInInstructionTemplate(AppSettings.defaultInstructionTemplateSource))
        #expect(AppSettings.isBuiltInInstructionTemplate(english))
        #expect(!AppSettings.isBuiltInInstructionTemplate(english + " Use bright colors."))

        // 既定のままなら空で保存し、別の言語の既定値が保存されていても今の言語の既定値で読む。
        let suite = "LocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        let store = SettingsStore(defaults: defaults)
        store.save(AppSettings.defaults)
        #expect(defaults.string(forKey: "settings.instructionTemplate") == "")
        defaults.set(english, forKey: "settings.instructionTemplate")
        #expect(store.load().instructionTemplate == AppSettings.defaultInstructionTemplate)
        var custom = AppSettings.defaults
        custom.instructionTemplate = "自分で書いた指示 {filenames}"
        store.save(custom)
        #expect(store.load().instructionTemplate == "自分で書いた指示 {filenames}")
    }

    @Test func builtAppResolvesEnglish() throws {
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"), "en.lproj がアプリに入っていない")
        let en = try #require(Bundle(path: path))
        let value = en.localizedString(forKey: "すべて一時停止", value: "__missing__", table: "Localizable")
        #expect(value != "__missing__" && value != "すべて一時停止", "英語の文字列が引けない: \(value)")
    }
}
