import Foundation
import SwiftUI
import AntiCaterCore

/// 界面与设备之间的唯一通道。
///
/// 所有 HID 调用都丢给 `HIDWorker` 的专属线程，回调统一在主线程，所以下面的
/// @Published 属性只会被主线程改动。
public final class DeviceModel: ObservableObject {

    public enum Connection: Equatable {
        case disconnected
        case connecting
        case connected(name: String, serial: String, firmware: String)

        public var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    @Published public private(set) var connection: Connection = .disconnected
    /// 从设备读回来的配置，作为「已保存」基线
    @Published private(set) var saved: [UInt8: [Proto.Binding]] = [:]
    /// 界面上正在编辑的副本
    @Published var draft: [UInt8: [Proto.Binding]] = [:]
    /// 灯效。选完立刻下发，不进 draft，所以只有一个值。
    @Published private(set) var lightMode: UInt8 = 0
    @Published private(set) var palette: [Color] = []
    private var rawPalette: [(r: UInt8, g: UInt8, b: UInt8)] = []

    /// USB / 蓝牙两条链路各自在不在线。插拔事件驱动，只读，不打开设备。
    @Published public private(set) var links = LinkStatus()

    @Published var layer: UInt8 = 1
    @Published var selected: PhysicalKey = .rotateLeft
    @Published private(set) var busy = false
    /// 一次性的成功提示，几秒后自己消失——不占版面，也不需要用户去关。
    @Published var message: String? {
        didSet {
            guard message != nil else { return }
            let shown = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.message == shown { self?.message = nil }
            }
        }
    }
    @Published var errorMessage: String?

    private let worker: JobRunner
    /// 测试要看它在拔线/写失败之后有没有被丢掉，所以 setter 私有、getter 内部可见。
    private(set) var session: DeviceSession?
    private let linkMonitor: LinkMonitor?
    /// 怎么建立一次连接。真机上是 `Session.connect()`，测试里换成假设备。
    private let makeSession: () throws -> DeviceSession

    public convenience init() {
        self.init(worker: HIDWorker(), monitorLinks: true, makeSession: { try Session.connect() })
    }

    /// - Parameter monitorLinks: 关掉之后不注册 IOKit 插拔回调，测试里直接调
    ///   `handleLinkChange` 就能模拟拔插，不需要真设备。
    init(worker: JobRunner,
         monitorLinks: Bool,
         makeSession: @escaping () throws -> DeviceSession) {
        self.worker = worker
        self.makeSession = makeSession
        self.linkMonitor = monitorLinks ? LinkMonitor() : nil
        linkMonitor?.onChange = { [weak self] status in self?.handleLinkChange(status) }
        linkMonitor?.refresh()
    }

    deinit {
        // 退出时也要走一遍 close()，否则输入回调会留在 worker 线程上悬着。
        if let session {
            worker.run { session.close() }
        }
    }

    // MARK: - 链路变化

    /// 拔线之后 `IOHIDDevice` 引用立刻作废，但 session 不会自己知道，
    /// 再往上面写就是 `kIOReturnBadArgument`（0xE00002C2）。所以徽标灭的同时
    /// 必须把 session 一起丢掉——两个状态不能脱节。
    func handleLinkChange(_ status: LinkStatus) {
        let hadUSB = links.usb
        links = status

        if hadUSB, !status.usb {
            invalidateSession(reason: "数据线已拔出。改动还留在编辑区，插回来就能继续写。")
        } else if !hadUSB, status.usb, !connection.isConnected, !busy {
            // 插回来自动接上。有未写入的改动就只更新基线，**不动 draft**，
            // 免得把用户编到一半的东西冲掉。
            connect(preservingDraft: hasChanges, silentOnFailure: true)
        }
    }

    /// 丢掉失效的 session。不碰 draft——用户的编辑内容跟连接状态没关系。
    ///
    /// 关设备这一步必须丢回 worker 线程：输入回调是在那个线程的 run loop 上注册的，
    /// 注销也只能在那里做（`HIDTransport.close()` 里有详细说明）。这里如果只是
    /// `session = nil`，回调就会留在 worker 上指着一个已经释放的对象。
    private func invalidateSession(reason: String?) {
        if let old = session {
            worker.run { old.close() }
        }
        session = nil
        connection = .disconnected
        if let reason { message = reason }
    }

    // MARK: - 取值与编辑

    func binding(_ key: PhysicalKey, in layer: UInt8) -> Proto.Binding? {
        draft[layer]?.first { $0.index == key.rawValue }
    }

    var current: Proto.Binding? { binding(selected, in: layer) }

    func update(_ binding: Proto.Binding) {
        guard var list = draft[binding.layer],
              let i = list.firstIndex(where: { $0.index == binding.index }) else { return }
        list[i] = binding
        draft[binding.layer] = list
    }

    /// 把当前这一套里的五个操作全部清空。只改 draft，仍需「写入旋钮」确认。
    /// 原版那个同名按钮，抓包时看到的只有一条 TX（只动了当时选中的那个键）；
    /// 但当时并没有在五个键都配好的前提下复测，所以这只是**观察**，不是定论。
    /// 这里不去猜原版的语义，按按钮的字面意思做成真的全清。
    func clearAll(in layer: UInt8) {
        guard let list = draft[layer] else { return }
        draft[layer] = list.map { Proto.cleared(index: $0.index, layer: layer) }
        message = "已在编辑区清空第 \(layer) 套的全部操作，点「写入旋钮」才会生效"
    }

    /// 某个键相对读回来的值是否有改动
    func isDirty(_ key: PhysicalKey, in layer: UInt8) -> Bool {
        guard let a = draft[layer]?.first(where: { $0.index == key.rawValue }),
              let b = saved[layer]?.first(where: { $0.index == key.rawValue })
        else { return false }
        return !Proto.sameFunction(a, b)
    }

    var dirtyKeys: [(layer: UInt8, key: PhysicalKey)] {
        (1...UInt8(Proto.layerCount)).flatMap { layer in
            PhysicalKey.allCases.filter { isDirty($0, in: layer) }.map { (layer, $0) }
        }
    }

    var hasChanges: Bool { !dirtyKeys.isEmpty }

    var changeCount: Int { dirtyKeys.count }

    /// 换灯效。灯光是即时可见、随时可改回的，没必要走「攒改动 → 确认 → 写入」那一套，
    /// 所以选完直接下发；写失败再退回设备上的旧值。
    func setLight(mode: UInt8) {
        guard let session, mode != lightMode else { return }
        let previous = lightMode
        let palette = rawPalette
        lightMode = mode
        errorMessage = nil

        worker.run {
            try session.writeLight(mode: mode, palette: palette)
        } completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.message = "灯效已切换为「"
                    + (Proto.lightModes.first { $0.mode == mode }?.name ?? "\(mode)") + "」"
            case .failure(let error):
                // 写可能是写到一半失败的，光把界面变量改回去不够——
                // 设备可能已经停在新灯效上了，补发一次旧灯效让两边对上。
                self.lightMode = previous
                if self.dropSessionIfStale(error) == false {
                    self.worker.run { try session.writeLight(mode: previous, palette: palette) }
                        completion: { _ in }
                }
                self.errorMessage = "切换灯效失败：" + Self.friendly(error)
            }
        }
    }

    // MARK: - 连接与读取

    struct Snapshot {
        let session: DeviceSession
        let name: String
        let serial: String
        let firmware: String
        let layers: [UInt8: [Proto.Binding]]
        let light: (mode: UInt8, palette: [(r: UInt8, g: UInt8, b: UInt8)])
    }

    /// - Parameter preservingDraft: 为真时只刷新「已保存」基线，保留编辑区内容。
    ///   拔插线自动重连时用得上：连接断过不代表用户想丢掉改到一半的东西。
    public func connect(preservingDraft: Bool = false, silentOnFailure: Bool = false) {
        guard !busy else { return }
        // 重连前先把旧的关掉，否则设备会被同一个进程开两次，旧句柄也没人注销回调。
        invalidateSession(reason: nil)
        busy = true
        connection = .connecting
        errorMessage = nil

        let makeSession = self.makeSession
        worker.run { () throws -> Snapshot in
            let session = try makeSession()
            do {
                let hello = try session.handshake()
                return Snapshot(
                    session: session,
                    name: session.deviceName,
                    serial: session.serialNumber ?? "-",
                    firmware: hello.count > 3 ? String(hello[3]) : "?",
                    layers: try session.readAllLayers(),
                    light: try session.readLight())
            } catch {
                // 设备已经打开、但握手或首次读取失败：这个 session 不会有人接手，
                // 必须就地关掉。这里已经在 worker 线程上，close() 的线程要求满足。
                session.close()
                throw error
            }
        } completion: { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let snapshot):
                self.session = snapshot.session
                self.connection = .connected(name: snapshot.name,
                                             serial: snapshot.serial,
                                             firmware: snapshot.firmware)
                if preservingDraft {
                    self.saved = snapshot.layers
                    self.message = "旋钮已重新连上，未写入的改动还在"
                } else {
                    self.apply(layers: snapshot.layers)
                    self.message = "已读取旋钮上的全部设置"
                }
                self.apply(light: snapshot.light)
            case .failure(let error):
                // session 已经在 worker 里关掉了，这里只要把界面状态摆正。
                self.session = nil
                self.connection = .disconnected
                // 插线触发的自动重连不该弹窗——用户没点任何东西，凭空跳个报错
                // 只会吓人。安静退回未连接，工具栏里还有「连接旋钮」可以手动来。
                if !silentOnFailure { self.errorMessage = Self.friendly(error) }
            }
        }
    }

    func reload() {
        guard let session, !busy else { return }
        busy = true
        errorMessage = nil
        worker.run { (try session.readAllLayers(), try session.readLight()) } completion: { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let (layers, light)):
                self.apply(layers: layers)
                self.apply(light: light)
                self.message = "已重新读取"
            case .failure(let error):
                self.dropSessionIfStale(error)
                self.errorMessage = Self.friendly(error)
            }
        }
    }

    // MARK: - 写入

    /// 只写真正改过的项，写完整体回读校验。
    func writeChanges() {
        let pending = dirtyKeys.compactMap { entry in
            draft[entry.layer]?.first { $0.index == entry.key.rawValue }
        }
        guard !pending.isEmpty, let session, !busy else { return }

        let total = changeCount
        busy = true
        errorMessage = nil

        worker.run { () -> ([UInt8: [Proto.Binding]], (UInt8, [(r: UInt8, g: UInt8, b: UInt8)])) in
            for binding in pending {
                try session.write(binding)
                Thread.sleep(forTimeInterval: 0.03)
            }
            return (try session.readAllLayers(), try session.readLight())
        } completion: { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let (layers, light)):
                self.apply(light: light)

                // 校验必须拿「本次打算写的内容」去和回读结果比。
                // 这里曾经比的是 draft/saved，而回读会把这两者同时刷成设备值，
                // 判据于是恒为「没有差异」——写失败也报成功，还顺手把用户的编辑
                // 内容冲掉。这是静默的数据丢失，别再改回去。
                let rejected = pending.filter { want in
                    guard let got = layers[want.layer]?
                        .first(where: { $0.index == want.index }) else { return true }
                    return !Proto.sameFunction(want, got)
                }

                if rejected.isEmpty {
                    self.apply(layers: layers)
                    self.message = "已写入 \(total) 项，回读校验通过"
                } else {
                    // 只把基线换成设备的真实状态，**保留 draft**：没写进去的那几项
                    // 仍然是脏的，用户不必重编一遍，再点一次写入就行。
                    self.saved = layers
                    let names = rejected
                        .compactMap { PhysicalKey(rawValue: $0.index)?.label }
                        .joined(separator: "、")
                    self.errorMessage = "有 \(rejected.count) 项没有写进旋钮：\(names)。"
                        + "你的编辑内容还在，确认数据线插好后再点一次「写入旋钮」。"
                }
            case .failure(let error):
                // 句柄失效的话必须断开重连，否则重试多少次都是同一个错。
                // draft 一律保留，改动不会因为掉线而丢。
                self.dropSessionIfStale(error)
                self.errorMessage = "写入失败：" + Self.friendly(error)
            }
        }
    }

    func discardChanges() {
        draft = saved
        message = "已放弃未保存的改动"
    }

    /// 错误是否意味着设备句柄已作废；是的话顺手把 session 丢掉。
    /// 返回值告诉调用方「还值不值得对这个 session 做后续动作」。
    @discardableResult
    private func dropSessionIfStale(_ error: Error) -> Bool {
        guard let failure = error as? HIDTransport.Failure, failure.meansDisconnected else {
            return false
        }
        invalidateSession(reason: nil)
        return true
    }

    /// IOKit 只会甩一串十六进制错误码回来，直接显示给用户没有意义，这里翻成人话。
    static func friendly(_ error: Error) -> String {
        let text = "\(error)"
        if text.contains("E00002C5") || text.lowercased().contains("exclusive") {
            return "旋钮被别的程序占着（多半是原版 ANTICATER 软件还开着）。"
                 + "退出它之后再点「连接旋钮」。"
        }
        // 0xE00002C2 kIOReturnBadArgument / 0xE00002C0 kIOReturnNoDevice /
        // 0xE00002CD kIOReturnNotOpen —— 都是「句柄已经作废」，实测就是中途拔了线。
        if text.contains("E00002C2") || text.contains("E00002C0")
            || text.contains("E00002CD") || text.contains("E00002D9") {
            return "和旋钮的连接已经断了（中途拔过数据线）。已自动断开，"
                 + "插好线后点「连接旋钮」即可，你的改动还在编辑区。"
        }
        if text.contains("notFound") || text.contains("noDevice") {
            return "没找到旋钮。改配置必须走 USB 数据线，只连蓝牙不行。"
        }
        return text
    }

    private func apply(layers: [UInt8: [Proto.Binding]]) {
        saved = layers
        draft = layers
    }

    private func apply(light: (mode: UInt8, palette: [(r: UInt8, g: UInt8, b: UInt8)])) {
        lightMode = light.mode
        rawPalette = light.palette
        palette = light.palette.map {
            Color(.sRGB, red: Double($0.r) / 255,
                  green: Double($0.g) / 255, blue: Double($0.b) / 255)
        }
    }
}
