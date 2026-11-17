import email.message
import http.server
import re
import socket
import subprocess
import sys
import urllib.parse

account, to, admin, host, port = sys.argv[1:6]

# Policy: an address is one mailbox, whatever its syntax would allow, so that it can't name others in Reply-To.
ADDRESS = re.compile(r"[^@\s<>,;:\"'()\[\]\\]+@[^@\s<>,;:\"'()\[\]\\]+\.[^@\s<>,;:\"'()\[\]\\]+")


def request(address, note, page, language):
    message = email.message.EmailMessage()
    message["To"] = to
    message["Reply-To"] = address
    message["Subject"] = f"Invite request: {address}"
    body = [f"{address} asks for an invite, from {page} ({language}).", ""]
    if note:
        body += [note, ""]
    body.append("Reply to this mail to answer them.")
    if admin:
        body.append(f"To invite them, add a user with their address, and send them Update Password from its Credentials: {admin}")
    message.set_content("\n".join(body) + "\n")
    return message.as_bytes()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(min(length, 16384)).decode("utf-8", "replace"))

        def field(name):
            return form.get(name, [""])[0].strip()

        back = field("back")
        if not back.startswith("/") or back.startswith("//") or "\\" in back:
            back = "/"
        address = field("email")
        # Policy: a request that fills the field people don't see is a bot's, which is told it was sent.
        if field("website"):
            return self.answer(back, "sent")
        if len(address) > 254 or not ADDRESS.fullmatch(address):
            return self.answer(back, "invalid")
        sent = subprocess.run(
            ["msmtp", "-C", "/etc/msmtprc", "-a", account, "--", to],
            input=request(address, field("note")[:2000], back, field("lang")[:8]),
        )
        self.answer(back, "sent" if sent.returncode == 0 else "failed")

    def answer(self, back, status):
        self.send_response(303)
        self.send_header("Location", f"{back}?invite={status}#invite")
        self.send_header("Content-Length", "0")
        self.end_headers()


class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


Server((host, int(port)), Handler).serve_forever()
