#!/usr/bin/env python3
"""
Hermes -> Open WebUI voice-command wrapper.

Companion to hermes-telegram-wrapper.py: instead of forwarding what you said
to Telegram, this posts each captured utterance to your Open WebUI instance
as a chat message and prints the model's reply. The reply lands in the Open
WebUI chat thread itself, so you read it on your phone/laptop — no TTS,
no Telegram.

Setup:
  1. pip install paho-mqtt requests
  2. In Open WebUI: profile icon (bottom-left) -> Settings -> Account ->
     API Keys -> click "Show", then "Create new secret key". Paste it into
     CONFIG["owui_api_key"] below.
  3. Pick the model id from Open WebUI's model dropdown (exact string),
     e.g. "llama3.1:8b" for a local Ollama model or "gpt-4o-mini" for a
     cloud backend you connected in Admin Settings -> Connections.
  4. (Optional) In Open WebUI, start a chat named e.g. "Voice", open it, and
     copy the chat id from the URL (.../c/<chat_id>) into CONFIG["chat_id"]
     so every voice command lands in that one thread. Leave "" for a fresh
     rolling thread per run (history is still kept in-memory).
  5. Fill in CONFIG and run:  python3 hermes-openwebui-wrapper.py

Endpoint used: POST {base_url}/api/chat/completions  (OpenAI-compatible)
"""

import json
import os
import sys
import time
from collections import deque

import paho.mqtt.client as mqtt
import requests

CONFIG = {
    "mqtt_host": "localhost",     # broker the Hermes stack talks to
    "mqtt_port": 1883,
    "owui_base_url": "http://localhost:3000",  # or http://100.x.y.z:3000 via Tailscale
    "owui_api_key": "",           # Open WebUI -> profile -> Settings -> API Keys
    "model": "",                  # exact model id from the Open WebUI dropdown
    "chat_id": "",                # optional: existing chat id to keep one thread
    "system_prompt": (
        "You are the Tally Ho boat assistant. Answer concisely, like a "
        "knowledgeable crew member. The user is speaking via voice, so keep "
        "replies short enough to read at a glance."
    ),
    "history_turns": 10,          # rolling user/assistant turns kept in context
    "timeout_s": 180,             # local models can be slow on first token
}

# Boat-box install: environment variables (from /opt/tallyho/.env via the
# systemd unit) override the CONFIG values above. Original behaviour is
# unchanged when unset.
CONFIG["owui_base_url"] = os.environ.get("OWUI_BASE_URL", CONFIG["owui_base_url"])
CONFIG["owui_api_key"] = os.environ.get("OWUI_API_KEY", CONFIG["owui_api_key"])
CONFIG["model"] = os.environ.get("OWUI_MODEL", CONFIG["model"])
CONFIG["chat_id"] = os.environ.get("OWUI_CHAT_ID", CONFIG["chat_id"])
CONFIG["mqtt_host"] = os.environ.get("MQTT_HOST", CONFIG["mqtt_host"])


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


class OwuiClient:
    def __init__(self):
        self.history: deque = deque(maxlen=CONFIG["history_turns"] * 2)

    def ask(self, text: str) -> str:
        messages = [{"role": "system", "content": CONFIG["system_prompt"]}]
        messages += list(self.history)
        messages.append({"role": "user", "content": text})

        body = {"model": CONFIG["model"], "messages": messages, "stream": False}
        if CONFIG["chat_id"]:
            body["chat_id"] = CONFIG["chat_id"]

        r = requests.post(
            f"{CONFIG['owui_base_url'].rstrip('/')}/api/chat/completions",
            headers={"Authorization": f"Bearer {CONFIG['owui_api_key']}"},
            json=body,
            timeout=CONFIG["timeout_s"],
        )
        r.raise_for_status()
        reply = r.json()["choices"][0]["message"]["content"].strip()

        self.history.append({"role": "user", "content": text})
        self.history.append({"role": "assistant", "content": reply})
        return reply


owui = OwuiClient()


def on_connect(client, userdata, flags, reason_code, properties=None):
    print(f"[mqtt] connected ({reason_code}), subscribing…")
    client.subscribe("hermes/asr/textCaptured")


def on_message(client, userdata, msg):
    text = payload_text(msg.payload)
    if not text:
        return
    print(f"[asr] {text}")
    try:
        reply = owui.ask(text)
    except Exception as e:  # keep listening even if Open WebUI hiccups
        print(f"[openwebui] request failed: {e}", file=sys.stderr)
        return
    print(f"[reply] {reply}")


def main() -> None:
    missing = [k for k in ("owui_api_key", "model") if not CONFIG[k]]
    if missing:
        sys.exit(f"Fill in {', '.join(missing)} in CONFIG first (see docstring).")
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
