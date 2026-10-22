import XCTest
@testable import AntiCaterCore

/// 杰理版协议。所有期望值都是原版 Mac 软件实际发出 / 收到的报文（2026-10-21 抓取），
/// 去掉了 Report ID，末尾的零补齐到 63 字节。
final class JieliProtocolTests: XCTestCase {

    /// 杰理版的载荷长度（报告描述符 Report Count 0x3F）
    private let length = 63

    /// 把抓包里的十六进制补零到一条报文的长度
    private func packet(_ hex: String) -> [UInt8] {
        let bytes = hex.split(separator: " ").map { UInt8($0, radix: 16)! }
        return bytes + [UInt8](repeating: 0, count: length - bytes.count)
    }

    private func reply(_ hex: String) -> [UInt8] { packet(hex) }

    // MARK: - 读取

    /// 查询没有命令头，整条都是 FF
    func testQueryIsAllFF() {
        XCTAssertEqual(Proto.Jieli.queryCommand(length: length),
                       [UInt8](repeating: 0xFF, count: length))
    }

    /// 应答按键号认，不按顺序：灯光排在前面也要认得出来
    func testRepliesAreIdentifiedByIndexNotOrder() {
        let (bindings, light) = Proto.Jieli.parseQueryReplies([
            reply("FD 00 06 00 FF 00 64"),
            reply("FD 06 01 02 00 01 00 00 6F"),
            reply("FD 02 01 02 00 01 00 00 EA"),
        ])
        XCTAssertEqual(bindings.map(\.index), [2, 6])
        XCTAssertNotNil(light)
    }

    /// 出厂配置：音量-/播放暂停/音量+/亮度-/亮度+，灯光绿色 100% 关。
    func testParsesFactoryDefaults() {
        let replies = [
            reply("FD 02 01 02 00 01 00 00 EA"),
            reply("FD 03 01 02 00 01 00 00 CD"),
            reply("FD 04 01 02 00 01 00 00 E9"),
            reply("FD 05 01 02 00 01 00 00 70"),
            reply("FD 06 01 02 00 01 00 00 6F"),
            reply("FD 00 06 00 FF 00 64"),
        ]
        let (bindings, light) = Proto.Jieli.parseQueryReplies(replies)

        XCTAssertEqual(bindings.map(\.index), [2, 3, 4, 5, 6])
        XCTAssertTrue(bindings.allSatisfy { $0.layer == 1 && $0.type == .media })
        XCTAssertEqual(bindings.map { $0.activeSteps.first?.code },
                       [0xEA, 0xCD, 0xE9, 0x70, 0x6F])

        XCTAssertEqual(light, Proto.RGBLight(effect: 0x06, red: 0x00, green: 0xFF, blue: 0x00,
                                             brightness: 100, isOn: false))
    }

    /// 键盘页拼出来的 ⌘Z：⌘ 之后等 50 ms 再按 Z，类型 01。
    func testParsesKeyboardSequenceWithDelay() throws {
        let binding = try XCTUnwrap(Proto.parseBinding(
            reply("FD 03 01 01 00 02 00 00 F4 00 32 1D"), command: 0xFD))
        XCTAssertEqual(binding.type, .keyboard)
        XCTAssertEqual(binding.activeSteps.map(\.code), [0xF4, 0x1D])
        XCTAssertEqual(binding.activeSteps.map(\.delayMs), [0, 50])
    }

    /// Procreate 页的「撤销」写成类型 04，要能认回预设。
    func testParsesChordTypeAsPreset() throws {
        let binding = try XCTUnwrap(Proto.parseBinding(
            reply("FD 05 01 04 00 02 00 00 F4 00 00 1D"), command: 0xFD))
        XCTAssertEqual(binding.type, .combo)
        XCTAssertEqual(Proto.preset(from: binding)?.name, "撤销")
        XCTAssertEqual(Proto.combo(from: binding), Proto.Combo(win: true, code: 0x1D))
    }

    func testParsesMouseLeftButton() throws {
        let binding = try XCTUnwrap(Proto.parseBinding(
            reply("FD 04 01 03 01 04 00 00 00 00 00 01"), command: 0xFD))
        XCTAssertEqual(Proto.mouseAction(from: binding)?.name, "鼠标左键")
    }

    /// 读应答里的灯光条目不能被当成一个键
    func testLightReplyIsNotABinding() {
        let (bindings, light) = Proto.Jieli.parseQueryReplies([reply("FD 00 06 FF 00 00 32 01")])
        XCTAssertTrue(bindings.isEmpty)
        XCTAssertEqual(light?.isOn, true)
        XCTAssertEqual(light?.brightness, 50)
    }

    // MARK: - 写入

    /// 「按下」改成空格：两条，第二条键号 03 → 11。
    func testWriteIsMirroredPair() {
        let space = Proto.Binding(index: 3, layer: 1, type: .keyboard, code: 0x2C)
        XCTAssertEqual(Proto.Jieli.writeCommands(space, length: length), [
            packet("FD 03 01 01 00 01 00 00 2C"),
            packet("FD 11 01 01 00 01 00 00 2C"),
        ])
    }

    /// 五个键的第二条键号都要对上，尤其 06 → 15 跳过了 14。
    func testMirrorIndicesMatchCapture() {
        let expected: [UInt8: UInt8] = [2: 0x10, 3: 0x11, 4: 0x12, 5: 0x13, 6: 0x15]
        for (index, mirror) in expected {
            let binding = Proto.Binding(index: index, layer: 1, type: .media, code: 0xE2)
            XCTAssertEqual(Proto.Jieli.writeCommands(binding, length: length).last?[1], mirror)
        }
    }

    func testWriteKeyboardSequenceMatchesCapture() {
        var binding = Proto.Binding(index: 3, layer: 1, type: .keyboard, code: 0xF4)
        binding.steps[1] = Proto.Step(delayMs: 50, code: 0x1D)
        binding.dataLength = 2
        XCTAssertEqual(Proto.Jieli.writeCommands(binding, length: length).first,
                       packet("FD 03 01 01 00 02 00 00 F4 00 32 1D"))
    }

    func testWriteProcreatePresetMatchesCapture() throws {
        let undo = try XCTUnwrap(Proto.procreatePresets.first { $0.name == "撤销" })
        let binding = Proto.binding(index: 5, layer: 1, preset: undo, type: Proto.Jieli.chordType)
        XCTAssertEqual(Proto.Jieli.writeCommands(binding, length: length), [
            packet("FD 05 01 04 00 02 00 00 F4 00 00 1D"),
            packet("FD 13 01 04 00 02 00 00 F4 00 00 1D"),
        ])
    }

    func testWriteMouseMatchesCapture() throws {
        let left = try XCTUnwrap(Proto.mouseActions.first { $0.name == "鼠标左键" })
        let binding = Proto.binding(index: 4, layer: 1, mouse: left)
        XCTAssertEqual(Proto.Jieli.writeCommands(binding, length: length).first,
                       packet("FD 04 01 03 01 04 00 00 00 00 00 01"))
    }

    /// 多媒体按原版写 dataLength = 1（抓包：FD 03 01 02 00 01 00 00 CD）
    func testNormalizedMediaMatchesCapture() {
        let play = Proto.Jieli.normalized(
            Proto.Binding(index: 3, layer: 1, type: .media, code: 0xCD))
        XCTAssertEqual(Proto.Jieli.writeCommands(play, length: length).first,
                       packet("FD 03 01 02 00 01 00 00 CD"))
    }

    /// 只有一层：调用方传进来别的层号，也要写成第 1 层。
    func testWriteForcesSingleLayer() {
        let binding = Proto.Binding(index: 2, layer: 3, type: .media, code: 0xEA)
        XCTAssertEqual(Proto.Jieli.writeCommands(binding, length: length).first?[2], 1)
    }

    // MARK: - 灯光

    func testLightCommandMatchesCapture() {
        let red = Proto.RGBLight(red: 0xFF, green: 0x00, blue: 0x00, brightness: 50, isOn: true)
        XCTAssertEqual(red.command, [0xFD, 0x00, 0x06, 0xFF, 0x00, 0x00, 0x32, 0x01])
    }

    func testBrightnessIsClampedTo100() {
        let light = Proto.RGBLight(red: 0, green: 0, blue: 0, brightness: 200, isOn: true)
        XCTAssertEqual(light.brightness, 100)
    }
}
