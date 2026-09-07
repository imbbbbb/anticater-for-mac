import Foundation

/// 对比 GitHub 上最新的 Release 和当前版本。
///
/// 这是本 app 唯一一处主动联网的地方，而且可以关掉（菜单里的「启动时检查更新」，
/// 状态存在 UserDefaults 里）。请求只发到 GitHub 的公开 API，不带任何标识信息，
/// 也不上报本机情况。
public enum UpdateChecker {

    public static let repository = "imbbbbb/anticater-for-mac"
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!

    /// 关掉之后启动时不再自动检查，菜单里手动点仍然可用。
    public static let autoCheckDefaultsKey = "AutoCheckForUpdates"

    public static var autoCheckEnabled: Bool {
        get {
            // 没写过这个键时默认开启，所以要区分「没设过」和「设成了 false」。
            UserDefaults.standard.object(forKey: autoCheckDefaultsKey) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckDefaultsKey) }
    }

    public enum Result: Equatable {
        case upToDate
        case available(version: String)
    }

    public enum Failure: Error, CustomStringConvertible {
        case network(String)
        case badResponse

        public var description: String {
            switch self {
            case .network(let detail): return "连不上 GitHub：\(detail)"
            case .badResponse:         return "GitHub 返回的内容看不懂"
            }
        }
    }

    /// 把 "v1.10" / "1.10.2" 这类字符串拆成可比较的数字序列。
    /// 必须按数字比而不是按字典序，否则 "1.10" 会被判成小于 "1.9"。
    static func components(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// `latest` 是否比 `current` 新。位数不同时短的一方按 0 补齐（1.1 == 1.1.0）。
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = components(latest), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 拉一次最新 Release 的 tag。网络失败一律吞掉细节交给调用方决定要不要提示。
    public static func check(current: String = AppVersion.string,
                            session: URLSession = .shared) async -> Swift.Result<Result, Failure> {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("anticater-for-mac/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failure(.badResponse)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                return .failure(.badResponse)
            }
            return .success(isNewer(tag, than: current) ? .available(version: tag) : .upToDate)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
