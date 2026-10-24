#!/usr/bin/env python3
import http.server
import urllib.request
import urllib.error
import json
import os
import time
import math

DISCORD_URL = os.environ.get('DISCORD_URL')
LISTEN_PORT = int(os.environ.get('LISTEN_PORT', 9999))
LISTEN_IP = os.environ.get('LISTEN_IP', '0.0.0.0')

if not DISCORD_URL:
    raise RuntimeError("DISCORD_URL environment variable is not set!")

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        data = self.rfile.read(length).decode('utf-8') if length else 'Test successful!'

        print(f"Received notification. Length: {len(data)} characters.")

        chunk_size = 1900
        total_parts = math.ceil(len(data) / chunk_size)

        for i in range(total_parts):
            chunk = data[i * chunk_size : (i + 1) * chunk_size]

            if total_parts > 1:
                header = f"🛠 **Turris Omnia** (Part {i + 1} of {total_parts}):\n"
            else:
                header = "🛠 **Turris Omnia:**\n"

            payload = {'content': header + chunk}
            req = urllib.request.Request(
                DISCORD_URL,
                data=json.dumps(payload).encode('utf-8'),
                headers={
                    'Content-Type': 'application/json',
                    'User-Agent': 'TurrisWebhookBot/1.2'
                }
            )

            try:
                urllib.request.urlopen(req)
                print(f"Successfully forwarded part {i + 1}/{total_parts} to Discord!")
            except urllib.error.HTTPError as e:
                error_body = e.read().decode('utf-8')
                print(f"Discord HTTP Error {e.code} on part {i + 1}: {e.reason}")
                print(f"Discord Error Details: {error_body}")
            except Exception as e:
                print(f"General error on part {i + 1}: {e}")

            if total_parts > 1 and i < total_parts - 1:
                time.sleep(1)

        self.send_response(200)
        self.end_headers()

    def log_message(self, format, *args):
        print(f"[{self.log_date_time_string()}] {format % args}")

if __name__ == '__main__':
    print(f"Listening on {LISTEN_IP}:{LISTEN_PORT}...")
    server = http.server.HTTPServer((LISTEN_IP, LISTEN_PORT), Handler)
    server.serve_forever()