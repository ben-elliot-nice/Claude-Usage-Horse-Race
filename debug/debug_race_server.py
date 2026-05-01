#!/usr/bin/env python3
"""
Horse Race Debug Server
Proves the API contract for the Claude Usage horse race feature.
In-memory state — resets on restart.

Usage:
    python3 debug/debug_race_server.py
    python3 debug/debug_race_server.py --port 9000
"""

import argparse
import json
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

# In-memory store: { slug: { name: { name, cost_used_cents, cost_limit_cents, updated_at } } }
RACES: dict = {}


def sorted_participants(slug: str) -> list:
    """Return participants sorted by % used descending."""
    participants = list(RACES.get(slug, {}).values())
    def pct(p):
        limit = p["cost_limit_cents"]
        return p["cost_used_cents"] / limit if limit > 0 else 0
    return sorted(participants, key=pct, reverse=True)


class RaceHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {fmt % args}")

    def send_json(self, status: int, data: dict):
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def parse_slug_and_action(self):
        """Parse /races/{slug}/participant or /races/{slug}/standings"""
        parts = urlparse(self.path).path.strip("/").split("/")
        # parts = ["races", slug, action]
        if len(parts) == 3 and parts[0] == "races":
            return parts[1], parts[2]
        return None, None

    def do_PUT(self):
        slug, action = self.parse_slug_and_action()
        if action != "participant":
            self.send_json(404, {"error": "Not found"})
            return

        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            self.send_json(400, {"error": "Invalid JSON"})
            return

        required = {"name", "cost_used_cents", "cost_limit_cents", "updated_at"}
        if not required.issubset(body.keys()):
            self.send_json(400, {"error": f"Missing fields. Required: {required}"})
            return

        # Auto-create race if not exists
        if slug not in RACES:
            RACES[slug] = {}
            print(f"  → Created race '{slug}'")

        RACES[slug][body["name"]] = {
            "name": body["name"],
            "cost_used_cents": int(body["cost_used_cents"]),
            "cost_limit_cents": int(body["cost_limit_cents"]),
            "updated_at": body["updated_at"],
        }
        print(f"  → Updated '{body['name']}' in '{slug}': "
              f"{body['cost_used_cents']}/{body['cost_limit_cents']} cents")

        self.send_json(200, {"status": "ok"})

    def do_GET(self):
        slug, action = self.parse_slug_and_action()
        if action != "standings":
            self.send_json(404, {"error": "Not found"})
            return

        if slug not in RACES:
            # Return empty standings — race auto-creates on first PUT
            self.send_json(200, {"race_slug": slug, "participants": []})
            return

        self.send_json(200, {
            "race_slug": slug,
            "participants": sorted_participants(slug),
        })


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Horse Race Debug Server")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()

    server = HTTPServer(("127.0.0.1", args.port), RaceHandler)
    print(f"Horse Race debug server running at http://localhost:{args.port}")
    print(f"Race URL format: http://localhost:{args.port}/races/YOUR-SLUG")
    print("Press Ctrl+C to stop.\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
