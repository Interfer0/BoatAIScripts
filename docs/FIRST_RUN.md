# First run — Hermes Agent + Hermes WebUI on the boat box

This is the order that works. Do it top to bottom; each step assumes
the one before it is done. The install script (`install.sh`) only
installs software — it deliberately does **not** pick your model,
your Telegram bot, or your Tailscale account for you. Those are
interactive first-run steps, below.

Run the `hermes` commands below as the service user (the user you
passed to `install.sh` with `--user`, defaulting to your sudo user),
not as root. If `hermes` is not found in a fresh shell, reload it
first: `source ~/.bashrc`.

## 1. Install the box

```bash
git clone https://github.com/Interfer0/BoatAIScripts.git
cd BoatAIScripts
sudo bash install.sh
```

Run it via `bash`: after a fresh clone `install.sh` is not marked
executable in git, so `./install.sh` gives "Permission denied".
Re-running `install.sh` later is safe (it never overwrites `.env`).

## 2. Set up Hermes Agent (model first)

```bash
hermes setup        # full wizard, or:
hermes setup --portal   # Nous Portal OAuth: one login for a Nous model
                            # plus web search / image / browser tools
hermes model        # pick provider + default model, any time
```

Pick one lane to start with:

- **Cloud (simplest):** a provider key (OpenAI, Anthropic, Google,
  DeepSeek, OpenRouter, …) via `hermes model`. Works when you have
  internet; does not work offshore with no connection.
- **Nous Portal:** `hermes setup --portal` (OAuth, per Hermes docs).
- **Local, on the boat:** host Ollama — remember, Ollama is **not**
  installed in the VM (VMs get poor GPU access). Install Ollama on
  the VM host, set `OLLAMA_HOST=0.0.0.0:11434` there, open port
  11434 only to this VM / Tailscale, then point Hermes at it in
  `hermes model` as an Ollama provider or a custom OpenAI-compatible
  endpoint (base URL, model name, context window when prompted).
  If the host is off or asleep, the local lane is down — the cloud
  lane is the fallback, when you have internet.

Verify it before adding anything else:

```bash
hermes
```

Ask it something concrete with a tool call, e.g. to inspect a
directory. If Hermes answers and a tool works, the base install is
good. If config starts behaving strangely later, first run
`hermes doctor`.

## 3. Finish Hermes WebUI onboarding

Open Hermes WebUI in Chromium on the box, or from any device on the local
network (WebUI is exposed to the LAN, password-protected):

```
http://localhost/
http://<box-LAN-IP>/
http://<box-LAN-IP>:8787
```

Do not port-forward 8787 or 80 to the public internet — the box
is expected to sit behind a router NAT on the boat LAN.

WebUI password: read `HERMES_WEBUI_PASSWORD` in `/opt/tallyho/.env`
(the installer generates one if you left it blank; change it to one
you remember if you like, then `sudo systemctl restart hermes-webui`).

Complete the first-run onboarding wizard in WebUI: profile, model,
and workspace. Model/profile/workspace controls live in the composer
footer; settings and session tools are in the Hermes Control Center
(launcher at the sidebar bottom). Set the workspace to
`/opt/tallyho/workspace` (created by the installer) or to a folder
you choose, and put the files Hermes should know — manuals, survey,
boat notes — where it can browse them.

Then paste the AI instructions from `docs/AI_INSTRUCTIONS.md` into
your WebUI profile / system prompt (replace the `<PLACEHOLDERS>`
first). That is the document that tells Hermes what boat it is
working on and what rules it follows.

Health check any time: `curl http://127.0.0.1:8787/health`.

## 4. Telegram

Follow `docs/TELEGRAM_SETUP.md` in full. Short version:

```bash
hermes gateway setup   # select Telegram, enter bot token + your
                       # allowed Telegram user ID
sudo systemctl restart hermes-gateway
```

Then message your bot from your own Telegram account and confirm
it answers before adding it to any group.

## 5. Tailscale (phone access)

Follow `docs/TAILSCALE_SETUP.md` in full. Short version:

```bash
sudo tailscale up
tailscale ip -4        # this box's tailnet IP
```

Phone: `http://<box-tailscale-ip>/` for WebUI,
`http://<box-tailscale-ip>/mirror/` for the Notion mirror.
Preferred for WebUI: Tailscale Serve (see that doc) — it keeps
WebUI on loopback and gives you a tailnet HTTPS address.

## 6. Notion mirror (first pull)

```bash
# Fill NOTION_TOKEN in /opt/tallyho/.env first: create a Notion
# integration, share the four pages with it (Refit HQ, Master
# Checklist, Project Costs, Systems Reference), paste the token.
cd /opt/tallyho/notion-mirror
python3 pull_notion.py && python3 render.py
```

After that it refreshes twice daily on its own
(`tallyho-mirror-pull.timer`). The mirror is read-only: Hermes
reads it, it never edits Notion. If a pull fails (offline on the
boat), the timer retries later and the last good snapshot keeps
serving.

## 7. Test checklist (do all of these before calling it done)

- [ ] `hermes` in a terminal answers with a working model
- [ ] WebUI opens at `http://localhost/`, onboarding complete, password works
- [ ] One Telegram DM to your bot gets an answer
- [ ] WebUI + mirror open from your phone over Tailscale
- [ ] Mirror shows current Notion data (check the snapshot banner time)
- [ ] `sudo systemctl status hermes-webui hermes-gateway tallyho-mirror`
      shows all three active (gateway only after step 4)
- [ ] Reboot the box, wait a minute, and confirm WebUI, gateway,
      and mirror all come back on their own (all units are enabled
      for autostart — if WebUI does not come back, check
      `sudo systemctl status hermes-webui` and `~/.hermes/webui.log`,
      then `sudo systemctl restart hermes-webui`)

## Updates (important)

Hermes WebUI imports Hermes Agent modules directly, and upstream
warns version skew is untested/unsupported. **Update both together:**

```bash
# As the service user, in each repo, pull the matching release,
# then restart:
sudo systemctl restart hermes-webui hermes-gateway
```

Re-running `install.sh` pulls the latest WebUI clone and re-applies
configs, but it does not by itself update the Hermes Agent install —
update that with the agent's own update path and keep the versions
matched.

## Troubleshooting pointers

```bash
sudo systemctl status hermes-webui hermes-gateway tallyho-mirror
sudo journalctl -u hermes-gateway -n 50
tail -n 100 ~/.hermes/webui.log
sudo nginx -t && sudo systemctl reload nginx
hermes doctor
```
