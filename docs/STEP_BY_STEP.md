# Step-by-step setup — boat box (Hermes edition)

Do these steps **in order, top to bottom**. Do not skip ahead: each
step assumes the one before it worked.

Every step has the same three parts:

- **Do** — the one action for this step.
- **Check** — how you know it worked. Do not move on until the
  check passes.
- **If the check fails** — the one thing to try. Only that thing.

You need before you start: an Ubuntu Desktop 24.04 or 26.04 VM,
internet, a Telegram account, a Tailscale account, and (for Step 8)
a Notion account. The `hermes` commands run as the service user —
the user you installed with, usually your own username — not as
root. If a `hermes` command says "command not found" in a fresh
terminal, run `source ~/.bashrc` first and try again.

---

## Step 1 — Install the box

**Do:**

```bash
git clone https://github.com/Interfer0/BoatAIScripts.git
cd BoatAIScripts
sudo bash install.sh
```

Run it with `bash` on purpose: after a fresh clone `install.sh`
is not marked executable, so `./install.sh` fails with
"Permission denied".

**Check:** The install finishes and prints its next-steps list
with no error line at the end.

**If the check fails:** Send back the last error line exactly
as printed. Do not change anything else first.

---

## Step 2 — Confirm the services are running

**Do:**

```bash
sudo systemctl status hermes-webui.service tallyho-mirror.service --no-pager
```

**Check:** Both show `active`. Do **not** worry about
`hermes-gateway` here — it shows as failed until Step 5, and
that is normal. It only starts working once a bot is configured.

**If the check fails:** Run `sudo systemctl restart hermes-webui`
once, then check again. If it still fails, stop here and send
back the output of `sudo systemctl status hermes-webui.service`.

---

## Step 3 — Open Hermes WebUI and finish onboarding

**Do:** Find your WebUI password, then open WebUI in Chromium
on the box:

```bash
sudo grep HERMES_WEBUI_PASSWORD /opt/tallyho/.env
```

```
http://localhost/
```

From another device on the same local network, use
`http://<box-LAN-IP>/` instead — find that IP with `hostname -I`
on the box (use the first address, not `127.0.0.1`).

**Check:** The WebUI login page opens, and the password from
`.env` logs you in.

**If the check fails:** On the box, run
`curl http://127.0.0.1:8787/health`. If that answers, WebUI is
running and the problem is the address or password you used —
re-check both. If it does not answer, go back to Step 2.

**Do (still Step 3):** Complete the first-run onboarding wizard
in WebUI: profile, model, and workspace. Set the workspace to
`/opt/tallyho/workspace`.

Then open `docs/AI_INSTRUCTIONS.md`, replace every
`<PLACEHOLDER>` with your own details, and paste the result
into your WebUI profile / system prompt. This is what tells
Hermes which boat it is working on and what rules it follows.

**Check:** WebUI shows your workspace and accepts the
instructions (no placeholder text left in what you pasted).

**If the check fails:** Re-open the pasted instructions and
search for `<` — any placeholder you missed is the problem.

---

## Step 4 — Pick a model

**Do:**

```bash
hermes setup        # full wizard, or:
hermes setup --portal   # Nous Portal OAuth login
hermes model        # pick provider + default model, any time
```

Pick one lane to start with:

- **Cloud (simplest):** a provider key (OpenAI, Anthropic,
  Google, DeepSeek, OpenRouter, …) via `hermes model`. Works
  with internet; does not work offshore with no connection.
- **Local, on the boat:** Ollama is **not** installed in the
  VM (VMs get poor GPU access). Install Ollama on the VM host,
  set `OLLAMA_HOST=0.0.0.0:11434` there, open port 11434 only
  to this VM, then point Hermes at it in `hermes model` as an
  Ollama provider or a custom OpenAI-compatible endpoint.

**Check:** Run `hermes` in a terminal and ask it something
concrete, like what directory it is working in. It answers.

**If the check fails:** Run `hermes doctor` and fix the first
problem it reports.

---

## Step 5 — Telegram (bot first, DM test second)

**Do, in this order:**

1. In Telegram, chat with `@BotFather`, send `/newbot`, give
   it a display name and a username ending in `bot`. Copy the
   bot token it replies with. **Never share, post, or commit
   that token.**
2. In Telegram, chat with `@userinfobot` and send any message.
   Copy the numeric user ID it replies with. This is your
   allowlist — only this account will be answered.
3. On the box, as the service user:

```bash
hermes gateway setup
```

Select Telegram, enter the bot token and your user ID, then:

```bash
sudo systemctl restart hermes-gateway
```

**Check:** From **your own** Telegram account, open your bot
and send it a message. It answers.

**If the check fails:** First confirm the sender is the
allowed user ID from step 2 — messages from anyone else are
ignored by design. If you are the allowed user and it is
still silent, confirm a model works (Step 4) before touching
the token.

**Do not** add the bot to a group until the DM test passes.
Full details, including the group rules and the silent-bot
order, are in `docs/TELEGRAM_SETUP.md` — only open it if the
DM test fails.

---

## Step 6 — Tailscale (phone access)

**Do:**

1. Sign up at tailscale.com with a login you already use
   (Google, Microsoft, GitHub, …).
2. On the box:

```bash
sudo tailscale up
```

Sign in with the same account when it asks.
3. Install the Tailscale app on your phone, sign in with the
   **same** account, and switch Tailscale on.
4. On the box, publish the front door:

```bash
sudo tailscale serve --bg 80
```

Tailscale prints an HTTPS MagicDNS URL.

**Check:** Open that HTTPS URL on your phone. WebUI opens
and asks for its password.

**If the check fails:** Run `tailscale ip -4` on the box and
open `http://<that-IP>/` on your phone instead. If that works,
Tailscale itself is fine and only Serve needs a second look
(full Serve notes are in `docs/TAILSCALE_SETUP.md`).

---

## Step 7 — Notion mirror (first pull)

Skip this step if you do not use Notion.

**Do:**

1. In Notion, create an integration and copy its token.
2. Share these four pages with that integration: Refit HQ,
   Refit Master Checklist, Project Costs, Systems Reference.
3. On the box, put the token in `.env`:

```bash
sudo nano /opt/tallyho/.env
```

Find the `NOTION_TOKEN=` line and paste the token directly
after the `=` — no spaces around it, no quotes. Save with
Ctrl+O, Enter, then Ctrl+X.
4. Run the first pull:

```bash
sudo systemctl start tallyho-mirror-pull.service
```

**Check:** Open `http://localhost/mirror/` and look at the
snapshot banner time at the top of a page. It shows today.

**If the check fails:** Run the pull by hand once to see the
actual error (the service only reports that it failed, not why):

```bash
cd /opt/tallyho/notion-mirror
set -a; source /opt/tallyho/.env; set +a
python3 pull_notion.py
```

"Unauthorized" means the token is wrong. "Not found" means a
page has not been shared with the integration yet. Fix that
one thing and run the pull again.

After this first pull, you do not repeat it by hand — the
timer pulls and re-renders twice a day on its own. The mirror
is read-only: it never edits Notion.

---

## Step 8 — Reboot test (do not skip this)

**Do:**

```bash
sudo reboot
```

Wait a minute or two for the box to come back up.

**Check:** All three of these work without you starting
anything by hand: WebUI opens at `http://localhost/`, a
Telegram DM to your bot gets an answer, and the mirror opens
at `http://localhost/mirror/`.

**If the check fails:** Note which one of the three did not
come back, and check only that service, e.g.
`sudo systemctl status hermes-webui.service`. Everything is
meant to autostart, so a service that stays down after reboot
is a real problem — report which one.

---

## Done — and keeping it updated

You are done when Step 8 passes. From here:

- **Update the bundle:** `cd BoatAIScripts`, `git pull`,
  then `sudo bash install.sh` again. Re-running never
  overwrites your existing `/opt/tallyho/.env`.
- **Update Hermes Agent + WebUI together, always.** WebUI
  imports Agent modules directly, and upstream warns version
  skew is untested/unsupported. Update both to matching
  releases, then `sudo systemctl restart hermes-webui
  hermes-gateway`.

If you want the long versions of any step, they still exist:
`docs/FIRST_RUN.md` (full first-run order),
`docs/TELEGRAM_SETUP.md`, and `docs/TAILSCALE_SETUP.md`.
This guide is the one to follow first; the others are
reference, not a second set of instructions.
