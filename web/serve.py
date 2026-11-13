#!/usr/bin/env python3
"""Pos XY local web viewer.

    python3 web/serve.py                 # serves http://127.0.0.1:8765 and opens your browser
    python3 web/serve.py --dir ~/Desktop # look for exports somewhere other than ~/Downloads

Python standard library only. Listens on 127.0.0.1, so nothing else on your network can reach it.
The page decrypts files in your browser: your passphrase never reaches this server, and this
server never sends anything anywhere. The only outside requests are map-tile images the browser
loads from tile.openstreetmap.org, and the Content-Security-Policy below forbids the page from
contacting anything else.
"""
import argparse
import http.server
import json
import os
import pathlib
import sys
import urllib.parse
import webbrowser

STATIC = pathlib.Path(__file__).resolve().parent / "static"
MAX_FILE = 512 * 1024 * 1024

CSP = "; ".join([
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' data: https://tile.openstreetmap.org",
    "connect-src 'self'",
    "font-src 'self'",
    "form-action 'none'",
    "frame-ancestors 'none'",
    "base-uri 'none'",
])


FOREIGN_NAMES = ("timeline", "location-history", "records", "semantic")
FOREIGN_MARKERS = (b'"semanticSegments"', b'"rawSignals"', b'"latitudeE7"', b'"timelinePath"', b'"visit"', b'"activity"')


def looks_like_export(path: pathlib.Path) -> bool:
    """Pos XY exports (.pxy, .json, .jsonl), GPX files, and Google Maps Timeline / Takeout JSON."""
    name = path.name.lower()
    if name.endswith((".pxy", ".gpx")):
        return True
    if not name.endswith((".json", ".jsonl")):
        return False
    if name.startswith(("posxy",) + FOREIGN_NAMES):
        return True
    try:
        with path.open("rb") as f:
            head = f.read(4096)
    except OSError:
        return False
    if b'"pos-xy"' in head or (head.lstrip().startswith(b'{"t":') and b'"lat"' in head):
        return True
    return any(m in head for m in FOREIGN_MARKERS)


class Handler(http.server.SimpleHTTPRequestHandler):
    data_dir: pathlib.Path
    allowed_hosts: set

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(STATIC), **kwargs)

    # --- security -----------------------------------------------------------------
    def host_ok(self) -> bool:
        # Blocks DNS-rebinding: a web page on evil.example pointed at 127.0.0.1 sends its own Host.
        return self.headers.get("Host", "") in self.allowed_hosts

    def end_headers(self):
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "strict-origin-when-cross-origin")  # OSM wants a Referer
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # --- routes -------------------------------------------------------------------
    def do_GET(self):
        if not self.host_ok():
            return self.send_error(403, "Forbidden host")
        path = urllib.parse.urlsplit(self.path).path
        if path == "/api/files":
            return self.list_files()
        if path.startswith("/api/files/"):
            return self.send_data_file(urllib.parse.unquote(path[len("/api/files/"):]))
        if path.startswith("/api/"):
            return self.send_error(404)
        if path.endswith("/") and path != "/":
            return self.send_error(404)   # no directory listings
        return super().do_GET()

    def do_HEAD(self):
        if not self.host_ok():
            return self.send_error(403, "Forbidden host")
        return super().do_HEAD()

    def list_files(self):
        files = []
        try:
            entries = list(self.data_dir.iterdir())
        except OSError as e:
            return self.send_json({"dir": str(self.data_dir), "files": [], "error": str(e)})
        for p in entries:
            try:
                if p.is_file() and looks_like_export(p):
                    st = p.stat()
                    files.append({"name": p.name, "size": st.st_size, "mtime": st.st_mtime})
            except OSError:
                continue
        files.sort(key=lambda f: f["mtime"], reverse=True)
        self.send_json({"dir": str(self.data_dir), "files": files})

    def send_data_file(self, name: str):
        # Only plain names that are in the listing: no paths, no traversal.
        if not name or "/" in name or "\\" in name or name.startswith("."):
            return self.send_error(400)
        p = self.data_dir / name
        if not (p.is_file() and looks_like_export(p)) or p.stat().st_size > MAX_FILE:
            return self.send_error(404)
        data = p.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        if os.environ.get("POSXY_VERBOSE"):
            super().log_message(fmt, *args)


def main():
    ap = argparse.ArgumentParser(description="Pos XY local web viewer")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--dir", default="~/Downloads", help="folder to list exports from (default ~/Downloads)")
    ap.add_argument("--no-open", action="store_true", help="don't open a browser")
    args = ap.parse_args()

    Handler.data_dir = pathlib.Path(args.dir).expanduser().resolve()
    Handler.allowed_hosts = {f"127.0.0.1:{args.port}", f"localhost:{args.port}"}
    Handler.extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                              ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css"}

    try:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as e:
        sys.exit(f"Couldn't listen on port {args.port}: {e}. Try --port 8766.")

    url = f"http://localhost:{args.port}/"
    print(f"Pos XY viewer: {url}")
    print(f"Listing exports in: {Handler.data_dir}")
    print("Press Ctrl+C to stop.")
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
