import SwiftUI
import AntiCaterCore

/// 菜单栏里的常驻面板。只放「看一眼」和「一键就能改」的东西，
/// 真要编辑按键还是回主窗口——菜单里塞编辑器不好用。
struct MenuBarContent: View {
    @ObservedObject var model: DeviceModel
    @Environment(\.openWindow) private var openWindow

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var needsApproval = LaunchAtLogin.needsApproval

    var body: some View {
        Text(linkSummary)
            // 菜单每次弹出都重读一次开关状态。用户可能刚在「系统设置 → 登录项」
            // 里手动关掉了，@State 里那份初值不会自己更新，会一直显示成开着。
            .onAppear {
                launchAtLogin = LaunchAtLogin.isEnabled
                needsApproval = LaunchAtLogin.needsApproval
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

        // 版本号露在界面上，方便和 GitHub 上的 Release 对得起来。
        Text("ANTICATER 原生版 \(AppVersion.string)")

        Button("退出 ANTICATER") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var linkSummary: String {
        switch (model.links.usb, model.links.bluetooth) {
        case (true, true):   return "旋钮已连接：数据线 + 蓝牙"
        case (true, false):  return "旋钮已连接：数据线"
        case (false, true):  return "旋钮已连接：蓝牙（改配置需插线）"
        case (false, false): return "未检测到旋钮"
        }
    }
}
