import SwiftUI
import AntiCaterCore

struct ContentView: View {
    @ObservedObject var model: DeviceModel
    @State private var confirmWrite = false
    @State private var confirmClearAll = false
    @State private var showError = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 272, max: 320)
        } detail: {
            EditorView(model: model)
                .navigationSplitViewColumnWidth(min: 400, ideal: 480)
                .overlay(alignment: .top) { toast }
        }
        .toolbar { toolbar }
        .frame(minWidth: 780, minHeight: 560)
        .onAppear { model.connect() }
        .onChange(of: model.errorMessage) { showError = $0 != nil }
        .animation(.easeOut(duration: 0.18), value: model.message)
        .confirmationDialog("把 \(model.changeCount) 项改动写入旋钮？",
                            isPresented: $confirmWrite, titleVisibility: .visible) {
            Button("写入", role: .destructive) { model.writeChanges() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会覆盖旋钮上对应操作的当前设置，写完自动回读校验。")
        }
        .confirmationDialog("清空全部五个旋钮操作？",
                            isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("清空", role: .destructive) { model.clearAll(in: model.layer) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只改编辑区，点「写入旋钮」之前都可以撤回。")
        }
        .alert("出错了", isPresented: $showError) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            KnobControl(
                selection: $model.selected,
                summary: { key in
                    model.binding(key, in: model.layer).map(Summary.short) ?? "—"
                },
                isDirty: { model.isDirty($0, in: model.layer) })
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
            .padding(.bottom, 10)

            linkBar
                .padding(.bottom, 12)

            List(selection: Binding(get: { model.selected },
                                    set: { model.selected = $0 ?? model.selected })) {
                Section("旋钮操作") {
                    ForEach(PhysicalKey.displayOrder, id: \.self) { key in
                        row(key).tag(key)
                    }
                }

                Section("灯光") {
                    Picker("灯效", selection: Binding(get: { model.lightMode },
                                                    set: { model.setLight(mode: $0) })) {
                        ForEach(Proto.lightModes, id: \.mode) { item in
                            Text(item.name).tag(item.mode)
                        }
                    }
                    .disabled(!model.connection.isConnected)
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button(role: .destructive) { confirmClearAll = true } label: {
                Label("清空全部配置", systemImage: "eraser")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!model.connection.isConnected)
            .padding(10)
            .help("把五个旋钮操作全部清空。会先弹窗确认，写入前还能撤回。")
        }
    }

    /// 两条链路的在线状态。挂在旋钮图下方——工具栏太挤，放这儿正好接着旋钮读。
    private var linkBar: some View {
        HStack(spacing: 10) {
            linkBadge("数据线", systemImage: "cable.connector", on: model.links.usb,
                      help: model.links.usb
                          ? "USB 线已插好，可以改配置" : "USB 线没插——改配置必须插线")
            linkBadge("蓝牙", systemImage: "dot.radiowaves.left.and.right",
                      on: model.links.bluetooth,
                      help: model.links.bluetooth ? "旋钮已通过蓝牙连上这台电脑" : "蓝牙未连接")
        }
        .frame(maxWidth: .infinity)
    }

    private func linkBadge(_ title: String, systemImage: String,
                           on: Bool, help: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(on ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(on ? Color.accentColor.opacity(0.14)
                              : Color.secondary.opacity(0.10))
        }
        .help(help)
    }

    private func row(_ key: PhysicalKey) -> some View {
        let binding = model.binding(key, in: model.layer)
        return HStack(spacing: 10) {
            Image(systemName: key.symbolName)
                .font(.system(size: 15))
                .frame(width: 22)
                .foregroundStyle(model.selected == key ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(key.label)
                    .font(.system(size: 13))
                Text(binding.map(Summary.short) ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if model.isDirty(key, in: model.layer) {
                Circle().fill(.orange).frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 3)
        .help(binding.map(Summary.full) ?? "未设置")
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if model.busy { ProgressView().controlSize(.small) }

            Menu {
                Button {
                    model.connection.isConnected ? model.reload() : model.connect()
                } label: {
                    Label(model.connection.isConnected ? "重新读取" : "连接旋钮",
                          systemImage: model.connection.isConnected
                              ? "arrow.clockwise" : "cable.connector")
                }
                .disabled(model.busy)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help(connectionDetail)

            if model.hasChanges {
                Button("放弃") { model.discardChanges() }
                    .help("退回到旋钮上现在的设置")
            }

            Button {
                confirmWrite = true
            } label: {
                Text(model.hasChanges ? "写入旋钮（\(model.changeCount)）" : "写入旋钮")
            }
            .keyboardShortcut("s")
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasChanges || model.busy)
        }
    }

    private var connectionDetail: String {
        if case .connected(let name, let serial, let firmware) = model.connection {
            return "\(name)\n序列号 \(serial)\n固件 \(firmware)"
        }
        return "用 USB 线把旋钮接到电脑上"
    }

    // MARK: - 瞬时提示

    /// 成功类提示浮在编辑区顶部，几秒后自己消失，不常驻占版面。
    @ViewBuilder
    private var toast: some View {
        if let message = model.message {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    Capsule().fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                }
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
