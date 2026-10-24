#!/usr/bin/env python3
"""Patrol 采集守护进程。

每 5 秒采一次进程级指标（CPU / 内存 / 磁盘读写），每 30 秒采一次
系统级指标（温度 / 内存压力 / 磁盘吞吐）。自身开销目标 < 0.5% 单核。

用法：
  python3 monitor/collector.py            # 前台运行
  python3 monitor/collector.py --once     # 采一次就退出（自检）
"""
import argparse
import collections
import json
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rusage
import store as store_mod
import system

HOME = os.path.expanduser("~")
PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(PROJECT, "data", "patrol.db")
LOG_PATH = os.path.join(PROJECT, "logs", "collector.log")

SAMPLE_INTERVAL = 5      # 秒：进程级采样
SYSTEM_INTERVAL = 30     # 秒：系统级采样（温度/内存/磁盘）
PROC_PERSIST_INTERVAL = 30  # 秒：进程明细落库间隔
TOP_N = 12               # 落库的 Top 进程数
KEEP_DAYS = 7

# 需要单独盯住的进程（按路径关键字匹配）。
# 下面是作者机器上的默认值，换成你自己要盯的进程即可；留空也能正常跑。
WATCHED = [
    ("DSH", ["DeepSeek Harness", "/Applications/DeepSeek Harness.app"]),
    ("billion-context", ["billion-context"]),
    ("DSHWidget", ["DSHWidget.app"]),
    ("cloudflared", ["cloudflared"]),
]

# 内存合计告警盯的进程组（名字需与 WATCHED 里的第一个字段一致）
COMPANIONS = ("DSH", "billion-context", "DSHWidget")

# 需要盯住总大小的目录或文件（同样是示例值，不存在时会被跳过）。
WATCH_PATHS = [
    os.path.join(HOME, ".dsh", "sessions"),
    os.path.join(HOME, ".local", "state", "billion-context", "bili.log"),
    os.path.join(HOME, ".dsh", "widget-events.log"),
    os.path.join(HOME, ".dsh", "storages"),
]

RULES = [
    # (规则名, 级别, 说明)
    ("proc_cpu", "warning", "单进程持续高 CPU"),
    ("disk_write", "warning", "单进程持续写盘"),
    ("mem_pressure", "warning", "关注进程组内存过高"),
    ("temp_high", "critical", "机身温度过高"),
    ("swap_high", "warning", "swap 使用过高"),
    ("session_growth", "warning", "会话目录快速增长"),
    ("load_high", "warning", "系统负载过高"),
]

ALERT_COOLDOWN = 600  # 同一规则 10 分钟内不重复通知


def log(msg):
    line = time.strftime("%Y-%m-%dT%H:%M:%S") + " " + msg
    print(line, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > 5 * 1024 * 1024:
            os.replace(LOG_PATH, LOG_PATH + ".1")
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def notify(title, message, sound="Basso"):
    """macOS 通知；失败不影响采集。"""
    script = (
        'display notification %s with title %s sound name %s'
        % (json.dumps(message, ensure_ascii=False),
           json.dumps(title, ensure_ascii=False),
           json.dumps(sound))
    )
    try:
        subprocess.run(["/usr/bin/osascript", "-e", script], timeout=5,
                       capture_output=True)
    except Exception:
        pass


def classify(proc):
    for label, keys in WATCHED:
        for k in keys:
            if k in proc.path:
                return label
    return None


class Monitor:
    def __init__(self, db_path=DB_PATH):
        self.store = store_mod.Store(db_path)
        self.prev = {}
        self.prev_ts = None
        self.history = collections.defaultdict(lambda: collections.deque(maxlen=80))
        self.last_alert = {}
        self.system_cache = {"temp_c": None, "mem": (0, 0, 0), "disk": (0.0, 0.0)}
        self.last_system = 0.0
        # 首次落库推迟一个周期，避免把「无差分」的首帧全零数据写进库
        self.last_proc_persist = time.monotonic()
        self.path_prev = {}
        self.path_history = collections.deque(maxlen=60)
        self.started = time.time()
        self.running = True

    # ---------- 采样 ----------
    def sample_once(self):
        now = time.monotonic()
        cur = rusage.snapshot()
        dt = (now - self.prev_ts) if self.prev_ts else SAMPLE_INTERVAL
        dt = max(dt, 0.2)

        procs = []
        total_cpu = 0.0
        total_read = 0.0
        total_write = 0.0
        for pid, s in cur.items():
            old = self.prev.get(pid)
            if old is None:
                cpu = 0.0
                rd = wr = 0.0
            else:
                cpu = (s.cpu_ns - old.cpu_ns) / 24_000_000.0 / dt * 100.0
                rd = max(0, s.read_bytes - old.read_bytes) / dt / 1024.0
                wr = max(0, s.write_bytes - old.write_bytes) / dt / 1024.0
            cpu = max(0.0, min(cpu, 1600.0))
            total_cpu += cpu
            total_read += rd
            total_write += wr
            label = classify(s)
            procs.append({
                "pid": pid,
                "name": label or s.name,
                "cpu": cpu,
                "rss_mb": s.rss_bytes / 1048576.0,
                "read_kbs": rd,
                "write_kbs": wr,
                "power": 0.0,
                "path": s.path,
            })

        self.prev = cur
        self.prev_ts = now

        procs.sort(key=lambda p: p["cpu"], reverse=True)
        top = procs[:TOP_N]
        # 写盘大户和内存大户不一定在 CPU Top 里，单独算
        writers = sorted(procs, key=lambda p: p["write_kbs"], reverse=True)[:5]
        watched_rss = sum(p["rss_mb"] for p in procs
                          if p["name"] in COMPANIONS)

        load1, load5, load15 = system.load()
        if now - self.last_system >= SYSTEM_INTERVAL:
            used, pressure, swap, rd_kbs, wr_kbs = system.memory()
            self.system_cache["mem"] = (used, pressure, swap)
            self.system_cache["temp_c"] = system.temperature()
            self.system_cache["disk"] = (rd_kbs, wr_kbs)
            self.last_system = now
            for path, size in system.watch_paths(WATCH_PATHS):
                self.path_prev[path] = size
            self.path_history.append((time.time(), dict(self.path_prev)))

        used, pressure, swap = self.system_cache["mem"]
        temp = self.system_cache["temp_c"]
        rd, wr = self.system_cache["disk"]

        sample = {
            "ts": time.time(),
            "load1": load1, "load5": load5, "load15": load15,
            "cpu_busy": min(total_cpu, 100.0 * (os.cpu_count() or 1)),
            "mem_used_mb": used, "mem_pressure_mb": pressure,
            "swap_used_mb": swap, "temp_c": temp or 0.0,
            "power_mw": 0.0,
            "disk_read_kbs": rd, "disk_write_kbs": wr,
        }
        self.store.add_sample(sample)

        if now - self.last_proc_persist >= PROC_PERSIST_INTERVAL:
            ts = sample["ts"]
            persist = {p["pid"]: p for p in top}
            for p in writers:
                persist.setdefault(p["pid"], p)
            self.store.add_procs(ts, list(persist.values()))
            if self.path_prev:
                self.store.add_paths(ts, list(self.path_prev.items()))
            self.last_proc_persist = now
            self.store.commit()

        self.evaluate(sample, top, writers, watched_rss, dt)
        return sample, top

    # ---------- 规则 ----------
    def push(self, key, value):
        self.history[key].append(value)

    def sustained(self, key, threshold, count, window_seconds=None):
        h = self.history[key]
        if len(h) < count:
            return False
        recent = list(h)[-count:]
        return sum(1 for v in recent if v >= threshold) >= count

    def fire(self, rule, level, detail, top):
        now = time.time()
        if now - self.last_alert.get(rule, 0) < ALERT_COOLDOWN:
            return
        self.last_alert[rule] = now
        snap = [{"name": p["name"], "pid": p["pid"], "cpu": round(p["cpu"], 1),
                 "rss_mb": round(p["rss_mb"]), "write_kbs": round(p["write_kbs"])}
                for p in top[:5]]
        self.store.add_alert(level, rule, detail, snap)
        log(f"ALERT {level} {rule}: {detail}")
        notify("Patrol · " + rule, detail,
               "Basso" if level == "warning" else "Sosumi")

    def evaluate(self, sample, top, writers, watched_rss, dt):
        # 单进程 CPU：连续 3 次（约 15 秒）≥ 200%
        heavy = [p for p in top if p["cpu"] >= 200]
        for p in top:
            self.push("cpu:" + p["name"], p["cpu"])
        if heavy:
            name = heavy[0]["name"]
            if self.sustained("cpu:" + name, 200, 3):
                self.fire("proc_cpu", "warning",
                          f"{name}（pid {heavy[0]['pid']}）持续占用 {heavy[0]['cpu']:.0f}% CPU", top)

        # 单进程写盘：连续 3 次 ≥ 5120 KB/s（5 MB/s）
        for p in writers:
            self.push("wr:" + p["name"], p["write_kbs"])
        for p in writers:
            if p["write_kbs"] >= 5120 and self.sustained("wr:" + p["name"], 5120, 3):
                self.fire("disk_write", "warning",
                          f"{p['name']}（pid {p['pid']}）持续写入 {p['write_kbs'] / 1024:.1f} MB/s", top)
                break

        # DSH 相关进程内存
        if watched_rss >= 3072:
            self.fire("mem_pressure", "warning",
                      f"关注进程合计 {watched_rss / 1024:.1f} GB 内存", top)

        # 温度
        if sample["temp_c"] and sample["temp_c"] >= 90:
            self.push("temp", sample["temp_c"])
            if self.sustained("temp", 90, 12):
                self.fire("temp_high", "critical", f"CPU 温度 {sample['temp_c']:.0f}°C 持续 1 分钟", top)
        else:
            self.push("temp", sample["temp_c"] or 0)

        # swap
        if sample["swap_used_mb"] >= 1536:
            self.fire("swap_high", "warning", f"swap 已用 {sample['swap_used_mb']:.0f} MB", top)

        # 会话目录增长：5 分钟内 ≥ 50 MB
        if len(self.path_history) >= 2:
            t0, snap0 = self.path_history[0]
            t1, snap1 = self.path_history[-1]
            if t1 - t0 >= 240:
                for path in snap1:
                    delta = snap1[path] - snap0.get(path, 0)
                    if delta >= 50 * 1024 * 1024:
                        self.fire("session_growth", "warning",
                                  f"{os.path.basename(path)} 在 {(t1 - t0) / 60:.0f} 分钟内增长 {delta / 1048576:.0f} MB", top)

        # load
        self.push("load1", sample["load1"])
        if self.sustained("load1", 12, 36):
            self.fire("load_high", "warning", f"load1={sample['load1']:.1f} 持续 3 分钟", top)

    def run(self):
        log(f"collector started (pid {os.getpid()}, db {DB_PATH})")
        last_prune = 0
        while self.running:
            try:
                self.sample_once()
            except Exception as e:
                log(f"sample error: {type(e).__name__}: {e}")
            if time.time() - last_prune > 3600:
                try:
                    self.store.prune(KEEP_DAYS)
                    last_prune = time.time()
                    log("pruned old samples")
                except Exception as e:
                    log(f"prune error: {e}")
            time.sleep(SAMPLE_INTERVAL)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true", help="采样一次后退出")
    ap.add_argument("--db", default=DB_PATH)
    args = ap.parse_args()

    mon = Monitor(args.db)
    if args.once:
        # 需要两次采样才有差分
        mon.prev = rusage.snapshot()
        mon.prev_ts = time.monotonic()
        time.sleep(2)
        sample, top = mon.sample_once()
        print(json.dumps({"sample": sample, "top": top[:5]}, ensure_ascii=False, indent=2))
        return

    def stop(_signum, _frame):
        mon.running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    mon.run()


if __name__ == "__main__":
    main()
