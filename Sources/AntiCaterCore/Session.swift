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

    // 下面几项是两代硬件不同的地方，都有默认实现（即老款的行为），
    // 老款的 `Session` 和测试里的假设备不用管它们。

    /// 单色灯（杰理版）。没有这套灯光的设备返回 nil。
    func readRGBLight() throws -> Proto.RGBLight?
    func writeRGBLight(_ light: Proto.RGBLight) throws

    /// 组合键、Procreate 预设写成哪一类。
    var chordType: Proto.ActionType { get }

    /// 编辑区里的一条配置按这台设备的写法规整。回读校验拿「打算写的」和
    /// 「读回来的」逐项比，所以凡是设备会改写的字段都要在进 draft 之前规整好。
    func normalized(_ binding: Proto.Binding) -> Proto.Binding

    /// 鼠标页给用户选的动作。只列在这台设备上验证过的。
    var mouseActions: [Proto.MouseAction] { get }
}

public extension DeviceSession {
    func readRGBLight() throws -> Proto.RGBLight? { nil }
    func writeRGBLight(_ light: Proto.RGBLight) throws { throw DeviceSessionError.unsupported }
    var chordType: Proto.ActionType { .keyboard }
    func normalized(_ binding: Proto.Binding) -> Proto.Binding { binding }
    var mouseActions: [Proto.MouseAction] { Proto.mouseActions }
}

public enum DeviceSessionError: Error, CustomStringConvertible {
    /// 这台设备没有这项功能。调用方按「不支持」处理，不当成故障。
    case unsupported

    public var description: String { "这台设备不支持该功能" }
}

/// 找到设备，按 VID/PID 选对应的会话实现。
public enum DeviceConnector {
    public static func connect() throws -> DeviceSession {
        guard let transport = HIDTransport.discover() else { throw HIDTransport.Failure.notFound }
        try transport.open()
        switch transport.variant {
        case .classic: return Session(transport: transport)
        case .jieli:   return JieliSession(transport: transport)
        }
    }
}

/// 在 HIDTransport 之上提供成套的读写动作。
public final class Session: DeviceSession {

    public let transport: HIDTransport

    public init(transport: HIDTransport) {
        self.transport = transport
    }

    /// 只连老款。不确定插的是哪一代时用 `DeviceConnector.connect()`。
    public static func connect() throws -> Session {
        guard let transport = HIDTransport.discover(), transport.variant == .classic
        else { throw HIDTransport.Failure.notFound }
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
        return replies.compactMap { Proto.parseBinding($0) }
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
        try transport.send(Proto.writeCommand(binding, length: transport.payloadLength))
        try transport.send(Proto.commitCommand())
    }
}
