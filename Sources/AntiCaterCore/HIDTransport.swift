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
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: payloadSize + 1)

    // MARK: - 发现

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    /// 找到第一个匹配的配置接口。复合设备里键盘接口会被跳过，只认 0xFF00。
    public static func discover() -> HIDTransport? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }

        for device in devices {
            guard let vid = intProperty(device, kIOHIDVendorIDKey),
                  let pid = intProperty(device, kIOHIDProductIDKey),
                  supportedIDs.contains(where: { $0.vid == vid && $0.pid == pid }),
                  intProperty(device, kIOHIDPrimaryUsagePageKey) == configUsagePage,
                  intProperty(device, kIOHIDPrimaryUsageKey) == configUsage
            else { continue }
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

    deinit {
        if opened {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        inputBuffer.deallocate()
    }

    // MARK: - 打开 / 收发

    public func open() throws {
        guard !opened else { return }
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
