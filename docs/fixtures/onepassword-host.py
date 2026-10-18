#!/usr/bin/env python3
"""A stand-in for 1Password's native host, 1Password-BrowserSupport.

Speaks Chrome's native-messaging framing (a four-byte little-endian length,
then UTF-8 JSON) and answers the way the real BrowserSupport (1Password 8,
captured 2026-10-18 with Copper's SEARCH_NATIVE_LOG) answers a browser it
doesn't know yet — a "partner" browser:

  - NmRequestAccounts (the extension looking for the desktop app):
    a NotificationModern BrowserVerificationFailed / UnknownBrowser, then exit 1.
  - NmAuthorizePartnerBrowser (Use the 1Password App…): the same notification,
    then, after `<log>/delay` seconds (0 unless the file says otherwise), a
    BrowserSupport message carrying the answer — `<log>/answer`, else
    PartnerBrowserAuthorizationSuccess — then exit 0.

Every frame in and out is appended to `<log>/host-frames.log` (`IN n json` /
`OUT n json`) and the arguments it was run with to `<log>/host-args.log`.
`<log>` is $STANDIN_LOG, else this file's own folder.
"""
import json
import os
import struct
import sys
import time

log = os.environ.get("STANDIN_LOG") or os.path.dirname(os.path.abspath(__file__))


def read(name, default):
    try:
        with open(os.path.join(log, name)) as f:
            return f.read().strip() or default
    except OSError:
        return default


delay = float(read("delay", "0"))
answer = read("answer", "PartnerBrowserAuthorizationSuccess")
with open(os.path.join(log, "host-args.log"), "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
frames = open(os.path.join(log, "host-frames.log"), "ab")
# What BrowserSupport says of a signed browser it hasn't been told to trust:
# the browser's bundle id, base64.
state = {"type": "Untrusted", "content": {"id": "Y29tLmNvbGxpbnJpam9jay5jb3BwZXIuZGV2"}}


def send(message):
    body = json.dumps(message, separators=(",", ":")).encode()
    frames.write(b"OUT %d " % len(body) + body + b"\n")
    frames.flush()
    sys.stdout.buffer.write(struct.pack("<I", len(body)) + body)
    sys.stdout.buffer.flush()


def unknown_browser():
    send({"type": "NotificationModern", "content": {
        "content": {"type": "BrowserVerificationFailed", "content": "UnknownBrowser"},
        "browser_state": state, "timestamp": "2026-10-18T10:36:15.057986Z"}})


while True:
    head = sys.stdin.buffer.read(4)
    if len(head) < 4:
        break
    body = sys.stdin.buffer.read(struct.unpack("<I", head)[0])
    frames.write(b"IN %d " % len(body) + body + b"\n")
    frames.flush()
    try:
        message = json.loads(body)
    except ValueError:
        continue
    kind = (message.get("invocation") or {}).get("type") if isinstance(message, dict) else None
    unknown_browser()
    if kind == "NmAuthorizePartnerBrowser":
        time.sleep(delay)
        send({"type": "BrowserSupport", "content": {
            "callbackId": message["callbackId"], "response": answer, "browser_state": state}})
        sys.exit(0)
    sys.exit(1)
