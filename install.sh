#!/usr/bin/env bash
# Tally Ho boat box — install script.
#
# Installs, on Ubuntu Desktop 24.04 (VM guest):
#   OpenSSH, Tailscale, UFW, Docker + Compose, nginx, Mosquitto,
#   Open WebUI (Docker, pointing at Ollama on the VM HOST — Ollama is
#   deliberately NOT installed in the VM), Hermes Telegram + Open WebUI
#   wrappers, the Notion read-only mirror (pull timer + local server),
#   and Chromium.
#   Grants the service user passwordless sudo.
#
# Usage:
#   sudo ./install.sh [--user boat] [--dry-run] [--no-compose-up]
#
# The script is idempotent: safe to re-run to update or repair. It never
# overwrites an existing /opt/tallyho/.env, and never prints tokens.
#
# Overrides (mainly for testing):
#   TALLYHO_ROOT, NGINX_DIR, SYSTEMD_DIR, SUDOERS_DIR, MOSQUITTO_CONF_DIR
#   DRY_RUN=1  — print privileged commands instead of running them, but
#                still stage files into the override directories.
set -euo pipefail

DRY_RUN=0
NO_COMPOSE_UP=0
ORIGINAL_ARGS=("$@")
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-}}"
while [ $# -gt 0 ]; do
    case "$1" in
        --user) SERVICE_USER="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-compose-up) NO_COMPOSE_UP=1; shift ;;
        -h|--help)
            echo "Usage: sudo $0 [--user NAME] [--dry-run] [--no-compose-up]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ "$DRY_RUN" != "1" ] && [ "$(id -u)" != "0" ]; then
    echo "Re-running under sudo…"
    exec sudo "$0" "${ORIGINAL_ARGS[@]}"
fi
if [ -z "$SERVICE_USER" ]; then SERVICE_USER="boat"; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALLYHO_ROOT="${TALLYHO_ROOT:-/opt/tallyho}"
NGINX_DIR="${NGINX_DIR:-/etc/nginx/sites-available}"
NGINX_ENABLED_DIR="${NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"
MOSQUITTO_CONF_DIR="${MOSQUITTO_CONF_DIR:-/etc/mosquitto/conf.d}"

log() { echo "==> $*"; }
warn() { echo "!!  $*" >&2; }
# run: executes a command, or just prints it in dry-run mode.
run() {
    if [ "$DRY_RUN" = "1" ]; then echo "[dry-run] $*"; else "$@"; fi
}

# --- OS guard ---------------------------------------------------------------
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "24.04" ]; then
        warn "This script targets Ubuntu 24.04 (found ${ID:-?} ${VERSION_ID:-?})."
        warn "Set FORCE_OS=1 to run anyway."
        [ "${FORCE_OS:-0}" = "1" ] || exit 1
    fi
fi

log "Tally Ho boat box install — user: $SERVICE_USER, root: $TALLYHO_ROOT"

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

# --- Base packages ----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
log "Installing base packages"
run apt-get update -qq
run apt-get install -y -qq openssh-server ufw nginx mosquitto mosquitto-clients \
    python3 python3-paho-mqtt python3-requests git curl rsync ca-certificates \
    unattended-upgrades docker.io docker-compose-v2 openssl lsb-release gnupg snapd

# --- Tailscale (official apt repo) ------------------------------------------
if ! command -v tailscale >/dev/null 2>&1 || [ "$DRY_RUN" = "1" ]; then
    log "Installing Tailscale"
    if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] install tailscale apt repo + apt-get install -y tailscale"
    else
        mkdir -p /usr/share/keyrings
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
            -o /etc/apt/sources.list.d/tailscale.list
        apt-get update -qq
        apt-get install -y -qq tailscale
    fi
else
    log "Tailscale already installed"
fi

# --- Docker -----------------------------------------------------------------
log "Enabling Docker"
run systemctl enable --now docker
run usermod -aG docker "$SERVICE_USER" || true
log "(Group change needs a re-login for $SERVICE_USER to run docker directly; services use systemd, so they are unaffected.)"

# --- Mosquitto: localhost only ----------------------------------------------
log "Configuring Mosquitto (localhost only)"
mkdir -p "$MOSQUITTO_CONF_DIR"
cat > "$MOSQUITTO_CONF_DIR/tallyho.conf" <<'EOF'
# Tally Ho: Hermes bus is local only. Nothing on the network talks MQTT.
listener 1883 127.0.0.1
allow_anonymous true
EOF
run systemctl enable --now mosquitto
run systemctl restart mosquitto || true

# --- Chromium ---------------------------------------------------------------
# On Ubuntu 24.04 the apt package is the Chromium snap build, so this
# also needs snapd (installed above). This is a Desktop install, so
# Chromium opens normally in the GUI; `chromium --headless` also works.
if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; then
    log "Chromium already installed"
else
    log "Installing Chromium"
    run apt-get install -y -qq chromium-browser || run apt-get install -y -qq chromium || \
        warn "Chromium install failed — install it manually: sudo apt install chromium-browser"
fi

# --- Copy the bundle --------------------------------------------------------
log "Installing bundle to $TALLYHO_ROOT"
mkdir -p "$TALLYHO_ROOT/hermes" "$TALLYHO_ROOT/notion-mirror"
cp "$SCRIPT_DIR/docker-compose.yml" "$TALLYHO_ROOT/docker-compose.yml"
cp "$SCRIPT_DIR/hermes/hermes-telegram-wrapper.py" "$SCRIPT_DIR/hermes/hermes-openwebui-wrapper.py" \
    "$TALLYHO_ROOT/hermes/"
cp "$SCRIPT_DIR/notion-mirror/pull_notion.py" "$SCRIPT_DIR/notion-mirror/render.py" \
    "$SCRIPT_DIR/notion-mirror/serve.py" "$SCRIPT_DIR/notion-mirror/pages.json" \
    "$TALLYHO_ROOT/notion-mirror/"
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

# --- .env: create once, never overwrite, generate the WebUI secret ----------
if [ ! -f "$TALLYHO_ROOT/.env" ]; then
    cp "$SCRIPT_DIR/.env.example" "$TALLYHO_ROOT/.env"
    log "Created $TALLYHO_ROOT/.env from .env.example — fill in the tokens (see README)"
else
    log "$TALLYHO_ROOT/.env already exists — leaving it untouched"
fi
if grep -q '^WEBUI_SECRET_KEY=$' "$TALLYHO_ROOT/.env" 2>/dev/null; then
    SECRET="$(openssl rand -hex 32)"
    # shellcheck disable=SC2001
    sed -i "s/^WEBUI_SECRET_KEY=$/WEBUI_SECRET_KEY=$SECRET/" "$TALLYHO_ROOT/.env"
    log "Generated WEBUI_SECRET_KEY in .env"
fi
chmod 600 "$TALLYHO_ROOT/.env" || true
# Service user must read .env (systemd EnvironmentFile) and write mirror output.
if [ "$DRY_RUN" != "1" ]; then
    chown -R "$SERVICE_USER:$SERVICE_USER" "$TALLYHO_ROOT/hermes" "$TALLYHO_ROOT/notion-mirror" || true
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
for unit in tallyho-stack hermes-telegram hermes-openwebui tallyho-mirror tallyho-mirror-pull; do
    sed -e "s/__SERVICE_USER__/$SERVICE_USER/g" -e "s|/opt/tallyho|$TALLYHO_ROOT|g" \
        "$SCRIPT_DIR/systemd/$unit.service" > "$SYSTEMD_DIR/$unit.service"
done
cp "$SCRIPT_DIR/systemd/tallyho-mirror-pull.timer" "$SYSTEMD_DIR/tallyho-mirror-pull.timer"
run systemctl daemon-reload
run systemctl enable tallyho-stack.service hermes-telegram.service hermes-openwebui.service \
    tallyho-mirror.service tallyho-mirror-pull.timer
run systemctl start tallyho-mirror.service || true
# Hermes wrappers exit until tokens are filled in .env — expected, not fatal.
run systemctl start hermes-telegram.service hermes-openwebui.service || true

# --- Firewall + unattended upgrades -----------------------------------------
log "Configuring firewall (SSH + HTTP(S) + Tailscale interface only)"
run ufw allow OpenSSH || true
run ufw allow 80/tcp || true
run ufw allow 443/tcp || true
run ufw allow in on tailscale0 || true
run ufw --force enable || true
run systemctl enable --now unattended-upgrades || true

# --- Desktop: keep the box awake ------------------------------------------
# A desktop install suspends on idle by default, which would take the
# services (and phone access) down with it. Mask the sleep targets so
# the box stays on. Reversible any time with:
#   sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
log "Disabling automatic suspend (always-on boat box)"
run systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true

# --- Container stack --------------------------------------------------------
if [ "$NO_COMPOSE_UP" = "0" ]; then
    log "Starting Open WebUI stack (Docker Compose)"
    (cd "$TALLYHO_ROOT" && run docker compose pull && run docker compose up -d) || \
        warn "Docker Compose stack did not start — check 'docker compose logs' in $TALLYHO_ROOT"
else
    log "Skipping compose up (--no-compose-up)"
fi

# --- Tailscale up (interactive unless an auth key is in .env) --------------
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] tailscale status / tailscale up (skipped)"
elif command -v tailscale >/dev/null 2>&1; then
    if tailscale status >/dev/null 2>&1; then
        log "Tailscale already connected"
    else
        AUTHKEY="$(grep '^TAILSCALE_AUTHKEY=' "$TALLYHO_ROOT/.env" 2>/dev/null | cut -d= -f2- || true)"
        if [ -n "${AUTHKEY:-}" ] && [ "$DRY_RUN" != "1" ]; then
            log "Connecting Tailscale with auth key from .env"
            tailscale up --authkey="$AUTHKEY" --hostname=tallyho-box || warn "tailscale up failed — run it manually"
        else
            warn "Tailscale not connected yet. Run:  sudo tailscale up"
            warn "Then note this box's Tailscale IP for phone access and for the host Ollama address."
        fi
    fi
fi

# --- Verification (warnings only — a missing token must not fail install) ---
log "Verification"
check_url() { # $1=url $2=label
    if [ "$DRY_RUN" = "1" ]; then echo "[dry-run] curl $1 ($2)"; return 0; fi
    if curl -sf --max-time 10 "$1" >/dev/null 2>&1; then echo "  OK  $2 ($1)";
    else echo "  ..  $2 not responding yet ($1) — check logs, may still be starting"; fi
}
check_url "http://127.0.0.1:3000" "Open WebUI (via Docker, proxied by nginx at /)"
check_url "http://127.0.0.1:8000" "Notion mirror server"
if [ "$DRY_RUN" != "1" ]; then
    systemctl is-active --quiet mosquitto && echo "  OK  mosquitto" || echo "  ..  mosquitto not active"
    systemctl is-active --quiet nginx && echo "  OK  nginx" || echo "  ..  nginx not active"
fi

cat <<'EOF'

================================================================
Tally Ho boat box — install complete. Next steps:
  1. Fill in /opt/tallyho/.env  (NOTION_TOKEN, TELEGRAM_BOT_TOKEN,
     TELEGRAM_CHAT_ID, OWUI_API_KEY, OWUI_MODEL, OLLAMA_BASE_URL)
     then:  sudo systemctl restart hermes-telegram hermes-openwebui
  2. On the VM HOST (not the VM): install Ollama, set
     OLLAMA_HOST=0.0.0.0:11434, pull a model, and open port 11434
     only to this VM / Tailscale. Put the host's Tailscale IP in
     OLLAMA_BASE_URL above (e.g. http://100.x.y.z:11434).
  3. Run:  sudo tailscale up   (if not connected yet)
     Phone: http://<box-tailscale-ip>/  -> Open WebUI
            http://<box-tailscale-ip>/mirror/  -> Notion mirror
     Locally (Chromium on the box): http://localhost/ and http://localhost/mirror/
  4. First mirror pull:
       cd /opt/tallyho/notion-mirror
       python3 pull_notion.py && python3 render.py
     (then it refreshes twice daily via tallyho-mirror-pull.timer)
  5. In Open WebUI: create the admin account, enable Channels
     (Admin Settings -> General), add a cloud model key if you
     want the cloud lane (Admin Settings -> Connections).
  6. Re-run this script any time to update/repair: sudo ./install.sh
     (it never overwrites .env)
================================================================
EOF
log "Done."
