import XCTest
import IOKit
@testable import AntiCaterCore

/// 协议编解码的回归测试。
///
/// 重点不是覆盖率，是守住那几条「一改就静默出错、界面上又看不出来」的不变量。
/// 每个 test 的注释都写清楚它到底在防什么，别当成样板代码删掉。
final class ProtocolTests: XCTestCase {

    // MARK: - sameFunction

    /// 独立审核抓到的 S2：鼠标类的 `dataLength` 是 4，但滚轮方向存在 `steps[4]`，
    /// 正好落在 `prefix(dataLength)` 之外。曾经的实现只比前四格，于是
    /// 「滚轮+」和「滚轮-」被判成同一个功能 —— 界面认为没有改动，
    /// 「写入旋钮」按钮不亮，用户根本改不了滚轮方向。
    func testMouseActionsAreAllDistinguishable() {
        let actions = Proto.mouseActions
        for (i, a) in actions.enumerated() {
            for b in actions[(i + 1)...] {
                let x = Proto.binding(index: 2, layer: 1, mouse: a)
                let y = Proto.binding(index: 2, layer: 1, mouse: b)
                XCTAssertFalse(Proto.sameFunction(x, y),
                               "「\(a.name)」和「\(b.name)」被判成了同一个功能，改动会被漏报")
            }
        }
    }

    /// 上面那条的最小复现，单独留着，坏了一眼就知道是滚轮。
    func testScrollUpDiffersFromScrollDown() {
        guard let up = Proto.mouseActions.first(where: { $0.slot4 == 0x01 }),
              let down = Proto.mouseActions.first(where: { $0.slot4 == 0xFF }) else {
            return XCTFail("鼠标动作表里找不到滚轮上/下")
        }
        XCTAssertFalse(Proto.sameFunction(Proto.binding(index: 2, layer: 1, mouse: up),
                                          Proto.binding(index: 2, layer: 1, mouse: down)))
    }

    /// 反过来：固件**不清零**槽位，`dataLength` 之外留着上一次配置的残值。
    /// 比较必须忽略这些残值，否则每次回读都判定成「有改动」，写入按钮永远亮着。
    func testResidueBeyondDataLengthIsIgnored() {
        var clean = Proto.Binding(index: 2, layer: 1, type: .keyboard, code: 0x06)
        var dirty = clean
        dirty.steps[7] = Proto.Step(delayMs: 0x32, code: 0x41)   // 上一次配置的残值
        dirty.steps[9] = Proto.Step(delayMs: 0x32, code: 0x42)
        XCTAssertTrue(Proto.sameFunction(clean, dirty))

        // 但有效区内的差异必须认出来。
        clean.steps[0] = Proto.Step(delayMs: 0, code: 0x07)
        XCTAssertFalse(Proto.sameFunction(clean, dirty))
    }

    /// 同一个键、不同索引/套，绝不能算同一个。
    func testDifferentSlotsAreNeverSame() {
        let a = Proto.Binding(index: 2, layer: 1, type: .keyboard, code: 0x06)
        let b = Proto.Binding(index: 4, layer: 1, type: .keyboard, code: 0x06)
        let c = Proto.Binding(index: 2, layer: 2, type: .keyboard, code: 0x06)
        XCTAssertFalse(Proto.sameFunction(a, b))
        XCTAssertFalse(Proto.sameFunction(a, c))
    }

    // MARK: - 报文布局

    /// 18 组三元组必须塞得进 64 字节载荷。改 macroSlots 时这条会拦住越界。
    func testPayloadFits() {
        XCTAssertLessThanOrEqual(Proto.triplesOffset + Proto.macroSlots * 3,
                                 HIDTransport.payloadSize)
        let cmd = Proto.writeCommand(Proto.Binding(index: 2, layer: 1,
                                                   type: .keyboard, code: 0x06))
        XCTAssertEqual(cmd.count, HIDTransport.payloadSize)
        XCTAssertEqual(cmd[0], Proto.Command.write.rawValue)
    }

    /// 写出去的字节再读回来必须是同一个配置。
    func testWriteReadRoundTrip() {
        for action in Proto.mouseActions {
            let original = Proto.binding(index: 2, layer: 1, mouse: action)
            var payload = Proto.writeCommand(original)
            payload[0] = Proto.Command.read.rawValue      // 应答用 FA 打头
            guard let parsed = Proto.parseBinding(payload) else {
                return XCTFail("「\(action.name)」解析失败")
            }
            XCTAssertTrue(Proto.sameFunction(original, parsed), action.name)
            XCTAssertEqual(Proto.mouseAction(from: parsed)?.name, action.name)
        }
    }

    /// M1：`dataLength` 是设备给的，界面拿它当下标上界。
    /// 设备抽风（或线上有噪声）返回 200，不夹紧就会越界崩溃。
    func testDataLengthIsClamped() {
        var payload = [UInt8](repeating: 0, count: HIDTransport.payloadSize)
        payload[0] = Proto.Command.read.rawValue
        payload[5] = 200
        guard let parsed = Proto.parseBinding(payload) else { return XCTFail("解析失败") }
        XCTAssertLessThanOrEqual(Int(parsed.dataLength), Proto.macroSlots)
        XCTAssertEqual(parsed.steps.count, Proto.macroSlots)
    }

    /// 载荷不够长必须返回 nil，不能读越界。
    func testShortPayloadRejected() {
        XCTAssertNil(Proto.parseBinding([Proto.Command.read.rawValue, 2, 1]))
        XCTAssertNil(Proto.parseBinding([]))
    }

    /// 「清除」按抓包实证：type=键盘、flag=0、dataLength=0、三元组全零。
    func testClearedShape() {
        let cleared = Proto.cleared(index: 2, layer: 1)
        XCTAssertEqual(cleared.rawType, Proto.ActionType.keyboard.rawValue)
        XCTAssertEqual(cleared.flag, 0)
        XCTAssertEqual(cleared.dataLength, 0)
        XCTAssertTrue(cleared.steps.allSatisfy { $0.code == 0 && $0.delayMs == 0 })
    }

    // MARK: - 组合键 / 预设

    func testComboRoundTrip() {
        let combos = [
            Proto.Combo(ctrl: true, code: 0x06),
            Proto.Combo(shift: true, win: true, code: 0x1D),
            Proto.Combo(alt: true, code: 0x2C),
            Proto.Combo(ctrl: true, shift: true, alt: true, win: true, code: 0x04),
        ]
        for combo in combos {
            let binding = Proto.binding(index: 2, layer: 1, combo: combo)
            XCTAssertEqual(Proto.combo(from: binding), combo)
        }
    }

    /// 31 条 Procreate 预设：名字和键码都不能有重复，
    /// 重复意味着抓包顺序对错位了（审核报告 §2.4 关注的就是这个）。
    func testProcreatePresetsAreUnique() {
        let presets = Proto.procreatePresets
        XCTAssertEqual(presets.count, 31)
        XCTAssertEqual(Set(presets.map(\.name)).count, presets.count, "预设名字有重复")
        XCTAssertEqual(Set(presets.map { $0.codes }).count, presets.count, "预设键码有重复")
    }

    func testProcreatePresetRoundTrip() {
        for preset in Proto.procreatePresets {
            let binding = Proto.binding(index: 2, layer: 1, preset: preset)
            XCTAssertEqual(Int(binding.dataLength), preset.codes.count, preset.name)
            XCTAssertEqual(Proto.preset(from: binding)?.name, preset.name)
        }
    }

    // MARK: - 安全红线

    /// §1.2：本实现的命令集中不得存在固件升级/刷写通道。
    func testNoFirmwareCommand() {
        XCTAssertEqual(Set([Proto.Command.handshake, .read, .write, .writeRGB]
                            .map(\.rawValue)),
                       [0xFB, 0xFA, 0xFD, 0xFE])
        XCTAssertNil(Proto.Command(rawValue: 0xFC), "0xFC 不在已实现的命令集中，不应可构造")
    }

    /// 五个物理动作，界面顺序必须和 allCases 覆盖同一批，别漏键也别多键。
    func testDisplayOrderCoversAllKeys() {
        XCTAssertEqual(Set(PhysicalKey.displayOrder), Set(PhysicalKey.allCases))
        XCTAssertEqual(PhysicalKey.displayOrder.count, PhysicalKey.allCases.count)
    }

    // MARK: - 掉线判定

    /// 拔线后往旧句柄上写，实测拿到的是 0xE00002C2（kIOReturnBadArgument）。
    /// 这类错误必须被识别成「掉线」并丢掉 session，否则重试多少次都是同一个错。
    func testStaleHandleErrorsMeanDisconnected() {
        for code in [kIOReturnBadArgument, kIOReturnNoDevice,
                     kIOReturnNotOpen, kIOReturnNotAttached] {
            XCTAssertTrue(HIDTransport.Failure.writeFailed(code).meansDisconnected,
                          String(format: "0x%08X 应判为掉线", UInt32(bitPattern: Int32(code))))
        }
        XCTAssertTrue(HIDTransport.Failure.notFound.meansDisconnected)
    }

    /// 反过来：被别的程序占用、以及超时，都**不是**掉线。
    /// 误判成掉线会把还活着的 session 丢掉，用户得莫名其妙重连一次。
    func testOtherErrorsDoNotMeanDisconnected() {
        XCTAssertFalse(HIDTransport.Failure.openFailed(kIOReturnExclusiveAccess)
                        .meansDisconnected)
        XCTAssertFalse(HIDTransport.Failure.timeout(expected: 5, got: 2).meansDisconnected)
    }
}

/// 版本比较的测试。看着琐碎，但比错了的后果是「有新版却不提示」
/// 或者「永远提示有新版」，两种都很烦人。
final class UpdateCheckerTests: XCTestCase {

    func testNewerVersionIsDetected() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.1", than: "1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0", than: "1.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
    }

    /// 必须按数字比，不能按字典序——字典序下 "1.10" < "1.9"，
    /// 于是从 1.9 升到 1.10 就永远不会提示。
    func testDoubleDigitVersionsCompareNumerically() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9", than: "1.10"))
    }

    func testSameVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.0", than: "1.0"), "开头的 v 不该影响比较")
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0"), "补零后应视为相等")
    }

    func testOlderVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("0.9", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.1"))
    }

    /// tag 里混进非数字后缀时不能崩，也不该误判成更新。
    func testMalformedTagsDoNotCrash() {
        XCTAssertFalse(UpdateChecker.isNewer("", than: AppVersion.string))
        XCTAssertFalse(UpdateChecker.isNewer("v1.0-beta", than: "1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.2-beta", than: "1.1"))
    }

    /// 发布流程会拿 AppVersion 当 tag，格式不对整条链都会歪。
    func testAppVersionIsParseable() {
        XCTAssertFalse(UpdateChecker.components(AppVersion.string).isEmpty)
        XCTAssertTrue(UpdateChecker.isNewer("99.0", than: AppVersion.string))
    }
}
