import Foundation
import AntiCaterCore

// 只读工具：把设备三层配置完整读出来，用于和原版 app 交叉验证。全程不写入。

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

// `--diagnose` 先**尝试**连一次再出报告，但连不上也照样出——用户跑它的时候
// 十有八九就是连不上，报告不能依赖「先连上」。
//
// 之所以要主动试一次：报告里的事件日志本来就是为了回答「连的时候发生了什么」。
// 直接打印报告的话日志永远是空的，等于白留一栏。这一次尝试会把选中了哪个接口、
// IOHIDDeviceOpen 的返回码、握手有没有超时全部记进去。
//
// 全程只读：只有 discover / open / handshake，不写任何配置。
if CommandLine.arguments.contains("--diagnose") {
    do {
        let session = try DeviceConnector.connect()
        defer { session.close() }
        try session.handshake()
    } catch {
        EventLog.shared.log("诊断", "连接尝试失败：\(error)")
    }
    print(Diagnostics.report())
    exit(0)
}

do {
    let session = try DeviceConnector.connect()
    // 漏了 close() 的话 HIDTransport 的 deinit 会往 stderr 打一行「未经 close() 即释放」，
    // 用户跑 --diagnose 排障时第一眼就看到这个，像是工具自己坏了。
    // CLI 全程在主线程，close() 的同线程要求天然满足。
    defer { session.close() }
    print("已连接  \(session.deviceName)  序列号 \(session.serialNumber ?? "-")")

    // 杰理版没有握手，返回空。
    let hello = try session.handshake()
    print("握手应答  \(hello.isEmpty ? "（这台设备没有握手）" : hex(Array(hello.prefix(4))))")

    let layers = try session.readAllLayers()
    for layer in layers.keys.sorted() {
        print("\n──────── 第 \(layer) 层 ────────")
        for binding in layers[layer] ?? [] {
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

    print("\n──────── 灯光 ────────")
    if let rgb = try session.readRGBLight() {
        print(String(format: "%@  颜色 #%02X%02X%02X  亮度 %d%%",
                     rgb.isOn ? "开" : "关", rgb.red, rgb.green, rgb.blue, Int(rgb.brightness)))
    } else {
        let light = try session.readLight()
        let palette = light.palette
        let lightName = Proto.lightModes.first { $0.mode == light.mode }?.name ?? "未知(\(light.mode))"
        print("当前灯效: \(lightName)")
        if !palette.isEmpty {
            print("调色板 (\(palette.count) 色)")
            print(palette.map { String(format: "#%02X%02X%02X", $0.r, $0.g, $0.b) }
                .joined(separator: "  "))
        }
    }

    print("\n带 * 的是这台设备上的实体键。全程只读，未向设备写入任何数据。")
} catch {
    FileHandle.standardError.write("失败: \(error)\n".data(using: .utf8)!)
    exit(1)
}
