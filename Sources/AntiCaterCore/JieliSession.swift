import Foundation

/// 杰理版的会话。报文格式见 `Proto.Jieli`。
///
/// 和老款 `Session` 的区别：没有握手，一条查询读回全部配置和灯光，只有一层，
/// 写一个键发两条，灯光是单色的。按键配置的编解码复用 `Proto`。
public final class JieliSession: DeviceSession {

    public let transport: HIDTransport

    /// 一次查询会把灯光一起带回来，存一份，`readRGBLight` 就不必再查一遍。
    /// 只在 worker 线程上读写。
    private var cachedLight: Proto.RGBLight?

    public init(transport: HIDTransport) {
        self.transport = transport
    }

    public var deviceName: String {
        String(format: "0x%04X:0x%04X", transport.vendorID, transport.productID)
    }

    public var serialNumber: String? { transport.serialNumber }

    public func close() { transport.close() }

    /// 没有握手：发了也不回。返回空数组，界面上固件版本显示成「?」。
    @discardableResult
    public func handshake() throws -> [UInt8] { [] }

    public func readAllLayers() throws -> [UInt8: [Proto.Binding]] {
        [Proto.Jieli.layer: try query().bindings]
    }

    /// 老款那套灯效（模式 + 调色板）这台没有。
    public func readLight() throws -> (mode: UInt8, palette: [(r: UInt8, g: UInt8, b: UInt8)]) {
        throw DeviceSessionError.unsupported
    }

    public func writeLight(mode: UInt8, palette: [(r: UInt8, g: UInt8, b: UInt8)]) throws {
        throw DeviceSessionError.unsupported
    }

    public func readRGBLight() throws -> Proto.RGBLight? {
        if let cachedLight { return cachedLight }
        return try query().light
    }

    /// 一条就生效，设备不回应答。
    public func writeRGBLight(_ light: Proto.RGBLight) throws {
        try transport.send(light.command)
        cachedLight = light
    }

    /// 写入一个键：两条报文，再发一次提交。设备都不回应答。
    ///
    /// 提交命令 `FD FE FF` 原版并不跟着写入发，而是每秒发一次；这里写完补一次，
    /// 效果一样，也省得另开定时器。
    public func write(_ binding: Proto.Binding) throws {
        // 记下标、类型和长度，不记键码本身——键码是用户数据，走 verbose。
        EventLog.shared.log("写入",
            "[\(String(format: "%02d", Int(binding.index)))] "
            + "类型 \(binding.type?.label ?? String(format: "0x%02X", binding.rawType)) "
            + "len=\(binding.dataLength)")
        for command in Proto.Jieli.writeCommands(binding, length: transport.payloadLength) {
            try transport.send(command)
            // 原版两条之间隔约 2 ms；这里给 3 ms，多一点不碍事。
            Thread.sleep(forTimeInterval: 0.003)
        }
        try transport.send(Proto.commitCommand())
    }

    public var chordType: Proto.ActionType { Proto.Jieli.chordType }

    public func normalized(_ binding: Proto.Binding) -> Proto.Binding {
        Proto.Jieli.normalized(binding)
    }

    public var mouseActions: [Proto.MouseAction] {
        Proto.mouseActions.filter { Proto.Jieli.verifiedMouseActionNames.contains($0.name) }
    }

    // MARK: - 查询

    /// 发一次查询，收齐五个键。灯光那一条收不到也不算失败——灯光是附带功能，
    /// 不该让整次连接跟着失败（1.2.2 在老款上修过同一类问题）。
    private func query() throws -> (bindings: [Proto.Binding], light: Proto.RGBLight?) {
        transport.flushPendingInput()
        try transport.send(Proto.Jieli.queryCommand(length: transport.payloadLength))

        var replies: [[UInt8]] = []
        var keys = Set<UInt8>()
        var sawLight = false
        // 上限防的是设备一直吐认不出的报文：正常 6 条就收齐了。
        while !keys.isSuperset(of: Proto.Jieli.keyIndices), replies.count < 12 {
            guard let reply = try transport.receive(count: 1).first else { break }
            replies.append(reply)
            guard reply.count > 1, reply[0] == Proto.Command.write.rawValue else { continue }
            if reply[1] == Proto.Jieli.lightIndex { sawLight = true } else { keys.insert(reply[1]) }
        }
        guard keys.isSuperset(of: Proto.Jieli.keyIndices) else {
            EventLog.shared.log("会话", "查询应答 \(replies.count) 条，五个键没有收齐")
            throw HIDTransport.Failure.timeout(expected: Proto.Jieli.keyIndices.count + 1,
                                               got: replies.count)
        }
        if !sawLight, let extra = try? transport.receive(count: 1, timeout: 0.3).first {
            replies.append(extra)
        }

        let result = Proto.Jieli.parseQueryReplies(replies)
        EventLog.shared.log("会话",
            "查询应答 \(replies.count) 条，灯光\(result.light == nil ? "没有读到" : "已读到")")
        cachedLight = result.light
        return result
    }
}
