import Foundation

extension Proto {

    /// 杰理版（VID 0x05AC / PID 0x022C）和老款不同的那部分协议。会话流程见 `JieliSession`。
    ///
    /// 结论来自对原版 Mac 软件的收发抓取（2026-10-21）：给它换了一个记日志的
    /// hidapi 外壳，在原版界面上逐项改、保存，再读回核对。按键配置的报文布局和
    /// 老款**完全一样**（`FD <键> <层> <类型> <flag> <长度> 00 {延时 键码 00}…`），
    /// 修饰前缀码、鼠标子类、Procreate 键码也一样，直接复用 `Proto` 里的编解码。
    /// 不同的只有下面这些：
    ///
    ///  * 没有握手。读取是一条全 `FF` 的查询（没有命令头），设备一口气回 6 条：
    ///    五个键加一条灯光。
    ///  * 读应答的命令字节是 `FD`，不是 `FA`。
    ///  * 只有一层。
    ///  * 写一个键要连发两条，第二条换成 `mirrorIndex` 里的键号，内容不变。
    ///  * 灯光是单色 RGB + 亮度 + 开关，见 `RGBLight`。
    ///  * 载荷 63 字节（报告描述符 Report Count 0x3F）。
    public enum Jieli {

        /// 只有一层，读回来的配置统一挂在第 1 层下面。
        public static let layer: UInt8 = 1

        /// 一次查询会回来的五个键。
        public static let keyIndices: Set<UInt8> = [0x02, 0x03, 0x04, 0x05, 0x06]

        /// 灯光那一条的键号
        public static let lightIndex: UInt8 = 0x00

        /// 写入时第二条报文用的键号。
        ///
        /// 实验结果（2026-10-21，在设备上做的）：只发第一条，读回和实际按键效果都变了，
        /// 有线、蓝牙、2.4G 一样；只发第二条，读回和实际效果都不变。它可能是开机时
        /// 加载的存档，但这台旋钮没有关机方式，验证不了——**推断，未验证**。
        /// 为什么跳过 0x14 也不知道。照原版两条都发。
        public static let mirrorIndex: [UInt8: UInt8] = [
            0x02: 0x10, 0x03: 0x11, 0x04: 0x12, 0x05: 0x13, 0x06: 0x15,
        ]

        /// 「修饰键 + 目标键」同时按下时写成的类型。原版 Procreate 页写的是 0x04，
        /// 键盘页拼出来的序列才写 0x01。0x04 已在设备上实测（Procreate「撤销」）。
        public static let chordType: ActionType = .combo

        /// 鼠标页里在这台设备上验证过的动作。只抓到并实测了「左键」，其余沿用老款
        /// 编码多半也对，但没验证，先不给用户选。
        public static let verifiedMouseActionNames: Set<String> = ["鼠标左键"]

        /// 读取全部配置的查询：整条载荷都是 `FF`，没有命令头。
        ///
        /// 原版经 hidapi 发的是 Report ID + 64 个 `FF`（比描述符多一字节，设备照收），
        /// 按描述符发 Report ID + 63 个 `FF` 也能拿到同样的 6 条应答（实测）。
        public static func queryCommand(length: Int) -> [UInt8] {
            [UInt8](repeating: 0xFF, count: length)
        }

        /// 一个键的写入：两条报文，依次发出。
        public static func writeCommands(_ binding: Binding, length: Int) -> [[UInt8]] {
            var normalized = binding
            normalized.layer = layer
            let first = writeCommand(normalized, length: length)
            guard let mirror = mirrorIndex[binding.index] else { return [first] }
            var second = first
            second[1] = mirror
            return [first, second]
        }

        /// 按原版的写法规整一条配置：只有一层；多媒体的 dataLength 老款写 2，
        /// 原版在杰理版上写 1（写 2 设备也认，但回读得到的是写进去的值）。
        public static func normalized(_ binding: Binding) -> Binding {
            var next = binding
            next.layer = layer
            if next.type == .media { next.dataLength = 1 }
            return next
        }

        /// 拆开查询的应答。**按 `payload[1]` 区分是键还是灯光，不靠顺序。**
        ///
        /// 抓到的几次顺序都是 02 03 04 05 06 00（灯光在最后），但固件没有义务保持，
        /// 所以不依赖它。认不出来的条目直接丢掉。
        public static func parseQueryReplies(_ replies: [[UInt8]])
            -> (bindings: [Binding], light: RGBLight?) {
            var bindings: [Binding] = []
            var light: RGBLight?
            for payload in replies {
                guard payload.count > 1, payload[0] == Command.write.rawValue else { continue }
                if payload[1] == lightIndex {
                    light = RGBLight(payload: payload)
                } else if keyIndices.contains(payload[1]),
                          let binding = parseBinding(payload, command: Command.write.rawValue) {
                    bindings.append(binding)
                }
            }
            return (bindings.sorted { $0.index < $1.index }, light)
        }
    }

    /// 杰理版的灯光：`FD 00 <效果> <R> <G> <B> <亮度 0–100> <开关>`。
    ///
    /// 只发一条，没有成对写入，也不需要提交；原版拖动取色器和亮度条时是连续发的。
    /// 写完读回能看到新值，说明直接存进了设备。
    ///
    /// 效果字节读回来一直是 06，原版界面也没有改它的地方，含义不明（**推断，未验证**），
    /// 界面不暴露，写的时候原样带回去。
    public struct RGBLight: Equatable {
        public var effect: UInt8
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8
        /// 0…100
        public var brightness: UInt8
        public var isOn: Bool

        public init(effect: UInt8 = 0x06, red: UInt8, green: UInt8, blue: UInt8,
                    brightness: UInt8, isOn: Bool) {
            self.effect = effect
            self.red = red
            self.green = green
            self.blue = blue
            self.brightness = min(brightness, 100)
            self.isOn = isOn
        }

        init?(payload: [UInt8]) {
            guard payload.count >= 8, payload[0] == Command.write.rawValue,
                  payload[1] == Jieli.lightIndex else { return nil }
            self.init(effect: payload[2], red: payload[3], green: payload[4],
                      blue: payload[5], brightness: payload[6], isOn: payload[7] != 0)
        }

        public var command: [UInt8] {
            [Command.write.rawValue, Jieli.lightIndex, effect, red, green, blue,
             min(brightness, 100), isOn ? 0x01 : 0x00]
        }
    }
}
