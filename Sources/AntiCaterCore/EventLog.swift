import Foundation

/// 进程内的环形事件日志，随「拷贝诊断信息」一起导出。
///
/// 为什么需要它：`Diagnostics` 给的是**静态快照**（此刻系统上有哪些 HID 设备），
/// 而真正难查的几类问题都需要**时间序列**——写入回读不一致要看发了什么、回了什么；
/// `receive` 超时要看卡在第几条；掉线要看前后的操作顺序。快照答不了这些。
///
/// 为什么不写文件：这个 app 的会话很短，出问题时用户就在电脑前，最近几百条足够定位。
/// 换成日志文件就要管轮转、管卸载残留、还得教用户找路径，收益不抵成本。
/// 代价是崩溃或强退时日志一起没了——但最常见的故障（连不上、写入失败）都不崩溃。
///
/// **隐私**：默认只记操作名称、载荷长度和错误码，**不记原始载荷**。宏是任意键码序列，
/// 理论上有人会把密码做成宏，全量 hex 属于过度采集。需要深挖协议问题时让用户打开
/// `verbose` 复现一次即可。改动前请守住这条默认。
public final class EventLog {

    /// 全局唯一实例。HID 操作在 worker 线程、界面在主线程，两边都会写，内部自己加锁。
    public static let shared = EventLog()

    /// 保留的条数上限。设备一次全量读取约 80 条，留 500 够放下几轮完整操作。
    public static let capacity = 500

    public struct Entry {
        public let time: Date
        public let category: String
        public let message: String
    }

    /// 打开后连 64 字节报文的 hex 一起记。默认关闭，见上面的隐私说明。
    /// 环境变量 `ANTICATER_DEBUG` 可在启动时打开，方便命令行排障。
    public var verbose: Bool {
        get { lock.withLock { _verbose } }
        set { lock.withLock { _verbose = newValue } }
    }

    private let lock = NSLock()
    private var _verbose = ProcessInfo.processInfo.environment["ANTICATER_DEBUG"] != nil
    /// 定长环形缓冲：写满后从头覆盖，内存占用有上界，不随运行时间增长。
    private var buffer: [Entry?]
    private var next = 0
    private var wrapped = false

    private init() {
        buffer = Array(repeating: nil, count: Self.capacity)
    }

    /// 记一条。热路径上只存 `Date` 不做格式化——格式化留到导出时，
    /// 省掉每条一次 DateFormatter 的开销。
    public func log(_ category: String, _ message: String) {
        lock.withLock {
            buffer[next] = Entry(time: Date(), category: category, message: message)
            next = (next + 1) % Self.capacity
            if next == 0 { wrapped = true }
        }
    }

    /// 仅在 `verbose` 打开时记录。载荷 hex 一律走这条，不要直接调 `log`。
    public func logVerbose(_ category: String, _ message: @autoclosure () -> String) {
        guard verbose else { return }
        log(category, message())
    }

    /// 按时间顺序取出全部条目（最旧的在前）。
    public func entries() -> [Entry] {
        lock.withLock {
            let ordered = wrapped
                ? Array(buffer[next...]) + Array(buffer[..<next])
                : Array(buffer[..<next])
            return ordered.compactMap { $0 }
        }
    }

    public func clear() {
        lock.withLock {
            buffer = Array(repeating: nil, count: Self.capacity)
            next = 0
            wrapped = false
        }
    }

    /// 渲染成可粘贴的纯文本。
    public func rendered() -> [String] {
        let items = entries()
        guard !items.isEmpty else { return ["（本次运行还没有记录到事件）"] }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        var lines = items.map {
            "\(formatter.string(from: $0.time))  [\($0.category)] \($0.message)"
        }
        if wrapped {
            lines.insert("（只保留最近 \(Self.capacity) 条，更早的已被覆盖）", at: 0)
        }
        return lines
    }

    /// 把字节转成 hex，超长时截断——单条 64 字节全打出来会把日志挤爆。
    public static func hex(_ bytes: [UInt8], limit: Int = 16) -> String {
        let shown = bytes.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > limit ? "\(shown) …(\(bytes.count) 字节)" : shown
    }
}
