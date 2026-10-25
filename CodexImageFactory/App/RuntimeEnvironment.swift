import Foundation

enum RuntimeEnvironment {
    /// ユニットテストのホストとして起動されたか。テスト中はキューの復元や codex の起動などの副作用を起こさない。
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()
}
