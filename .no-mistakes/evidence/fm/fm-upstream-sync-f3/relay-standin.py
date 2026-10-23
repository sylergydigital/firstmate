# Local stand-in for the X-mode relay: logs every request line + headers, and
# answers /connector/poll once with an Overseer Query payload (then 204).
import http.server, json, sys
LOG = sys.argv[2]
BODY = json.dumps({
    "request_id": "req-live-query", "platform": "discord", "reply_max_chars": 1900,
    "text": "what is the fleet working on today?", "author_id": "overseer-42",
    "in_reply_to": None, "in_reply_to_chain": [], "images": [], "attachments": [],
    "kind": "query",
    "query": {"asker": {"handle": "@lead", "display_name": "Fleet Lead", "platform": "discord"},
              "direct": False, "outsiders": False, "continues": None},
}).encode()
served = {"poll": 0}
class H(http.server.BaseHTTPRequestHandler):
    def _log(self):
        with open(LOG, "a") as f:
            f.write(f"{self.command} {self.path}\n")
            for k, v in self.headers.items():
                f.write(f"  {k}: {'Bearer <redacted>' if k.lower() == 'authorization' else v}\n")
    def do_GET(self):
        self._log()
        if self.path.startswith("/connector/poll") and served["poll"] == 0:
            served["poll"] += 1
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(BODY))); self.end_headers(); self.wfile.write(BODY)
        else:
            self.send_response(204); self.end_headers()
    def do_POST(self):
        self._log()
        n = int(self.headers.get("Content-Length") or 0); self.rfile.read(n)
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
