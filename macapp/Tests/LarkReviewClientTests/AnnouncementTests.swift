import XCTest
@testable import LarkReviewClient

/// v1.11 服务端公告: 协议解析 + 本机已读状态(与 Node 版同一文件格式)。
final class AnnouncementTests: XCTestCase {

    private func tmpPath() -> String {
        NSTemporaryDirectory() + "ann-\(UUID().uuidString).json"
    }

    func testParseAnnouncementPush() {
        let text = #"{"type":"announcement","id":"ann_1","title":"请升级","message":"第一行\n第二行","level":"important","ts":"2026-10-23T02:00:00.123Z","expires_at":"2099-01-01T00:00:00.000Z"}"#
        guard case .announcement(let a)? = InboundMessage.parse(text) else { return XCTFail("应解析为 announcement") }
        XCTAssertEqual(a.id, "ann_1")
        XCTAssertEqual(a.message, "第一行\n第二行", "正文换行必须原样保留(详情窗口看全文)")
        XCTAssertTrue(a.isImportant)
        XCTAssertFalse(a.isExpired)
    }

    func testRegisterAckCarriesAnnouncements() {
        let text = #"{"type":"register_ack","open_id":"ou_1","announcements":[{"id":"a","title":"t","message":"m"}]}"#
        guard case .registerAck(let ack)? = InboundMessage.parse(text) else { return XCTFail("应解析为 register_ack") }
        XCTAssertEqual(ack.announcements?.map(\.id), ["a"])
        // 旧 hub 不带该字段 → nil, 不影响注册
        guard case .registerAck(let old)? = InboundMessage.parse(#"{"type":"register_ack"}"#) else { return XCTFail() }
        XCTAssertNil(old.announcements)
    }

    func testExpiredAndLenientDates() {
        let past = Announcement(id: "x", title: "t", message: "m", level: nil, ts: nil, expires_at: "2020-01-01T00:00:00Z")
        XCTAssertTrue(past.isExpired, "不带毫秒的 ISO8601 也要能解析")
        let none = Announcement(id: "y", title: "t", message: "m", level: nil, ts: nil, expires_at: nil)
        XCTAssertFalse(none.isExpired, "没有有效期 = 不过期")
    }

    func testStoreSeenOnceAndPersists() {
        let p = tmpPath()
        var s = AnnouncementStore(path: p)
        XCTAssertTrue(s.markSeen("a"), "首次见到 → 要弹")
        XCTAssertFalse(s.markSeen("a"), "已弹过 → 不再弹")
        s.dismiss("a")
        let reloaded = AnnouncementStore(path: p)
        XCTAssertEqual(reloaded.seen, ["a"], "重启后仍记得已弹过")
        XCTAssertEqual(reloaded.dismissed, ["a"])
    }

    func testStoreReadsNodeFormatAndCaps() throws {
        // Node 版写的同一文件: {"seen":[...],"dismissed":[...]}
        let p = tmpPath()
        try #"{"seen":["n1"],"dismissed":[]}"#.write(toFile: p, atomically: true, encoding: .utf8)
        var s = AnnouncementStore(path: p)
        XCTAssertFalse(s.markSeen("n1"), "Node 版弹过的, Mac App 不再弹")
        for i in 0..<(AnnouncementStore.keep + 10) { _ = s.markSeen("id\(i)") }
        XCTAssertEqual(AnnouncementStore(path: p).seen.count, AnnouncementStore.keep, "只留最近 200 条")
    }

    @MainActor
    func testVisibleAnnouncementsHidesDismissedAndExpired() {
        let st = AppState()
        st.announcements = [
            Announcement(id: "a", title: "t", message: "m", level: nil, ts: nil, expires_at: nil),
            Announcement(id: "b", title: "t", message: "m", level: nil, ts: nil, expires_at: nil),
            Announcement(id: "c", title: "t", message: "m", level: nil, ts: nil, expires_at: "2020-01-01T00:00:00Z"),
        ]
        st.dismissedAnnouncementIds = ["b"]
        XCTAssertEqual(st.visibleAnnouncements.map(\.id), ["a"])
    }
}
