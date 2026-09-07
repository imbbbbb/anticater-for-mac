import SwiftUI
import AntiCaterCore

/// 旋钮实物示意图，五个操作区都可以直接点。
///
/// 布局照着实物来：方形底座 + 居中的滚花旋钮，四角是四种旋转操作。
/// 中心圆 = 按压，上排两个 = 单纯左右旋，下排两个 = 长按着旋。
struct KnobControl: View {
    @Binding var selection: PhysicalKey
    var summary: (PhysicalKey) -> String
    var isDirty: (PhysicalKey) -> Bool

    private let baseSize: CGFloat = 196
    private let knobSize: CGFloat = 104
    private let cornerSize: CGFloat = 44
    private let cornerOffset: CGFloat = 66

    var body: some View {
        ZStack {
            baseplate
            knurledKnob
            corner(.rotateLeft,      x: -cornerOffset, y: -cornerOffset)
            corner(.rotateRight,     x:  cornerOffset, y: -cornerOffset)
            corner(.holdRotateLeft,  x: -cornerOffset, y:  cornerOffset)
            corner(.holdRotateRight, x:  cornerOffset, y:  cornerOffset)
        }
        .frame(width: baseSize, height: baseSize)
        .animation(.snappy(duration: 0.18), value: selection)
    }

    // MARK: - 底座

    private var baseplate: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.72)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    // MARK: - 中心旋钮（按压）

    private var knurledKnob: some View {
        let active = selection == .press

        return Button {
            selection = .press
        } label: {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.38), Color(white: 0.22)],
                                         startPoint: .top, endPoint: .bottom))

                // 侧面滚花
                ForEach(0..<56, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(0.13))
                        .frame(width: 1.3, height: 8)
                        .offset(y: -(knobSize / 2 - 6))
                        .rotationEffect(.degrees(Double(i) / 56 * 360))
                }

                // 顶面
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.46), Color(white: 0.30)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: knobSize - 26, height: knobSize - 26)

                // 顶面上的定位点，和实物一致
                Circle()
                    .fill(.white.opacity(0.7))
                    .frame(width: 5, height: 5)
                    .offset(y: -(knobSize / 2 - 24))

                Text(summary(.press))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.65)
                    .frame(width: knobSize - 40)
            }
            .frame(width: knobSize, height: knobSize)
            .overlay {
                Circle().strokeBorder(Color.accentColor, lineWidth: 3).opacity(active ? 1 : 0)
            }
            .overlay(alignment: .topTrailing) { dirtyDot(.press).offset(x: -6, y: 6) }
            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .help("\(PhysicalKey.press.label)：\(summary(.press))")
    }

    // MARK: - 四角旋转操作

    private func corner(_ key: PhysicalKey, x: CGFloat, y: CGFloat) -> some View {
        let active = selection == key

        return Button {
            selection = key
        } label: {
            ZStack {
                Circle()
                    .fill(active ? AnyShapeStyle(Color.accentColor)
                                 : AnyShapeStyle(Material.thick))
                Image(systemName: key.symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(active ? .white : .primary)
            }
            .frame(width: cornerSize, height: cornerSize)
            .overlay(alignment: .topTrailing) { dirtyDot(key).offset(x: 1, y: -1) }
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .offset(x: x, y: y)
        .help("\(key.label)：\(summary(key))")
    }

    @ViewBuilder
    private func dirtyDot(_ key: PhysicalKey) -> some View {
        if isDirty(key) {
            Circle()
                .fill(.orange)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
        }
    }
}
