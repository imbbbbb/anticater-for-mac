import Foundation
import IOKit.hid

/// 盯着 USB / 蓝牙两条链路的通断，**事件驱动**，不轮询。
///
/// 之前是每 3 秒 `IOHIDManagerCopyDevices` 全量扫一遍系统里所有 HID 设备，
/// 一天下来两万多次无谓的枚举。改成向 IOHIDManager 注册插拔回调后，
/// 只有真的插拔设备时才会醒一次，静置时 CPU 占用为零。
///
/// 回调挂在主线程的 run loop 上——它只读属性、不做 IO，开销可以忽略；
/// 而且 `onChange` 本来就要回主线程更新界面，省掉一次线程切换。
public final class LinkMonitor {

    private let manager: IOHIDManager
    private var status = LinkStatus()

    /// 状态变化时回调（主线程）。相同的状态不会重复通知。
    public var onChange: ((LinkStatus) -> Void)?

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let handler: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let monitor = Unmanaged<LinkMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.refresh()
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, handler, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, handler, context)
        // 必须是 commonModes：defaultMode 下，用户按住菜单或拖着窗口时
        // run loop 切到 event tracking 模式，插拔回调会一直压着不投递，
        // 徽标要等鼠标松开才更新。
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                        CFRunLoopMode.commonModes.rawValue)

        // 这里**故意不调 IOHIDManagerOpen**。匹配的是全部 HID 设备（要认蓝牙侧那只），
        // 一旦 Open 就等于打开了真键盘，可能触发「输入监控」权限申请——而本项目
        // 一个关键结论就是只碰厂商页 0xFF00、不需要该权限。
        // 插拔回调和 CopyDevices 都不要求先 Open，省掉它既够用又不碰权限边界。
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(),
                                          CFRunLoopMode.commonModes.rawValue)
    }

    /// 立刻重新判定一次。启动时要主动调一次拿初值。
    public func refresh() {
        // 插拔事件到达时设备还没完全注册好，晚一点再看，免得读到半成品。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let next = LinkStatus.scan(in: self.manager)
            guard next != self.status else { return }
            self.status = next
            self.onChange?(next)
        }
    }
}
