#!/usr/bin/env python3
"""HTTP on :8080 that answers with the client's IP as the server sees it.
Run inside a pod:  setsid ip netns exec pod2 python3 echo-server.py &"""
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (self.client_address[0] + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
