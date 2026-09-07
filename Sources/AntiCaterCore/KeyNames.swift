import Foundation

/// 键值 ↔ 名称。键盘用标准 HID Usage Page 0x07，多媒体用 Consumer Page 0x0C，
/// 0xF1 起是厂商自定义的修饰键前缀码，抓包确认 F1=Ctrl、F2=Shift、F3=Alt、F4=Win(⌘)；
/// 右侧四个按原版前缀清单的顺序排在 F5…F8（清单末位 F8 已抓到）。
public enum KeyNames {

    public static func name(for code: UInt8, type: Proto.ActionType?) -> String {
        guard code != 0 else { return "—" }
        switch type {
        case .keyboard: return keyboardName(code)
        case .media:    return mediaName(code)
        case .mouse:    return String(format: "鼠标 0x%02X", code)
        case nil:       return String(format: "0x%02X", code)
        }
    }

    // MARK: - 键盘 (HID Usage Page 0x07)

    public static func keyboardName(_ code: UInt8) -> String {
        if let named = keyboardTable[code] { return named }
        switch code {
        case 0x04...0x1D:  // a-z
            return String(UnicodeScalar(UInt8(0x41 + code - 0x04)))
        case 0x1E...0x26:  // 1-9
            return String(UnicodeScalar(UInt8(0x31 + code - 0x1E)))
        case 0x3A...0x45:  // F1-F12
            return "F\(code - 0x3A + 1)"
        case 0x59...0x61:  // 小键盘 1-9
            return "小键盘 \(code - 0x59 + 1)"
        default:
            return String(format: "0x%02X", code)
        }
    }

    private static let keyboardTable: [UInt8: String] = [
        0x27: "0", 0x28: "Enter", 0x29: "Esc", 0x2A: "Backspace", 0x2B: "Tab",
        0x2C: "Space", 0x2D: "-", 0x2E: "=", 0x2F: "[", 0x30: "]", 0x31: "\\",
        0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/",
        0x39: "Caps Lock",
        0x46: "PrtSc", 0x47: "Scroll Lock", 0x48: "Pause",
        0x49: "Insert", 0x4A: "Home", 0x4B: "Page Up", 0x4C: "Delete",
        0x4D: "End", 0x4E: "Page Down",
        0x4F: "→", 0x50: "←", 0x51: "↓", 0x52: "↑",
        0x53: "Num Lock", 0x54: "小键盘 /", 0x55: "小键盘 *",
        0x56: "小键盘 -", 0x57: "小键盘 +", 0x58: "小键盘 Enter",
        0x62: "小键盘 0", 0x63: "小键盘 .",
        0x64: "><", 0x65: "菜单键 ▤",
        0xE0: "Left Ctrl", 0xE1: "Left Shift", 0xE2: "Left Alt", 0xE3: "Left Cmd",
        0xE4: "Right Ctrl", 0xE5: "Right Shift", 0xE6: "Right Alt", 0xE7: "Right Cmd",
        // 厂商自定义的组合键前缀码
        0xF1: "Ctrl+", 0xF2: "Shift+", 0xF3: "Alt+", 0xF4: "Win/⌘+",
        0xF5: "右 Ctrl+", 0xF6: "右 Shift+", 0xF7: "右 Alt+", 0xF8: "右 Win/⌘+",
    ]

    /// 窄处显示用的短名：小键盘只写字符本身（1 而不是「小键盘 1」），修饰键只留 Ctrl / Shift 之类。
    public static func compactName(for code: UInt8, type: Proto.ActionType?) -> String {
        guard type == .keyboard else { return name(for: code, type: type) }
        switch code {
        case 0x59...0x61: return "\(code - 0x59 + 1)"
        case 0x62:        return "0"
        case 0x63:        return "."
        case 0x54:        return "/"
        case 0x55:        return "*"
        case 0x56:        return "-"
        case 0x57:        return "+"
        case 0x58:        return "⏎"
        case 0x28:        return "⏎"
        case 0x2A:        return "⌫"
        case 0x2B:        return "⇥"
        case 0x2C:        return "空格"
        case 0xE0, 0xE4:  return "Ctrl"
        case 0xE1, 0xE5:  return "Shift"
        case 0xE2, 0xE6:  return "Alt"
        case 0xE3, 0xE7:  return "Cmd"
        case 0xF1:        return "Ctrl"
        case 0xF2:        return "Shift"
        case 0xF3:        return "Alt"
        case 0xF4:        return "⌘"
        case 0xF5:        return "右Ctrl"
        case 0xF6:        return "右Shift"
        case 0xF7:        return "右Alt"
        case 0xF8:        return "右⌘"
        default:          return keyboardName(code)
        }
    }

    // MARK: - 多媒体 (Consumer Page 0x0C)

    public static func mediaName(_ code: UInt8) -> String {
        mediaTable[code] ?? String(format: "多媒体 0x%02X", code)
    }

    private static let mediaTable: [UInt8: String] = [
        0xB5: "下一曲", 0xB6: "上一曲", 0xB7: "停止", 0xCD: "播放/暂停",
        0xE2: "静音", 0xE9: "音量+", 0xEA: "音量-",
    ]

    /// 供界面选择用的常用动作清单
    public static let mediaChoices: [(code: UInt8, name: String)] = [
        (0xCD, "播放/暂停"), (0xB5, "下一曲"), (0xB6, "上一曲"),
        (0xE9, "音量+"), (0xEA, "音量-"), (0xE2, "静音"), (0xB7, "停止"),
    ]

    // MARK: - 界面用的键盘清单

    public struct Choice: Identifiable, Hashable {
        public let code: UInt8
        public let name: String
        public var id: UInt8 { code }
    }

    public struct Group: Identifiable, Hashable {
        public let title: String
        public let items: [Choice]
        public var id: String { title }
    }

    private static func range(_ codes: ClosedRange<UInt8>) -> [Choice] {
        codes.map { Choice(code: $0, name: keyboardName($0)) }
    }

    private static func list(_ codes: [UInt8]) -> [Choice] {
        codes.map { Choice(code: $0, name: keyboardName($0)) }
    }

    /// 按分组排好的可选键盘码，界面下拉直接用
    public static let keyboardGroups: [Group] = [
        Group(title: "字母", items: range(0x04...0x1D)),
        Group(title: "数字", items: list(Array(0x1E...0x26) + [0x27])),
        Group(title: "功能键", items: range(0x3A...0x45)),
        Group(title: "控制", items: list([0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x39,
                                          0x46, 0x47, 0x48, 0x65])),
        Group(title: "符号", items: list([0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x64])),
        Group(title: "编辑与方向", items: list([0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52])),
        Group(title: "小键盘", items: list(Array(0x53...0x58) + Array(0x59...0x63))),
        Group(title: "修饰键", items: list([0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7])),
        Group(title: "组合前缀", items: list([0xF1, 0xF2, 0xF3, 0xF4,
                                            0xF5, 0xF6, 0xF7, 0xF8])),
    ]

    public static let allKeyboardChoices: [Choice] = keyboardGroups.flatMap(\.items)
}
