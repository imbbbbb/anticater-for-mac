// ⚠️ 一次性的应急工具，不由 app 调用，也别写进任何脚本。
//
// 它会**无条件覆盖**第 1 套的左旋(02)和右旋(04)两个键，写成音量-/音量+，
// 不问、不确认、不备份。抓包时这两个键被反复改写过，用它恢复出厂手感。
// 如果你现在已经把左右旋设成了别的功能，跑一次就没了，只能手动改回来。
// 正常改配置请用 app，那条路有确认弹窗和回读校验。

import Foundation
import AntiCaterCore

// 抓包收尾工具：把被当成实验田的那个键改回原来的功能，写完立刻回读校验。
// 只动指定的那一个键，其它一概不碰。

let session = try Session.connect()
try session.handshake()

func restore(_ key: PhysicalKey, to binding: Proto.Binding) throws {
    try session.write(binding)
    Thread.sleep(forTimeInterval: 0.05)
    let after = try session.readLayer(1).first { $0.index == key.rawValue }
    // 比较只看「有效」部分：类型 + dataLength + 前 dataLength 组三元组。
    // 固件不清零槽位，dataLength 之外留着上一次配置的残值；flag 也只对鼠标类持久化。
    // 这两处算进来都会误报不一致。
    func fingerprint(_ b: Proto.Binding) -> [UInt8] {
        var out: [UInt8] = [b.rawType, b.dataLength]
        for step in b.steps.prefix(Int(b.dataLength)) {
            out.append(step.delayMs)
            out.append(step.code)
        }
        return out
    }
    let ok = after.map { fingerprint($0) == fingerprint(binding) } ?? false
    print("\(key.label): \(ok ? "✅ 已恢复" : "⚠️ 回读不一致")")
}

// 抓包把 02 / 04 改成了 Cmd+Z / Cmd+] ，改回出厂的音量 -/+。
try restore(.rotateLeft,
            to: Proto.Binding(index: PhysicalKey.rotateLeft.rawValue, layer: 1,
                              type: .media, code: 0xEA))
try restore(.rotateRight,
            to: Proto.Binding(index: PhysicalKey.rotateRight.rawValue, layer: 1,
                              type: .media, code: 0xE9))

// 顶层代码里不能用 defer 兜底（抛错时不会走到这），但这里抛错本来就该带着
// 「未经 close() 即释放」的告警退出——那正是需要被看见的信号。
session.close()
