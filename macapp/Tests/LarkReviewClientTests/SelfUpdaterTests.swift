import XCTest
@testable import LarkReviewClient

final class SelfUpdaterTests: XCTestCase {

    // ---------- normalizeVersion ----------

    func testNormalizeVersion() {
        XCTAssertEqual(SelfUpdater.normalizeVersion("1.6.0"), "1.6.0")
        XCTAssertEqual(SelfUpdater.normalizeVersion("v1.6.0"), "1.6.0")
        XCTAssertEqual(SelfUpdater.normalizeVersion("V1.6.0"), "1.6.0")
        XCTAssertEqual(SelfUpdater.normalizeVersion(" v1.6.0\n"), "1.6.0")
        XCTAssertNil(SelfUpdater.normalizeVersion(nil))
        XCTAssertNil(SelfUpdater.normalizeVersion(""))
        XCTAssertNil(SelfUpdater.normalizeVersion("   "))
        XCTAssertNil(SelfUpdater.normalizeVersion("v"))
    }

    // ---------- dmgURL：与 release.yml 的附件命名是契约 ----------

    func testDmgURLMatchesReleaseWorkflowNaming() {
        XCTAssertEqual(
            SelfUpdater.dmgURL(version: "1.6.0").absoluteString,
            "https://github.com/TommyZhao888/lark-review-client/releases/download/v1.6.0/LarkReviewClient-v1.6.0.dmg"
        )
    }

    // ---------- latestTag ----------

    func testLatestTagParsesTagName() {
        let json = #"{"tag_name": "v1.5.5", "name": "LarkReviewClient v1.5.5", "assets": []}"#
        XCTAssertEqual(SelfUpdater.latestTag(fromJSON: Data(json.utf8)), "v1.5.5")
    }

    func testLatestTagBadInput() {
        XCTAssertNil(SelfUpdater.latestTag(fromJSON: Data("not json{{".utf8)))
        XCTAssertNil(SelfUpdater.latestTag(fromJSON: Data(#"{"no_tag": true}"#.utf8)))
        XCTAssertNil(SelfUpdater.latestTag(fromJSON: Data(#"[1,2,3]"#.utf8)))
    }

    // ---------- isTranslocated ----------

    func testIsTranslocated() {
        XCTAssertTrue(SelfUpdater.isTranslocated(
            "/private/var/folders/ab/xyz/T/AppTranslocation/1B2C-3D4E/d/LarkReviewClient.app"))
        XCTAssertFalse(SelfUpdater.isTranslocated("/Applications/LarkReviewClient.app"))
        XCTAssertFalse(SelfUpdater.isTranslocated("/Users/x/repo/macapp/build/LarkReviewClient.app"))
    }

    // ---------- installDestination ----------

    func testInstallDestination() {
        let r = SelfUpdater.installDestination(bundlePath: "/Applications/LarkReviewClient.app")
        XCTAssertEqual(r?.dest, "/Applications/LarkReviewClient.app")
        XCTAssertEqual(r?.parent, "/Applications")
        // swift run 开发态：可执行文件不是 .app
        XCTAssertNil(SelfUpdater.installDestination(bundlePath: "/Users/x/macapp/.build/debug/LarkReviewClient"))
        XCTAssertNil(SelfUpdater.installDestination(bundlePath: ""))
    }

    // ---------- verifyStagedPlist ----------

    private let goodPlist: [String: Any] = [
        "CFBundleIdentifier": "com.larkbot.review-client-app",
        "CFBundleShortVersionString": "1.6.0",
        "CFBundleExecutable": "LarkReviewClient",
    ]

    func testVerifyStagedPlistOK() {
        XCTAssertNil(SelfUpdater.verifyStagedPlist(goodPlist, expectVersion: "1.6.0"))
    }

    func testVerifyStagedPlistVersionMismatch() {
        let err = SelfUpdater.verifyStagedPlist(goodPlist, expectVersion: "1.7.0")
        XCTAssertNotNil(err)
        XCTAssertTrue(err!.contains("1.6.0"))
        XCTAssertTrue(err!.contains("1.7.0"))
    }

    func testVerifyStagedPlistWrongBundleId() {
        var plist = goodPlist
        plist["CFBundleIdentifier"] = "com.evil.other-app"
        XCTAssertNotNil(SelfUpdater.verifyStagedPlist(plist, expectVersion: "1.6.0"))
    }

    func testVerifyStagedPlistMissingKeys() {
        XCTAssertNotNil(SelfUpdater.verifyStagedPlist([:], expectVersion: "1.6.0"))
        XCTAssertNotNil(SelfUpdater.verifyStagedPlist(
            ["CFBundleIdentifier": "com.larkbot.review-client-app"], expectVersion: "1.6.0"))
    }

    // ---------- swapBundle ----------

    private var workRoot: String!

    override func setUp() {
        super.setUp()
        workRoot = NSTemporaryDirectory() + "lrc-swap-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: workRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: workRoot)
        super.tearDown()
    }

    /// 造一个带标记文件的假 .app 目录。
    private func makeFakeApp(at path: String, marker: String) throws {
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        try marker.write(toFile: path + "/Contents/marker.txt", atomically: true, encoding: .utf8)
    }

    private func marker(at appPath: String) -> String? {
        try? String(contentsOfFile: appPath + "/Contents/marker.txt", encoding: .utf8)
    }

    func testSwapBundleHappyPath() throws {
        let dest = workRoot + "/Installed.app"
        let newApp = workRoot + "/New.app"
        let aside = workRoot + "/Old.app"
        try makeFakeApp(at: dest, marker: "old")
        try makeFakeApp(at: newApp, marker: "new")

        XCTAssertNil(SelfUpdater.swapBundle(newApp: newApp, dest: dest, aside: aside))
        XCTAssertEqual(marker(at: dest), "new")                                    // dest 已换新
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside))              // aside 已删
        XCTAssertFalse(FileManager.default.fileExists(atPath: newApp))             // newApp 已挪走
    }

    func testSwapBundleRollbackWhenNewAppMissing() throws {
        let dest = workRoot + "/Installed.app"
        let aside = workRoot + "/Old.app"
        try makeFakeApp(at: dest, marker: "old")

        // newApp 不存在 → 第一步 dest→aside 成功、第二步失败 → 回滚
        let err = SelfUpdater.swapBundle(newApp: workRoot + "/Missing.app", dest: dest, aside: aside)
        XCTAssertNotNil(err)
        XCTAssertEqual(marker(at: dest), "old")                                    // dest 复原
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside))              // 无 aside 残留
        XCTAssertTrue(err!.contains("已回滚"))
    }

    func testSwapBundleFailsWhenDestMissing() {
        // dest 不存在 → 第一步就失败，什么都不该发生
        let err = SelfUpdater.swapBundle(
            newApp: workRoot + "/New.app", dest: workRoot + "/Nope.app", aside: workRoot + "/Old.app")
        XCTAssertNotNil(err)
    }
}
