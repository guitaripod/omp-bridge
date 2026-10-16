#!/usr/bin/env python3
"""A release server for tests: serves one directory over HTTP on a port the system picks, answers
conditional requests the way GitHub's release downloads do (a strong ETag, 304 on a match), and
records every request so a test can say how often it was asked.

    fake-release-server.py --dir DIR --port-file FILE [--log FILE] [--parent PID]

The port is written to --port-file once the socket is listening. Each request adds a line to --log:
the path, the status sent and whether it carried If-None-Match. With --parent the server ends by
itself once that process is gone, so a test run that dies cannot leave it behind.
"""

import argparse
import hashlib
import http.server
import os
import threading
import time


class Handler(http.server.BaseHTTPRequestHandler):
    root = ""
    log_path = None
    lock = threading.Lock()

    def record(self, status):
        if not self.log_path:
            return
        conditional = "conditional" if self.headers.get("If-None-Match") else "plain"
        with self.lock, open(self.log_path, "a") as handle:
            handle.write("%s %s %s\n" % (self.path, status, conditional))

    def resolve(self):
        relative = os.path.normpath(self.path.split("?", 1)[0].lstrip("/"))
        if relative.startswith("..") or os.path.isabs(relative):
            return None
        path = os.path.join(self.root, relative)
        return path if os.path.isfile(path) else None

    def serve(self, with_body):
        path = self.resolve()
        if path is None:
            self.record(404)
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        with open(path, "rb") as handle:
            body = handle.read()
        etag = '"%s"' % hashlib.sha256(body).hexdigest()[:32]
        if self.headers.get("If-None-Match") == etag:
            self.record(304)
            self.send_response(304)
            self.send_header("ETag", etag)
            self.end_headers()
            return
        self.record(200)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("ETag", etag)
        self.end_headers()
        if with_body:
            self.wfile.write(body)

    def do_GET(self):
        self.serve(True)

    def do_HEAD(self):
        self.serve(False)

    def log_message(self, format, *args):
        pass


def watch_parent(pid):
    while True:
        time.sleep(1)
        try:
            os.kill(pid, 0)
        except OSError:
            os._exit(0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", required=True)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--log")
    parser.add_argument("--parent", type=int)
    arguments = parser.parse_args()
    Handler.root = os.path.abspath(arguments.dir)
    Handler.log_path = arguments.log
    if arguments.parent:
        threading.Thread(target=watch_parent, args=(arguments.parent,), daemon=True).start()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(arguments.port_file + ".tmp", "w") as handle:
        handle.write(str(server.server_address[1]))
    os.replace(arguments.port_file + ".tmp", arguments.port_file)
    server.serve_forever()


main()
