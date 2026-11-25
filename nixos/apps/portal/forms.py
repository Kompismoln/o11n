import email.message
import http.server
import re
import shlex
import socket
import subprocess
import sys
import urllib.parse

account, invites, invite, inquiries, host, port = sys.argv[1:7]

# Policy: an address is one mailbox, whatever its syntax would allow, so that it can't name others in Reply-To.
ADDRESS = re.compile(r"[^@\s<>,;:\"'()\[\]\\]+@[^@\s<>,;:\"'()\[\]\\]+\.[^@\s<>,;:\"'()\[\]\\]+")


def request(address, note, page, language):
    message = email.message.EmailMessage()
    message["To"] = invites
    message["Reply-To"] = address
    message["Subject"] = f"Invite request: {address}"
    body = [f"{address} asks for an invite, from {page} ({language}).", ""]
    if note:
        body += [note, ""]
    body.append("Reply to this mail to answer them.")
    if invite:
        body.append(f"To invite them: {invite} {shlex.quote(address)}")
    message.set_content("\n".join(body) + "\n")
    return message.as_bytes()


def inquiry(address, text, page, language):
    message = email.message.EmailMessage()
    message["To"] = inquiries
    message["Reply-To"] = address
    message["Subject"] = f"Inquiry: {address}"
    message.set_content(f"{address} writes, from {page} ({language}):\n\n{text}\n\nReply to this mail to answer them.\n")
    return message.as_bytes()


# Fact: nginx passes a form's path here only when the portal has its address.
FORMS = {
    "/invite": ("invite", invites, lambda field: request(field("email"), field("note")[:4000], field("back"), field("lang")[:8])),
    "/inquiry": ("inquiry", inquiries, lambda field: inquiry(field("email"), field("text")[:4000], field("back"), field("lang")[:8])),
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        kind, to, mail = FORMS[self.path]
        length = int(self.headers.get("Content-Length") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(min(length, 16384)).decode("utf-8", "replace"))

        def field(name):
            return form.get(name, [""])[0].strip()

        back = field("back")
        if not back.startswith("/") or back.startswith("//") or "\\" in back:
            back = "/"
        form["back"] = [back]
        address = field("email")
        # Policy: a request that fills the field people don't see is a bot's, which is told it was sent.
        if field("website"):
            return self.answer(kind, back, "sent")
        if len(address) > 254 or not ADDRESS.fullmatch(address):
            return self.answer(kind, back, "invalid")
        sent = subprocess.run(["msmtp", "-C", "/etc/msmtprc", "-a", account, "--", to], input=mail(field))
        self.answer(kind, back, "sent" if sent.returncode == 0 else "failed")

    def answer(self, kind, back, status):
        self.send_response(303)
        self.send_header("Location", f"{back}?{kind}={status}#{kind}")
        self.send_header("Content-Length", "0")
        self.end_headers()


class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


Server((host, int(port)), Handler).serve_forever()
