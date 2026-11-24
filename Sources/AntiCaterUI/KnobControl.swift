import SwiftUI
import AntiCaterCore

/// 旋钮舞台：白色底座 + 红色旋钮居中，四个旋转操作以药丸排在底座上下两侧，按压 = 旋钮本体。
///
/// 每次点某个操作，旋钮把这个手势演示一遍，然后回到 12 点：
/// 左/右旋 = 转 ∓15°；按压 = 按下回弹；长按左/右旋 = 先按下、按住再转 ∓30°。
/// 转完停 2 秒再回正——不累加角度，免得指示点停在随机位置，被当成硬件状态。
struct KnobControl: View {
    @Binding var selection: PhysicalKey
    var summary: (PhysicalKey) -> String
    var isDirty: (PhysicalKey) -> Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var angle: Double = 0
    @State private var pressed = false
    /// 每次演示加一。延时回调发现自己不是最新一次就作废，连点时不会被旧的回正打断。
    @State private var demo = 0

    private let baseSize: CGFloat = 308
    private let knobSize: CGFloat = 224

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                pill(.rotateLeft)
                Spacer(minLength: 16)
                pill(.rotateRight)
            }
            ZStack {
                base
                knob
            }
            HStack {
                pill(.holdRotateLeft)
                Spacer(minLength: 16)
                pill(.holdRotateRight)
            }
        }
        .frame(width: 400)
        .opacity(isEnabled ? 1 : 0.38)
    }

    /// 选中并演示。点已选中的那个也会再演示一遍。
    private func select(_ key: PhysicalKey) {
        selection = key
        guard !reduceMotion else { return }
        demo += 1
        let id = demo
        func later(_ s: Double, _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { if demo == id { body() } }
        }
        // 上一次演示可能还停在半路，先瞬间归位
        angle = 0
        pressed = false

        switch key {
        case .press:
            // 和长按前半段一模一样的「按下」，停够时间再弹回。停 0.13s / 0.2s 都一闪而过，看不出按了。
            withAnimation(Theme.Motion.pressDown) { pressed = true }
            later(0.45) { withAnimation(Theme.Motion.press) { pressed = false } }
        case .rotateLeft, .rotateRight:
            withAnimation(Theme.Motion.rotate) { angle = key == .rotateLeft ? -15 : 15 }
            later(2) { withAnimation(Theme.Motion.settle) { angle = 0 } }
        case .holdRotateLeft, .holdRotateRight:
            withAnimation(Theme.Motion.pressDown) { pressed = true }
            later(0.22) {
                withAnimation(Theme.Motion.rotate) { angle = key == .holdRotateLeft ? -30 : 30 }
            }
            later(2) { withAnimation(Theme.Motion.settle) { angle = 0; pressed = false } }
        }
    }

    // MARK: - 底座与旋钮

    private var base: some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(LinearGradient(colors: [Theme.baseTop, Theme.baseBottom],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            // 浅色外观下底座和舞台都是近白，外沿描一圈分隔线才分得开
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1))
            .frame(width: baseSize, height: baseSize)
            .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
    }

    private var knob: some View {
        let active = selection == .press
        return Button { select(.press) } label: {
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        stops: [.init(color: Theme.knobHighlight, location: 0),
                                .init(color: Theme.knob, location: 0.42),
                                .init(color: Theme.knobEdge, location: 1)],
                        center: UnitPoint(x: 0.34, y: 0.28),
                        startRadius: 0, endRadius: knobSize * 0.75))
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                        .blur(radius: 1).offset(y: 1).mask(Circle()))
                    // 按下时投影收短，看起来是陷进底座里
                    .shadow(color: .black.opacity(0.45), radius: pressed ? 8 : 17, y: pressed ? 6 : 16)
                    .overlay(alignment: .top) {
                        // 顶部定位凹点，随旋钮转动
                        Circle()
                            .fill(Color(red: 0.47, green: 0.09, blue: 0).opacity(0.55))
                            .frame(width: 13, height: 13)
                            .padding(.top, 15)
                    }
                    .rotationEffect(.degrees(angle))

                // 中央标签不随旋钮转：深褐字印在红面上（5.61 : 1），白字只有 3.10，不用。
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        Text("按压").font(Theme.Font.headline)
                        if isDirty(.press) { dirtyDot }
                    }
                    Text(summary(.press))
                        .font(Theme.Font.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 130)
                }
                .foregroundStyle(Theme.knobLabel)
            }
            .frame(width: knobSize, height: knobSize)
            // 0.965 只缩 8pt，加上选中蓝圈，实测看不出按了；0.92 缩 18pt
            .scaleEffect(pressed ? 0.92 : 1)
            .padding(5)
            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2.5).opacity(active ? 1 : 0))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("按压旋钮：\(summary(.press))")
        .accessibilityLabel(label(.press))
    }

    // MARK: - 药丸

    private func pill(_ key: PhysicalKey) -> some View {
        let active = selection == key
        return Button { select(key) } label: {
            HStack(spacing: 7) {
                if isDirty(key) { dirtyDot }
                Text(shortName(key)).font(active ? Theme.Font.captionBold : Theme.Font.caption)
                Text(summary(key))
                    .font(Theme.Font.caption)
                    .foregroundStyle(active ? Color.white : Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? Color.white : Theme.text1)
            .padding(.horizontal, 14)
            .frame(width: 184, height: 38)
            .background(Capsule().fill(active ? Theme.primary : Theme.card))
            .overlay(Capsule().strokeBorder(active ? .clear : Theme.separator))
            .shadow(color: .black.opacity(0.2), radius: 7, y: 4)
            .contentShape(Capsule())
            .animation(Theme.Motion.select, value: active)
        }
        .buttonStyle(.plain)
        .help("\(key.label)：\(summary(key))")
        .accessibilityLabel(label(key))
    }

    private func shortName(_ key: PhysicalKey) -> String {
        switch key {
        case .holdRotateLeft:  return "长按左旋"
        case .holdRotateRight: return "长按右旋"
        default:               return key.label
        }
    }

    private func label(_ key: PhysicalKey) -> String {
        "\(key.label)，当前功能 \(summary(key))" + (isDirty(key) ? "，有未写入修改" : "")
    }

    private var dirtyDot: some View {
        Circle().fill(Theme.warning).frame(width: 7, height: 7)
    }
}
