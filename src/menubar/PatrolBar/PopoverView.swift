import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var model: MonitorModel

    private let bg = Color(red: 0.075, green: 0.082, blue: 0.094)
    private let dim = Color.white.opacity(0.34)
    private let bodyColor = Color.white.opacity(0.9)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            metrics
            divider
            procsBlock
            divider
            alertsBlock
            divider
            footer
        }
        .frame(width: 304)
        .background(bg)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
    }

    // MARK: - 指标

    private var metrics: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            alignment: .leading,
            spacing: 12
        ) {
            metric(tempText, unit: "°C", label: "温度", tint: tempTint)
            metric(loadText, unit: "", label: "load", tint: bodyColor)
            metric(memText, unit: "GB", label: "内存", tint: bodyColor)
            metric(swapText, unit: "MB", label: "swap", tint: bodyColor)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private func metric(_ value: String, unit: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(dim)
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 进程

    private var procsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("进程").font(.system(size: 10, weight: .medium)).foregroundStyle(dim)
                Spacer(minLength: 8)
                Text("CPU").font(.system(size: 10)).foregroundStyle(dim).frame(width: 38, alignment: .trailing)
                Text("内存").font(.system(size: 10)).foregroundStyle(dim).frame(width: 48, alignment: .trailing)
            }
            if model.procs.isEmpty {
                Text(model.reachable ? "—" : "面板未运行")
                    .font(.system(size: 11))
                    .foregroundStyle(dim)
            } else {
                ForEach(model.procs) { p in
                    HStack(spacing: 0) {
                        HStack(spacing: 4) {
                            Text(p.name)
                                .font(.system(size: 11))
                                .foregroundStyle(bodyColor)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(String(p.pid))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(dim)
                                .fixedSize()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%.0f%%", p.cpu))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(p.cpu >= 80 ? Color.orange : bodyColor.opacity(0.85))
                            .frame(width: 38, alignment: .trailing)
                        Text(rssText(p.rss_mb))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(bodyColor.opacity(0.6))
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 告警

    private var alertsBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("告警").font(.system(size: 10, weight: .medium)).foregroundStyle(dim)
            if model.alerts.isEmpty {
                Text("暂无").font(.system(size: 11)).foregroundStyle(dim)
            } else {
                ForEach(model.alerts) { a in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(a.level == "critical" ? Color.red : Color.orange)
                            .frame(width: 4, height: 4)
                        Text(clockText(a.ts))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(dim)
                        Text(a.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(bodyColor.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                if let url = URL(string: "http://127.0.0.1:8787/") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("打开完整面板")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(bodyColor)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("退出")
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .foregroundStyle(dim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 数值

    private var tempText: String {
        guard let now = model.now, now.temp_c > 0 else { return "—" }
        return String(format: "%.0f", now.temp_c)
    }

    private var tempTint: Color {
        guard let now = model.now else { return dim }
        if now.temp_c >= 85 { return .red }
        if now.temp_c >= 78 { return .orange }
        return bodyColor
    }

    private var loadText: String {
        guard let now = model.now else { return "—" }
        return String(format: "%.1f", now.load1)
    }

    private var memText: String {
        guard let now = model.now else { return "—" }
        return String(format: "%.1f", now.mem_used_mb / 1024)
    }

    private var swapText: String {
        guard let now = model.now else { return "—" }
        return String(format: "%.0f", now.swap_used_mb)
    }

    private func rssText(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1fG", mb / 1024) : String(format: "%.0fM", mb)
    }

    private func clockText(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}
