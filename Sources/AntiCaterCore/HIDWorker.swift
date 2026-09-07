import Foundation

/// 把一段活儿丢到别处执行，完成后回调。
///
/// 抽成协议是为了测试：真机上是 `HIDWorker` 的专属线程，测试里换成
/// `ImmediateRunner` 当场跑完，用不着等异步。
public protocol JobRunner: AnyObject {
    func run<T>(_ body: @escaping () throws -> T,
                completion: @escaping (Result<T, Error>) -> Void)
}

extension JobRunner {
    public func run<T>(_ body: @escaping () throws -> T) {
        run(body, completion: { _ in })
    }
}

/// 一个专属线程，所有 HID 操作都在它上面跑。
///
/// 必须固定线程：`IOHIDDeviceScheduleWithRunLoop` 把输入回调绑在了调用时所在线程的
/// run loop 上，而 `receive` 又要在同一个 run loop 上 pump 才收得到报文。用
/// DispatchQueue 不行——它的执行线程会变。
public final class HIDWorker: JobRunner {

    /// 线程和 `HIDWorker` 共享的队列状态。
    ///
    /// 单独拆出来是有原因的：线程体不能捕获 `HIDWorker` 自身。早先写的是
    /// `Thread { [weak self] in self?.runLoop() }`，看着是弱引用，但 `runLoop()`
    /// 一进去就把 self 强引用住且永不返回，于是 `deinit` 永远不会执行、`stopped`
    /// 永远设不上，线程也就永远退不掉。现在线程只持有 Box，`HIDWorker` 可以正常析构。
    private final class Box {
        let lock = NSCondition()
        var jobs: [() -> Void] = []
        var stopped = false

        func drain() {
            while true {
                lock.lock()
                while jobs.isEmpty && !stopped { lock.wait() }
                if stopped { lock.unlock(); return }
                let job = jobs.removeFirst()
                lock.unlock()
                job()
            }
        }

        func submit(_ job: @escaping () -> Void) {
            lock.lock()
            jobs.append(job)
            lock.signal()
            lock.unlock()
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.broadcast()
            lock.unlock()
        }
    }

    private let box = Box()

    public init() {
        let box = self.box
        let thread = Thread { box.drain() }
        thread.name = "anticater.hid"
        thread.start()
    }

    deinit {
        box.stop()
    }

    /// 提交一个任务，结果回到主线程。
    public func run<T>(_ body: @escaping () throws -> T,
                       completion: @escaping (Result<T, Error>) -> Void) {
        box.submit {
            let result = Result { try body() }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// 当场执行、当场回调。只给测试用，省掉等异步的麻烦。
public final class ImmediateRunner: JobRunner {
    public init() {}
    public func run<T>(_ body: @escaping () throws -> T,
                       completion: @escaping (Result<T, Error>) -> Void) {
        completion(Result { try body() })
    }
}
