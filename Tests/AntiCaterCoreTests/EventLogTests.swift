import XCTest
@testable import AntiCaterCore

/// 事件日志的回归测试。
///
/// `EventLog.shared` 是全局单例，测试之间会互相污染，所以每个用例都先 `clear()`，
/// 并把 `verbose` 恢复原值——否则「默认不记载荷」那条断言会被前一个用例带歪。
final class EventLogTests: XCTestCase {

    private var savedVerbose = false

    override func setUp() {
        super.setUp()
        savedVerbose = EventLog.shared.verbose
        EventLog.shared.clear()
    }

    override func tearDown() {
        EventLog.shared.verbose = savedVerbose
        EventLog.shared.clear()
        super.tearDown()
    }

    /// 导出顺序必须是最旧在前。顺序反了，「先发生什么后发生什么」就读不出来，
    /// 而这正是这份日志唯一的用处。
    func testEntriesAreInChronologicalOrder() {
        EventLog.shared.verbose = false
        for i in 1...5 { EventLog.shared.log("测试", "第 \(i) 条") }

        let messages = EventLog.shared.entries().map(\.message)
        XCTAssertEqual(messages, ["第 1 条", "第 2 条", "第 3 条", "第 4 条", "第 5 条"])
    }

    /// 写满后必须从头覆盖，且条数有上界——内存占用不能随运行时间增长。
    /// 覆盖之后留下的应该是**最近**的那批，不是最早的那批。
    func testRingBufferKeepsNewestAndStaysBounded() {
        let overflow = EventLog.capacity + 50
        for i in 1...overflow { EventLog.shared.log("测试", "\(i)") }

        let entries = EventLog.shared.entries()
        XCTAssertEqual(entries.count, EventLog.capacity, "条数不能超过上限")
        XCTAssertEqual(entries.first?.message, "\(overflow - EventLog.capacity + 1)",
                       "最旧的应该已被覆盖")
        XCTAssertEqual(entries.last?.message, "\(overflow)", "最新的必须留着")
    }

    /// 覆盖发生后要在导出文本里说明，否则看日志的人会以为拿到的是完整记录，
    /// 从而把「日志开头」误当成「事情开始的地方」。
    func testWrapIsDisclosedInRenderedOutput() {
        for i in 1...(EventLog.capacity + 1) { EventLog.shared.log("测试", "\(i)") }
        XCTAssertTrue(EventLog.shared.rendered().first?.contains("只保留最近") == true)
    }

    /// 隐私默认：verbose 关闭时 `logVerbose` 什么也不记。
    /// 载荷里有用户配置的键码（宏理论上能编码密码），这条默认不能被改掉。
    func testVerboseEntriesAreDroppedByDefault() {
        EventLog.shared.verbose = false
        EventLog.shared.logVerbose("发", "AA BB CC")
        XCTAssertTrue(EventLog.shared.entries().isEmpty, "关闭时不能记录载荷")

        EventLog.shared.verbose = true
        EventLog.shared.logVerbose("发", "AA BB CC")
        XCTAssertEqual(EventLog.shared.entries().count, 1, "打开后才记录")
    }

    /// 关闭时连 hex 字符串都不该被构造出来——`logVerbose` 收的是 @autoclosure，
    /// 求值应当被跳过。热路径上每条报文拼一次 hex 再扔掉是纯浪费。
    func testVerboseMessageIsNotEvaluatedWhenDisabled() {
        EventLog.shared.verbose = false
        var evaluated = false
        EventLog.shared.logVerbose("发", { evaluated = true; return "x" }())
        XCTAssertFalse(evaluated, "关闭时不应对消息求值")
    }

    /// hex 超长要截断并标出真实长度，否则单条 64 字节报文会把日志挤爆。
    func testHexTruncatesAndReportsRealLength() {
        let long = [UInt8](repeating: 0xAB, count: 64)
        let text = EventLog.hex(long)
        XCTAssertTrue(text.contains("64 字节"))
        XCTAssertLessThan(text.count, 100)

        XCTAssertEqual(EventLog.hex([0x01, 0x02]), "01 02", "没超长就不该有截断标记")
    }

    /// 空日志也要给一行可读的说明，不能在报告里留一段空白。
    func testEmptyLogRendersPlaceholder() {
        XCTAssertEqual(EventLog.shared.rendered().count, 1)
        XCTAssertTrue(EventLog.shared.rendered()[0].contains("还没有记录"))
    }

    /// 诊断报告必须带上提 issue 的地址——用户拿到文本时往往已经离开 app 了。
    func testReportCarriesIssuesLink() {
        let report = Diagnostics.report()
        XCTAssertTrue(report.contains(Diagnostics.issuesPage.absoluteString))
        XCTAssertTrue(report.contains(UpdateChecker.repository),
                      "地址应当来自 UpdateChecker.repository，别写死第二份")
    }
}
