#!/usr/bin/env python3
"""
opencode-autopilot — Notification Sender (Python)

Sends phase-level and important notifications to WeChat Work Bot and/or
Feishu Bot via webhooks. Disabled gracefully when webhook URLs are empty.

Usage:
  python3 notify.py <level> <title> <body>

Levels: start | phase | complete | error | warning | info

Environment:
  WECHAT_BOT_KEY    WeChat Work Bot webhook key (empty = skip)
  FEISHU_BOT_URL    Feishu Bot webhook URL    (empty = skip)
"""

import json
import os
import sys
import urllib.request

# ── Level config ─────────────────────────────────────────────────────────────
LEVEL_CONFIG = {
    "start":    {"icon": "\N{ROCKET}",                              "template": "blue"},
    "phase":    {"icon": "\N{BAR CHART}",                           "template": "indigo"},
    "complete": {"icon": "\N{WHITE HEAVY CHECK MARK}",              "template": "green"},
    "error":    {"icon": "\N{CROSS MARK}",                          "template": "red"},
    "warning":  {"icon": "\N{WARNING SIGN}\N{VARIATION SELECTOR-16}", "template": "yellow"},
    "info":     {"icon": "\N{INFORMATION SOURCE}\N{VARIATION SELECTOR-16}", "template": "grey"},
}


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <level> <title> [body]")
        sys.exit(1)

    level = sys.argv[1]
    title = sys.argv[2]
    body = sys.argv[3] if len(sys.argv) > 3 else ""

    # Validate level
    if level not in LEVEL_CONFIG:
        print(f"[notify] WARNING: unknown level '{level}', treating as info", file=sys.stderr)
        level = "info"

    # Check channels
    wechat_key = os.environ.get("WECHAT_BOT_KEY", "")
    feishu_url = os.environ.get("FEISHU_BOT_URL", "")
    if not wechat_key and not feishu_url:
        print("[notify] No notification channels configured. Set WECHAT_BOT_KEY or FEISHU_BOT_URL.")
        print(f"[notify] Skipped: [{level}] {title}")
        return

    cfg = LEVEL_CONFIG[level]
    icon = cfg["icon"]
    template = cfg["template"]

    import datetime
    timestr = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    import socket
    hostname = socket.gethostname().split(".")[0]
    project = os.path.basename(os.environ.get("PROJECT_DIR", os.getcwd()))

    footer = f"{timestr} | {hostname} | {project}"
    content = f"{body}\n\n---\n{footer}"

    # ── WeChat Work Bot ──────────────────────────────────────────────────────
    if wechat_key:
        md = f"## {icon} {title}\n### {level.upper()}\n{content}"
        payload = json.dumps({
            "msgtype": "markdown",
            "markdown": {"content": md}
        }).encode("utf-8")
        url = f"https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key={wechat_key}"
        try:
            req = urllib.request.Request(url, data=payload,
                                         headers={"Content-Type": "application/json"})
            resp = urllib.request.urlopen(req, timeout=10)
            if resp.status == 200:
                print("[notify] WeChat Work: ok")
            else:
                print(f"[notify] WeChat Work: HTTP {resp.status}")
        except Exception as e:
            print(f"[notify] WeChat Work: failed - {e}")
    else:
        print("[notify] WeChat Work: skipped (no key)")

    # ── Feishu Bot ───────────────────────────────────────────────────────────
    if feishu_url:
        card = {
            "msg_type": "interactive",
            "card": {
                "header": {
                    "title": {"tag": "plain_text", "content": f"{icon} {title}"},
                    "template": template,
                },
                "elements": [
                    {
                        "tag": "markdown",
                        "content": (f"**{level.upper()}** | {timestr} | {hostname}\n\n"
                                    f"{body}\n\n---\n{footer}"),
                    }
                ],
            },
        }
        payload = json.dumps(card).encode("utf-8")
        try:
            req = urllib.request.Request(feishu_url, data=payload,
                                         headers={"Content-Type": "application/json"})
            resp = urllib.request.urlopen(req, timeout=10)
            if resp.status == 200:
                print("[notify] Feishu: ok")
            else:
                print(f"[notify] Feishu: HTTP {resp.status}")
        except Exception as e:
            print(f"[notify] Feishu: failed - {e}")
    else:
        print("[notify] Feishu: skipped (no URL)")

    print(f"[notify] Done: [{level}] {title}")


if __name__ == "__main__":
    main()
