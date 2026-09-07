import Foundation
import AntiCaterCore

// 只读工具：把设备三层配置完整读出来，用于和原版 app 交叉验证。全程不写入。

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

do {
    let session = try Session.connect()
    let transport = session.transport
    print(String(format: "已连接  VID=0x%04X PID=0x%04X  序列号 %@",
                 transport.vendorID, transport.productID, transport.serialNumber ?? "-"))

    let hello = try session.handshake()
    print("握手应答  \(hex(Array(hello.prefix(4))))")

    for layer in 1...UInt8(Proto.layerCount) {
        print("\n──────── 第 \(layer) 层 ────────")
        let bindings = try session.readLayer(layer)
        for binding in bindings {
            let physical = PhysicalKey(rawValue: binding.index)
            let position = physical.map { "\($0.label)" } ?? "  —  "
            let typeName = binding.type?.label ?? String(format: "0x%02X", binding.rawType)

            let steps = binding.activeSteps
            let described = steps.map { step -> String in
                let name = KeyNames.name(for: step.code, type: binding.type)
                return step.delayMs == 0 ? name : "\(name)(+\(step.delayMs)ms)"
            }.joined(separator: " → ")

            let marker = physical == nil ? " " : "*"
            print(String(format: "%@ [%02d] %@  %-6@ len=%d flag=%d  %@",
                         marker, Int(binding.index), position, typeName as NSString,
                         Int(binding.dataLength), Int(binding.flag),
                         described.isEmpty ? "—" : described))
        }
    }

    let light = try session.readLight()
    let palette = light.palette
    let lightName = Proto.lightModes.first { $0.mode == light.mode }?.name ?? "未知(\(light.mode))"
    print("\n──────── 灯光 ────────")
    print("当前灯效: \(lightName)")
    if !palette.isEmpty {
        print("调色板 (\(palette.count) 色)")
        print(palette.map { String(format: "#%02X%02X%02X", $0.r, $0.g, $0.b) }
            .joined(separator: "  "))
    }

    print("\n带 * 的是这台设备上的实体键。全程只读，未向设备写入任何数据。")
} catch {
    FileHandle.standardError.write("失败: \(error)\n".data(using: .utf8)!)
    exit(1)
}
