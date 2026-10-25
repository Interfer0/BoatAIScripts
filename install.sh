#!/usr/bin/env bash
# Tally Ho boat box — install script (Hermes Agent + Hermes WebUI edition).
#
# Installs, on Ubuntu Desktop 24.04 or 26.04 LTS (VM guest):
#   Hermes Agent (Nous Research, official installer) + Hermes WebUI
#   (nesquena/hermes-webui, native, port 8787, exposed to the local
#   network with password auth, autostarting on boot via systemd),
#   nginx as the front door, Tailscale, UFW, Chromium, and the
#   Notion read-only mirror (pull timer + local server).
#   Grants the service user passwordless sudo.
#
# This REPLACES the earlier Open WebUI edition: Open WebUI, its Docker
# stack, Mosquitto, and the MQTT Hermes wrappers are gone. Telegram now
# goes through Hermes Agent's own gateway (see docs/TELEGRAM_SETUP.md),
# and models are configured with `hermes model` (see docs/FIRST_RUN.md).
# If you ran the old edition, stop its Docker stack manually first —
# this script does not delete your old data.
#
# Usage:
#   sudo bash install.sh [--user boat] [--dry-run] [--no-webui-start]
#   (Run via bash on purpose: install.sh is stored mode 100644 in git
#   — the push tool does not preserve the executable bit — so ./install.sh
#   fails with "Permission denied" after a fresh clone. `chmod +x install.sh`
#   also works, but bash works regardless.)
#
# The script is idempotent: safe to re-run to update or repair. It never
# overwrites an existing /opt/tallyho/.env, and never prints tokens.
#
# Overrides (mainly for testing):
#   TALLYHO_ROOT, HERMES_WEBUI_DIR, NGINX_DIR, SYSTEMD_DIR, SUDOERS_DIR
#   DRY_RUN=1  — print privileged commands instead of running them, but
#                still stage files into the override directories.
set -euo pipefail

DRY_RUN=0
NO_WEBUI_START=0
ORIGINAL_ARGS=("$@")
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-}}"
while [ $# -gt 0 ]; do
    case "$1" in
        --user) SERVICE_USER="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-webui-start) NO_WEBUI_START=1; shift ;;
        -h|--help)
            echo "Usage: sudo $0 [--user NAME] [--dry-run] [--no-webui-start]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ "$DRY_RUN" != "1" ] && [ "$(id -u)" != "0" ]; then
    echo "Re-running under sudo…"
    exec sudo FORCE_OS="${FORCE_OS:-0}" "$0" "${ORIGINAL_ARGS[@]}"
fi
if [ -z "$SERVICE_USER" ]; then SERVICE_USER="boat"; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALLYHO_ROOT="${TALLYHO_ROOT:-/opt/tallyho}"
HERMES_WEBUI_DIR="${HERMES_WEBUI_DIR:-/opt/hermes-webui}"
NGINX_DIR="${NGINX_DIR:-/etc/nginx/sites-available}"
NGINX_ENABLED_DIR="${NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"

log() { echo "==> $*"; }
warn() { echo "!!  $*" >&2; }
# run: executes a command, or just prints it in dry-run mode.
run() {
    if [ "$DRY_RUN" = "1" ]; then echo "[dry-run] $*"; else "$@"; fi
}

# --- OS guard ---------------------------------------------------------------
# Tested on Ubuntu Desktop 24.04 (noble) and 26.04 (resolute) LTS.
# Other Ubuntu versions proceed with a warning (apt packages and the
# dynamic Tailscale codename below usually just work); non-Ubuntu
# systems still require FORCE_OS=1, which is now preserved through
# the sudo re-exec above.
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ]; then
        warn "This script targets Ubuntu (found ${ID:-?} ${VERSION_ID:-?})."
        warn "Set FORCE_OS=1 to run anyway."
        [ "${FORCE_OS:-0}" = "1" ] || exit 1
    elif [ "${VERSION_ID:-}" != "24.04" ] && [ "${VERSION_ID:-}" != "26.04" ]; then
        warn "Untested Ubuntu version ${VERSION_ID:-?} (tested: 24.04, 26.04) — proceeding anyway."
        warn "If a package or repo fails below, report the exact error."
    fi
fi

log "Tally Ho boat box install (Hermes edition) — user: $SERVICE_USER, root: $TALLYHO_ROOT"

# --- Service user + passwordless sudo ---------------------------------------
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    log "Creating user $SERVICE_USER"
    run useradd -m -s /bin/bash "$SERVICE_USER"
else
    log "User $SERVICE_USER already exists"
fi
SUDOERS_FILE="$SUDOERS_DIR/tallyho-$SERVICE_USER"
mkdir -p "$SUDOERS_DIR"
echo "$SERVICE_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
if command -v visudo >/dev/null 2>&1; then
    run visudo -cf "$SUDOERS_FILE" >/dev/null || {
        warn "sudoers file failed validation — removing it"; rm -f "$SUDOERS_FILE"; exit 1; }
fi
log "Passwordless sudo granted to $SERVICE_USER (see README security note)"

# --- Base packages (no Docker, no Mosquitto in this edition) ----------------
export DEBIAN_FRONTEND=noninteractive
log "Installing base packages"
run apt-get update -qq
run apt-get install -y -qq openssh-server ufw nginx \
    python3 python3-venv python3-pip git curl rsync ca-certificates \
    unattended-upgrades openssl lsb-release gnupg snapd

# --- Tailscale (official apt repo) ------------------------------------------
if ! command -v tailscale >/dev/null 2>&1 || [ "$DRY_RUN" = "1" ]; then
    log "Installing Tailscale"
    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] install tailscale apt repo (codename: $(lsb_release -cs 2>/dev/null || echo noble)) + apt-get install -y tailscale"
    else
        # Codename comes from the running system (noble on 24.04,
        # resolute on 26.04), NOT hardcoded — the old hardcoded noble
        # repo was part of why non-24.04 installs failed. If Tailscale
        # has not published a repo for this codename yet, fall back
        # to noble and warn (its packages usually still install).
        TS_CODENAME="$(lsb_release -cs 2>/dev/null || echo noble)"
        mkdir -p /usr/share/keyrings
        if ! curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${TS_CODENAME}.noarmor.gpg" \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg; then
            warn "No Tailscale repo for codename $TS_CODENAME — falling back to noble"
            TS_CODENAME="noble"
            curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${TS_CODENAME}.noarmor.gpg" \
                -o /usr/share/keyrings/tailscale-archive-keyring.gpg
        fi
        curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${TS_CODENAME}.tailscale-keyring.list" \
            -o /etc/apt/sources.list.d/tailscale.list
        apt-get update -qq
        apt-get install -y -qq tailscale
    fi
else
    log "Tailscale already installed"
fi

# --- Chromium ---------------------------------------------------------------
# On Ubuntu 24.04/26.04 the apt package is the Chromium snap build, so this
# also needs snapd (installed above). This is a Desktop install, so
# Chromium opens normally in the GUI; `chromium --headless` also works.
if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; then
    log "Chromium already installed"
else
    log "Installing Chromium"
    run apt-get install -y -qq chromium-browser || run apt-get install -y -qq chromium || \
        warn "Chromium install failed — install it manually: sudo apt install chromium-browser"
fi

# --- Old Open WebUI edition: warn, don't delete ------------------------------
if [ -f "$TALLYHO_ROOT/docker-compose.yml" ]; then
    warn "Previous Open WebUI edition detected ($TALLYHO_ROOT/docker-compose.yml)."
    warn "Stop it manually before relying on this edition, e.g.:"
    warn "  cd $TALLYHO_ROOT && docker compose down   (if Docker is still installed)"
fi

# --- Hermes Agent (official installer, run as the service user) -------------
# Source: NousResearch/hermes-agent, scripts/install.sh. The installer
# sets up dependencies, a virtual environment, and the `hermes` command
# for the service user. It is downloaded first (inspect it at
# $TALLYHO_ROOT/src/hermes-agent-install.sh if you want) rather than
# piped straight from curl into a shell. It may ask setup questions;
# answer them, or press through and run `hermes setup` afterwards
# (see docs/FIRST_RUN.md). Model choice is NOT made here on purpose:
# `hermes model` is interactive, and the boat's local-model lane (host
# Ollama) is configured there as a provider / custom endpoint.
log "Installing Hermes Agent"
mkdir -p "$TALLYHO_ROOT/src"
AGENT_INSTALLER="$TALLYHO_ROOT/src/hermes-agent-install.sh"
# NOTE: the `hermes` check must not go through run(), or dry-run (which
# always "succeeds") would falsely report Hermes as already installed.
HERMES_FOUND=0
if [ "$DRY_RUN" != "1" ] && sudo -u "$SERVICE_USER" bash -lc 'command -v hermes' >/dev/null 2>&1; then
    HERMES_FOUND=1
fi
if [ "$HERMES_FOUND" = "1" ]; then
    log "Hermes Agent already installed (hermes command found)"
else
    run curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
        -o "$AGENT_INSTALLER"
    log "Running Hermes Agent installer as $SERVICE_USER"
    run sudo -u "$SERVICE_USER" bash "$AGENT_INSTALLER" || \
        warn "Hermes Agent installer did not complete — run it manually as $SERVICE_USER: bash $AGENT_INSTALLER"
fi

# --- Hermes WebUI (native clone, owned by the service user) -----------------
# Source: nesquena/hermes-webui (default branch). Native, not Docker:
# Python + vanilla JS, no build step. WebUI imports Hermes Agent modules
# directly, so keep the two in lockstep — update both together, never
# one alone (upstream warns version skew is untested/unsupported).
log "Installing Hermes WebUI"
mkdir -p "$(dirname "$HERMES_WEBUI_DIR")"
if [ "$DRY_RUN" != "1" ]; then chown "$SERVICE_USER:$SERVICE_USER" "$(dirname "$HERMES_WEBUI_DIR")" 2>/dev/null || true; fi
if [ -d "$HERMES_WEBUI_DIR/.git" ]; then
    log "Hermes WebUI already cloned — pulling latest"
    (cd "$HERMES_WEBUI_DIR" && run sudo -u "$SERVICE_USER" git pull --ff-only) || \
        warn "Hermes WebUI git pull failed — resolve it in $HERMES_WEBUI_DIR and re-run"
else
    run sudo -u "$SERVICE_USER" git clone https://github.com/nesquena/hermes-webui.git "$HERMES_WEBUI_DIR" || \
        warn "Hermes WebUI clone failed — clone it manually as $SERVICE_USER"
fi

# --- Copy the bundle --------------------------------------------------------
log "Installing bundle to $TALLYHO_ROOT"
mkdir -p "$TALLYHO_ROOT/notion-mirror" "$TALLYHO_ROOT/docs" "$TALLYHO_ROOT/workspace"
cp "$SCRIPT_DIR/notion-mirror/pull_notion.py" "$SCRIPT_DIR/notion-mirror/render.py" \
    "$SCRIPT_DIR/notion-mirror/serve.py" "$SCRIPT_DIR/notion-mirror/pages.json" \
    "$TALLYHO_ROOT/notion-mirror/"
cp "$SCRIPT_DIR"/docs/*.md "$TALLYHO_ROOT/docs/" 2>/dev/null || true
mkdir -p "$TALLYHO_ROOT/notion-mirror/site"
if [ ! -f "$TALLYHO_ROOT/notion-mirror/site/index.html" ]; then
    cat > "$TALLYHO_ROOT/notion-mirror/site/index.html" <<'EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Tally Ho mirror — not pulled yet</title></head>
<body><h1>Tally Ho mirror — not pulled yet</h1>
<p>Fill in NOTION_TOKEN in /opt/tallyho/.env, then run:<br>
<code>cd /opt/tallyho/notion-mirror && python3 pull_notion.py && python3 render.py</code></p>
</body></html>
EOF
fi

# --- .env: create once, never overwrite, generate the WebUI password --------
if [ ! -f "$TALLYHO_ROOT/.env" ]; then
    cp "$SCRIPT_DIR/.env.example" "$TALLYHO_ROOT/.env"
    log "Created $TALLYHO_ROOT/.env from .env.example — fill in the tokens (see README)"
else
    log "$TALLYHO_ROOT/.env already exists — leaving it untouched"
fi
if grep -q '^HERMES_WEBUI_PASSWORD=$' "$TALLYHO_ROOT/.env" 2>/dev/null; then
    SECRET="$(openssl rand -hex 16)"
    sed -i "s/^HERMES_WEBUI_PASSWORD=$/HERMES_WEBUI_PASSWORD=$SECRET/" "$TALLYHO_ROOT/.env"
    log "Generated a Hermes WebUI password in .env — read it there, or change it to one you remember"
fi
chmod 600 "$TALLYHO_ROOT/.env" || true
if [ "$DRY_RUN" != "1" ]; then
    chown -R "$SERVICE_USER:$SERVICE_USER" "$TALLYHO_ROOT/notion-mirror" "$TALLYHO_ROOT/docs" "$TALLYHO_ROOT/workspace" || true
    chown "$SERVICE_USER:$SERVICE_USER" "$TALLYHO_ROOT/.env" || true
fi

# --- nginx ------------------------------------------------------------------
log "Installing nginx site"
mkdir -p "$NGINX_DIR" "$NGINX_ENABLED_DIR"
cp "$SCRIPT_DIR/nginx/tallyho.conf" "$NGINX_DIR/tallyho"
ln -sf "$NGINX_DIR/tallyho" "$NGINX_ENABLED_DIR/tallyho"
rm -f "$NGINX_ENABLED_DIR/default"
run nginx -t
run systemctl enable --now nginx
run systemctl reload nginx || run systemctl restart nginx || true

# --- systemd units ----------------------------------------------------------
log "Installing systemd units"
mkdir -p "$SYSTEMD_DIR"
for unit in hermes-webui hermes-gateway tallyho-mirror tallyho-mirror-pull; do
    sed -e "s/__SERVICE_USER__/$SERVICE_USER/g" \
        -e "s|__HERMES_WEBUI_DIR__|$HERMES_WEBUI_DIR|g" \
        -e "s|/opt/tallyho|$TALLYHO_ROOT|g" \
        "$SCRIPT_DIR/systemd/$unit.service" > "$SYSTEMD_DIR/$unit.service"
done
cp "$SCRIPT_DIR/systemd/tallyho-mirror-pull.timer" "$SYSTEMD_DIR/tallyho-mirror-pull.timer"
run systemctl daemon-reload
run systemctl enable hermes-webui.service hermes-gateway.service \
    tallyho-mirror.service tallyho-mirror-pull.timer
run systemctl start tallyho-mirror.service || true
# The gateway exits until `hermes gateway setup` is done — expected, not fatal.
run systemctl start hermes-gateway.service || true

# --- Firewall + unattended upgrades -----------------------------------------
# WebUI is exposed to the local network (see HERMES_WEBUI_HOST below),
# so port 8787 is opened too. The box is expected to sit behind a
# router NAT / boat LAN, NOT port-forwarded to the public internet,
# and WebUI password auth is mandatory when bound beyond loopback.
log "Configuring firewall (SSH + HTTP(S) + WebUI 8787 + Tailscale interface)"
run ufw allow OpenSSH || true
run ufw allow 80/tcp || true
run ufw allow 443/tcp || true
run ufw allow 8787/tcp || true
run ufw allow in on tailscale0 || true
run ufw --force enable || true
run systemctl enable --now unattended-upgrades || true

# --- Desktop: keep the box awake --------------------------------------------
# A desktop install suspends on idle by default, which would take the
# services (and phone access) down with it. Mask the sleep targets so
# the box stays on. Reversible any time with:
#   sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
log "Disabling automatic suspend (always-on boat box)"
run systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true

# --- Hermes WebUI (autostart on boot is set by `systemctl enable` above) ---
if [ "$NO_WEBUI_START" = "0" ]; then
    if grep -q '^HERMES_WEBUI_PASSWORD=$' "$TALLYHO_ROOT/.env" 2>/dev/null; then
        warn "HERMES_WEBUI_PASSWORD is empty — NOT starting WebUI bound to the local network without a password. Set one in $TALLYHO_ROOT/.env and start it with: sudo systemctl start hermes-webui"
    else
        log "Starting Hermes WebUI (ctl.sh daemon, port 8787 on the local network)"
        run systemctl start hermes-webui.service || \
            warn "Hermes WebUI did not start — check 'sudo systemctl status hermes-webui' and ~/.hermes/webui.log"
    fi
else
    log "Skipping WebUI start (--no-webui-start)"
fi

# --- Tailscale up (interactive unless an auth key is in .env) --------------
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] tailscale status / tailscale up (skipped)"
elif command -v tailscale >/dev/null 2>&1; then
    if tailscale status >/dev/null 2>&1; then
        log "Tailscale already connected"
    else
        AUTHKEY="$(grep '^TAILSCALE_AUTHKEY=' "$TALLYHO_ROOT/.env" 2>/dev/null | cut -d= -f2- || true)"
        if [ -n "${AUTHKEY:-}" ]; then
            log "Connecting Tailscale with auth key from .env"
            tailscale up --authkey="$AUTHKEY" --hostname=tallyho-box || warn "tailscale up failed — run it manually"
        else
            warn "Tailscale not connected yet. Run:  sudo tailscale up"
            warn "Then see docs/TAILSCALE_SETUP.md for phone access and Tailscale Serve."
        fi
    fi
fi

# --- Verification (warnings only — missing setup must not fail install) -----
log "Verification"
check_url() { # $1=url $2=label
    if [ "$DRY_RUN" = "1" ]; then echo "[dry-run] curl $1 ($2)"; return 0; fi
    if curl -sf --max-time 10 "$1" >/dev/null 2>&1; then echo "  OK  $2 ($1)";
    else echo "  ..  $2 not responding yet ($1) — check logs, may still be starting"; fi
}
check_url "http://127.0.0.1:8787/health" "Hermes WebUI health (via loopback, proxied by nginx at /)"
check_url "http://127.0.0.1:8000" "Notion mirror server"
if [ "$DRY_RUN" != "1" ]; then
    systemctl is-active --quiet nginx && echo "  OK  nginx" || echo "  ..  nginx not active"
fi

cat <<'EOF'

================================================================
Tally Ho boat box — install complete (Hermes edition). Next steps:
  1. Run Hermes setup (interactive, as the service user):
       hermes setup        # full wizard
       hermes model        # pick provider/model (cloud, Nous Portal,
                           # or host Ollama as a local/custom endpoint)
     See docs/FIRST_RUN.md.
  2. Open Hermes WebUI and finish its onboarding wizard:
       Locally (Chromium): http://localhost/
       Local network:      http://<box-LAN-IP>/  or  http://<box-LAN-IP>:8787
       Phone (Tailscale):  http://<box-tailscale-ip>/
     WebUI password: read HERMES_WEBUI_PASSWORD in /opt/tallyho/.env.
     All services autostart on reboot (systemd units are enabled);
     after a reboot, verify with:
       sudo systemctl status hermes-webui hermes-gateway tallyho-mirror
  3. Telegram (Hermes gateway, NOT the old MQTT wrapper):
       hermes gateway setup   # select Telegram, enter bot token
                              # + your allowed Telegram user ID
       sudo systemctl restart hermes-gateway
     See docs/TELEGRAM_SETUP.md.
  4. Tailscale phone access + Serve: see docs/TAILSCALE_SETUP.md.
       sudo tailscale up   (if not connected yet)
       sudo tailscale serve --bg 80   (preferred: publishes nginx,
         i.e. WebUI + mirror, over tailnet HTTPS)
  5. First mirror pull:
       cd /opt/tallyho/notion-mirror
       python3 pull_notion.py && python3 render.py
     (then it refreshes twice daily via tallyho-mirror-pull.timer)
     Fill NOTION_TOKEN in /opt/tallyho/.env first.
  6. Re-run this script any time to update/repair: sudo bash install.sh
     (it never overwrites .env; update Hermes Agent + WebUI TOGETHER)
================================================================
EOF
log "Done."
