import Foundation
import IOKit.hid

/// 旋钮当前挂在哪条链路上。
///
/// 这台设备可以同时以两种身份出现在系统里：USB 线插着时是
/// `0x514C:0x8850` 的复合设备（配置通道就在它的 0xFF00 接口上），
/// 蓝牙配对上时另有一个 `CXKJ / ANTICATER_MINI` 的 BLE HID 设备。
/// 两者互不影响，可以同时在线。
public struct LinkStatus: Equatable {
    public var usb = false
    public var bluetooth = false

    public init(usb: Bool = false, bluetooth: Bool = false) {
        self.usb = usb
        self.bluetooth = bluetooth
    }

    public var isAnyConnected: Bool { usb || bluetooth }

    /// 扫一遍系统里的 HID 设备。纯读，不打开任何设备。
    ///
    /// 复用调用方已有的 manager——每次现建一个再丢掉，光是建/销毁就比判定本身还贵。
    public static func scan(in manager: IOHIDManager) -> LinkStatus {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return LinkStatus()
        }

        var status = LinkStatus()
        for device in devices {
            let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String

            // 只认带 0xFF00 配置集合的接口。复合设备的键盘/多媒体接口 VID/PID 一样，
            // 光比 VID/PID 的话，即使配置通道不可用徽标也会亮，
            // 界面就会骗用户说「可以改配置」。
            // 判据必须和 `HIDTransport.discover()` 用同一个——否则会出现徽标亮着
            // 但连接按钮报「没找到旋钮」（或反过来）的自相矛盾。
            if let vendor, let product,
               HIDTransport.supportedIDs.contains(where: { $0.vid == vendor && $0.pid == product }),
               HIDTransport.hasConfigUsage(device) {
                status.usb = true
            }
            // 蓝牙侧借用了苹果的 VID，光看 VID/PID 会误伤真苹果外设，所以认名字。
            if transport?.hasPrefix("Bluetooth") == true,
               name?.uppercased().contains("ANTICATER") == true {
                status.bluetooth = true
            }
        }
        return status
    }
}
