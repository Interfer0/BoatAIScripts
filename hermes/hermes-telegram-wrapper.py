#!/usr/bin/env python3
"""
Hermes -> Telegram voice-command wrapper.

Sits on the Hermes MQTT bus (Snips.AI / Rhasspy `hermes/*` protocol) and sends
what you said — and optionally what your agent did with it — to Telegram as
text messages, instead of speaking replies back with TTS.

Setup:
  1. pip install paho-mqtt requests
  2. Get a bot token from @BotFather on Telegram.
  3. Message your bot once, then open
         https://api.telegram.org/bot<TOKEN>/getUpdates
     and read your chat id from the JSON.
  4. Fill in CONFIG below and run:  python3 hermes-telegram-wrapper.py

Modes (CONFIG["mode"]):
  "transcript"        -> forwards every captured utterance from
                         hermes/asr/textCaptured
  "transcript+reply"  -> also intercepts hermes/tts/say and forwards the
                         agent's reply text (nothing is spoken — the wrapper
                         replaces TTS entirely)

If your Hermes agent publishes replies on a custom topic instead of
hermes/tts/say, put it in CONFIG["agent_reply_topic"].
"""

import json
import os
import sys
import time

import paho.mqtt.client as mqtt
import requests

CONFIG = {
    "mqtt_host": "localhost",     # broker the Hermes stack talks to
    "mqtt_port": 1883,
    "mode": "transcript+reply",   # "transcript" or "transcript+reply"
    "agent_reply_topic": "hermes/tts/say",  # topic carrying the agent's reply
    "bot_token": "",              # from @BotFather
    "chat_id": "",                # your chat id from getUpdates
}

# Boat-box install: environment variables (from /opt/tallyho/.env via the
# systemd unit) override the CONFIG values above, so tokens never have to
# be edited into this file. Original behaviour is unchanged when unset.
CONFIG["bot_token"] = os.environ.get("TELEGRAM_BOT_TOKEN", CONFIG["bot_token"])
CONFIG["chat_id"] = os.environ.get("TELEGRAM_CHAT_ID", CONFIG["chat_id"])
CONFIG["mqtt_host"] = os.environ.get("MQTT_HOST", CONFIG["mqtt_host"])


def send_telegram(text: str) -> None:
    url = f"https://api.telegram.org/bot{CONFIG['bot_token']}/sendMessage"
    try:
        r = requests.post(
            url,
            json={"chat_id": CONFIG["chat_id"], "text": text},
            timeout=10,
        )
        r.raise_for_status()
    except Exception as e:  # keep listening even if Telegram hiccups
        print(f"[telegram] send failed: {e}", file=sys.stderr)


def payload_text(payload: bytes) -> str:
    """Rhasspy publishes JSON like {"text": "..."}; some setups send raw text."""
    raw = payload.decode("utf-8", errors="replace").strip()
    try:
        data = json.loads(raw)
        if isinstance(data, dict) and "text" in data:
            return str(data["text"])
    except (json.JSONDecodeError, ValueError):
        pass
    return raw


def on_connect(client, userdata, flags, reason_code, properties=None):
    print(f"[mqtt] connected ({reason_code}), subscribing…")
    client.subscribe("hermes/asr/textCaptured")
    if CONFIG["mode"] == "transcript+reply":
        client.subscribe(CONFIG["agent_reply_topic"])


def on_message(client, userdata, msg):
    text = payload_text(msg.payload)
    if not text:
        return
    if msg.topic == "hermes/asr/textCaptured":
        print(f"[asr] {text}")
        send_telegram(f"🎤 {text}")
    elif msg.topic == CONFIG["agent_reply_topic"]:
        print(f"[reply] {text}")
        send_telegram(f"🤖 {text}")


def main() -> None:
    if not CONFIG["bot_token"] or not CONFIG["chat_id"]:
        sys.exit("Fill in bot_token and chat_id in CONFIG first (see docstring).")
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.on_connect = on_connect
    client.on_message = on_message
    while True:  # loop_forever reconnects on broker drops; this guards connect
        try:
            client.connect(CONFIG["mqtt_host"], CONFIG["mqtt_port"], keepalive=60)
            client.loop_forever()
        except Exception as e:
            print(f"[mqtt] {e} — retrying in 5s…", file=sys.stderr)
            time.sleep(5)


if __name__ == "__main__":
    main()
