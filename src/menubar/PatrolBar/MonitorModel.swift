import Foundation
import Combine

final class MonitorModel: ObservableObject {
    @Published var now: NowSnapshot?
    @Published var procs: [ProcRow] = []
    @Published var alerts: [AlertRow] = []
    @Published var reachable = true

    var onUpdate: ((NowSnapshot?) -> Void)?

    // 面板地址与 web/server.py 保持一致；端口可用 PATROL_PORT 覆盖（安装脚本会写进 plist）。
    private let base: String = {
        let port = ProcessInfo.processInfo.environment["PATROL_PORT"] ?? "8787"
        return "http://127.0.0.1:" + port
    }()
    private var timer: Timer?

    func start() {
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        get("/api/overview", as: Overview.self) { [weak self] ov in
            guard let self else { return }
            guard let ov else {
                self.reachable = false
                self.onUpdate?(nil)
                return
            }
            self.reachable = true
            self.now = ov.now
            self.procs = Array(ov.procs.prefix(6))
            self.onUpdate?(ov.now)
        }

        get("/api/alerts", as: AlertsResponse.self) { [weak self] res in
            guard let self else { return }
            self.alerts = Array((res?.alerts ?? []).prefix(3))
        }
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type, _ done: @escaping (T?) -> Void) {
        guard let url = URL(string: base + path) else {
            done(nil)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let decoded: T? = data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
            DispatchQueue.main.async { done(decoded) }
        }.resume()
    }
}
