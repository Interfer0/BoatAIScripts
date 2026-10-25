#!/usr/bin/env python3
"""Serve the generated mirror on the local network only.

  python3 serve.py              # http://127.0.0.1:8000 (this machine only)
  python3 serve.py --lan        # http://<boat-PC-IP>:8000 (boat LAN / Tailscale)

The pages are static files, so this is just a file server — it never
talks to Notion and never writes anything. If you only need it on one
machine, use the default (localhost). Use --lan when you want your phone
to open it over the boat Wi-Fi or Tailscale. Do NOT expose this port to
the public internet: the mirror contains your refit data.
"""
import argparse, functools, http.server, socketserver

ap = argparse.ArgumentParser()
ap.add_argument("--lan", action="store_true", help="listen on all interfaces")
ap.add_argument("--port", type=int, default=8000)
ap.add_argument("--dir", default="site")
args = ap.parse_args()
host = "0.0.0.0" if args.lan else "127.0.0.1"
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=args.dir)
with socketserver.TCPServer((host, args.port), handler) as httpd:
    print(f"Serving {args.dir}/ at http://{host}:{args.port}  (Ctrl-C to stop)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
