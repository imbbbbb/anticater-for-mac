import SwiftUI
import AppKit

/// 设计令牌。取值来自《ANTICATER 旋钮配置 App 设计规范》，深浅两套都按 WCAG 4.5 : 1 验过。
///
/// 颜色在代码里定义而不是放 Asset Catalog：项目用 `swift build` + `make-app.sh` 打包，
/// 这条链路不编译 `.xcassets`。
enum Theme {
    private static func dynamic(dark: UInt32, light: UInt32, alphaDark: CGFloat = 1,
                                alphaLight: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: isDark ? alphaDark : alphaLight)
        })
    }

    // 背景与表面
    static let window   = dynamic(dark: 0x17181A, light: 0xF5F5F7)
    static let stage    = dynamic(dark: 0x1F2023, light: 0xECECF0)
    static let card     = dynamic(dark: 0x26272B, light: 0xFFFFFF)
    static let elevated = dynamic(dark: 0x2E2F34, light: 0xFFFFFF)
    /// 分类切换条：轨道 + 选中块。选中块要明显亮于轨道，深浅两种外观下都一眼看得出选了哪个。
    static let segmentTrack = dynamic(dark: 0x26272B, light: 0xE3E3E8)
    static let segmentThumb = dynamic(dark: 0x48494F, light: 0xFFFFFF)
    static let hover    = dynamic(dark: 0xFFFFFF, light: 0x000000, alphaDark: 0.06, alphaLight: 0.045)
    /// 容器描边、行分隔线
    static let separator = dynamic(dark: 0xFFFFFF, light: 0x000000, alphaDark: 0.08, alphaLight: 0.08)

    // 文字
    static let text1 = dynamic(dark: 0xFFFFFF, light: 0x1D1D1F)
    static let text2 = dynamic(dark: 0xC7C7CC, light: 0x515154)
    static let text3 = dynamic(dark: 0x9A9AA0, light: 0x636368)

    // 交互（蓝只给交互，红只给旋钮）
    static let accent  = dynamic(dark: 0x0A84FF, light: 0x007AFF)
    static let primary = dynamic(dark: 0x0066D6, light: 0x0071E3)

    // 状态
    static let success = dynamic(dark: 0x30D158, light: 0x1D7A33)
    static let warning = dynamic(dark: 0xFF9F0A, light: 0xB25000)
    static let danger  = dynamic(dark: 0xFF453A, light: 0xD70015)

    // 旋钮实物，两种外观相同
    static let knobHighlight = Color(red: 0xFF / 255, green: 0x7A / 255, blue: 0x5C / 255)
    static let knob          = Color(red: 0xFF / 255, green: 0x5A / 255, blue: 0x36 / 255)
    static let knobEdge      = Color(red: 0xD9 / 255, green: 0x34 / 255, blue: 0x12 / 255)
    static let knobLabel     = Color(red: 0x2B / 255, green: 0x14 / 255, blue: 0x08 / 255)
    static let baseTop       = Color(red: 0xF4 / 255, green: 0xF2 / 255, blue: 0xED / 255)
    static let baseBottom    = Color(red: 0xE3 / 255, green: 0xE0 / 255, blue: 0xD9 / 255)

    /// 字阶。macOS 的 `.body` 是 13pt，和 iOS 不同，所以一律写明字号。全 App 不低于 13pt。
    /// 字重只用 regular / semibold 两档。
    enum Font {
        static let title    = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let headline = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body     = SwiftUI.Font.system(size: 15, weight: .regular)
        static let bodyBold = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let callout  = SwiftUI.Font.system(size: 14, weight: .regular)
        static let caption  = SwiftUI.Font.system(size: 13, weight: .regular)
        static let captionBold = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let mono     = SwiftUI.Font.system(size: 13, weight: .regular).monospaced()
    }

    enum Radius {
        static let container: CGFloat = 12
    }

    enum Motion {
        static let select = Animation.easeInOut(duration: 0.15)
        static let rotate = Animation.spring(response: 0.34, dampingFraction: 0.72)
        static let pressDown = Animation.easeOut(duration: 0.1)
        /// 松开回弹
        static let press  = Animation.spring(response: 0.26, dampingFraction: 0.6)
        /// 演示完回到 12 点
        static let settle = Animation.easeInOut(duration: 0.4)
    }
}

/// 检查器里的分组容器：标题 + 圆角卡片，卡片内行与行之间画分隔线。
struct CardSection<Content: View>: View {
    var title: String?
    var trailing: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { Text(title) }
                    Spacer()
                    if let trailing { Text(trailing).font(Theme.Font.mono) }
                }
                .font(Theme.Font.captionBold)
                .foregroundStyle(Theme.text3)
                .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(Separated()) { content }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.container))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.container)
                .strokeBorder(Theme.separator))
            if let footer {
                Text(footer)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private struct Separated: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            ForEach(children) { child in
                child
                if child.id != children.last?.id {
                    Theme.separator.frame(height: 1).padding(.leading, 16)
                }
            }
        }
    }
}

/// 卡片里的一行：左右内边距 16，最低 47 高。
struct RowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Font.body)
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 47)
    }
}

extension View {
    func row() -> some View { modifier(RowStyle()) }
}
