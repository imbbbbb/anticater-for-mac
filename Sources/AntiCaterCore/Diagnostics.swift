import Foundation
import IOKit.hid

/// 排障用的 HID 环境快照。
///
/// 存在的理由：当用户报「插上了但连不上」时，远程猜原因成本极高——可能是接了
/// 2.4G 接收器、用了不带数据线芯的充电线、硬件是列表外的 PID，也可能是配置集合
/// 不在首位导致匹配落空。这里把判断所需的原始属性一次性倒出来，让对方跑一条
/// 命令就能给出结论性证据，而不是来回问。
///
/// 全程只读属性，不打开任何设备，不触发任何权限弹窗。
public enum Diagnostics {

    /// 提 issue 的地址。仓库名只有 `UpdateChecker.repository` 一处来源。
    public static let issuesPage =
        URL(string: "https://github.com/\(UpdateChecker.repository)/issues")!

    public struct DeviceInfo {
        public let vendorID: Int?
        public let productID: Int?
        public let product: String?
        public let manufacturer: String?
        public let transport: String?
        public let serialNumber: String?
        public let primaryUsagePage: Int?
        public let primaryUsage: Int?
        /// 该接口上全部顶层集合。配置通道能否被找到取决于它，而不是 primary。
        public let usagePairs: [(page: Int, usage: Int)]

        /// VID/PID 在 app 的支持列表里
        public var isSupportedID: Bool {
            guard let vendorID, let productID else { return false }
            return HIDTransport.supportedIDs.contains { $0.vid == vendorID && $0.pid == productID }
        }

        /// 带 0xFF00/0x01 配置集合
        public var hasConfigUsage: Bool {
            usagePairs.contains {
                $0.page == HIDTransport.configUsagePage && $0.usage == HIDTransport.configUsage
            }
        }

        /// app 会选中它当配置通道
        public var isConfigInterface: Bool { isSupportedID && hasConfigUsage }
    }

    /// 枚举系统里全部 HID 设备。
    public static func scanAll() -> [DeviceInfo] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devices.map(info(for:)).sorted {
            ($0.vendorID ?? 0, $0.productID ?? 0, $0.primaryUsagePage ?? 0)
                < ($1.vendorID ?? 0, $1.productID ?? 0, $1.primaryUsagePage ?? 0)
        }
    }

    private static func info(for device: IOHIDDevice) -> DeviceInfo {
        func int(_ key: String) -> Int? {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
        }
        func string(_ key: String) -> String? {
            IOHIDDeviceGetProperty(device, key as CFString) as? String
        }

        var pairs: [(page: Int, usage: Int)] = []
        if let raw = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString)
            as? [[String: Any]] {
            pairs = raw.compactMap { pair in
                guard let page = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue,
                      let usage = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue
                else { return nil }
                return (page, usage)
            }
        }
        // 没有 DeviceUsagePairs 的设备，至少把 primary 补上，免得报告里是空的。
        if pairs.isEmpty, let page = int(kIOHIDPrimaryUsagePageKey),
           let usage = int(kIOHIDPrimaryUsageKey) {
            pairs = [(page, usage)]
        }

        return DeviceInfo(vendorID: int(kIOHIDVendorIDKey),
                          productID: int(kIOHIDProductIDKey),
                          product: string(kIOHIDProductKey),
                          manufacturer: string(kIOHIDManufacturerKey),
                          transport: string(kIOHIDTransportKey),
                          serialNumber: string(kIOHIDSerialNumberKey),
                          primaryUsagePage: int(kIOHIDPrimaryUsagePageKey),
                          primaryUsage: int(kIOHIDPrimaryUsageKey),
                          usagePairs: pairs)
    }

    /// 生成可直接粘贴给维护者的纯文本报告。
    public static func report() -> String {
        let devices = scanAll()
        var lines: [String] = []

        lines.append("ANTICATER 连接诊断  ——  版本 \(AppVersion.string)")
        // 提 issue 的入口就写在报告头部：用户拿到这段文本时往往已经离开了 app，
        // 地址跟着文本走，他们不必再回去翻菜单找链接。
        // 地址复用 UpdateChecker.repository，别在这里写第二份。
        lines.append("提交问题：\(Diagnostics.issuesPage.absoluteString)")
        lines.append("系统 \(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if arch(arm64)
        lines.append("架构 arm64（Apple Silicon 原生）")
        #else
        lines.append("架构 \(archName)（注意：发布版只有 arm64）")
        #endif
        lines.append("")

        let candidates = devices.filter { $0.isSupportedID }
        let configInterfaces = candidates.filter { $0.hasConfigUsage }

        lines.append("── 结论 ──")
        if let chosen = configInterfaces.first {
            lines.append(String(format: "✅ 找到配置通道：VID=0x%04X PID=0x%04X（%@）",
                                chosen.vendorID ?? 0, chosen.productID ?? 0,
                                chosen.product ?? "无名称"))
            lines.append("   如果 app 仍然连不上，多半是设备被别的程序占着——")
            lines.append("   先退出原版 ANTICATER 软件，再试一次。")
        } else if candidates.isEmpty {
            lines.append("❌ 系统里没有任何 VID/PID 在支持列表内的 USB 设备。")
            lines.append("   依次排查：")
            lines.append("   1. 是不是用 2.4G 接收器或蓝牙连的？配置只能走 USB 数据线。")
            lines.append("   2. 线是不是只能充电不能传数据？换一根确认能传数据的线。")
            lines.append("   3. 换一个 USB 口，绕开扩展坞/Hub 直插机器。")
            lines.append("   以上都排除了，说明这台硬件的 PID 不在列表里，")
            lines.append("   请把下面的完整设备清单发给维护者。")
        } else {
            lines.append("⚠️ 找到了本设备，但它上面没有 0xFF00/0x01 配置集合。")
            lines.append("   这台硬件的固件与已知型号不同，请把下面的完整清单发给维护者。")
        }
        lines.append("")

        lines.append("── 本设备相关的接口（VID/PID 命中支持列表）──")
        if candidates.isEmpty {
            lines.append("（无）")
        } else {
            for device in candidates { lines.append(describe(device)) }
        }
        lines.append("")

        lines.append("── 系统里全部 HID 设备（共 \(devices.count) 个）──")
        for device in devices { lines.append(describe(device)) }
        lines.append("")

        // 事件日志放在最后：设备清单是「现在什么样」，日志是「刚才发生了什么」，
        // 前者通常一眼就能定性，翻到日志的多半是前者没答案的疑难情况。
        lines.append("── 本次运行的事件日志 ──")
        // 必须讲清「开关只对之后发生的事生效」：用户很容易以为打开开关就能把
        // 已经记下的条目补全，结果拿到一份没有报文的日志，白折腾一轮。
        if !EventLog.shared.verbose {
            lines.append("（未开启详细模式，因此不含报文内容。需要的话：先在诊断窗口打开"
                       + "「记录详细日志」，然后重新复现一次问题，再回来拷贝——"
                       + "开关只对打开之后发生的操作生效，不会补全上面已有的记录。）")
        }
        lines.append(contentsOf: EventLog.shared.rendered())
        lines.append("")
        lines.append("── 把以上内容贴到 issue 里 ──")
        lines.append(Diagnostics.issuesPage.absoluteString)

        return lines.joined(separator: "\n")
    }

    private static func describe(_ device: DeviceInfo) -> String {
        let ids = String(format: "VID=0x%04X PID=0x%04X",
                         device.vendorID ?? 0, device.productID ?? 0)
        let pairs = device.usagePairs
            .map { String(format: "%04X:%02X", $0.page, $0.usage) }
            .joined(separator: " ")
        let marker = device.isConfigInterface ? "→" : " "
        return "\(marker) \(ids)  [\(device.transport ?? "?")]  "
            + "\(device.manufacturer ?? "") \(device.product ?? "无名称")".trimmingCharacters(in: .whitespaces)
            + "\n      usage pairs: \(pairs.isEmpty ? "（无）" : pairs)"
    }

    private static var archName: String {
        #if arch(x86_64)
        return "x86_64"
        #else
        return "未知"
        #endif
    }
}
