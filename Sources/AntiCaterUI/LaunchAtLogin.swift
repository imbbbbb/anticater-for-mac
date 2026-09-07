import Foundation
import ServiceManagement

/// 开机自启开关。走 macOS 13 起的 `SMAppService`，不需要装 LaunchAgent plist，
/// 注册后会出现在「系统设置 → 通用 → 登录项」里，用户随时能自己关掉。
///
/// 注意：这个 app 是本地临时签名（ad-hoc）的，系统对未公证的 app 有可能拒绝注册。
/// 真被拒了这里会把错误抛给界面，而不是假装成功。
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 系统设置里被用户手动关掉之后会变成这个状态，需要去设置里放行。
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
