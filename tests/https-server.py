"""Local verified-TLS download fixture. Not a production component."""
import http.server
import pathlib
import ssl
import sys

root = pathlib.Path(sys.argv[1])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/binary" or (self.path == "/flaky" and (root / "wan-up").exists()):
            body = (root / "fixture").read_bytes()
            code = 200
        elif self.path == "/bad":
            body, code = b"not an ELF executable", 200
        elif self.path == "/redirect-http":
            self.send_response(302)
            self.send_header("Location", "http://localhost:18888/binary")
            self.end_headers()
            return
        else:
            body, code = b"unavailable", 503
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 18888), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(root / "cert.pem", root / "key.pem")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
