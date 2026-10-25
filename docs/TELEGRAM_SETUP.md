# Telegram setup — Hermes Agent gateway (walkthrough)

This is for Hermes Agent's own messaging gateway — **not** the old
MQTT wrapper from the Open WebUI edition, which is gone. The same
Hermes agent you talk to in WebUI is the one that answers on
Telegram, with the same memory and skills.

Do this in order. You need: a Telegram account, the Telegram app
on your phone, and a working model in Hermes first (see
`docs/FIRST_RUN.md` step 2 — a gateway with no model cannot answer).

## Step 1 — Create the bot with BotFather

1. Open Telegram, search for `@BotFather`, and start a chat with it.
2. Send `/newbot`.
3. Give the bot a display name (anything you like, e.g. `Tally Ho AI`).
4. Give it a username ending in `bot` (e.g. `tallyhoai_bot`). The
   username must be unique across Telegram.
5. BotFather replies with a **bot token** — a long string like
   `123456789:AA...`. Copy it somewhere safe and **never share it,
   never post it, never commit it**. Anyone with the token can
   control your bot.

If you ever leak the token, go back to BotFather, send `/revoke`,
pick your bot, and get a fresh token — then re-run gateway setup
below with the new one.

## Step 2 — Get your Telegram user ID (the allowlist)

Hermes must know which Telegram account to trust, or anyone who
finds your bot could talk to your agent.

1. Search for `@userinfobot` on Telegram and send it any message.
2. It replies with your numeric user ID. Copy that number.

Alternative: message your new bot once, then open
`https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser
(replace `<TOKEN>` with your bot token) and read the numeric `id`
for your account in the JSON. For a private chat, that ID is your
user ID.

You will enter this ID as the allowed user in gateway setup. Only
that account will be answered. Do not skip this step.

## Step 3 — Configure the gateway

On the box, as the service user:

```bash
hermes gateway setup
```

Select **Telegram** when prompted, then enter your bot token and
your allowed user ID. If you prefer to set the values directly,
Hermes reads them from your profile's `.env` (under `~/.hermes/`):

```
TELEGRAM_BOT_TOKEN=<your bot token>
TELEGRAM_ALLOWED_USERS=<your numeric user ID>
```

Do not put these in `/opt/tallyho/.env` — that file is for the
box services (WebUI password, Notion token), not for Hermes'
own gateway config. Keep the two files separate.

## Step 4 — Start the gateway and test with a DM first

```bash
sudo systemctl restart hermes-gateway
sudo systemctl status hermes-gateway
```

Then, from **your own** Telegram account (the allowed one), open
your bot and send it a task — something small and verifiable,
like asking it what directory it is working in. Confirm you get a
real answer before doing anything else.

Test a private DM **before** adding the bot to any group. Groups
and topics come after a working DM, and only if you need them:
add the bot to the group, confirm it still only answers allowed
users, and check whether it needs to be mentioned to respond in
a busy group. If it answers strangers in a group, stop and fix
the allowlist before continuing.

## Rules that keep this safe

- **One gateway per token.** Running two gateways with the same
  bot token causes polling conflicts (messages go to one or the
  other, or neither reliably). The box's `hermes-gateway` service
  is the one owner of this token — do not also run `hermes gateway`
  by hand in a terminal at the same time.
- **Gateway stops = bot stops.** The bot only answers while the
  gateway process is running. That is why it runs as a systemd
  service with autostart on boot, not in a terminal you might close.
- **Keep dangerous actions behind approval.** Hermes can run tools
  and commands. Do not allowlist anyone else until you have
  deliberately decided they may ask your agent to act, and keep
  purchases, deletions, external messages, and system changes
  behind explicit confirmation (see `docs/AI_INSTRUCTIONS.md`).

## If the bot is silent

Work through this in order instead of rotating the token first:

1. Is the gateway running? `sudo systemctl status hermes-gateway`
   and `sudo journalctl -u hermes-gateway -n 50`.
2. Is a model configured and working? Test `hermes` in a terminal.
   A gateway with no working model cannot complete a reply.
3. Is the sender the allowed user ID from step 2? Messages from
   anyone else are ignored by design.
4. Is the token correct and current? If you revoked it in
   BotFather, re-run `hermes gateway setup` with the new token.
5. Is another gateway using the same token somewhere (old laptop,
   terminal session, another container)? Stop the other one.
