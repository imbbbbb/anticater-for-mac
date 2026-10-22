import XCTest
import IOKit.hid
@testable import AntiCaterCore

/// 设备匹配的回归测试。
///
/// 守的是 1.2 修掉的那个 bug：匹配条件里带了 `kIOHIDPrimaryUsagePageKey: 0xFF00`，
/// 于是只有「厂商集合恰好排在首位」的设备能被找到。开发机上凑巧排在首位，
/// 别人的机器上排在键盘集合后面，`discover()` 直接返回 nil，界面报「没找到旋钮」。
/// 这类 bug 在本机是 100% 复现不了的，只能靠测试钉住。
final class DeviceMatchingTests: XCTestCase {

    /// 匹配条件只能按 VID/PID 交给 IOKit 筛，usage 一律留到 Swift 侧按
    /// `DeviceUsagePairs` 判。把 usage 加回匹配字典就是在重犯那个 bug。
    func testMatchingCriteriaDoNotFilterByUsage() {
        let forbidden = [kIOHIDPrimaryUsagePageKey, kIOHIDPrimaryUsageKey,
                         kIOHIDDeviceUsagePageKey, kIOHIDDeviceUsageKey]
        for criteria in HIDTransport.configMatchingCriteria {
            for key in forbidden {
                XCTAssertNil(criteria[key],
                             "匹配条件里不能出现 \(key)——会漏掉厂商集合不在首位的设备")
            }
            XCTAssertNotNil(criteria[kIOHIDVendorIDKey])
            XCTAssertNotNil(criteria[kIOHIDProductIDKey])
        }
    }

    /// 支持列表是 2 个 VID × 8 个 PID，每组都要生成一条匹配条件。
    func testMatchingCriteriaCoverEverySupportedID() {
        XCTAssertEqual(HIDTransport.configMatchingCriteria.count,
                       HIDTransport.supportedIDs.count)
        for ids in HIDTransport.supportedIDs {
            let found = HIDTransport.configMatchingCriteria.contains { criteria in
                (criteria[kIOHIDVendorIDKey] as? Int) == ids.vid
                    && (criteria[kIOHIDProductIDKey] as? Int) == ids.pid
            }
            XCTAssertTrue(found, String(format: "0x%04X:0x%04X 没有对应的匹配条件",
                                        ids.vid, ids.pid))
        }
    }

    /// 诊断报告必须在**没有设备**时也能跑完并给出内容——它存在的意义就是
    /// 在连不上的时候用。任何依赖「先连上设备」的实现都是错的。
    func testDiagnosticReportWorksWithoutDevice() {
        let report = Diagnostics.report()
        XCTAssertTrue(report.contains("ANTICATER 连接诊断"))
        XCTAssertTrue(report.contains("── 结论 ──"))
        XCTAssertFalse(report.isEmpty)
    }

    /// `isConfigInterface` 是「VID/PID 命中」且「带 FF00:01 集合」两个条件的合取。
    /// 光看 usage pair 会把别家设备认成旋钮——本机的罗技接收器就带 FF00:01。
    func testConfigInterfaceRequiresBothIDAndUsage() {
        let supported = HIDTransport.supportedIDs[0]
        let config = (page: HIDTransport.configUsagePage, usage: HIDTransport.configUsage)

        func make(vid: Int, pid: Int, pairs: [(page: Int, usage: Int)]) -> Diagnostics.DeviceInfo {
            Diagnostics.DeviceInfo(vendorID: vid, productID: pid, product: nil,
                                   manufacturer: nil, transport: "USB", serialNumber: nil,
                                   primaryUsagePage: pairs.first?.page,
                                   primaryUsage: pairs.first?.usage,
                                   usagePairs: pairs)
        }

        // 厂商集合排在键盘集合**后面**——正是旧代码漏掉的那一类。
        let knob = make(vid: supported.vid, pid: supported.pid,
                        pairs: [(0x01, 0x06), (0x0C, 0x01), config])
        XCTAssertTrue(knob.isConfigInterface, "厂商集合不在首位也必须被认出来")

        // 罗技接收器：带 FF00:01，但 VID/PID 不是我们的。
        let logitech = make(vid: 0x046D, pid: 0xC534, pairs: [(0x01, 0x02), config])
        XCTAssertFalse(logitech.isConfigInterface, "VID/PID 不匹配的设备不能被认成旋钮")

        // 同一台设备的纯键盘接口：VID/PID 对得上，但没有配置通道。
        let keyboardOnly = make(vid: supported.vid, pid: supported.pid, pairs: [(0x01, 0x06)])
        XCTAssertFalse(keyboardOnly.isConfigInterface, "没有 FF00:01 的接口不能当配置通道")
    }

    /// 0x05AC:0x022C 被三样东西共用，只有杰理版的有线配置接口能被选中。
    /// usage pairs 取自真机 ioreg（2026-10-21）。
    func testSharedJieliIDOnlyMatchesWiredConfigInterface() {
        func make(transport: String, pairs: [(page: Int, usage: Int)]) -> Diagnostics.DeviceInfo {
            Diagnostics.DeviceInfo(vendorID: 0x05AC, productID: 0x022C, product: nil,
                                   manufacturer: nil, transport: transport, serialNumber: nil,
                                   primaryUsagePage: pairs.first?.page,
                                   primaryUsage: pairs.first?.usage,
                                   usagePairs: pairs)
        }
        let hidSet: [(page: Int, usage: Int)] = [(0x01, 0x06), (0x01, 0x02), (0x01, 0x01), (0x0C, 0x01)]

        let wiredConfig = make(transport: "USB", pairs: [(0xFF00, 0x01)])
        XCTAssertTrue(wiredConfig.isConfigInterface, "杰理版有线的 FF00:01 接口要被认出来")

        let wiredKeyboard = make(transport: "USB", pairs: hidSet)
        XCTAssertFalse(wiredKeyboard.isConfigInterface, "杰理版有线的键盘接口不是配置通道")

        let dongle = make(transport: "USB", pairs: [(0xFF02, 0x02)])
        XCTAssertFalse(dongle.isConfigInterface, "2.4G 接收器的厂商接口是 FF02:02，不能被选中")

        let dongleKeyboard = make(transport: "USB", pairs: hidSet)
        XCTAssertFalse(dongleKeyboard.isConfigInterface, "2.4G 接收器的键盘接口不能被选中")

        let bluetooth = make(transport: "Bluetooth Low Energy", pairs: hidSet)
        XCTAssertFalse(bluetooth.isConfigInterface, "蓝牙侧没有厂商页，不能被选中")
    }

    /// 选哪个会话实现只看 VID/PID。
    func testVariantFollowsVIDPID() {
        XCTAssertEqual(HIDTransport.variant(vid: 0x05AC, pid: 0x022C), .jieli)
        for ids in HIDTransport.classicIDs {
            XCTAssertEqual(HIDTransport.variant(vid: ids.vid, pid: ids.pid), .classic)
        }
    }

    /// 载荷长度跟着设备报的 MaxOutputReportSize 走（含 Report ID 一字节），
    /// 读不到或小得放不下一条按键配置时退回老款的 64。
    func testPayloadLengthFollowsDevice() {
        XCTAssertEqual(HIDTransport.payloadLength(maxOutputReportSize: 64), 63)   // 杰理版
        XCTAssertEqual(HIDTransport.payloadLength(maxOutputReportSize: 65), 64)   // 老款
        XCTAssertEqual(HIDTransport.payloadLength(maxOutputReportSize: nil), 64)
        XCTAssertEqual(HIDTransport.payloadLength(maxOutputReportSize: 9), 64)
    }
}
