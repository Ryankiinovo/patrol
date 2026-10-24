"""系统级指标：负载、内存、swap、温度、磁盘吞吐。

全部走廉价的数据源：loadavg 走 os，内存走 vm_stat（约 3ms），
温度走 smctemp（约 10ms）。powermetrics 需要 root，不采用。
"""
import ctypes
import os
import re
import shutil
import subprocess
import time

# smctemp 不一定是 /opt/homebrew/bin：Intel Mac 在 /usr/local/bin，也可能在 PATH 其他位置
_SMCTEMP = shutil.which("smctemp") or "/opt/homebrew/bin/smctemp"
_timebase_lock = None
_timebase = None


def timebase():
    """返回 mach absolute time 的纳秒倍率 (numer/denom)。"""
    global _timebase
    if _timebase is not None:
        return _timebase
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    numer = ctypes.c_uint32()
    denom = ctypes.c_uint32()
    libc.mach_timebase_info(ctypes.byref(numer), ctypes.byref(denom))
    _timebase = (numer.value / denom.value) if denom.value else 1.0
    return _timebase


def ticks_to_seconds(ticks):
    """rusage 的时间单位是 mach absolute time ticks。"""
    # 24 MHz 时钟：1 tick = 1/24e6 秒。用 timebase 兜底更稳。
    return ticks / 24_000_000.0


def load():
    return os.getloadavg()


_last_page = {"ts": None, "in": 0, "out": 0}


def memory():
    """返回 (已用 MB, 压力 MB, swap 已用 MB, 磁盘读 KB/s, 磁盘写 KB/s)。

    磁盘吞吐用 vm_stat 的 pageins/pageouts 差分（页大小 16 KB），
    比 iostat 便宜（3 ms vs 1 s）且能区分读写。
    """
    out = subprocess.run(["/usr/bin/vm_stat"], capture_output=True, text=True, timeout=5).stdout
    page = 16384
    m = re.search(r"page size of (\d+) bytes", out)
    if m:
        page = int(m.group(1))

    def grab(key):
        mm = re.search(rf"^{key}:\s+(\d+)\.", out, re.M)
        return int(mm.group(1)) if mm else 0

    active = grab("Pages active")
    wired = grab("Pages wired down")
    compressor = grab("Pages occupied by compressor")
    pageins = grab("Pageins")
    pageouts = grab("Pageouts")
    # macOS 口径：已用 = active + wired + 压缩内存（inactive 是缓存，算可用）
    used_mb = (active + wired + compressor) * page / 1048576
    pressure_mb = (wired + compressor) * page / 1048576

    now = time.monotonic()
    rd_kbs = wr_kbs = 0.0
    prev = _last_page
    if prev["ts"] is not None and now > prev["ts"]:
        dt = now - prev["ts"]
        rd_kbs = max(0, pageins - prev["in"]) * page / 1024.0 / dt
        wr_kbs = max(0, pageouts - prev["out"]) * page / 1024.0 / dt
    _last_page.update({"ts": now, "in": pageins, "out": pageouts})

    swap = subprocess.run(["/usr/sbin/sysctl", "-n", "vm.swapusage"],
                          capture_output=True, text=True, timeout=5).stdout
    sm = re.search(r"used = ([\d.]+)M", swap)
    swap_mb = float(sm.group(1)) if sm else 0.0
    return used_mb, pressure_mb, swap_mb, rd_kbs, wr_kbs


def temperature():
    """CPU 温度（摄氏度）；smctemp 不可用时返回 None。"""
    if not os.path.exists(_SMCTEMP):
        return None
    try:
        r = subprocess.run([_SMCTEMP, "-c", "-i25", "-n180", "-f"],
                           capture_output=True, text=True, timeout=5)
        vals = [float(x) for x in re.findall(r"-?\d+\.\d+", r.stdout)]
        if not vals:
            return None
        # 多传感器取最大值（最热核心最能代表散热压力）
        return max(v for v in vals if 0 < v < 120)
    except Exception:
        return None


def watch_paths(roots):
    """统计关键路径的字节数，只 stat 不读内容。"""
    rows = []
    for root in roots:
        if os.path.isfile(root):
            try:
                rows.append((root, os.path.getsize(root)))
            except OSError:
                pass
            continue
        if not os.path.isdir(root):
            continue
        total = 0
        try:
            for dirpath, _dirnames, filenames in os.walk(root):
                for fn in filenames:
                    try:
                        total += os.path.getsize(os.path.join(dirpath, fn))
                    except OSError:
                        pass
        except OSError:
            pass
        rows.append((root, total))
    return rows
