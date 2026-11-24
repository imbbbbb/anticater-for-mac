import SwiftUI
import AntiCaterCore

/// 主窗口：左边旋钮舞台（固定 460 宽），右边检查器（弹性）。
public struct ContentView: View {
    @ObservedObject var model: DeviceModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirmWrite = false
    @State private var confirmClearAll = false
    @State private var showError = false

    public init(model: DeviceModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 0) {
            stage
                .frame(width: 460)
                .frame(maxHeight: .infinity)
                .background(Theme.stage)
            Theme.separator.frame(width: 1)
            EditorView(model: model)
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.window)
                .overlay(alignment: .bottom) { toast }
        }
        .navigationTitle("ANTICATER")
        .toolbar { toolbar }
        .frame(minWidth: 920, minHeight: 660)
        // 开窗即连，但失败要静默：主窗口每显示一次就会走一遍这里（菜单栏 app
        // 关窗再开是常事），没插线的人会被反复拦住。占位页已经在讲该怎么做了。
        .onAppear { model.connect(silentOnFailure: true) }
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
            // 连不上时远程排障全靠这个。放在报错弹窗里而不是只在菜单深处，
            // 因为需要它的时刻就是这一刻。
            // 打开窗口而不是直接拷贝：让用户先看清要发出去的是什么再决定拷不拷。
            Button("查看诊断信息…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "diagnostics")
            }
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - 旋钮舞台

    private var stage: some View {
        VStack(spacing: 0) {
            KnobControl(
                selection: $model.selected,
                summary: { key in
                    model.binding(key, in: model.layer).map(Summary.short) ?? "—"
                },
                isDirty: { model.isDirty($0, in: model.layer) })
            .disabled(model.current == nil)
            .padding(.vertical, 28)
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                // 灯光在左、清空全部在右，同一行，左右边缘和上方药丸对齐
                HStack(spacing: 16) {
                    lightRow
                    Spacer(minLength: 0)
                    Button(role: .destructive) { confirmClearAll = true } label: {
                        Text("清空全部配置").foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .disabled(model.current == nil)
                    .opacity(model.current == nil ? 0.38 : 1)
                    .help("把五个旋钮操作全部清空。会先弹窗确认，写入前还能撤回。")
                }
                // 连上了却读不到灯效，说明这台固件不认这组命令。说一句，
                // 否则用户只会看到一个点不动的选择器，不知道是坏了还是没连上。
                if model.connection.isConnected, !model.lightAvailable, model.rgbLight == nil {
                    Text("这台旋钮的固件不支持灯效设置，按键配置不受影响。")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.text3)
                }
            }
            .font(Theme.Font.caption)
            .padding(.horizontal, 30)
            .padding(.bottom, 44)
        }
    }

    /// 灯光改了立即下发，不进「写入旋钮」。
    @ViewBuilder
    private var lightRow: some View {
        if let rgb = model.rgbLight {
            RGBLightControls(model: model, light: rgb)
        } else {
            Picker("灯效", selection: Binding(get: { model.lightMode },
                                            set: { model.setLight(mode: $0) })) {
                ForEach(Proto.lightModes, id: \.mode) { item in
                    Text(item.name).tag(item.mode)
                }
            }
            .frame(width: 220)
            .disabled(!model.connection.isConnected || !model.lightAvailable)
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            linkBadge("数据线", systemImage: "cable.connector", on: model.links.usb,
                      help: model.links.usb
                          ? "USB 线已插好，可以改配置" : "USB 线没插——改配置必须插线")
            linkBadge("蓝牙", systemImage: "dot.radiowaves.left.and.right",
                      on: model.links.bluetooth,
                      help: model.links.bluetooth
                          ? "旋钮已通过蓝牙连上这台电脑。蓝牙链路上没有配置通道，"
                            + "读写配置都要插 USB 线"
                          : "蓝牙未连接")
        }

        ToolbarItem { Spacer() }

        ToolbarItemGroup {
            syncBadge

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

            // 自己画主按钮：新系统的工具栏不认 borderedProminent 的 tint，画出来是灰的。
            let canWrite = model.hasChanges && !model.busy && model.connection.isConnected
            Button {
                confirmWrite = true
            } label: {
                Text(model.busy && model.connection.isConnected ? "写入中…" : "写入旋钮")
                    .font(Theme.Font.captionBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(Capsule().fill(Theme.primary))
                    .opacity(canWrite ? 1 : 0.38)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s")
            .disabled(!canWrite)
        }
    }

    /// 两条链路的在线状态，只读——用户选不了走哪条，蓝牙上本来就没有配置通道。
    private func linkBadge(_ title: String, systemImage: String,
                           on: Bool, help: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(Theme.Font.caption)
            .foregroundStyle(on ? Theme.accent : Theme.text3)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(on ? Theme.accent.opacity(0.14) : Theme.hover))
            .help(help)
    }

    private var syncBadge: some View {
        let (text, color): (String, Color) = {
            switch model.connection {
            case .connecting:
                return ("连接中…", Theme.text3)
            case .disconnected:
                return (model.links.bluetooth ? "仅蓝牙，读不到配置" : "未连接", Theme.danger)
            case .connected:
                return model.hasChanges ? ("未写入 · \(model.changeCount) 处", Theme.warning)
                                        : ("已同步", Theme.success)
            }
        }()
        return HStack(spacing: 6) {
            if model.busy {
                ProgressView().controlSize(.small)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(text)
                .font(Theme.Font.caption)
                .foregroundStyle(model.connection.isConnected ? color : Theme.text2)
        }
        .padding(.horizontal, 6)
    }

    private var connectionDetail: String {
        if case .connected(let name, let serial, let firmware) = model.connection {
            return "\(name)\n序列号 \(serial)\n固件 \(firmware)"
        }
        if model.links.bluetooth {
            return "蓝牙已连接，但配置通道只在 USB 上\n插上数据线会自动连接"
        }
        return "用 USB 数据线把旋钮接到电脑上，会自动连接"
    }

    // MARK: - 瞬时提示

    /// 成功类提示浮在检查器底部，几秒后自己消失，不常驻占版面。
    /// 不放顶部：会盖住标题和状态行，而那正是用户刚改完要看的地方。
    @ViewBuilder
    private var toast: some View {
        if let message = model.message {
            Text(message)
                .font(Theme.Font.captionBold)
                .foregroundStyle(Theme.text1)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background {
                    Capsule().fill(Theme.elevated)
                        .overlay(Capsule().strokeBorder(Theme.separator))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                }
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
