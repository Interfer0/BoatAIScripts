# Tailscale setup — phone access to the boat box (walkthrough)

Tailscale is a mesh VPN built on WireGuard. It gives the box and
your phone private addresses on the same virtual network, with no
port forwarding and no public exposure. `install.sh` already
installs Tailscale on the box — this doc is the account, phone,
and access part.

## What you can already do without Tailscale

Hermes WebUI is exposed to the **local network** (see
`docs/FIRST_RUN.md`): any device on the boat LAN can open
`http://<box-LAN-IP>/` (via nginx) or `http://<box-LAN-IP>:8787`
(direct to WebUI, password required). Tailscale is for when you
are **not** on the boat LAN, and for a safer HTTPS address.

Find the box's LAN IP on the box with `hostname -I` (the address
on your boat Wi-Fi / LAN, not `127.0.0.1`).

## Step 1 — Create a Tailscale account

Go to [tailscale.com](https://tailscale.com) and sign up with
whatever login you already use (Google, Microsoft, GitHub, etc.).
You will use the same account on the box and on your phone.

## Step 2 — Connect the box

On the box:

```bash
sudo tailscale up
```

This prints a login link (or opens a browser flow on Desktop).
Sign in with the account from step 1. Then check:

```bash
tailscale status
tailscale ip -4        # this box's tailnet IP, looks like 100.x.y.z
```

If you put a `TAILSCALE_AUTHKEY` in `/opt/tallyho/.env`, the
installer connects unattended instead, with hostname `tallyho-box`.
Otherwise `tailscale up` is interactive, once.

## Step 3 — Connect your phone

Install the Tailscale app (iOS / Android), sign in with the **same**
account, and make sure Tailscale is switched on. Your phone now has
its own `100.x.y.z` address on the same tailnet as the box.

## Step 4 — Open the box from your phone

Over Tailscale, the same nginx front door answers:

```
http://<box-tailscale-ip>/          # Hermes WebUI
http://<box-tailscale-ip>/mirror/   # Notion mirror
```

WebUI still asks for its password (`HERMES_WEBUI_PASSWORD` in
`/opt/tallyho/.env`). Add the page to your phone's home screen
for an app-like shortcut.

## Preferred: Tailscale Serve (HTTPS, WebUI stays on loopback)

Instead of opening the box's IP directly, you can publish it
through Tailscale Serve, which gives you a tailnet HTTPS address
while the services themselves stay off the wider network. For
this box, serve the nginx front door (WebUI + mirror together):

```bash
sudo tailscale serve --bg 80
```

Tailscale prints an HTTPS MagicDNS URL — open that on your phone.
If Serve reports `Access denied: serve config denied`, either
run it with sudo (as above) or allow the service user to manage
Tailscale, then retry without sudo:

```bash
sudo tailscale set --operator=$USER
tailscale serve --bg 80
```

Note: serving port 80 publishes nginx, not WebUI directly. If you
ever bypass nginx and serve WebUI itself (`tailscale serve --bg
8787`), keep WebUI password auth on — Serve does not replace it.

## Fallback: direct tailnet IP (no Serve)

If Serve is unavailable or disabled, direct tailnet access still
works: `http://<box-tailscale-ip>:8787` with WebUI password auth
(WebUI must be bound beyond loopback for this, which is this
box's default: `HERMES_WEBUI_HOST=0.0.0.0` in `/opt/tallyho/.env`).
Traffic is encrypted end-to-end by WireGuard, and the password
protects the UI at the application level.

## If the phone cannot reach the box

1. Is Tailscale on, on both ends? Check `tailscale status` on the
   box and the Tailscale app on the phone — same account, both
   showing as connected.
2. Are the services actually up? On the box:
   `sudo systemctl status hermes-webui nginx` and
   `curl http://127.0.0.1:8787/health`.
3. Are you on the right IP? `tailscale ip -4` on the box is the
   address to use; the LAN IP from `hostname -I` only works while
   you are on the boat LAN.
4. Did the box suspend? The installer masks sleep targets so an
   always-on box stays awake; if it still sleeps, check power
   settings and `sudo systemctl status sleep.target`.
5. As a last resort on the boat, use the LAN address from the
   "without Tailscale" section above — that path does not need
   Tailscale at all.
