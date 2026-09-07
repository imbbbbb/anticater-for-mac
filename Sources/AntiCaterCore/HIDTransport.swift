import Foundation
import IOKit.hid

/// 与 ANTICATER 键盘的厂商自定义配置接口通信。
///
/// 该接口位于 UsagePage 0xFF00 / Usage 0x01，收发均为 Report ID 3 加 64 字节定长载荷。
/// 因为不是键盘/消费者页，打开它不需要「输入监控」授权（已实测确认）。
public final class HIDTransport {

    public static let configUsagePage = 0xFF00
    public static let configUsage = 0x01
    public static let reportID: UInt8 = 3
    /// 载荷长度，不含 Report ID
    public static let payloadSize = 64

    /// app 支持的全部 VID/PID 组合，取自原版程序启动时的枚举顺序
    public static let supportedIDs: [(vid: Int, pid: Int)] = {
        let pids = [0x8842, 0x8840, 0x8830, 0x8831, 0x8832, 0x8833, 0x8850, 0x8851]
        return [0x1189, 0x514C].flatMap { vid in pids.map { (vid, $0) } }
    }()

    public enum Failure: Error, CustomStringConvertible {
        case notFound
        case openFailed(IOReturn)
        case writeFailed(IOReturn)
        case timeout(expected: Int, got: Int)

        public var description: String {
            switch self {
            case .notFound:
                return "没有找到 ANTICATER 设备的配置接口（检查 USB 线是否连接）"
            case .openFailed(let r):
                return String(format: "打开设备失败: IOReturn 0x%08X", UInt32(bitPattern: r))
            case .writeFailed(let r):
                return String(format: "发送报文失败: IOReturn 0x%08X", UInt32(bitPattern: r))
            case .timeout(let expected, let got):
                return "等待设备应答超时：期望 \(expected) 条，只收到 \(got) 条"
            }
        }

        /// 这几个码的含义都是「手上这个设备句柄已经作废」——通常是中途拔了线。
        /// 重试没有意义：`IOHIDDevice` 引用不会自己复活，必须丢掉整个 session
        /// 重新走一遍 discover。实测拔插后再写会拿到 `kIOReturnBadArgument`。
        public var meansDisconnected: Bool {
            switch self {
            case .notFound:
                return true
            case .openFailed(let r), .writeFailed(let r):
                return r == kIOReturnBadArgument || r == kIOReturnNoDevice
                    || r == kIOReturnNotAttached || r == kIOReturnNotOpen
            case .timeout:
                return false
            }
        }
    }

    public let vendorID: Int
    public let productID: Int
    public let serialNumber: String?

    private let device: IOHIDDevice
    private var opened = false
    private var inbox: [[UInt8]] = []
    private var inputBuffer: UnsafeMutablePointer<UInt8>? =
        .allocate(capacity: payloadSize + 1)

    /// `open()` 时所在线程的 run loop。注销回调必须回到同一个 run loop，
    /// 不能用 deinit 当时的 `CFRunLoopGetCurrent()` —— 见 `close()` 的说明。
    private var scheduledRunLoop: CFRunLoop?

    // MARK: - 发现

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    /// 交给 IOKit 在内核侧做筛选的匹配条件：受支持的 VID/PID，且必须是 0xFF00 配置接口。
    ///
    /// 早先这里传的是 `nil`（匹配全部 HID 设备）再在 Swift 侧过滤，等于把系统上
    /// 每一个键鼠都拿到手里再扔掉。改成显式匹配后只会拿到目标接口。
    static var configMatchingCriteria: [[String: Any]] {
        supportedIDs.map { ids in
            [kIOHIDVendorIDKey: ids.vid,
             kIOHIDProductIDKey: ids.pid,
             kIOHIDPrimaryUsagePageKey: configUsagePage,
             kIOHIDPrimaryUsageKey: configUsage]
        }
    }

    /// 找到第一个匹配的配置接口。复合设备里键盘接口不在匹配条件内，不会被返回。
    public static func discover() -> HIDTransport? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, configMatchingCriteria as CFArray)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }

        for device in devices {
            guard let vid = intProperty(device, kIOHIDVendorIDKey),
                  let pid = intProperty(device, kIOHIDProductIDKey) else { continue }
            return HIDTransport(device: device, vid: vid, pid: pid)
        }
        return nil
    }

    private init(device: IOHIDDevice, vid: Int, pid: Int) {
        self.device = device
        self.vendorID = vid
        self.productID = pid
        self.serialNumber = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
    }

    /// 关闭设备并注销输入回调。**必须在当初调用 `open()` 的那个线程上调用。**
    ///
    /// 输入回调的 context 是 `Unmanaged.passUnretained(self)`，也就是说回调里拿到的
    /// self 没有引用计数保护。只要设备还挂在 run loop 上，晚到一条报文就会去解一个
    /// 已经释放的指针。所以注销回调这件事必须发生在对象还活着的时候，不能拖到 deinit。
    ///
    /// 而 deinit 里做也不行：`IOHIDDeviceScheduleWithRunLoop` 挂的是 worker 线程的
    /// run loop，session 却是在主线程被置 nil 的，deinit 里的 `CFRunLoopGetCurrent()`
    /// 拿到的是主线程 run loop，那句 unschedule 是空操作 —— 设备照旧挂在 worker 上，
    /// context 已经悬空。
    public func close() {
        guard opened else { return }
        opened = false

        // 传 nil 回调即注销。必须赶在缓冲区释放之前，否则 IOKit 可能往已释放的内存写。
        if let buffer = inputBuffer {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.payloadSize + 1, nil, nil)
        }
        IOHIDDeviceUnscheduleFromRunLoop(device,
                                         scheduledRunLoop ?? CFRunLoopGetCurrent(),
                                         CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        scheduledRunLoop = nil
        inbox.removeAll()
    }

    deinit {
        // 正常路径下 `close()` 已经调过了，这里只剩释放缓冲区。
        // 走到 else 分支说明有调用方漏了 close()，属于编程错误：此时既不能安全地
        // 注销回调（不在正确的线程上），也不能释放缓冲区（回调可能还会往里写），
        // 只好把这 65 字节泄漏掉换取内存安全，并留下记录。
        if opened {
            assertionFailure("HIDTransport 被释放时仍处于打开状态，close() 漏调了")
            FileHandle.standardError.write(
                "warning: HIDTransport 未经 close() 即释放，输入缓冲区已泄漏以避免悬垂写入\n"
                    .data(using: .utf8)!)
        } else {
            inputBuffer?.deallocate()
        }
        inputBuffer = nil
    }

    // MARK: - 打开 / 收发

    public func open() throws {
        guard !opened else { return }
        guard let inputBuffer else { return }
        let rc = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard rc == kIOReturnSuccess else { throw Failure.openFailed(rc) }
        opened = true

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, inputBuffer, Self.payloadSize + 1,
            { context, _, _, _, _, report, length in
                guard let context, length > 0 else { return }
                let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
                let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
                if HIDTransport.traceInput {
                    let dump = bytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                    FileHandle.standardError.write("← len=\(bytes.count)  \(dump)\n".data(using: .utf8)!)
                }
                transport.inbox.append(bytes)
            },
            context)
        // 记住是哪个 run loop，close() 要回到同一个上面注销。
        scheduledRunLoop = CFRunLoopGetCurrent()
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// 发送一条命令。`payload` 不含 Report ID，不足 64 字节的部分补零。
    ///
    /// 注意：原版程序发送时会把未用字节留成栈垃圾，设备显然不看它们；这里一律补零，
    /// 既更干净，也和抓到的写入命令（全零）一致。
    public func send(_ payload: [UInt8]) throws {
        precondition(payload.count <= Self.payloadSize, "载荷超过 64 字节")
        // 这台设备要求缓冲区首字节就是 Report ID —— IOHIDDeviceSetReport 的 reportID 参数
        // 之外还得带上它，缓冲区总长 65。hidapi 在 macOS 上也是这么做的（仅当 ID 为 0 时才剥掉）。
        var buffer: [UInt8] = [Self.reportID]
        buffer.append(contentsOf: payload)
        buffer.append(contentsOf: repeatElement(0, count: Self.payloadSize - payload.count))
        let rc = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(Self.reportID),
                                      buffer, buffer.count)
        guard rc == kIOReturnSuccess else { throw Failure.writeFailed(rc) }
    }

    /// 收集接下来的 `count` 条输入报文，返回去掉 Report ID 的载荷。
    public func receive(count: Int, timeout: TimeInterval = 2.0) throws -> [[UInt8]] {
        let deadline = Date().addingTimeInterval(timeout)
        while inbox.count < count, Date() < deadline {
            // returnAfterSourceHandled 必须是 false：设为 true 时 run loop 会在处理完
            // 任意一个源后立刻返回，HID 回调经常来不及排上队。
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
        }
        guard inbox.count >= count else {
            let partial = inbox.count
            inbox.removeAll()
            throw Failure.timeout(expected: count, got: partial)
        }
        let batch = Array(inbox.prefix(count))
        inbox.removeFirst(count)
        // IOKit 在带 Report ID 的设备上会把 ID 放在首字节，去掉它以对齐载荷索引
        return batch.map { $0.first == Self.reportID ? Array($0.dropFirst()) : $0 }
    }

    public func flushPendingInput() {
        CFRunLoopRunInMode(.defaultMode, 0.02, false)
        inbox.removeAll()
    }

    /// 设为 true 后每条收到的报文都会打到 stderr，用于调试收发。
    public static var traceInput = ProcessInfo.processInfo.environment["ANTICATER_DEBUG"] != nil
}
