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

/// 右侧详情：改的是 draft，按「写入旋钮」才真正下发。
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

            Form {
                overview(binding, mode: mode)

                Section {
                    Picker("类型", selection: Binding(
                        get: { mode },
                        set: { browsing = (slotID, $0) })
                    ) {
                        ForEach(EditorMode.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                switch mode {
                case .media: mediaSection(binding)
                case .combo: comboSection(binding)
                case .key:   macroSection(binding)
                case .mouse: mouseSection(binding)
                case .procreate: procreateSection(binding)
                }

                clearSection(binding)
            }
            .formStyle(.grouped)
            .navigationTitle(model.selected.label)
            .navigationSubtitle(model.selected.hint)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "dial.medium")
                .font(.system(size: 42, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("未连接旋钮").font(.title3)
            Text("用 USB 线把旋钮接到电脑，再点右上角的连接按钮。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    // MARK: - 概览

    /// 当前这个键相对旋钮上的值改没改过。
    private var dirty: Bool { model.isDirty(model.selected, in: model.layer) }

    /// 提示行的文案。三种状态，且**必须都是单行**，否则占位等高会失效。
    private func bannerText(_ mode: EditorMode, _ binding: Proto.Binding) -> String {
        // 改过就说改过。之前这里无论如何都写「尚未改动」——在 Procreate 页选完一条
        // 预设后仍然显示「尚未改动」，跟侧栏的橙点直接打架。
        if dirty { return "已改动，点右上角「写入旋钮」才会生效" }
        if mode == .inferred(from: binding) { return " " }
        return "正在用「\(mode.label)」的方式编辑，尚未改动"
    }

    @ViewBuilder
    private func overview(_ binding: Proto.Binding, mode: EditorMode) -> some View {
        Section {
            LabeledContent("触发方式", value: model.selected.hint)
            // 标题得跟着状态走：改过之后这里显示的已经是编辑区的值，
            // 再叫「旋钮上的当前功能」就是在骗人。
            LabeledContent(dirty ? "改完的功能（待写入）" : "旋钮上的当前功能") {
                Text(Summary.full(binding))
                    .font(.system(size: 13, weight: .medium))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 常驻一行：没话说的时候留空但仍占位，这样切换类别时下方内容不会上下跳。
            // lineLimit(1) 是占位等高的前提——一旦折行，这行就比空占位高一截，白做了。
            Label(bannerText(mode, binding),
                  systemImage: dirty ? "pencil" : "eye")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(dirty ? Color.orange : Color.secondary)
                .opacity(bannerText(mode, binding) == " " ? 0 : 1)
                .accessibilityHidden(bannerText(mode, binding) == " ")
        }
    }

    // MARK: - 统一的可选行

    /// 三处列表（多媒体、鼠标/划屏、Procreate）共用同一种「点一下就选中，右侧打勾」的行。
    /// 之前多媒体用的是 inline Picker、另外两处是自定义按钮，视觉不统一。
    private func choiceRow(_ title: String, detail: String? = nil,
                           selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 多媒体

    private func mediaSection(_ binding: Proto.Binding) -> some View {
        let current = binding.type == .media ? binding.steps.first?.code : nil
        return Section("媒体动作") {
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

        Section {
            Toggle("Control", isOn: comboField(binding, combo, \.ctrl))
            Toggle("Shift",   isOn: comboField(binding, combo, \.shift))
            Toggle("Option",  isOn: comboField(binding, combo, \.alt))
            Toggle("Command（Windows 上是 Win）", isOn: comboField(binding, combo, \.win))
        } header: {
            Text("修饰键")
        }

        Section {
            Picker("配合的按键", selection: comboField(binding, combo, \.code)) {
                ForEach(KeyNames.keyboardGroups.filter { $0.title != "组合前缀" }) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            Text(item.name).tag(item.code)
                        }
                    }
                }
            }
        } footer: {
            Text(existing == nil ? "至少勾一个修饰键，改动才会生效。"
                                 : "旋钮会依次发出 \(comboPreview(combo))。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                model.update(Proto.binding(index: binding.index, layer: binding.layer, combo: next))
                browsing = nil
            })
    }

    // MARK: - 单个按键 / 序列

    @ViewBuilder
    private func macroSection(_ binding: Proto.Binding) -> some View {
        let isKeyboard = binding.type == .keyboard
        let count = isKeyboard ? Int(binding.dataLength) : 0

        Section {
            if count == 0 {
                Text(isKeyboard ? "还没有按键，点下面的「添加按键」开始。"
                                : "这个操作目前不是键盘功能。点「添加按键」会把它改成键盘。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(0..<count, id: \.self) { i in
                    stepRow(binding, index: i)
                }
            }

            Button {
                addStep(binding)
            } label: {
                Label("添加按键", systemImage: "plus")
            }
            .disabled(count >= Proto.macroSlots)
        } header: {
            HStack {
                Text("按键序列")
                Spacer()
                Text("\(count) / \(Proto.macroSlots)")
                    .foregroundStyle(.secondary)
                    .font(.caption.monospacedDigit())
            }
        } footer: {
            Text("按上到下依次发出，延时是发出该键之前先等待的毫秒数。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func stepRow(_ binding: Proto.Binding, index i: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(i + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)

            Picker("", selection: codeBinding(binding, index: i)) {
                ForEach(KeyNames.keyboardGroups) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            Text(item.name).tag(item.code)
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 170)

            Spacer(minLength: 4)

            TextField("", value: delayBinding(binding, index: i), format: .number)
                .labelsHidden()
                .frame(width: 46)
                .multilineTextAlignment(.trailing)
            Text("ms").font(.caption).foregroundStyle(.secondary)
            Stepper("", value: delayBinding(binding, index: i), in: 0...255)
                .labelsHidden()

            Button {
                removeStep(binding, at: i)
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("删掉这一步")
        }
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
        var next = binding.type == .keyboard
            ? binding
            : Proto.Binding(index: binding.index, layer: binding.layer,
                            type: .keyboard, code: 0x04)
        if binding.type != .keyboard {
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

    @ViewBuilder
    private func procreateSection(_ binding: Proto.Binding) -> some View {
        let current = Proto.preset(from: binding)

        Section("Procreate 快捷键") {
            ForEach(Proto.procreatePresets) { preset in
                choiceRow(preset.name, detail: presetShortcut(preset),
                          selected: current == preset) {
                    model.update(Proto.binding(index: binding.index,
                                               layer: binding.layer, preset: preset))
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

    @ViewBuilder
    private func clearSection(_ binding: Proto.Binding) -> some View {
        Section {
            Button(role: .destructive) {
                model.update(Proto.cleared(index: binding.index, layer: binding.layer))
                browsing = nil
            } label: {
                Label("清空这个操作", systemImage: "eraser")
            }
            .disabled(binding.type == .keyboard && binding.dataLength == 0)
        }
    }

    // MARK: - 鼠标 / 划屏

    @ViewBuilder
    private func mouseSection(_ binding: Proto.Binding) -> some View {
        let current = Proto.mouseAction(from: binding)

        Section("鼠标按键与滚轮") {
            mousePicker(binding, current: current, flag: 0x01)
        }

        Section {
            mousePicker(binding, current: current, flag: 0x04)
        } header: {
            Text("划屏与手势")
        } footer: {
            if binding.type == .mouse && current == nil {
                Text("旋钮上现在存的是一个没见过的鼠标动作，原始数据 "
                     + binding.steps.prefix(5)
                        .map { String(format: "%02X", $0.code) }.joined(separator: " ")
                     + "。选一项会把它覆盖掉。")
                .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func mousePicker(_ binding: Proto.Binding,
                             current: Proto.MouseAction?,
                             flag: UInt8) -> some View {
        ForEach(Proto.mouseActions.filter { $0.flag == flag }) { action in
            choiceRow(action.name, selected: current == action) {
                model.update(Proto.binding(index: binding.index, layer: binding.layer,
                                           mouse: action))
                browsing = nil
            }
        }
    }
}
