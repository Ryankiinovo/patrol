# Patrol

[English](README.md) · [简体中文](README.zh-CN.md)

A small, always-on resource monitor for macOS. Every 5 seconds it samples per-process CPU, memory and disk I/O; every 30 seconds it samples CPU temperature, memory pressure, swap and load. Everything lands in SQLite, seven days are kept, and when something starts eating the machine a normal macOS notification shows up.

I wrote it after a Node process spent hours writing 19 MB/s to disk and nothing on the system said a word about it.

![Patrol panel](assets/panel.png)

*Read-only web panel on `http://127.0.0.1:8787` — plain HTML and canvas, no framework, no CDN.*

![Patrol menu bar](assets/menubar.png)

*Optional menu bar app. It shows the current CPU temperature (white, orange at 78 °C, red at 85 °C) and expands into a popover.*

## What it measures

| Metric | Source | Notes |
|---|---|---|
| Per-process CPU, RSS, disk read/write | `proc_pid_rusage` (flavor 6) through `ctypes` | No root required. CPU time comes as mach absolute ticks and is converted with a fixed 24 MHz assumption. |
| System memory | `vm_stat` | Used = active + wired + compressor; inactive counts as cache, matching how macOS reports memory pressure. |
| Disk throughput | `vm_stat` pageins/pageouts delta | Chosen over `iostat`: same 3 ms cost as the rest of the sample, and it separates reads from writes. |
| Swap | `sysctl -n vm.swapusage` | |
| CPU temperature | `smctemp` (Homebrew) | Max across sensors. `powermetrics` would be more accurate but needs root. |
| Watched path growth | `os.walk` | Sizes only, file contents are never read. |

## Alert rules

| Rule | Threshold | Must hold for | Level |
|---|---|---|---|
| `proc_cpu` | one process ≥ 200% CPU | 3 samples (~15 s) | warning |
| `disk_write` | one process ≥ 5 MB/s | 3 samples | warning |
| `mem_pressure` | watched process group ≥ 3 GB RSS | 1 sample | warning |
| `temp_high` | CPU ≥ 90 °C | 12 samples (~1 min) | critical |
| `swap_high` | swap used ≥ 1.5 GB | 1 sample | warning |
| `session_growth` | a watched path grows ≥ 50 MB in 5 min | — | warning |
| `load_high` | load1 ≥ 12 | 36 samples (~3 min) | warning |

The same rule firing for the same process is throttled to once every 10 minutes. Notifications use `osascript display notification`, so they need no extra permissions.

## Requirements

| | |
|---|---|
| macOS | 14 or newer |
| Python | 3.9+ — standard library only, nothing to `pip install` |
| [smctemp](https://github.com/narugit/smctemp) | `brew tap narugit/tap && brew install smctemp` — required for temperature, everything else works without it |
| Xcode Command Line Tools | only for the menu bar app (`swiftc`) |

## Install

```bash
git clone https://github.com/Ryankiinovo/patrol.git
cd patrol
./bin/install.sh
open http://127.0.0.1:8787/
```

`install.sh` writes three LaunchAgents to `~/Library/LaunchAgents/` — collector, web panel and menu bar — with `RunAtLoad` and `KeepAlive`, so they start at login and come back within seconds if they crash. It is idempotent: run it again after pulling.

```bash
./bin/install-bar.sh      # rebuild and reinstall only the menu bar app
./bin/uninstall-bar.sh    # stop the menu bar app, keep monitoring
./bin/uninstall.sh        # stop everything; data/ is left on disk
```

## Configuration

Everything lives at the top of `monitor/collector.py`:

```python
SAMPLE_INTERVAL = 5         # seconds between process samples
SYSTEM_INTERVAL = 30        # seconds between temperature/memory samples
PROC_PERSIST_INTERVAL = 30  # seconds between inserts
TOP_N = 12                  # processes stored per insert
KEEP_DAYS = 7               # retention
ALERT_COOLDOWN = 600        # per-rule throttle

WATCHED = [                 # (label, path keywords to match)
    ("DSH", ["DeepSeek Harness"]),
    ...
]
WATCH_PATHS = [...]         # directories or files whose total size is tracked
COMPANIONS = (...)          # which of the above are summed for the memory alert
```

The defaults point at my own toolchain (DeepSeek Harness, a log file, a session directory). Replace them with whatever you want watched — the monitor works fine with the lists empty, you just lose the per-path growth alert.

Thresholds are hard-coded in `Monitor.evaluate()`; they are a handful of integers, easy to change.

## HTTP API

The panel is read-only and bound to loopback (`127.0.0.1`, override the port with `PATROL_PORT`). All endpoints return JSON:

| Endpoint | Returns |
|---|---|
| `/api/overview` | latest sample, the most recent process batch, recent alerts |
| `/api/series?seconds=3600` | time series for the panel charts |
| `/api/procs` | recent process rows |
| `/api/writers` | top writers in the latest batch |
| `/api/paths` | watched path sizes |
| `/api/alerts` | recent alerts |

## Overhead

Measured on a MacBook Air M2, after 18 minutes of running:

| | |
|---|---|
| CPU | 0.0% for the collector, 0.0% for the panel, 0.0–0.7% for the menu bar app |
| Memory | ~20 MB collector, ~20 MB panel, ~75 MB menu bar |
| Database growth | ~6 MB/day; with 7-day retention it levels off around 50 MB |
| Disk writes | ~150 MB/day including SQLite WAL churn |
| Logs | ~11 KB/day — lines are only written when a rule fires |

## Limitations

- macOS only. The collector is built on libproc, `vm_stat` and `smctemp`.
- CPU time is converted assuming a 24 MHz mach timebase. This holds on Apple Silicon; on other hardware the percentages would be off by a constant factor — `monitor/system.py` already reads the real timebase, switch `ticks_to_seconds` over if you need portability.
- Energy (mW) is always 0: `proc_pid_rusage` returns 0 for that field without root.
- The web panel has no authentication. It binds to loopback; do not expose it.
- Not a process supervisor. It watches; it does not kill anything.

## Layout

```text
monitor/     collector, libproc bindings, system metrics, SQLite store
web/         read-only HTTP panel (single Python file + one HTML page)
src/menubar/ SwiftUI menu bar app and its build script
bin/         install / uninstall scripts and LaunchAgent templates
data/  logs/ runtime state (git-ignored)
```

## License

MIT.
