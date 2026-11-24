import SwiftUI
import AntiCaterCore

/// 编辑面板顶部的分类。只影响显示哪一组控件，**切换它本身不算改动**。
enum EditorMode: String, CaseIterable, Hashable {
    case key, combo, media, mouse, procreate

    var label: String {
        switch self {
        case .key:   return "单个按键"
        case .combo: return "组合键"
        case .media: return "多媒体"
        case .mouse: return "鼠标/划屏"
        case .procreate: return "Procreate"
        }
    }

    /// 从设备读回来的配置反推该显示哪一类
    static func inferred(from binding: Proto.Binding) -> EditorMode {
        switch binding.type {
        case .media: return .media
        case .mouse: return .mouse
        default:     return Proto.combo(from: binding) != nil ? .combo : .key
        }
    }
}

/// 右侧检查器：改的是 draft，按「写入旋钮」才真正下发。
/// 标题、状态行、分类切换固定在顶部，下面的列表在框内滚动，窗口不随选项多少变形。
struct EditorView: View {
    @ObservedObject var model: DeviceModel

    /// 用户手动切过的分类。只对当前选中的那个操作有效，切走自动失效——
    /// 这样「点开别的类别看看」不会污染 draft，也就不会误报改动。
    @State private var browsing: (id: String, mode: EditorMode)?

    private var slotID: String { "\(model.layer)-\(model.selected.rawValue)" }

    private func mode(for binding: Proto.Binding) -> EditorMode {
        if let browsing, browsing.id == slotID { return browsing.mode }
        return .inferred(from: binding)
    }

    var body: some View {
        if let binding = model.current {
            let mode = mode(for: binding)

            VStack(alignment: .leading, spacing: 0) {
                header(binding, mode: mode)
                    .padding(.horizontal, 28)
                    .padding(.top, 24)

                modePicker(mode)
                    .padding(.horizontal, 28)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch mode {
                        case .media: mediaSection(binding)
                        case .combo: comboSection(binding)
                        case .key:   macroSection(binding)
                        case .mouse: mouseSection(binding)
                        case .procreate: procreateSection(binding)
                        }
                        clearButton(binding)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                    .id(mode)
                    .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.18), value: mode)
            }
        } else {
            placeholder
        }
    }

    /// 空状态。**不要在这里教用户点「连接旋钮」**——插线会自动连上
    /// （`DeviceModel.handleLinkChange`），那个按钮只是原版软件占用等
    /// 收不到插拔事件时的兜底。把兜底写成正常路径，用户会以为插了线还得手动操作。
    private var placeholder: some View {
        VStack(spacing: 14) {
            if model.connection == .connecting {
                ProgressView()
                Text("正在读取旋钮配置…").font(Theme.Font.headline)
            } else {
                Image(systemName: model.links.bluetooth ? "dot.radiowaves.left.and.right"
                                                        : "cable.connector")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(Theme.text3)

                if model.links.bluetooth {
                    // 蓝牙亮着的时候说「未连接旋钮」会和徽标打架。
                    // 这里的实情是：连着，但这条链路上没有配置通道。
                    Text("蓝牙已连接，但读不到配置").font(Theme.Font.title)
                    Text("蓝牙链路上没有配置通道，读取和修改都只能走 USB 数据线。\n"
                       + "插上线会自动连接。")
                } else {
                    Text("未连接旋钮").font(Theme.Font.title)
                    Text("用 USB 数据线把旋钮接到电脑，会自动连接。")
                }
            }
        }
        .font(Theme.Font.callout)
        .multilineTextAlignment(.center)
        .foregroundStyle(Theme.text2)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 标题区

    /// 当前这个键相对旋钮上的值改没改过。
    private var dirty: Bool { model.isDirty(model.selected, in: model.layer) }

    /// 状态行的文案。**必须单行**，否则切换类别时下面的内容会上下跳。
    private func statusText(_ mode: EditorMode, _ binding: Proto.Binding) -> String? {
        // 改过就说改过。之前这里无论如何都写「尚未改动」——在 Procreate 页选完一条
        // 预设后仍然显示「尚未改动」，跟旋钮图上的橙点直接打架。
        if dirty { return "已改动，点右上角「写入旋钮」才会生效" }
        if mode == .inferred(from: binding) { return nil }
        return "正在用「\(mode.label)」的方式编辑，尚未改动"
    }

    private func header(_ binding: Proto.Binding, mode: EditorMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.selected.label).font(Theme.Font.title)
                Text(model.selected.hint)
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.text3)
            }
            .foregroundStyle(Theme.text1)

            // 标题得跟着状态走：改过之后这里显示的已经是编辑区的值，
            // 再叫「旋钮上的当前功能」就是在骗人。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(dirty ? "改完的功能（待写入）" : "旋钮上的当前功能")
                    .foregroundStyle(Theme.text2)
                Text(Summary.full(binding))
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.text1)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .help(Summary.full(binding))
            }
            .font(Theme.Font.callout)

            // 常驻一行，没话说时留空但占位。
            Label(statusText(mode, binding) ?? " ", systemImage: dirty ? "pencil" : "eye")
                .font(Theme.Font.caption)
                .lineLimit(1)
                .foregroundStyle(dirty ? Theme.warning : Theme.text3)
                .opacity(statusText(mode, binding) == nil ? 0 : 1)
                .accessibilityHidden(statusText(mode, binding) == nil)
        }
    }

    /// 分类切换。自己画而不用原生分段控件：原生的五段等宽、宽度取整，
    /// 右边缘随窗口宽度和下面的卡片差 0–4pt，对不齐。
    private func modePicker(_ mode: EditorMode) -> some View {
        HStack(spacing: 2) {
            ForEach(EditorMode.allCases, id: \.self) { m in
                let on = m == mode
                Button {
                    browsing = (slotID, m)
                } label: {
                    Text(m.label)
                        .font(on ? Theme.Font.captionBold : Theme.Font.caption)
                        .foregroundStyle(on ? Theme.text1 : Theme.text2)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Theme.segmentThumb)
                                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.segmentTrack, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.separator))
        .animation(Theme.Motion.select, value: mode)
    }

    // MARK: - 统一的可选行

    /// 多媒体、鼠标/划屏、Procreate 共用「点一下就选中，右侧打勾」的行。
    /// 选中靠字重 + 勾选两项表达，不只靠颜色。
    private func choiceRow(_ title: String, detail: String? = nil,
                           selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(selected ? Theme.Font.bodyBold : Theme.Font.body)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.text3)
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                    .opacity(selected ? 1 : 0)
            }
            .row()
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - 多媒体

    private func mediaSection(_ binding: Proto.Binding) -> some View {
        let current = binding.type == .media ? binding.steps.first?.code : nil
        return CardSection(title: "媒体动作") {
            ForEach(KeyNames.mediaChoices, id: \.code) { choice in
                choiceRow(choice.name, selected: current == choice.code) {
                    model.update(Proto.Binding(index: binding.index, layer: binding.layer,
                                               type: .media, code: choice.code))
                    browsing = nil
                }
            }
        }
    }

    // MARK: - 组合键

    @ViewBuilder
    private func comboSection(_ binding: Proto.Binding) -> some View {
        let existing = Proto.combo(from: binding)
        let combo = existing ?? Proto.Combo()

        CardSection(title: "修饰键") {
            toggleRow("Control", comboField(binding, combo, \.ctrl))
            toggleRow("Shift",   comboField(binding, combo, \.shift))
            toggleRow("Option",  comboField(binding, combo, \.alt))
            toggleRow("Command（Windows 上是 Win）", comboField(binding, combo, \.win))
        }

        CardSection(footer: existing == nil ? "至少勾一个修饰键，改动才会生效。"
                                            : "旋钮会依次发出 \(comboPreview(combo))。") {
            HStack {
                Text("配合的按键")
                Spacer()
                keyPicker(comboField(binding, combo, \.code),
                          groups: KeyNames.keyboardGroups.filter { $0.title != "组合前缀" })
                    .frame(width: 180)
            }
            .row()
        }
    }

    private func toggleRow(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .row()
    }

    private func comboPreview(_ combo: Proto.Combo) -> String {
        (combo.modifierCodes + [combo.code])
            .map { KeyNames.compactName(for: $0, type: .keyboard) }
            .joined(separator: " + ")
    }

    /// 组合键的每个字段：改了就写进 draft，但只有真的构成组合键（至少一个修饰键）才写
    private func comboField<V>(_ binding: Proto.Binding,
                               _ combo: Proto.Combo,
                               _ path: WritableKeyPath<Proto.Combo, V>) -> Binding<V> {
        SwiftUI.Binding(
            get: { combo[keyPath: path] },
            set: { newValue in
                var next = combo
                next[keyPath: path] = newValue
                guard next.hasModifier else { return }
                model.update(Proto.binding(index: binding.index, layer: binding.layer, combo: next,
                                           type: model.chordType))
                browsing = nil
            })
    }

    private func keyPicker(_ selection: Binding<UInt8>, groups: [KeyNames.Group]) -> some View {
        Picker("", selection: selection) {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        Text(item.name).tag(item.code)
                    }
                }
            }
        }
        .labelsHidden()
    }

    // MARK: - 单个按键 / 序列

    @ViewBuilder
    private func macroSection(_ binding: Proto.Binding) -> some View {
        let isKeyboard = binding.type?.isKeySequence == true
        let count = isKeyboard ? Int(binding.dataLength) : 0

        CardSection(title: "按键序列", trailing: "\(count) / \(Proto.macroSlots)",
                    footer: "按上到下依次发出，延时是发出该键之前先等待的毫秒数。") {
            if count == 0 {
                Text(isKeyboard ? "还没有按键，点下面的「添加按键」开始。"
                                : "这个操作目前不是键盘功能。点「添加按键」会把它改成键盘。")
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .row()
            } else {
                ForEach(0..<count, id: \.self) { i in
                    stepRow(binding, index: i)
                }
            }

            Button {
                addStep(binding)
            } label: {
                Label("添加按键", systemImage: "plus")
                    .font(Theme.Font.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .row()
                    .foregroundStyle(count >= Proto.macroSlots ? Theme.text3 : Theme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverRowStyle())
            .disabled(count >= Proto.macroSlots)
        }
    }

    private func stepRow(_ binding: Proto.Binding, index i: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(i + 1)")
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.text3)
                .frame(width: 20, alignment: .trailing)

            keyPicker(codeBinding(binding, index: i), groups: KeyNames.keyboardGroups)
                .frame(maxWidth: 180)

            Spacer(minLength: 4)

            TextField("", value: delayBinding(binding, index: i), format: .number)
                .labelsHidden()
                .font(Theme.Font.mono)
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
            Text("ms").font(Theme.Font.caption).foregroundStyle(Theme.text3)
            Stepper("", value: delayBinding(binding, index: i), in: 0...255)
                .labelsHidden()

            Button {
                removeStep(binding, at: i)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.text3)
            }
            .buttonStyle(.borderless)
            .help("删掉这一步")
        }
        .row()
    }

    private func codeBinding(_ binding: Proto.Binding, index: Int) -> Binding<UInt8> {
        SwiftUI.Binding(
            get: { binding.steps[index].code },
            set: { code in
                var next = binding
                next.steps[index].code = code
                model.update(next)
                browsing = nil
            })
    }

    private func delayBinding(_ binding: Proto.Binding, index: Int) -> Binding<Int> {
        SwiftUI.Binding(
            get: { Int(binding.steps[index].delayMs) },
            set: { value in
                var next = binding
                next.steps[index].delayMs = UInt8(clamping: value)
                model.update(next)
                browsing = nil
            })
    }

    private func addStep(_ binding: Proto.Binding) {
        // 从别的类型切过来时，先清成一个干净的键盘配置
        let isKeyboard = binding.type?.isKeySequence == true
        var next = isKeyboard
            ? binding
            : Proto.Binding(index: binding.index, layer: binding.layer,
                            type: .keyboard, code: 0x04)
        if !isKeyboard {
            model.update(next)
            browsing = nil
            return
        }
        let i = Int(next.dataLength)
        guard i < Proto.macroSlots else { return }
        next.steps[i] = Proto.Step(delayMs: 0, code: 0x04)
        next.dataLength = UInt8(i + 1)
        model.update(next)
        browsing = nil
    }

    private func removeStep(_ binding: Proto.Binding, at index: Int) {
        var next = binding
        let count = Int(next.dataLength)
        guard index < count else { return }
        for i in index..<(count - 1) { next.steps[i] = next.steps[i + 1] }
        next.steps[count - 1] = Proto.Step()
        next.dataLength = UInt8(count - 1)
        model.update(next)
        browsing = nil
    }

    // MARK: - Procreate 预设

    private func procreateSection(_ binding: Proto.Binding) -> some View {
        let current = Proto.preset(from: binding)

        // 键码经过验证，名称是推断的，所以快捷键标注常驻显示，方便以键码为准。
        return CardSection(title: "Procreate 快捷键",
                           footer: "名称对照为推断结果，以右侧快捷键为准。") {
            ForEach(Proto.procreatePresets) { preset in
                choiceRow(preset.name, detail: presetShortcut(preset),
                          selected: current == preset) {
                    model.update(Proto.binding(index: binding.index,
                                               layer: binding.layer, preset: preset,
                                               type: model.chordType))
                    // 这里**不能**清 browsing。预设写进去就是一段普通键盘序列，
                    // 推断出来是「单个按键」，一清就会把页面弹走。留在原地。
                    browsing = (slotID, .procreate)
                }
            }
        }
    }

    private func presetShortcut(_ preset: Proto.Preset) -> String {
        preset.codes.map { KeyNames.compactName(for: $0, type: .keyboard) }
            .joined(separator: "+")
    }

    // MARK: - 清空

    private func clearButton(_ binding: Proto.Binding) -> some View {
        Button {
            model.update(Proto.cleared(index: binding.index, layer: binding.layer))
            browsing = nil
        } label: {
            Label("清空这个操作", systemImage: "eraser")
        }
        .controlSize(.large)
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(binding.type?.isKeySequence == true && binding.dataLength == 0)
        .help("只改编辑区，写入前可以撤回（⌘⌫）")
    }

    // MARK: - 鼠标 / 划屏

    @ViewBuilder
    private func mouseSection(_ binding: Proto.Binding) -> some View {
        let current = Proto.mouseAction(from: binding)

        CardSection(title: "鼠标按键与滚轮") {
            mouseRows(binding, current: current, flag: 0x01)
        }

        let gestures = model.mouseActions.filter { $0.flag == 0x04 }
        let unknown = binding.type == .mouse && current == nil
        if !gestures.isEmpty || unknown {
            CardSection(title: "划屏与手势",
                        footer: unknown
                            ? "旋钮上现在存的是一个没见过的鼠标动作，原始数据 "
                              + binding.steps.prefix(5)
                                  .map { String(format: "%02X", $0.code) }.joined(separator: " ")
                              + "。选一项会把它覆盖掉。"
                            : nil) {
                mouseRows(binding, current: current, flag: 0x04)
            }
        }
    }

    private func mouseRows(_ binding: Proto.Binding,
                           current: Proto.MouseAction?,
                           flag: UInt8) -> some View {
        ForEach(model.mouseActions.filter { $0.flag == flag }) { action in
            choiceRow(action.name, selected: current == action) {
                model.update(Proto.binding(index: binding.index, layer: binding.layer,
                                           mouse: action))
                browsing = nil
            }
        }
    }
}

/// 列表行的悬停与按下反馈：整行浅填充，120ms 淡入。
private struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(hovering || configuration.isPressed ? Theme.hover : .clear)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}
