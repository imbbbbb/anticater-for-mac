import Foundation
import AntiCaterCore

/// 一台可编程的假旋钮。
///
/// 真机上很难稳定复现的几件事——拔线、设备把写入吃掉不生效、返回缺斤少两的数据——
/// 在这里都能直接摆出来。
final class FakeSession: DeviceSession {

    /// 设备当前的「固件内容」。写进来的东西默认落到这里，回读也从这里出。
    var layers: [UInt8: [Proto.Binding]]
    var light: (mode: UInt8, palette: [(r: UInt8, g: UInt8, b: UInt8)]) = (0, [])

    /// 这些键的写入会被设备默默吃掉：命令不报错，但配置不生效。
    /// 用来复现「写了没进去」——回读校验就是为这个存在的。
    var silentlyIgnoredIndices: Set<UInt8> = []

    /// 下一次调用对应方法时抛出的错误。抛完自动清空，只影响一次。
    var handshakeError: Error?
    var writeError: Error?
    var readError: Error?
    /// 单独一个：issue #1 那台设备读配置正常、只有读灯效不应答，
    /// 和 `readError` 共用就没法复现「三层都读到了，唯独灯效超时」。
    var readLightError: Error?
    var writeLightError: Error?

    /// 回读时故意少给一层，模拟设备返回残缺数据。
    var dropLayerOnRead: UInt8?

    private(set) var writtenBindings: [Proto.Binding] = []
    private(set) var closeCount = 0
    private(set) var handshakeCount = 0

    var deviceName: String { "0x514C:0x8850" }
    var serialNumber: String? { "FAKE-0001" }

    init(layers: [UInt8: [Proto.Binding]] = FakeSession.defaultLayers()) {
        self.layers = layers
    }

    /// 三层 × 五个物理动作，全部空配置。
    static func defaultLayers() -> [UInt8: [Proto.Binding]] {
        var result: [UInt8: [Proto.Binding]] = [:]
        for layer in 1...UInt8(Proto.layerCount) {
            result[layer] = PhysicalKey.allCases.map {
                Proto.cleared(index: $0.rawValue, layer: layer)
            }
        }
        return result
    }

    private func take(_ error: inout Error?) throws {
        if let e = error { error = nil; throw e }
    }

    @discardableResult
    func handshake() throws -> [UInt8] {
        handshakeCount += 1
        try take(&handshakeError)
        return [0xFB, 0x00, 0x01, 0x0B]
    }

    func readAllLayers() throws -> [UInt8: [Proto.Binding]] {
        try take(&readError)
        var snapshot = layers
        if let drop = dropLayerOnRead { snapshot[drop] = nil }
        return snapshot
    }

    func readLight() throws -> (mode: UInt8, palette: [(r: UInt8, g: UInt8, b: UInt8)]) {
        try take(&readLightError)
        return light
    }

    func writeLight(mode: UInt8, palette: [(r: UInt8, g: UInt8, b: UInt8)]) throws {
        try take(&writeLightError)
        light = (mode, palette)
    }

    func write(_ binding: Proto.Binding) throws {
        try take(&writeError)
        writtenBindings.append(binding)
        guard !silentlyIgnoredIndices.contains(binding.index) else { return }
        guard var list = layers[binding.layer],
              let i = list.firstIndex(where: { $0.index == binding.index }) else { return }
        list[i] = binding
        layers[binding.layer] = list
    }

    func close() { closeCount += 1 }
}
