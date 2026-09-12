import XCTest
import IOKit
import AntiCaterCore
@testable import AntiCaterUI

/// `DeviceModel` 状态机的回归测试。
///
/// 之前出的两个 bug——写入回读校验比错了对象（静默丢数据）、拔线后不丢 session
/// （重试永远是 0xE00002C2）——都是靠真机手动试出来的，测试一条没拦住。
/// 这里用假设备把它们固定下来。
final class DeviceModelTests: XCTestCase {

    /// 造一个已连上假设备的 model。`ImmediateRunner` 让所有异步当场跑完，
    /// 不用 expectation 等回调。
    private func makeModel(_ fake: FakeSession = FakeSession())
        -> (DeviceModel, FakeSession) {
        let model = DeviceModel(worker: ImmediateRunner(),
                                monitorLinks: false,
                                makeSession: { fake })
        model.connect()
        return (model, fake)
    }

    private func edit(_ model: DeviceModel, _ key: PhysicalKey,
                      layer: UInt8 = 1, code: UInt8 = 0x06) {
        model.update(Proto.Binding(index: key.rawValue, layer: layer,
                                   type: .keyboard, code: code))
    }

    // MARK: - 连接

    func testConnectPopulatesDraftAndSaved() {
        let (model, fake) = makeModel()
        XCTAssertTrue(model.connection.isConnected)
        XCTAssertEqual(fake.handshakeCount, 1)
        XCTAssertEqual(model.draft.count, Proto.layerCount)
        XCTAssertFalse(model.hasChanges)
    }

    /// 握手失败时那个已经打开的设备必须被关掉，否则句柄泄漏、
    /// 下次连接还会撞上「设备已被占用」。
    func testFailedHandshakeClosesSession() {
        let fake = FakeSession()
        fake.handshakeError = HIDTransport.Failure.timeout(expected: 1, got: 0)
        let model = DeviceModel(worker: ImmediateRunner(), monitorLinks: false,
                                makeSession: { fake })
        model.connect()

        XCTAssertEqual(fake.closeCount, 1, "握手失败后设备没有被关闭")
        XCTAssertNil(model.session)
        XCTAssertFalse(model.connection.isConnected)
        XCTAssertNotNil(model.errorMessage)
    }

    /// 重复点「连接旋钮」不能把同一台设备开两次。
    func testReconnectClosesPreviousSession() {
        let (model, fake) = makeModel()
        model.connect()
        XCTAssertEqual(fake.closeCount, 1, "重连前没有关掉旧 session")
    }

    // MARK: - 写入校验（S1 回归）

    func testSuccessfulWriteSyncsBaseline() {
        let (model, fake) = makeModel()
        edit(model, .rotateLeft)
        XCTAssertTrue(model.hasChanges)

        model.writeChanges()

        XCTAssertEqual(fake.writtenBindings.count, 1)
        XCTAssertFalse(model.hasChanges, "写入成功后基线应该跟上，不该还是脏的")
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.message)
    }

    /// 核心回归：设备把写入吃掉了（不报错但不生效）。
    /// 必须报错、必须点名是哪个键、而且**用户的编辑内容不能丢**。
    /// 早先的实现拿 draft 和 saved 比，而回读会把两者同时刷成设备值，
    /// 判据恒为「没有差异」，于是写失败也报成功，还顺手把编辑内容冲掉了。
    func testSilentlyRejectedWriteIsReportedAndDraftSurvives() {
        let fake = FakeSession()
        fake.silentlyIgnoredIndices = [PhysicalKey.rotateLeft.rawValue]
        let (model, _) = makeModel(fake)

        edit(model, .rotateLeft, code: 0x06)
        edit(model, .press, code: 0x07)
        model.writeChanges()

        XCTAssertNotNil(model.errorMessage, "写入没生效却报成功了")
        XCTAssertEqual(model.errorMessage?.contains(PhysicalKey.rotateLeft.label), true,
                       "报错里没点名是哪个键")
        XCTAssertTrue(model.isDirty(.rotateLeft, in: 1), "没写进去的项应该还是脏的")
        XCTAssertFalse(model.isDirty(.press, in: 1), "写进去的项不该还是脏的")
        XCTAssertEqual(model.binding(.rotateLeft, in: 1)?.steps.first?.code, 0x06,
                       "用户的编辑内容被冲掉了")
    }

    /// 设备回读时少给一层。缺失的项一律算作没写进去，不能当成功，更不能崩。
    func testMissingLayerInReadbackCountsAsRejected() {
        let fake = FakeSession()
        let (model, _) = makeModel(fake)
        edit(model, .rotateLeft)
        fake.dropLayerOnRead = 1

        model.writeChanges()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.binding(.rotateLeft, in: 1)?.steps.first?.code, 0x06)
    }

    // MARK: - 掉线处理（0xE00002C2 回归）

    /// 写入时拿到句柄失效类错误，必须丢掉 session 并关掉设备。
    /// 不丢的话重试多少次都是同一个错——这正是用户报的那个 bug。
    func testStaleHandleOnWriteDropsSession() {
        let fake = FakeSession()
        let (model, _) = makeModel(fake)
        edit(model, .rotateLeft)
        fake.writeError = HIDTransport.Failure.writeFailed(kIOReturnBadArgument)

        model.writeChanges()

        XCTAssertNil(model.session, "掉线后 session 没有被丢掉")
        XCTAssertFalse(model.connection.isConnected)
        XCTAssertEqual(fake.closeCount, 1, "掉线后设备没有被 close()")
        XCTAssertTrue(model.isDirty(.rotateLeft, in: 1), "掉线不该让用户的改动消失")
    }

    /// 反面：被别的程序占用不是掉线，session 不该被丢掉。
    /// 误判会让用户莫名其妙地掉一次连接。
    func testExclusiveAccessErrorKeepsSession() {
        let fake = FakeSession()
        let (model, _) = makeModel(fake)
        edit(model, .rotateLeft)
        fake.writeError = HIDTransport.Failure.openFailed(kIOReturnExclusiveAccess)

        model.writeChanges()

        XCTAssertNotNil(model.session, "非掉线错误不该丢掉 session")
        XCTAssertTrue(model.connection.isConnected)
        XCTAssertEqual(fake.closeCount, 0)
    }

    // MARK: - 热插拔

    func testUnplugInvalidatesSessionAndKeepsDraft() {
        let fake = FakeSession()
        let (model, _) = makeModel(fake)
        edit(model, .rotateLeft)

        model.handleLinkChange(LinkStatus(usb: true, bluetooth: false))
        model.handleLinkChange(LinkStatus(usb: false, bluetooth: false))

        XCTAssertNil(model.session)
        XCTAssertFalse(model.connection.isConnected)
        XCTAssertEqual(fake.closeCount, 1, "拔线后设备没有被 close()")
        XCTAssertTrue(model.isDirty(.rotateLeft, in: 1), "拔线把用户的改动弄丢了")
    }

    /// 插回来自动重连，且**不能**把编辑到一半的内容冲掉。
    func testReplugReconnectsPreservingDraft() {
        let fake = FakeSession()
        let (model, _) = makeModel(fake)
        edit(model, .rotateLeft, code: 0x06)

        model.handleLinkChange(LinkStatus(usb: true, bluetooth: false))
        model.handleLinkChange(LinkStatus(usb: false, bluetooth: false))
        model.handleLinkChange(LinkStatus(usb: true, bluetooth: false))

        XCTAssertTrue(model.connection.isConnected, "插回来没有自动重连")
        XCTAssertEqual(model.binding(.rotateLeft, in: 1)?.steps.first?.code, 0x06,
                       "重连把未写入的改动冲掉了")
        XCTAssertTrue(model.isDirty(.rotateLeft, in: 1))
    }

    /// 没有改动时插回来，走的是正常路径，draft 应该刷成设备上的值。
    func testReplugWithoutChangesRefreshesFromDevice() {
        let fake = FakeSession()
        let (model, _) = makeModel(fake)
        fake.layers[1]?[0] = Proto.Binding(index: PhysicalKey.rotateLeft.rawValue,
                                           layer: 1, type: .keyboard, code: 0x2C)

        model.handleLinkChange(LinkStatus(usb: true, bluetooth: false))
        model.handleLinkChange(LinkStatus(usb: false, bluetooth: false))
        model.handleLinkChange(LinkStatus(usb: true, bluetooth: false))

        XCTAssertTrue(model.connection.isConnected)
        XCTAssertFalse(model.hasChanges)
        XCTAssertEqual(model.binding(.rotateLeft, in: 1)?.steps.first?.code, 0x2C)
    }

    /// 只有蓝牙在线时不该尝试连接——配置接口只在 USB 侧。
    func testBluetoothOnlyDoesNotConnect() {
        let fake = FakeSession()
        let model = DeviceModel(worker: ImmediateRunner(), monitorLinks: false,
                                makeSession: { fake })
        model.handleLinkChange(LinkStatus(usb: false, bluetooth: true))

        XCTAssertFalse(model.connection.isConnected)
        XCTAssertEqual(fake.handshakeCount, 0)
    }

    /// 没插线不该弹模态框。主窗口每显示一次就连一次，只用蓝牙的人会被反复拦住；
    /// 这是预期状态，编辑区的占位页已经在讲该怎么做了。
    func testDeviceNotFoundDoesNotRaiseModalError() {
        let model = DeviceModel(worker: ImmediateRunner(), monitorLinks: false,
                                makeSession: { throw HIDTransport.Failure.notFound })
        model.connect()

        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.connection.isConnected)
    }

    /// 蓝牙在线时不能说「没找到旋钮」——界面上蓝牙徽标正亮着。
    /// 也不能说成只有写受限：0xFF00 在蓝牙上根本不存在，读写一起没有。
    func testBluetoothOnlyMessageDoesNotClaimDeviceIsMissing() {
        let text = DeviceModel.friendly(HIDTransport.Failure.notFound,
                                        links: LinkStatus(usb: false, bluetooth: true))
        XCTAssertFalse(text.contains("没找到旋钮"))
        XCTAssertTrue(text.contains("蓝牙"))
        XCTAssertTrue(text.contains("读取"))
    }

    /// 设备在、但被别的进程占着，是真错误：退出那个程序不会产生插拔事件，
    /// 所以这一条必须留在模态框里，并且要指向手动的「连接旋钮」。
    func testExclusiveAccessStillRaisesModalError() {
        let model = DeviceModel(worker: ImmediateRunner(), monitorLinks: false,
                                makeSession: {
                                    throw HIDTransport.Failure.openFailed(kIOReturnExclusiveAccess)
                                })
        model.connect()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.errorMessage?.contains("连接旋钮") == true)
    }

    /// issue #1：固件 0x00 的机器握手正常、三层配置也全读到了，唯独不应答读调色板，
    /// 结果整次连接失败，用户连按键都改不了。灯效是附带功能，不该有权否决主功能。
    func testLightReadTimeoutStillConnectsAndKeepsConfig() {
        let fake = FakeSession()
        fake.readLightError = HIDTransport.Failure.timeout(expected: 1, got: 0)
        let model = DeviceModel(worker: ImmediateRunner(), monitorLinks: false,
                                makeSession: { fake })
        model.connect()

        XCTAssertTrue(model.connection.isConnected)
        XCTAssertNil(model.errorMessage)
        // 按键配置必须照常可用——这才是这个 app 存在的理由。
        XCTAssertEqual(model.binding(.rotateLeft, in: 1)?.index, PhysicalKey.rotateLeft.rawValue)
        // 灯效整块标为不可用，界面据此禁掉，而不是留个点不动的选择器。
        XCTAssertFalse(model.lightAvailable)
    }

    /// 读不到灯效时不许下发灯效命令——设备都没应答读，写过去只会是瞎猜。
    func testLightWriteIsRefusedWhenUnsupported() {
        let fake = FakeSession()
        fake.readLightError = HIDTransport.Failure.timeout(expected: 1, got: 0)
        let model = DeviceModel(worker: ImmediateRunner(), monitorLinks: false,
                                makeSession: { fake })
        model.connect()
        model.setLight(mode: 3)

        XCTAssertEqual(model.lightMode, 0)
        XCTAssertNil(model.errorMessage)
    }

    /// 正常固件不受影响：读得到就照常可用。
    func testLightAvailableOnHealthyFirmware() {
        let (model, _) = makeModel()
        XCTAssertTrue(model.lightAvailable)
    }

    // MARK: - 编辑区

    func testDiscardChangesRestoresBaseline() {
        let (model, _) = makeModel()
        edit(model, .rotateLeft)
        XCTAssertTrue(model.hasChanges)

        model.discardChanges()

        XCTAssertFalse(model.hasChanges)
    }

    func testClearAllOnlyTouchesDraft() {
        let (model, fake) = makeModel()
        fake.layers[1] = PhysicalKey.allCases.map {
            Proto.Binding(index: $0.rawValue, layer: 1, type: .keyboard, code: 0x06)
        }
        model.connect()
        XCTAssertFalse(model.hasChanges)

        model.clearAll(in: 1)

        XCTAssertEqual(model.changeCount, PhysicalKey.allCases.count)
        XCTAssertEqual(fake.writtenBindings.count, 0, "清空不该直接下发到设备")
    }

    /// 只写真正改过的项，没动的不该被重复下发。
    func testOnlyDirtyBindingsAreWritten() {
        let (model, fake) = makeModel()
        edit(model, .rotateLeft)
        edit(model, .press, layer: 2)

        model.writeChanges()

        XCTAssertEqual(fake.writtenBindings.count, 2)
        XCTAssertEqual(Set(fake.writtenBindings.map(\.layer)), [1, 2])
    }

    // MARK: - 灯效

    func testLightFailureRollsBackMode() {
        let fake = FakeSession()
        let (model, _) = makeModel(fake)
        let original = model.lightMode
        fake.writeLightError = HIDTransport.Failure.writeFailed(kIOReturnBadArgument)

        model.setLight(mode: 3)

        XCTAssertEqual(model.lightMode, original, "写失败后界面上的灯效没有回退")
        XCTAssertNotNil(model.errorMessage)
    }
}
