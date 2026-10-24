#!/usr/bin/env python3
"""本地只读面板：127.0.0.1 上一个 HTTP 服务 + JSON API。

只读同一个 SQLite；不写数据。默认端口 8787。
"""
import json
import os
import sqlite3
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
DB_PATH = os.path.join(PROJECT, "data", "patrol.db")
PORT = int(os.environ.get("PATROL_PORT", "8787"))


def db():
    conn = sqlite3.connect(DB_PATH, timeout=5)
    conn.row_factory = sqlite3.Row
    return conn


def rows(cur):
    return [dict(r) for r in cur.fetchall()]


def api(path, q):
    conn = db()
    try:
        if path == "/api/overview":
            s = conn.execute("SELECT * FROM samples ORDER BY ts DESC LIMIT 1").fetchone()
            latest = dict(s) if s else {}
            # 进程明细每 30 秒才落库，取最近一批即可
            p = conn.execute("SELECT ts FROM procs ORDER BY ts DESC LIMIT 1").fetchone()
            procs = rows(conn.execute(
                "SELECT pid,name,cpu,rss_mb,read_kbs,write_kbs FROM procs WHERE ts=? ORDER BY cpu DESC LIMIT 15",
                (p["ts"],))) if p else []
            return {"now": latest, "procs": procs}

        if path == "/api/series":
            seconds = int(q.get("seconds", ["3600"])[0])
            pts = rows(conn.execute(
                "SELECT ts,load1,cpu_busy,mem_used_mb,swap_used_mb,temp_c FROM samples "
                "WHERE ts >= strftime('%s','now') - ? ORDER BY ts ASC", (seconds,)))
            return {"points": pts}

        if path == "/api/procs":
            seconds = int(q.get("seconds", ["300"])[0])
            rows_ = rows(conn.execute(
                "SELECT name, MAX(cpu) mx_cpu, MAX(rss_mb) mx_rss, SUM(write_kbs)*30/1024.0 write_mb, "
                "COUNT(*) n FROM procs WHERE ts >= strftime('%s','now') - ? GROUP BY name "
                "ORDER BY mx_cpu DESC LIMIT 20", (seconds,)))
            return {"procs": rows_}

        if path == "/api/writers":
            seconds = int(q.get("seconds", ["900"])[0])
            rows_ = rows(conn.execute(
                "SELECT name, SUM(write_kbs)*30/1024.0 write_mb, SUM(read_kbs)*30/1024.0 read_mb "
                "FROM procs WHERE ts >= strftime('%s','now') - ? GROUP BY name "
                "HAVING write_mb > 0 ORDER BY write_mb DESC LIMIT 15", (seconds,)))
            return {"writers": rows_}

        if path == "/api/paths":
            rows_ = rows(conn.execute(
                "SELECT path, MIN(bytes) b0, MAX(bytes) b1 FROM paths WHERE ts >= strftime('%s','now') - ? "
                "GROUP BY path", (900,)))
            return {"paths": rows_}

        if path == "/api/alerts":
            return {"alerts": rows(conn.execute(
                "SELECT id,ts,level,rule,detail FROM alerts ORDER BY id DESC LIMIT 40"))}

        return {"error": "not found"}
    finally:
        conn.close()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/":
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if u.path.startswith("/api/"):
            try:
                data = api(u.path, parse_qs(u.query))
                body = json.dumps(data, ensure_ascii=False).encode()
                self.send_response(200)
            except Exception as e:
                body = json.dumps({"error": f"{type(e).__name__}: {e}"}).encode()
                self.send_response(500)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()


def main():
    if not os.path.exists(DB_PATH):
        print(f"database not found: {DB_PATH}", file=sys.stderr)
        return 1
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"patrol panel: http://127.0.0.1:{PORT}/", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
