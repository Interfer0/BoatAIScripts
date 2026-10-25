# Tally Ho boat box — install bundle (Hermes edition)

Installs the boat assistant stack on an **Ubuntu Desktop 24.04 VM guest**:
**Hermes Agent** (Nous Research) + **Hermes WebUI**
(nesquena/hermes-webui), with nginx, Tailscale, Chromium, and the
Notion read-only mirror.

This replaces the earlier Open WebUI edition in full: Open WebUI,
its Docker stack, Mosquitto, and the MQTT Hermes wrappers are gone.
If you ran that edition, stop its Docker stack manually first —
this script does not delete your old data.

## What it installs

- Base: OpenSSH, UFW, `unattended-upgrades`, `rsync`, `git`
- **Hermes Agent** — official installer from
  NousResearch/hermes-agent, run as the service user (sets up its
  venv and the `hermes` command). Models are configured afterwards
  with `hermes model` / `hermes setup` — see `docs/FIRST_RUN.md`.
- **Hermes WebUI** — native clone of nesquena/hermes-webui, run
  via `ctl.sh` as a systemd service (`hermes-webui.service`).
  Python + vanilla JS, no build step, port 8787.
  - **Exposed to the local network**: `HERMES_WEBUI_HOST=0.0.0.0`,
    UFW opens 8787, and any device on the boat LAN can open
    `http://<box-LAN-IP>/` (via nginx) or `http://<box-LAN-IP>:8787`.
    Password auth is mandatory when bound beyond loopback.
  - **Autostarts on reboot**: `hermes-webui`, `hermes-gateway`,
    and `tallyho-mirror` units are all enabled.
- **Hermes gateway** — systemd service (`hermes-gateway.service`)
  running `hermes gateway` for Telegram (and other messaging).
  It exits until `hermes gateway setup` is done — see
  `docs/TELEGRAM_SETUP.md`.
- **nginx** — the front door: `/` → Hermes WebUI (8787),
  `/mirror/` → Notion mirror (8000).
- **Tailscale** (official apt repo) — phone access from off the
  boat LAN, plus Tailscale Serve — see `docs/TAILSCALE_SETUP.md`.
- **Notion read-only mirror** — local server on port 8000,
  pull+render timer twice daily + on boot. Read-only: Hermes reads
  it, it never edits Notion.
- **Chromium** — browser for the box, opening normally in the
  Desktop GUI (on Ubuntu 24.04 the apt package is the Chromium
  snap build; snapd is installed with it).
- **Automatic suspend disabled** — a desktop install suspends on
  idle by default, which would take the services down. The script
  masks the sleep targets so the box stays on. Reversible with
  `sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target`.
- **Passwordless sudo** for the service user
  (`/etc/sudoers.d/tallyho-<user>`, validated with `visudo -cf`).

What it does **not** install, on purpose: Docker (no longer needed
— WebUI is native), Ollama in the VM (VMs get poor GPU access;
run Ollama on the VM host and point Hermes at it as a provider /
custom endpoint, per `docs/FIRST_RUN.md`), or Mosquitto (the MQTT
voice wrappers are gone with the old edition).

## Run it

On the VM, from this directory:

```bash
sudo bash install.sh
```

Run it via `bash` on purpose: `install.sh` is stored without the
executable bit in git (the tool used to push it does not preserve
file modes), so `./install.sh` fails with "Permission denied" after
a fresh clone. `chmod +x install.sh && sudo ./install.sh` works too,
but the `bash` form works regardless.

Options: `--user <name>` (default: your sudo user, or `boat`),
`--dry-run` (print privileged commands, stage files to override dirs),
`--no-webui-start` (skip starting WebUI).

Re-running is safe and is the update mechanism: it never overwrites
an existing `/opt/tallyho/.env`. **Update Hermes Agent + WebUI
together** — WebUI imports Agent modules directly, and upstream
warns version skew is untested/unsupported.

## Setup docs (read these after install)

- `docs/FIRST_RUN.md` — the full first-run order: model setup,
  WebUI onboarding, workspace, Telegram, Tailscale, mirror pull,
  and the test checklist (including a reboot/autostart test).
- `docs/AI_INSTRUCTIONS.md` — templated, paste-ready instructions
  for Hermes (identity, boat facts, rules). Replace the
  `<PLACEHOLDERS>` with your own details; do not commit a filled-in
  copy with personal details to a public repo.
- `docs/TELEGRAM_SETUP.md` — BotFather, user-ID allowlist,
  `hermes gateway setup`, DM-first testing, and troubleshooting.
- `docs/TAILSCALE_SETUP.md` — account, phone, tailnet IP, Serve
  (preferred), direct-IP fallback, and LAN access without Tailscale.

## Post-install (short version)

1. `hermes setup` / `hermes model` as the service user (pick a
   provider; host Ollama for the local lane, cloud for the online lane).
2. Open WebUI (`http://localhost/`, or `http://<box-LAN-IP>/` from
   the LAN), finish onboarding, paste in `docs/AI_INSTRUCTIONS.md`.
   Password: `HERMES_WEBUI_PASSWORD` in `/opt/tallyho/.env`.
3. `hermes gateway setup` for Telegram, then
   `sudo systemctl restart hermes-gateway`.
4. `sudo tailscale up`, then `sudo tailscale serve --bg 80` for a
   tailnet HTTPS address (or use the tailnet IP directly).
5. Fill `NOTION_TOKEN` in `/opt/tallyho/.env`, then first mirror pull:
   ```bash
   cd /opt/tallyho/notion-mirror
   python3 pull_notion.py && python3 render.py
   ```

## Layout on the box

- `/opt/tallyho/` — `.env`, `docs/`, `workspace/`, `notion-mirror/`, `src/`
- `/opt/hermes-webui/` — Hermes WebUI clone (owned by the service user)
- `/etc/nginx/sites-available/tallyho` — nginx site
- `hermes-webui`, `hermes-gateway`, `tallyho-mirror`,
  `tallyho-mirror-pull.{service,timer}` — systemd units

## Security notes (read before exposing anything)

- WebUI bound to `0.0.0.0` means anyone on the local network who
  can reach port 8787 can *attempt* to log in — the password is
  therefore mandatory, not optional, and the installer generates
  one if you leave it blank. Do **not** port-forward 8787 (or 80)
  to the public internet; this box is expected to sit behind a
  router NAT on the boat LAN, with Tailscale as the remote path.
- Passwordless sudo means anything running as the service user can
  become root. Mitigations built in: SSH key-only is assumed (set
  `PasswordAuthentication no` in sshd_config), firewall locked to
  SSH + HTTP(S) + WebUI + Tailscale, and Hermes' own processes run
  as the service user, not root.
- Telegram: allowlist only your own user ID until you deliberately
  decide otherwise, run exactly one gateway per bot token, and
  keep purchases, deletions, external messages, and system changes
  behind explicit approval.
- Secrets live only in `/opt/tallyho/.env` (mode 600) and in
  Hermes' own `~/.hermes/` config (bot token, provider keys).
  Never commit a filled `.env`.

## Status / what was actually tested

- `bash -n` syntax check: pass. All Python files compile: pass.
- Dry-run into staging directories: pass — sudoers file, nginx site,
  systemd units (user + paths substituted), generated WebUI password,
  and `.env` preservation on re-run verified.
- **Not yet tested:** a full run on a real boat VM (apt installs,
  Hermes Agent installer, WebUI clone + `ctl.sh` start, `hermes
  setup` / `hermes model`, gateway setup, first mirror pull).
  Run it in a throwaway VM first, and send back any error output —
  not any token.

## Troubleshooting

```bash
sudo systemctl status hermes-webui hermes-gateway tallyho-mirror
sudo journalctl -u hermes-gateway -n 50
tail -n 100 ~/.hermes/webui.log
curl http://127.0.0.1:8787/health
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl list-timers tallyho-mirror-pull.timer
hermes doctor
```
