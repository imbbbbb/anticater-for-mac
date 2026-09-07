import Foundation

/// ANTICATER 私有 HID 协议的编解码。
///
/// 全部结论来自对原版 app 的收发抓取（2026-09-06），要点：
///  * 每条报文 = Report ID 3 + 64 字节载荷。下面所有下标都是**去掉 Report ID 之后**的载荷下标。
///  * 无校验和、无序号、无加密。
///  * 读应答和写命令共用同一套载荷布局，只有命令字节不同。
public enum Proto {

    public static let entryCount = 0x19        // 每层 25 条
    public static let layerCount = 3           // 层 1..3
    public static let macroSlots = 18          // 原版「延时」页正好排 18 格；载荷放得下 19 组
    public static let triplesOffset = 7        // 三元组起始下标

    public enum Command: UInt8 {
        case handshake = 0xFB
        case read      = 0xFA
        case write     = 0xFD
        case writeRGB  = 0xFE
    }

    public enum ActionType: UInt8 {
        case keyboard = 0x01
        case media    = 0x02
        case mouse    = 0x03

        public var label: String {
            switch self {
            case .keyboard: return "键盘"
            case .media:    return "多媒体"
            case .mouse:    return "鼠标"
            }
        }
    }

    /// 宏里的一步：先等 `delayMs` 毫秒，再发 `code`。
    public struct Step: Equatable {
        public var delayMs: UInt8
        public var code: UInt8
        public init(delayMs: UInt8 = 0, code: UInt8 = 0) {
            self.delayMs = delayMs
            self.code = code
        }
        public var isEmpty: Bool { code == 0 }
    }

    /// 一个键在某一层上的完整配置。
    public struct Binding {
        public var index: UInt8            // 1...25，物理键见 PhysicalKey
        public var layer: UInt8            // 1...3
        public var rawType: UInt8
        // 载荷 [4]。只有鼠标类（type 03）用它区分子类：01=按键滚轮，04=划屏手势。
        // 键盘和多媒体类不存这个字节——写 0 进去，回读拿到的是该槽位上一次的残值，
        // 所以比对这两类配置时不能把 flag 算进去。
        public var flag: UInt8
        public var dataLength: UInt8       // 载荷 [5]，键盘=宏步数，多媒体=2，鼠标=4
        public var steps: [Step]           // 全部 18 个槽位，含空槽

        public var type: ActionType? { ActionType(rawValue: rawType) }

        /// 实际生效的步骤。键盘按 dataLength 截断，其余类型只有第一项有意义。
        public var activeSteps: [Step] {
            switch type {
            case .keyboard: return Array(steps.prefix(Int(dataLength)))
            case .media, .mouse: return Array(steps.prefix(1))
            case nil: return steps.filter { !$0.isEmpty }
            }
        }

        public init(index: UInt8, layer: UInt8, rawType: UInt8, flag: UInt8,
                    dataLength: UInt8, steps: [Step]) {
            self.index = index
            self.layer = layer
            self.rawType = rawType
            self.flag = flag
            self.dataLength = dataLength
            self.steps = steps
        }

        /// 单键/单动作的便捷构造
        public init(index: UInt8, layer: UInt8, type: ActionType, code: UInt8, delayMs: UInt8 = 0) {
            var steps = Array(repeating: Step(), count: Proto.macroSlots)
            steps[0] = Step(delayMs: delayMs, code: code)
            let length: UInt8 = (type == .keyboard) ? 1 : type.rawValue == 3 ? 4 : 2
            self.init(index: index, layer: layer, rawType: type.rawValue,
                      flag: 0, dataLength: length, steps: steps)
        }
    }

    /// 组合键。设备没有单独的组合键类型，就是键盘序列里先放修饰前缀、末尾放目标键。
    /// 前缀是厂商自定义码，不是 HID 标准码。
    ///
    /// 抓包实证：F1=Ctrl、F2=Shift、F3=Alt、F4=Win(⌘)。
    /// 原版的前缀清单一共 9 项（NULL、左四个、右四个），F8 也抓到了，
    /// 落在清单最后一格，所以右侧四个按 F5…F8 顺排。
    public struct Combo: Equatable {
        public static let ctrlCode: UInt8 = 0xF1
        public static let shiftCode: UInt8 = 0xF2
        public static let altCode: UInt8 = 0xF3
        public static let winCode: UInt8 = 0xF4
        public static let rightCtrlCode: UInt8 = 0xF5
        public static let rightShiftCode: UInt8 = 0xF6
        public static let rightAltCode: UInt8 = 0xF7
        public static let rightWinCode: UInt8 = 0xF8

        public var ctrl = false
        public var shift = false
        public var alt = false
        public var win = false
        public var code: UInt8 = 0x06   // 默认 C，配上 Ctrl 就是复制

        public init(ctrl: Bool = false, shift: Bool = false, alt: Bool = false,
                    win: Bool = false, code: UInt8 = 0x06) {
            self.ctrl = ctrl
            self.shift = shift
            self.alt = alt
            self.win = win
            self.code = code
        }

        /// 顺序固定成 Ctrl → Shift → Alt → Win，和原版发包顺序一致。
        public var modifierCodes: [UInt8] {
            var codes: [UInt8] = []
            if ctrl  { codes.append(Self.ctrlCode) }
            if shift { codes.append(Self.shiftCode) }
            if alt   { codes.append(Self.altCode) }
            if win   { codes.append(Self.winCode) }
            return codes
        }

        public var hasModifier: Bool { !modifierCodes.isEmpty }
    }

    public static let modifierPrefixes: Set<UInt8> = [
        Combo.ctrlCode, Combo.shiftCode, Combo.altCode, Combo.winCode,
        Combo.rightCtrlCode, Combo.rightShiftCode, Combo.rightAltCode, Combo.rightWinCode,
    ]

    /// 判断一条键盘配置是不是「修饰前缀 + 单个目标键」的组合键形态
    public static func combo(from binding: Binding) -> Combo? {
        guard binding.type == .keyboard else { return nil }
        let steps = binding.activeSteps
        guard steps.count >= 2, steps.count <= 5,
              steps.allSatisfy({ $0.delayMs == 0 }) else { return nil }

        let prefixes = steps.dropLast().map(\.code)
        let target = steps[steps.count - 1].code
        guard !prefixes.isEmpty,
              prefixes.allSatisfy(modifierPrefixes.contains),
              Set(prefixes).count == prefixes.count,
              !modifierPrefixes.contains(target), target != 0
        else { return nil }

        // 右侧那四个前缀这里不还原成 Combo，交给「按键序列」原样编辑。
        guard prefixes.allSatisfy({
            [Combo.ctrlCode, Combo.shiftCode, Combo.altCode, Combo.winCode].contains($0)
        }) else { return nil }

        return Combo(ctrl: prefixes.contains(Combo.ctrlCode),
                     shift: prefixes.contains(Combo.shiftCode),
                     alt: prefixes.contains(Combo.altCode),
                     win: prefixes.contains(Combo.winCode),
                     code: target)
    }


    // MARK: - Procreate 预设

    /// 原版「Procreate」页的 31 条预设。
    ///
    /// 键码经过验证，键码与标签的对应关系为推断结果，两者需分开看待：
    ///
    /// - 键码：按界面从左到右、从上到下依次触发 31 次，收到 31 条写命令，条数一致。
    /// - 标签：取自原版二进制中的字符串表（`QuickMenu` … `Redo`）。
    /// - 对应关系：基于「字符串表的内存顺序等同于界面排列顺序」与「触发过程无错漏」
    ///   两项假设推得。独立验证仅覆盖首尾两个锚点（⌘] = 放大 1%、⌘Z = 撤销），
    ///   中间条目未单独验证。
    ///
    /// 即：选中任一预设发出的键码必属于原版那 31 个之一，但其显示名称是否为原版
    /// 对该键码的命名，仅首尾两条可以确认。使用时应以键码为准。
    ///
    /// 注：原版发送「5% 加减」两条时 `dataLength` 写 1，三元组第二格留有上一条的残值
    /// （其发送缓冲区不清零）。设备按 dataLength 取值，实际生效的是单个 `[` / `]`。
    /// 本实现发送时清零。
    public struct Preset: Identifiable, Equatable {
        public let name: String
        public let codes: [UInt8]
        public var id: String { name }
        public init(_ name: String, _ codes: [UInt8]) {
            self.name = name
            self.codes = codes
        }
    }

    public static let procreatePresets: [Preset] = [
        Preset("快速菜单",            [0x2C]),                       // Space
        Preset("调试命令",            [0x35]),                       // `
        Preset("画笔工具",            [0x05]),                       // B
        Preset("打开颜色面板",         [0x06]),                       // C
        Preset("橡皮擦工具",           [0x3E]),                       // F5
        Preset("打开图层面板",         [0x0F]),                       // L
        Preset("进入选区模式",         [0x16]),                       // S
        Preset("进入变换模式",         [0x19]),                       // V
        Preset("先前/当前颜色切换",     [0x1B]),                       // X
        Preset("取色（Alt）",         [Combo.altCode]),              // Alt
        Preset("取色 M（iOS 17）",    [0x10]),                       // M
        Preset("清空当前图层",         [Combo.winCode, 0x2A]),        // ⌘Delete
        Preset("全屏切换",            [Combo.winCode, 0x27]),        // ⌘0
        Preset("透视参考线开关",       [Combo.winCode, 0x33]),        // ⌘;
        Preset("画笔缩小 1%",         [Combo.winCode, 0x2F]),        // ⌘[
        Preset("画笔放大 1%",         [Combo.winCode, 0x30]),        // ⌘]
        Preset("画笔缩小 5%",         [0x2F]),                       // [
        Preset("画笔放大 5%",         [0x30]),                       // ]
        Preset("画笔缩小 10%",        [Combo.shiftCode, 0x2F]),      // ⇧[
        Preset("画笔放大 10%",        [Combo.shiftCode, 0x30]),      // ⇧]
        Preset("拷贝全部",            [Combo.winCode, 0x04]),        // ⌘A
        Preset("色彩平衡调整",         [Combo.winCode, 0x05]),        // ⌘B
        Preset("拷贝",               [Combo.winCode, 0x06]),        // ⌘C
        Preset("取消选区",            [Combo.winCode, 0x07]),        // ⌘D
        Preset("复制选区",            [Combo.winCode, 0x0D]),        // ⌘J
        Preset("打开操作菜单",         [Combo.winCode, 0x0E]),        // ⌘K
        Preset("HSB 调整",           [Combo.winCode, 0x18]),        // ⌘U
        Preset("粘贴",               [Combo.winCode, 0x19]),        // ⌘V
        Preset("剪切",               [Combo.winCode, 0x1B]),        // ⌘X
        Preset("撤销",               [Combo.winCode, 0x1D]),        // ⌘Z
        Preset("重做",               [Combo.shiftCode, Combo.winCode, 0x1D]), // ⇧⌘Z
    ]

    public static func binding(index: UInt8, layer: UInt8, preset: Preset) -> Binding {
        var steps = Array(repeating: Step(), count: macroSlots)
        for (i, code) in preset.codes.prefix(macroSlots).enumerated() {
            steps[i] = Step(delayMs: 0, code: code)
        }
        return Binding(index: index, layer: layer, rawType: ActionType.keyboard.rawValue,
                       flag: 0, dataLength: UInt8(preset.codes.count), steps: steps)
    }

    /// 反查：这个配置是不是恰好等于某条预设。
    public static func preset(from binding: Binding) -> Preset? {
        guard binding.type == .keyboard else { return nil }
        let codes = binding.steps.prefix(Int(binding.dataLength)).map(\.code)
        return procreatePresets.first { $0.codes == codes }
    }

    // MARK: - 清除

    /// 两条配置在**功能上**是否一样。
    ///
    /// 不能直接比 64 字节：固件不清零槽位，`dataLength` 之外留着上一次配置的残值；
    /// `flag` 也只有鼠标类会持久化，键盘/多媒体写 0 进去回读拿到的是残值。
    /// 这两处算进来都会把「没改过」误判成「改过」。
    public static func sameFunction(_ a: Binding, _ b: Binding) -> Bool {
        guard a.index == b.index, a.layer == b.layer,
              a.rawType == b.rawType, a.dataLength == b.dataLength else { return false }

        // 鼠标类要单独处理：它的 dataLength 是 4，但滚轮方向存在 steps[4]，
        // 正好落在 prefix(dataLength) 之外。只比前四格的话「滚轮+」和「滚轮-」
        // 会被判成同一个东西，用户改不动滚轮方向。
        if a.type == .mouse {
            guard a.steps.count > 4, b.steps.count > 4 else { return false }
            return a.flag == b.flag
                && a.steps[0].code == b.steps[0].code
                && a.steps[1].code == b.steps[1].code
                && a.steps[4].code == b.steps[4].code
        }

        // 键盘/多媒体：dataLength 之外是固件留下的残值，flag 也不持久化，都不能算。
        let n = Int(a.dataLength)
        return zip(a.steps.prefix(n), b.steps.prefix(n))
            .allSatisfy { $0.delayMs == $1.delayMs && $0.code == $1.code }
    }

    /// 「清除」：原版发的是 type=键盘、dataLength=0、三元组全零。抓包实证。
    public static func cleared(index: UInt8, layer: UInt8) -> Binding {
        Binding(index: index, layer: layer, rawType: ActionType.keyboard.rawValue,
                flag: 0, dataLength: 0,
                steps: Array(repeating: Step(), count: macroSlots))
    }

    public static func binding(index: UInt8, layer: UInt8, combo: Combo) -> Binding {
        let codes = combo.modifierCodes + [combo.code]
        var steps = Array(repeating: Step(), count: macroSlots)
        for (i, code) in codes.enumerated() { steps[i] = Step(delayMs: 0, code: code) }
        return Binding(index: index, layer: layer, rawType: ActionType.keyboard.rawValue,
                       flag: 0, dataLength: UInt8(codes.count), steps: steps)
    }

    // MARK: - 鼠标 / 划屏

    /// 鼠标类（type 03）的一个动作。
    ///
    /// 载荷仍然是三元组布局，只用到其中三个槽，`flag` 当子类用：
    ///  * `flag = 01` —— 鼠标：三元组 1 的 code 是按钮位图，三元组 4 的 code 是滚轮，
    ///    三元组 0 的 code 是可选的修饰前缀（和键盘共用 F1/F2/F3）。
    ///  * `flag = 04` —— 划屏/手势：三元组 0 的 code 是方向编号。
    /// dataLength 一律是 4。
    public struct MouseAction: Identifiable, Hashable {
        public let name: String
        public let flag: UInt8
        public let slot0: UInt8   // 修饰前缀，或 flag=04 时的划屏方向
        public let slot1: UInt8   // 鼠标按钮位图
        public let slot4: UInt8   // 滚轮：01 上，FF 下

        public var id: String { name }

        init(_ name: String, flag: UInt8 = 0x01,
             slot0: UInt8 = 0, slot1: UInt8 = 0, slot4: UInt8 = 0) {
            self.name = name
            self.flag = flag
            self.slot0 = slot0
            self.slot1 = slot1
            self.slot4 = slot4
        }
    }

    /// 原版软件「鼠标/划屏」页的全部 16 个动作。
    ///
    /// 编号来源分三类，**不是全部实证**：
    /// - 抓包直接实证：左键/中键/右键、滚轮±、Ctrl+滚轮、Shift+向上(F2)、Alt+向下(F3)。
    /// - 对称推断：Ctrl+向下 / Shift+向下 / Alt+向上，由同一修饰键的另一半推得。
    /// - 顺序推断：四个划屏方向。日志里只有「向下划屏 = 04」有人工 marker，
    ///   01/02/03 是配合原版 objectName 表 `LeftSwipe/RightSwipe/UpSwipe/DownSwipe`
    ///   的排列反推的，「点赞 = 05」则是排除法剩下的。
    /// 独立复核认为结论都对，但上面后两类**是推断，不是实证**。
    public static let mouseActions: [MouseAction] = [
        MouseAction("鼠标左键", slot1: 0x01),
        MouseAction("鼠标中键", slot1: 0x04),
        MouseAction("鼠标右键", slot1: 0x02),
        MouseAction("鼠标滚轮+", slot4: 0x01),
        MouseAction("鼠标滚轮-", slot4: 0xFF),
        MouseAction("Ctrl + 鼠标向上",  slot0: Combo.ctrlCode,  slot4: 0x01),
        MouseAction("Ctrl + 鼠标向下",  slot0: Combo.ctrlCode,  slot4: 0xFF),
        MouseAction("Shift + 鼠标向上", slot0: Combo.shiftCode, slot4: 0x01),
        MouseAction("Shift + 鼠标向下", slot0: Combo.shiftCode, slot4: 0xFF),
        MouseAction("Alt + 鼠标向上",   slot0: Combo.altCode,   slot4: 0x01),
        MouseAction("Alt + 鼠标向下",   slot0: Combo.altCode,   slot4: 0xFF),
        MouseAction("点赞",     flag: 0x04, slot0: 0x05),
        MouseAction("向左划屏", flag: 0x04, slot0: 0x01),
        MouseAction("向右划屏", flag: 0x04, slot0: 0x02),
        MouseAction("向上划屏", flag: 0x04, slot0: 0x03),
        MouseAction("向下划屏", flag: 0x04, slot0: 0x04),
    ]

    public static func mouseAction(from binding: Binding) -> MouseAction? {
        guard binding.type == .mouse, binding.steps.count > 4 else { return nil }
        return mouseActions.first {
            $0.flag == binding.flag
                && $0.slot0 == binding.steps[0].code
                && $0.slot1 == binding.steps[1].code
                && $0.slot4 == binding.steps[4].code
        }
    }

    public static func binding(index: UInt8, layer: UInt8, mouse action: MouseAction) -> Binding {
        var steps = Array(repeating: Step(), count: macroSlots)
        steps[0] = Step(code: action.slot0)
        steps[1] = Step(code: action.slot1)
        steps[4] = Step(code: action.slot4)
        return Binding(index: index, layer: layer, rawType: ActionType.mouse.rawValue,
                       flag: action.flag, dataLength: 4, steps: steps)
    }

    // MARK: - RGB 灯效

    /// 六种灯效，编号就是写进去的值。
    ///
    /// 名字按**实机观察**来，不按说明书——说明书写的是
    /// 「1 顺时针行走 / 2 逆时针行走 / 3 交替更换 / 4 跳跃 / 5 闪烁」，
    /// 但这台机器上 1 是白光、2 是绿光，行走效果实际落在 3 和 4 上，5 是流光。
    /// 大概是说明书照抄了同系列另一款的固件。
    public static let lightModes: [(mode: UInt8, name: String)] = [
        (0, "关闭灯光"), (1, "白光"), (2, "绿光"),
        (3, "顺时针行走"), (4, "逆时针行走"), (5, "流光"),
    ]

    /// 灯效写入命令，共三包，必须依次发出。
    ///
    /// 布局 `FE B0 <包号 0..2> <模式> <调色板 16×RGB>`；只有第 0 包带模式，
    /// 后两包模式位是 0。调色板每包都原样重发——原版软件就是这么干的，
    /// RGB 页也没有调色板编辑器，照抄即可。
    public static func lightCommands(mode: UInt8,
                                     palette: [(r: UInt8, g: UInt8, b: UInt8)]) -> [[UInt8]] {
        (0..<3).map { packet -> [UInt8] in
            var payload: [UInt8] = [Command.writeRGB.rawValue, 0xB0, UInt8(packet),
                                    packet == 0 ? mode : 0]
            for color in palette.prefix(16) {
                payload.append(contentsOf: [color.r, color.g, color.b])
            }
            return payload
        }
    }

    // MARK: - 命令构造

    /// `FB FB FB 00` —— 握手，设备回 `FB 00 01 0B`
    public static func handshakeCommand() -> [UInt8] {
        [Command.handshake.rawValue, 0xFB, 0xFB, 0x00]
    }

    /// `FA 19 00 <层>` —— 请求整层，设备逐条回 25 条应答
    public static func readLayerCommand(layer: UInt8) -> [UInt8] {
        [Command.read.rawValue, UInt8(entryCount), 0x00, layer]
    }

    /// `FA B0` —— 读 RGB 调色板
    public static func readPaletteCommand() -> [UInt8] {
        [Command.read.rawValue, 0xB0]
    }

    /// `FD FE FF` —— 提交，每次写完配置后发一次
    public static func commitCommand() -> [UInt8] {
        [Command.write.rawValue, 0xFE, 0xFF]
    }

    /// 把一个 Binding 编码成写入命令
    public static func writeCommand(_ binding: Binding) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: HIDTransport.payloadSize)
        payload[0] = Command.write.rawValue
        payload[1] = binding.index
        payload[2] = binding.layer
        payload[3] = binding.rawType
        payload[4] = binding.flag
        payload[5] = binding.dataLength
        payload[6] = 0
        for (i, step) in binding.steps.prefix(macroSlots).enumerated() {
            let base = triplesOffset + i * 3
            payload[base] = step.delayMs
            payload[base + 1] = step.code
            payload[base + 2] = 0
        }
        return payload
    }

    // MARK: - 应答解析

    /// 解析一条 `FA` 读应答。载荷不含 Report ID。
    public static func parseBinding(_ payload: [UInt8]) -> Binding? {
        guard payload.count >= triplesOffset + macroSlots * 3,
              payload[0] == Command.read.rawValue else { return nil }
        var steps: [Step] = []
        steps.reserveCapacity(macroSlots)
        for i in 0..<macroSlots {
            let base = triplesOffset + i * 3
            steps.append(Step(delayMs: payload[base], code: payload[base + 1]))
        }
        // dataLength 来自设备，属于外部输入。界面「按键序列」页拿它当下标上界，
        // 超过槽位数就会越界崩溃，这里夹紧。
        return Binding(index: payload[1], layer: payload[2], rawType: payload[3],
                       flag: payload[4], dataLength: min(payload[5], UInt8(macroSlots)),
                       steps: steps)
    }

    /// `FA B0` 的应答：`FA <当前灯效模式> <RGB × 16>`
    public static func parseLight(_ payload: [UInt8])
        -> (mode: UInt8, palette: [(r: UInt8, g: UInt8, b: UInt8)])? {
        guard payload.count > 2, payload[0] == Command.read.rawValue else { return nil }
        var colors: [(UInt8, UInt8, UInt8)] = []
        var i = 2
        while i + 2 < payload.count, colors.count < 16 {
            let c = (payload[i], payload[i + 1], payload[i + 2])
            // 不能碰到黑色就 break——调色板中间要是有黑色，后面的颜色会被吃掉，
            // 下次换灯效把这份残缺的调色板写回去就真的把它们抹黑了。读满为止。
            colors.append(c)
            i += 3
        }
        return (payload[1], colors)
    }
}

/// 25 条配置里只有 2..6 有意义——它们是旋钮的五种操作方式。
///
/// 对应关系由说明书「旋钮操作：左旋转、右旋转、按压旋钮、长按左旋转、长按右旋转」
/// 与设备出厂值交叉验证得出（02=音量-、04=音量+、03=按压）。
public enum PhysicalKey: UInt8, CaseIterable {
    case rotateLeft      = 2
    case press           = 3
    case rotateRight     = 4
    case holdRotateLeft  = 5
    case holdRotateRight = 6

    /// 按上手顺序排：两个旋转、按压，再是两个长按。
    public static let displayOrder: [PhysicalKey] =
        [.rotateLeft, .rotateRight, .press, .holdRotateLeft, .holdRotateRight]

    public var label: String {
        switch self {
        case .rotateLeft:      return "左旋转"
        case .press:           return "按压旋钮"
        case .rotateRight:     return "右旋转"
        case .holdRotateLeft:  return "长按左旋转"
        case .holdRotateRight: return "长按右旋转"
        }
    }

    public var symbolName: String {
        switch self {
        case .rotateLeft:      return "arrow.counterclockwise"
        case .press:           return "hand.tap"
        case .rotateRight:     return "arrow.clockwise"
        case .holdRotateLeft:  return "arrow.counterclockwise.circle"
        case .holdRotateRight: return "arrow.clockwise.circle"
        }
    }

    public var hint: String {
        switch self {
        case .rotateLeft:      return "逆时针拧一格"
        case .press:           return "按下旋钮"
        case .rotateRight:     return "顺时针拧一格"
        case .holdRotateLeft:  return "按住旋钮再逆时针拧"
        case .holdRotateRight: return "按住旋钮再顺时针拧"
        }
    }
}
