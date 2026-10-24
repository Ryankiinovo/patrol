"""进程级指标采集：直接调用 libproc，零外部依赖。

macOS 的 proc_pid_rusage 提供每个进程的累计 CPU 时间、常驻内存、
磁盘读写字节数，做两次差分即可得到瞬时占用——比 ps 精确，也比
top 便宜（top -l 1 要 1 秒 CPU，这里只要几十微秒）。
"""
import ctypes
import os
import time
from dataclasses import dataclass

PROC_ALL_PIDS = 1
RUSAGE_INFO_V6 = 6
_BUF = 1024

_libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
_libproc.proc_listpids.restype = ctypes.c_int
_libproc.proc_pidpath.restype = ctypes.c_int
_libproc.proc_pid_rusage.restype = ctypes.c_int


@dataclass
class ProcStat:
    pid: int
    name: str
    path: str
    cpu_ns: int        # user + system，纳秒
    rss_bytes: int
    read_bytes: int    # 累计磁盘读
    write_bytes: int   # 累计磁盘写
    at: float


def list_pids():
    """枚举当前所有进程 pid。"""
    size = 4096
    while True:
        buf = (ctypes.c_int * size)()
        n = _libproc.proc_listpids(PROC_ALL_PIDS, 0, buf, ctypes.sizeof(buf))
        if n <= 0:
            return []
        if n < ctypes.sizeof(buf):
            return [buf[i] for i in range(n // 4)]
        size *= 2


def process_path(pid):
    buf = ctypes.create_string_buffer(4096)
    n = _libproc.proc_pidpath(ctypes.c_int(pid), buf, ctypes.sizeof(buf))
    if n <= 0:
        return ""
    return buf.value.decode("utf-8", "replace")


def read(pid):
    """读取单个进程的累计指标；进程已退出时返回 None。"""
    buf = ctypes.create_string_buffer(_BUF)
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(RUSAGE_INFO_V6), buf) != 0:
        return None
    q = [int.from_bytes(buf.raw[i * 8:(i + 1) * 8], "little") for i in range(40)]
    path = process_path(pid)
    return ProcStat(
        pid=pid,
        name=os.path.basename(path) or "?",
        path=path,
        cpu_ns=q[2] + q[3],       # ri_user_time + ri_system_time
        rss_bytes=q[8],           # ri_resident_size
        read_bytes=q[18],         # ri_diskio_bytesread
        write_bytes=q[19],        # ri_diskio_byteswritten
        at=time.monotonic(),
    )


def snapshot():
    """一次性读取全部进程；返回 {pid: ProcStat}。"""
    out = {}
    for pid in list_pids():
        if pid <= 0:
            continue
        s = read(pid)
        if s is not None:
            out[pid] = s
    return out
