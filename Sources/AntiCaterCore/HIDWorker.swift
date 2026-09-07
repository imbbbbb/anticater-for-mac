import Foundation

/// 一个专属线程，所有 HID 操作都在它上面跑。
///
/// 必须固定线程：`IOHIDDeviceScheduleWithRunLoop` 把输入回调绑在了调用时所在线程的
/// run loop 上，而 `receive` 又要在同一个 run loop 上 pump 才收得到报文。用
/// DispatchQueue 不行——它的执行线程会变。
public final class HIDWorker {

    private let lock = NSCondition()
    private var jobs: [() -> Void] = []
    private var stopped = false

    public init() {
        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "anticater.hid"
        thread.start()
    }

    deinit {
        lock.lock()
        stopped = true
        lock.broadcast()
        lock.unlock()
    }

    private func runLoop() {
        while true {
            lock.lock()
            while jobs.isEmpty && !stopped { lock.wait() }
            if stopped { lock.unlock(); return }
            let job = jobs.removeFirst()
            lock.unlock()
            job()
        }
    }

    /// 提交一个任务，结果回到主线程。
    public func run<T>(_ body: @escaping () throws -> T,
                       completion: @escaping (Result<T, Error>) -> Void) {
        lock.lock()
        jobs.append {
            let result = Result { try body() }
            DispatchQueue.main.async { completion(result) }
        }
        lock.signal()
        lock.unlock()
    }
}
