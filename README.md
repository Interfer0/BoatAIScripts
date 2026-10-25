# Tally Ho boat box — install bundle

Installs the boat assistant stack on an **Ubuntu Desktop 24.04 VM guest**.
Ollama is deliberately **not** installed here — it runs on the VM host
(direct GPU access) and Open WebUI points at it.

## What it installs

- Base: OpenSSH, UFW (SSH + 80/443 + Tailscale interface only),
  `unattended-upgrades`, `rsync`, `git`
- Tailscale (official apt repo) — phone access, no port forwarding
- Docker + Docker Compose, running **Open WebUI** only
  (`ghcr.io/open-webui/open-webui:main`, localhost-only port 3000)
- **nginx** — the front door: `/` → Open WebUI, `/mirror/` → mirror
- **Mosquitto** — MQTT broker, bound to `127.0.0.1:1883` only
- **Hermes wrappers** (Telegram + Open WebUI) as systemd services,
  reading tokens from `/opt/tallyho/.env`
- **Notion read-only mirror** — local server on port 8000, pull+render
  timer twice daily + on boot
- **Chromium** — browser for the box, opening normally in the Desktop
  GUI (on Ubuntu 24.04 the apt package is the Chromium snap build;
  snapd is installed with it). Locally: `http://localhost/` for Open
  WebUI, `http://localhost/mirror/` for the mirror.
- **Automatic suspend disabled** — a desktop install suspends on idle
  by default, which would take the services down. The script masks
  the sleep targets so the box stays on. Reversible with
  `sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target`.
- **Passwordless sudo** for the service user
  (`/etc/sudoers.d/tallyho-<user>`, validated with `visudo -cf`)

## Run it

On the VM, from this directory:

```bash
sudo ./install.sh
```

Options: `--user <name>` (default: your sudo user, or `boat`),
`--dry-run` (print privileged commands, stage files to override dirs),
`--no-compose-up` (skip starting the Docker stack).

Re-running is safe and is the update mechanism: it never overwrites
an existing `/opt/tallyho/.env`.

## Post-install (in order)

1. **Fill in `/opt/tallyho/.env`** — `NOTION_TOKEN`, `TELEGRAM_BOT_TOKEN`,
   `TELEGRAM_CHAT_ID`, `OWUI_API_KEY`, `OWUI_MODEL`, `OLLAMA_BASE_URL`.
   Then: `sudo systemctl restart hermes-telegram hermes-openwebui`
   - Telegram token: @BotFather. Chat id: message the bot once, then
     open `https://api.telegram.org/bot<TOKEN>/getUpdates`.
   - Open WebUI API key: profile → Settings → Account → API Keys.
     Model id must match the dropdown exactly.
2. **On the VM host (not the VM):** install Ollama, set
   `OLLAMA_HOST=0.0.0.0:11434`, pull a model, and open port 11434
   **only to this VM / Tailscale**. Put the host's Tailscale IP in
   `OLLAMA_BASE_URL` (e.g. `http://100.x.y.z:11434`). Without the host
   running, the local-model lane is down and only the cloud lane works.
3. **`sudo tailscale up`** if not connected. Phone URLs:
   `http://<box-tailscale-ip>/` → Open WebUI,
   `http://<box-tailscale-ip>/mirror/` → Notion mirror.
4. **First mirror pull:**
   ```bash
   cd /opt/tallyho/notion-mirror
   python3 pull_notion.py && python3 render.py
   ```
5. **In Open WebUI:** create the admin account, enable Channels
   (Admin Settings → General), and add a cloud model key if you want
   the cloud lane (Admin Settings → Connections).

## Layout on the box

- `/opt/tallyho/` — compose file, `.env`, `hermes/`, `notion-mirror/`
- `/etc/nginx/sites-available/tallyho` — nginx site
- `tallyho-stack`, `hermes-telegram`, `hermes-openwebui`,
  `tallyho-mirror`, `tallyho-mirror-pull.{service,timer}` — systemd units

## Security notes (read before exposing anything)

- Passwordless sudo means anything running as the service user can
  become root. Mitigations built in: SSH key-only is assumed (set
  `PasswordAuthentication no` in sshd_config), firewall locked to LAN +
  Tailscale, Mosquitto localhost-only, Open WebUI localhost-only behind
  nginx, Ollama never proxied. If you want it tighter later, scope the
  sudoers line to specific commands instead of `ALL`.
- nginx serves plain HTTP. That is acceptable behind Tailscale (encrypted
  tunnel, private IPs). If the box ever sits on untrusted marina Wi-Fi
  with nginx reachable on LAN, add nginx basic auth or TLS before
  relying on it.
- Secrets live only in `/opt/tallyho/.env` (mode 600). Never commit a
  filled `.env`. The wrapper copies in this bundle read tokens from the
  environment first and fall back to their in-file CONFIG.

## Status / what was actually tested

- `bash -n` syntax check: pass. All Python files compile: pass.
- Dry-run into staging directories: pass — sudoers file, nginx site,
  systemd units (user + root substituted), generated `WEBUI_SECRET_KEY`,
  compose file, and `.env` preservation on re-run all verified.
- **Not yet tested:** a full run on a real boat VM (apt installs, Docker
  image pull, `tailscale up`, first Open WebUI boot, first mirror pull
  against a real Notion token). Run it in a throwaway VM first, and
  send back any error output — not any token.

## Troubleshooting

```bash
sudo systemctl status tallyho-stack hermes-telegram hermes-openwebui tallyho-mirror
sudo journalctl -u hermes-telegram -n 50
cd /opt/tallyho && sudo docker compose logs -f openwebui
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl list-timers tallyho-mirror-pull.timer
```
