import Foundation

struct NowSnapshot: Codable {
    let ts: Double
    let load1: Double
    let load5: Double
    let load15: Double
    let cpu_busy: Double
    let mem_used_mb: Double
    let mem_pressure_mb: Double
    let swap_used_mb: Double
    let temp_c: Double
    let power_mw: Double
    let disk_read_kbs: Double
    let disk_write_kbs: Double
}

struct ProcRow: Codable, Identifiable {
    let pid: Int32
    let name: String
    let cpu: Double
    let rss_mb: Double
    let read_kbs: Double
    let write_kbs: Double

    var id: Int32 { pid }
}

struct Overview: Codable {
    let now: NowSnapshot
    let procs: [ProcRow]
}

struct AlertRow: Codable, Identifiable {
    let id: Int64
    let ts: Double
    let level: String
    let rule: String
    let detail: String
}

struct AlertsResponse: Codable {
    let alerts: [AlertRow]
}
