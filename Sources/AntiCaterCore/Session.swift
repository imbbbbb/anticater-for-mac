import Foundation

/// 一台旋钮能提供的全部操作。
///
/// 抽成协议是为了让 `DeviceModel` 不再直接依赖 `HIDTransport`：测试里可以塞一个
/// 假设备，模拟拔线、写入被拒、返回垃圾数据这些真机上很难稳定复现的情况。
public protocol DeviceSession: AnyObject {
    var deviceName: String { get }
    var serialNumber: String? { get }

    @discardableResult
    func handshake() throws -> [UInt8]
    func readAllLayers() throws -> [UInt8: [Proto.Binding]]
    func readLight() throws -> (mode: UInt8, palette: [(r: UInt8, g: UInt8, b: UInt8)])
    func writeLight(mode: UInt8, palette: [(r: UInt8, g: UInt8, b: UInt8)]) throws
    func write(_ binding: Proto.Binding) throws

    /// 释放设备。必须在提交这次会话的那个 worker 线程上调用，原因见
    /// `HIDTransport.close()`。
    func close()
}

/// 在 HIDTransport 之上提供成套的读写动作。
public final class Session: DeviceSession {

    public let transport: HIDTransport

    public init(transport: HIDTransport) {
        self.transport = transport
    }

    public static func connect() throws -> Session {
        guard let transport = HIDTransport.discover() else { throw HIDTransport.Failure.notFound }
        try transport.open()
        return Session(transport: transport)
    }

    public var deviceName: String {
        String(format: "0x%04X:0x%04X", transport.vendorID, transport.productID)
    }

    public var serialNumber: String? { transport.serialNumber }

    public func close() { transport.close() }

    /// 握手。设备回 `FB 00 01 0B`，最后一字节疑似固件版本。
    @discardableResult
    public func handshake() throws -> [UInt8] {
        transport.flushPendingInput()
        try transport.send(Proto.handshakeCommand())
        let reply = try transport.receive(count: 1).first ?? []
        // 应答的前四字节是 FB 00 01 <固件版本>，不含用户数据，可以直接记：
        // 用户报协议异常时，固件版本是第一个要问的东西。
        EventLog.shared.log("会话", "握手应答 \(EventLog.hex(Array(reply.prefix(4))))")
        return reply
    }

    /// 读取一层的全部 25 条配置。
    public func readLayer(_ layer: UInt8) throws -> [Proto.Binding] {
        transport.flushPendingInput()
        try transport.send(Proto.readLayerCommand(layer: layer))
        let replies = try transport.receive(count: Proto.entryCount)
        return replies.compactMap(Proto.parseBinding)
    }

    public func readAllLayers() throws -> [UInt8: [Proto.Binding]] {
        var result: [UInt8: [Proto.Binding]] = [:]
        for layer in 1...UInt8(Proto.layerCount) {
            result[layer] = try readLayer(layer)
        }
        return result
    }

    /// 读当前灯效模式和调色板。
    public func readLight() throws -> (mode: UInt8, palette: [(r: UInt8, g: UInt8, b: UInt8)]) {
        transport.flushPendingInput()
        try transport.send(Proto.readPaletteCommand())
        guard let reply = try transport.receive(count: 1).first,
              let light = Proto.parseLight(reply) else { return (0, []) }
        return light
    }

    /// 写灯效。三包连发，设备不回应答，也不需要提交命令。
    public func writeLight(mode: UInt8, palette: [(r: UInt8, g: UInt8, b: UInt8)]) throws {
        for command in Proto.lightCommands(mode: mode, palette: palette) {
            try transport.send(command)
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// 写入一个键的配置并提交。设备不回应答。
    public func write(_ binding: Proto.Binding) throws {
        // 记下标、层、类型和长度，不记键码本身——键码是用户数据，走 verbose。
        // 这几项已经够把「写入回读不一致」定位到具体是哪一次写入出的问题。
        EventLog.shared.log("写入",
            "第 \(binding.layer) 层 [\(String(format: "%02d", Int(binding.index)))] "
            + "类型 \(binding.type?.label ?? String(format: "0x%02X", binding.rawType)) "
            + "len=\(binding.dataLength)")
        try transport.send(Proto.writeCommand(binding))
        try transport.send(Proto.commitCommand())
    }
}
