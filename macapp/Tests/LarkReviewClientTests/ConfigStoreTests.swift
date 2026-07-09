import XCTest
@testable import LarkReviewClient

final class ConfigStoreTests: XCTestCase {

    private var tmpConfig: String!

    override func setUp() {
        super.setUp()
        tmpConfig = NSTemporaryDirectory() + "lrc-test-\(UUID().uuidString).json"
        setenv("LARK_REVIEW_CLIENT_CONFIG", tmpConfig, 1)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpConfig)
        unsetenv("LARK_REVIEW_CLIENT_CONFIG")
        super.tearDown()
    }

    func testLoadMissingFileGivesDefaults() {
        let cfg = ConfigStore.load()
        XCTAssertEqual(cfg.serverUrl, "")
        XCTAssertEqual(cfg.reviewModel, "claude-opus-4-8")
        XCTAssertEqual(cfg.claudePath, "claude")
        XCTAssertEqual(cfg.heartbeatMs, 15000)
        XCTAssertEqual(cfg.worktreeMaxAgeDays, 14)
        XCTAssertTrue(cfg.notify)
        XCTAssertFalse(cfg.isReady)
    }

    func testLoadGarbageFileGivesDefaults() throws {
        try "not json{{".write(toFile: tmpConfig, atomically: true, encoding: .utf8)
        let cfg = ConfigStore.load()
        XCTAssertEqual(cfg.serverUrl, "")
    }

    func testRoundTripPreservesUnknownKeysAndDropsLegacy() throws {
        // 模拟 Node 版生成的配置：有未知键 configPort、遗留身份字段
        let nodeConfig = """
        {
          "serverUrl": "wss://review.example.com",
          "token": "tk-123",
          "configPort": 8791,
          "name": "遗留姓名",
          "openId": "ou_legacy",
          "promptOverride": "旧全局提示词",
          "repos": {
            "owner/repo": {"mainRepo": "/Users/x/repo", "worktreeBase": "/Users/x/repo-wt", "prompt": "P"}
          },
          "notify": false,
          "notifySound": "Glass"
        }
        """
        try nodeConfig.write(toFile: tmpConfig, atomically: true, encoding: .utf8)

        var cfg = ConfigStore.load()
        XCTAssertEqual(cfg.serverUrl, "wss://review.example.com")
        XCTAssertEqual(cfg.repos["owner/repo"]?.prompt, "P")
        XCTAssertFalse(cfg.notify)
        XCTAssertEqual(cfg.notifySound, "Glass")
        XCTAssertTrue(cfg.isReady)

        cfg.reviewModel = "claude-sonnet-5"
        try ConfigStore.save(cfg)

        let obj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: tmpConfig))) as! [String: Any]
        XCTAssertEqual(obj["configPort"] as? Int, 8791, "未知键必须保留（Node 版还要用）")
        XCTAssertNil(obj["name"], "遗留身份字段必须删除")
        XCTAssertNil(obj["openId"])
        XCTAssertNil(obj["promptOverride"])
        XCTAssertEqual(obj["reviewModel"] as? String, "claude-sonnet-5")
        XCTAssertEqual(obj["notify"] as? Bool, false)
        let repos = obj["repos"] as! [String: Any]
        let repo = repos["owner/repo"] as! [String: Any]
        XCTAssertEqual(repo["mainRepo"] as? String, "/Users/x/repo")
        XCTAssertEqual(repo["prompt"] as? String, "P")
    }

    func testSaveDropsBlankPrompt() throws {
        var cfg = Config()
        cfg.serverUrl = "wss://x"
        cfg.token = "t"
        cfg.repos["a/b"] = RepoConfig(mainRepo: "/m", worktreeBase: "/w", prompt: "   \n ")
        try ConfigStore.save(cfg)
        let obj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: tmpConfig))) as! [String: Any]
        let repo = (obj["repos"] as! [String: Any])["a/b"] as! [String: Any]
        XCTAssertNil(repo["prompt"], "空白 prompt 不落盘")
    }

    func testSaveToNewFile() throws {
        var cfg = Config()
        cfg.serverUrl = "wss://x"
        cfg.token = "t"
        try ConfigStore.save(cfg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpConfig))
        let reloaded = ConfigStore.load()
        XCTAssertEqual(reloaded.serverUrl, "wss://x")
    }
}
