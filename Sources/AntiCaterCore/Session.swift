import Foundation

/// 在 HIDTransport 之上提供成套的读写动作。
public final class Session {

    public let transport: HIDTransport

    public init(transport: HIDTransport) {
        self.transport = transport
    }

    public static func connect() throws -> Session {
        guard let transport = HIDTransport.discover() else { throw HIDTransport.Failure.notFound }
        try transport.open()
        return Session(transport: transport)
    }

    /// 握手。设备回 `FB 00 01 0B`，最后一字节疑似固件版本。
    @discardableResult
    public func handshake() throws -> [UInt8] {
        transport.flushPendingInput()
        try transport.send(Proto.handshakeCommand())
        return try transport.receive(count: 1).first ?? []
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
        try transport.send(Proto.writeCommand(binding))
        try transport.send(Proto.commitCommand())
    }
}
