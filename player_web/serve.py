#!/usr/bin/env python3
"""Static server with HTTP Range support (python3 -m http.server has none, so seeking in the 200 MB mp4 would fail).
Serves the project root.  Usage: python3 player_web/serve.py [port]   ->  http://localhost:8000/player_web/index.html?export=../export/alpine_summit_10m"""
import os, re, sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

class H(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=ROOT, **k)
    def log_message(self, *a): pass
    def end_headers(self):
        self.send_header("Accept-Ranges", "bytes"); self.send_header("Cache-Control", "no-cache")
        super().end_headers()
    def send_head(self):
        rng = self.headers.get("Range")
        path = self.translate_path(self.path)
        if not rng or not os.path.isfile(path): return super().send_head()
        m = re.match(r"bytes=(\d*)-(\d*)", rng)
        size = os.path.getsize(path)
        a = int(m.group(1)) if m.group(1) else max(0, size - int(m.group(2)))
        b = int(m.group(2)) if m.group(1) and m.group(2) else size - 1
        b = min(b, size - 1)
        if a > b: self.send_error(416); return None
        f = open(path, "rb"); f.seek(a)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {a}-{b}/{size}")
        self.send_header("Content-Length", str(b - a + 1))
        self.end_headers()
        self._left = b - a + 1
        return f
    def do_POST(self):  # debug only: PLAYER_DEBUG=1 enables POST /__save/<name>.png -> player_web/verify/<name>.png
        m = re.fullmatch(r"/__save/([\w.-]+\.png)", self.path)
        if not (os.environ.get("PLAYER_DEBUG") and m): self.send_error(403); return
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        os.makedirs(os.path.join(ROOT, "player_web", "verify"), exist_ok=True)
        open(os.path.join(ROOT, "player_web", "verify", m.group(1)), "wb").write(data)
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def copyfile(self, src, dst):
        left = getattr(self, "_left", None); self._left = None
        try:
            if left is None: return super().copyfile(src, dst)
            while left > 0:
                buf = src.read(min(1 << 20, left))
                if not buf: break
                dst.write(buf); left -= len(buf)
        except (BrokenPipeError, ConnectionResetError): pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    print(f"serving {ROOT} on http://localhost:{port}/player_web/index.html?export=../export/alpine_summit_10m")
    ThreadingHTTPServer(("", port), H).serve_forever()
