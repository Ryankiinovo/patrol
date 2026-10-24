"""SQLite 存储层：定长采样表 + 保留策略。"""
import json
import os
import sqlite3
import time

SCHEMA = """
CREATE TABLE IF NOT EXISTS samples (
  ts REAL PRIMARY KEY,
  load1 REAL, load5 REAL, load15 REAL,
  cpu_busy REAL, mem_used_mb REAL, mem_pressure_mb REAL,
  swap_used_mb REAL, temp_c REAL, power_mw REAL,
  disk_read_kbs REAL, disk_write_kbs REAL
);
CREATE TABLE IF NOT EXISTS procs (
  ts REAL, pid INTEGER, name TEXT, cpu REAL, rss_mb REAL,
  read_kbs REAL, write_kbs REAL, power REAL,
  PRIMARY KEY (ts, pid)
);
CREATE INDEX IF NOT EXISTS idx_procs_ts ON procs(ts);
CREATE TABLE IF NOT EXISTS paths (
  ts REAL, path TEXT, bytes INTEGER,
  PRIMARY KEY (ts, path)
);
CREATE TABLE IF NOT EXISTS alerts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts REAL, level TEXT, rule TEXT, detail TEXT, snapshot TEXT
);
CREATE INDEX IF NOT EXISTS idx_alerts_ts ON alerts(ts);
"""


class Store:
    def __init__(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.path = path
        self.db = sqlite3.connect(path, timeout=10)
        self.db.executescript(SCHEMA)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=NORMAL")
        self.db.commit()

    def add_sample(self, row):
        self.db.execute(
            "INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (row["ts"], row["load1"], row["load5"], row["load15"], row["cpu_busy"],
             row["mem_used_mb"], row["mem_pressure_mb"], row["swap_used_mb"],
             row["temp_c"], row["power_mw"], row["disk_read_kbs"], row["disk_write_kbs"]),
        )

    def add_procs(self, ts, procs):
        self.db.executemany(
            "INSERT OR REPLACE INTO procs VALUES (?,?,?,?,?,?,?,?)",
            [(ts, p["pid"], p["name"], p["cpu"], p["rss_mb"],
              p["read_kbs"], p["write_kbs"], p["power"]) for p in procs],
        )

    def add_paths(self, ts, rows):
        self.db.executemany(
            "INSERT OR REPLACE INTO paths VALUES (?,?,?)",
            [(ts, path, size) for path, size in rows],
        )

    def add_alert(self, level, rule, detail, snapshot):
        self.db.execute(
            "INSERT INTO alerts (ts, level, rule, detail, snapshot) VALUES (?,?,?,?,?)",
            (time.time(), level, rule, detail, json.dumps(snapshot, ensure_ascii=False)),
        )
        self.db.commit()

    def commit(self):
        self.db.commit()

    def prune(self, keep_days=7):
        cutoff = time.time() - keep_days * 86400
        self.db.execute("DELETE FROM samples WHERE ts < ?", (cutoff,))
        self.db.execute("DELETE FROM procs WHERE ts < ?", (cutoff,))
        self.db.execute("DELETE FROM paths WHERE ts < ?", (cutoff,))
        self.db.execute("DELETE FROM alerts WHERE ts < ?", (cutoff,))
        self.db.commit()
        self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        self.db.commit()

    def recent(self, table, seconds, limit=5000):
        rows = self.db.execute(
            f"SELECT * FROM {table} WHERE ts >= ? ORDER BY ts ASC LIMIT ?",
            (time.time() - seconds, limit),
        ).fetchall()
        return rows

    def alerts(self, limit=50):
        return self.db.execute(
            "SELECT id, ts, level, rule, detail, snapshot FROM alerts ORDER BY id DESC LIMIT ?",
            (limit,),
        ).fetchall()
