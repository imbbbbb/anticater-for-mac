import SwiftUI
import AntiCaterCore

/// 菜单栏里的常驻面板。只放「看一眼」和「一键就能改」的东西，
/// 真要编辑按键还是回主窗口——菜单里塞编辑器不好用。
public struct MenuBarContent: View {
    @ObservedObject var model: DeviceModel
    @Environment(\.openWindow) private var openWindow

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var needsApproval = LaunchAtLogin.needsApproval

    @State private var autoCheckUpdates = UpdateChecker.autoCheckEnabled
    @State private var updateStatus: String?
    @State private var newVersion: String?
    /// 一次启动只自动查一次，菜单反复打开不该反复发请求。
    @State private var didAutoCheck = false


    public init(model: DeviceModel) { self.model = model }

    public var body: some View {
        Text(linkSummary)
            // 菜单每次弹出都重读一次开关状态。用户可能刚在「系统设置 → 登录项」
            // 里手动关掉了，@State 里那份初值不会自己更新，会一直显示成开着。
            .onAppear {
                launchAtLogin = LaunchAtLogin.isEnabled
                needsApproval = LaunchAtLogin.needsApproval
                if autoCheckUpdates, !didAutoCheck {
                    didAutoCheck = true
                    // 自动检查是静默的：查不到新版本、或者根本连不上网，都不打扰用户。
                    Task { await runUpdateCheck(announceNoUpdate: false) }
                }
            }

        Divider()

        Menu("灯效") {
            ForEach(Proto.lightModes, id: \.mode) { item in
                Button {
                    model.setLight(mode: item.mode)
                } label: {
                    if item.mode == model.lightMode {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
        }
        .disabled(!model.connection.isConnected)

        Button("打开主窗口") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Divider()

        Toggle("开机时自动启动", isOn: Binding(
            get: { launchAtLogin },
            set: { on in
                do {
                    try LaunchAtLogin.set(on)
                    launchAtLogin = LaunchAtLogin.isEnabled
                    needsApproval = LaunchAtLogin.needsApproval
                    // 注册接口不报错不等于真的开了：被系统拦下时状态会停在原处，
                    // 这时得说实话，不能默默装成已开启。
                    launchError = (launchAtLogin == on)
                        ? nil : "系统没有接受这次设置，请到「系统设置 → 通用 → 登录项」里手动放行。"
                } catch {
                    launchAtLogin = LaunchAtLogin.isEnabled
                    needsApproval = LaunchAtLogin.needsApproval
                    launchError = "\(error.localizedDescription)"
                }
            }))

        if needsApproval {
            Button("需要在「系统设置 → 登录项」里放行…") {
                LaunchAtLogin.openLoginItemsSettings()
            }
        }
        if let launchError {
            Text("设置自启失败：\(launchError)")
        }

        Divider()

        // 排障入口。放在菜单栏而不是只放在报错弹窗里，是因为有些问题不报错——
        // 比如写进去了但旋钮行为不对，用户此时没有弹窗可点。
        //
        // 只留一个入口指向诊断窗口：拷贝和详细日志开关都在窗口里，
        // 菜单里再摆一份就成了两套名字相近、行为又不完全一样的动作。
        Button("诊断信息…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "diagnostics")
        }

        Button("反馈问题…") { NSWorkspace.shared.open(Diagnostics.issuesPage) }

        Divider()

        // 版本号露在界面上，方便和 GitHub 上的 Release 对得起来。
        Text("ANTICATER 原生版 \(AppVersion.string)")

        if let newVersion {
            Button("有新版本 \(newVersion)，去下载…") {
                NSWorkspace.shared.open(UpdateChecker.releasesPage)
            }
        }
        if let updateStatus {
            Text(updateStatus)
        }

        Button("检查更新") {
            Task { await runUpdateCheck(announceNoUpdate: true) }
        }

        Toggle("启动时检查更新", isOn: Binding(
            get: { autoCheckUpdates },
            set: { on in
                autoCheckUpdates = on
                UpdateChecker.autoCheckEnabled = on
            }))

        Button("退出 ANTICATER") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// - Parameter announceNoUpdate: 手动点「检查更新」时要给个回音，
    ///   哪怕结果是「已经是最新」或者没联网；自动检查则一律静默。
    @MainActor
    private func runUpdateCheck(announceNoUpdate: Bool) async {
        if announceNoUpdate { updateStatus = "正在检查…" }
        switch await UpdateChecker.check() {
        case .success(.available(let version)):
            newVersion = version
            updateStatus = nil
        case .success(.upToDate):
            newVersion = nil
            updateStatus = announceNoUpdate ? "已经是最新版本" : nil
        case .failure(let error):
            newVersion = nil
            updateStatus = announceNoUpdate ? "\(error)" : nil
        }
    }

    private var linkSummary: String {
        switch (model.links.usb, model.links.bluetooth) {
        case (true, true):   return "旋钮已连接：数据线 + 蓝牙"
        case (true, false):  return "旋钮已连接：数据线"
        case (false, true):  return "旋钮已连接：蓝牙（读写配置都需插线）"
        case (false, false): return "未检测到旋钮"
        }
    }
}
