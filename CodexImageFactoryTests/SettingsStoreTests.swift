import Foundation
import Testing
@testable import CodexImageFactory

/// テスト専用の UserDefaults（終わったら消す）。
///
/// ドメイン名に一時フォルダの絶対パスを使い、plist を ~/Library/Preferences ではなくそのフォルダに書かせる。
/// ふつうの名前（`UIT.SettingsStore.<UUID>`）だと removePersistentDomain のあとも空の plist が残り、
/// cfprefsd があとから書き直すこともあるので、消しても ~/Library/Preferences にファイルがたまっていた。
struct UITDefaultsSuite {
    /// plist を置くフォルダ（テストごとに 1 つ）。
    let folder: URL
    let name: String
    let defaults: UserDefaults

    init() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("UIT-Prefs-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        name = folder.appendingPathComponent("UIT.SettingsStore").path
        defaults = UserDefaults(suiteName: name)!
    }

    /// cfprefsd が書く plist。
    var plistURL: URL {
        URL(fileURLWithPath: name + ".plist")
    }

    static var preferencesDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("Preferences", isDirectory: true)
    }

    /// 中身を消してディスクに書き終えてから、フォルダごと（plist と .lockfile も）消す。
    func remove() {
        defaults.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(at: folder)
    }
}

@Suite("SettingsStore")
struct UITSettingsStoreTests {
    @Test func emptySuiteReturnsDefaults() {
        let suite = UITDefaultsSuite()
        defer { suite.remove() }
        #expect(SettingsStore(defaults: suite.defaults).load() == AppSettings.defaults)
    }

    @Test func roundTripKeepsEveryField() {
        let suite = UITDefaultsSuite()
        defer { suite.remove() }
        let store = SettingsStore(defaults: suite.defaults)
        let s = AppSettings(
            outputDirectory: "~/Desktop/画像",
            codexPath: "/opt/codex/bin/codex",
            concurrency: 5,
            timeoutSeconds: 1234,
            stylePreset: "フラットなイラスト",
            instructionTemplate: "{count} 枚 {filenames}",
            model: "gpt-5.5",
            reasoningEffort: .high,
            useEphemeral: true
        )
        store.save(s)
        #expect(store.load() == s)
        // 別インスタンスからも同じ値が読める。
        #expect(SettingsStore(defaults: UserDefaults(suiteName: suite.name)!).load() == s)
    }

    @Test func usesOneKeyPerField() {
        let suite = UITDefaultsSuite()
        defer { suite.remove() }
        SettingsStore(defaults: suite.defaults).save(.defaults)
        for key in SettingsStore.Key.all {
            #expect(suite.defaults.object(forKey: key) != nil, "\(key)")
        }
        #expect(SettingsStore.Key.all.count == 9)
        #expect(Set(SettingsStore.Key.all).count == 9)
    }

    @Test func loadNormalizesOutOfRangeValues() {
        let suite = UITDefaultsSuite()
        defer { suite.remove() }
        var s = AppSettings.defaults
        s.concurrency = 20
        s.timeoutSeconds = 5
        s.instructionTemplate = "   "
        s.outputDirectory = ""
        let store = SettingsStore(defaults: suite.defaults)
        store.save(s)
        let loaded = store.load()
        #expect(loaded.concurrency == 8)
        #expect(loaded.timeoutSeconds == AppSettings.minimumTimeoutSeconds)
        #expect(loaded.instructionTemplate == AppSettings.defaultInstructionTemplate)
        #expect(loaded.outputDirectory == AppSettings.defaultOutputDirectory)

        s.concurrency = 0
        store.save(s)
        #expect(store.load().concurrency == 1)
    }

    @Test func wrongTypesFallBackToDefaults() {
        let suite = UITDefaultsSuite()
        defer { suite.remove() }
        let d = suite.defaults
        d.set("three", forKey: SettingsStore.Key.concurrency)
        d.set(12.5, forKey: SettingsStore.Key.timeoutSeconds)
        d.set("ultra", forKey: SettingsStore.Key.reasoningEffort)
        d.set("yes", forKey: SettingsStore.Key.useEphemeral)
        d.set(42, forKey: SettingsStore.Key.outputDirectory)
        let loaded = SettingsStore(defaults: d).load()
        #expect(loaded.concurrency == AppSettings.defaults.concurrency)
        #expect(loaded.timeoutSeconds == AppSettings.defaults.timeoutSeconds)
        #expect(loaded.reasoningEffort == .default)
        #expect(loaded.useEphemeral == false)
        #expect(loaded.outputDirectory == AppSettings.defaultOutputDirectory)
    }

    @Test func removeLeavesNoPreferenceFileBehind() throws {
        let suite = UITDefaultsSuite()
        SettingsStore(defaults: suite.defaults).save(.defaults)
        CFPreferencesAppSynchronize(suite.name as CFString)
        // ~/Library/Preferences ではなく、テスト用のフォルダに書いている。
        #expect(FileManager.default.fileExists(atPath: suite.plistURL.path))
        #expect(suite.plistURL.path.hasPrefix(suite.folder.path))
        suite.remove()
        #expect(!FileManager.default.fileExists(atPath: suite.folder.path))
        let marker = suite.folder.lastPathComponent
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: UITDefaultsSuite.preferencesDirectory.path)
            .filter { $0.contains(marker) || ($0.hasPrefix("UIT.SettingsStore.") && $0.contains(".\(ProcessInfo.processInfo.processIdentifier).")) }
        #expect(leftovers.isEmpty, "\(leftovers)")
    }

    @Test func emptyPresetIsKept() {
        let suite = UITDefaultsSuite()
        defer { suite.remove() }
        let store = SettingsStore(defaults: suite.defaults)
        var s = AppSettings.defaults
        s.stylePreset = "a"
        store.save(s)
        s.stylePreset = ""
        store.save(s)
        #expect(store.load().stylePreset == "")
    }
}
