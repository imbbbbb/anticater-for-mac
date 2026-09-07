import SwiftUI
import AntiCaterCore
import AntiCaterUI

// SwiftPM 的 executableTarget 里 main.swift 不能用 @main，这里手工起 App。
struct AntiCaterApp: App {

    /// 主窗口和菜单栏共用同一个 model——两边看到的连接状态、配置、灯效都是同一份。
    @StateObject private var model = DeviceModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("ANTICATER", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.links.isAnyConnected ? "dial.medium.fill" : "dial.medium")
        }
    }
}

AntiCaterApp.main()
