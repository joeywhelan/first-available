"""Talk to the Netomi virtual agent through the Netomi Headless Chat API.

One token per notebook run (tokens last 24 hours). One POST per customer message,
reusing the same conversationId so the agent keeps the context.
"""

import html
import json
import os
import re
import time
import uuid

import requests
from dotenv import load_dotenv

load_dotenv()


def chat_headers():
    """Headers every Chat API call needs."""
    return {
        "Content-Type": "application/json",
        "x-channel": "CHAT",
        "x-channel-ref-id": os.environ["NETOMI_CHANNEL_REF_ID"],
        "x-virtual-agent-id": os.environ["NETOMI_VIRTUAL_AGENT_ID"],
    }


def check(response):
    """Raise a readable error (Netomi's own message) for a failed call. Never shows the token.

    Any 2xx is success: the auth call returns 200, and each chat message returns 201 Created.
    """
    if not 200 <= response.status_code < 300:
        try:
            message = response.json().get("message", response.text)
        except ValueError:
            message = response.text
        raise RuntimeError(f"Netomi returned HTTP {response.status_code}: {message}")


def get_token():
    """Get a Chat API token (valid for 24 hours)."""
    response = requests.post(os.environ["NETOMI_AUTH_URL"], headers=chat_headers(), timeout=60)
    check(response)
    return response.json()["payload"]["token"]


def decode_objects(text):
    """Decode the JSON objects in a streamed reply, one after another.

    Works whether they're newline-separated or back to back.
    """
    decoder, objects, position = json.JSONDecoder(), [], 0
    while position < len(text):
        if text[position].isspace():
            position += 1
            continue
        obj, position = decoder.raw_decode(text, position)
        objects.append(obj)
    return objects


def plain_text(value):
    """Strip HTML tags and entities from the agent's answer (line breaks kept)."""
    value = re.sub(r"(?i)<br\s*/?>|</(p|div|li)>", "\n", value)  # block ends become line breaks
    value = html.unescape(re.sub(r"<[^>]+>", "", value))           # other tags just go
    lines = (re.sub(r"[ \t]+", " ", line).strip() for line in value.splitlines())
    return "\n".join(line for line in lines if line)


def send_message(token, conversation_id, text):
    """Send one customer message and return the agent's complete reply for that turn.

    Returns a small dict:
      text:          the answer as plain text (FillerText "just a moment" messages skipped)
      sources:       knowledge-source citations, if any
    """
    body = {
        "conversationId": conversation_id,
        "ownerType": "BOT",
        "messagePayload": {
            "text": text,
            "label": ".",
            "messageId": str(uuid.uuid4()),
            "timestamp": int(time.time() * 1000),
        },
    }
    headers = chat_headers() | {
        "x-integration": os.environ.get("NETOMI_INTEGRATION", "NETOMI_WEB_WIDGET"),
        "x-auth-token": token,
    }
    response = requests.post(os.environ["NETOMI_CHAT_URL"], headers=headers, json=body, timeout=300)
    check(response)
    return parse_reply(response.text)


def parse_reply(stream):
    """Turn one streamed reply into the small dict send_message returns.

    The reply streams as JSON objects; the turn is complete when the stream ends
    (the last object has CHUNK_STATUS SUCCESS). Order them by CHUNK_INDEX.
    """
    # Field names verified against a real reply (2026-11-08). CHUNK_INDEX arrives as a string.
    # TODO: verify a multi-chunk reply (only single-chunk replies seen so far).
    objects = sorted(decode_objects(stream),
                     key=lambda o: int((o.get("customPayload") or {}).get("CHUNK_INDEX", 0)))
    texts, options, sources = [], [], []
    for obj in objects:
        for attachment in obj.get("attachments") or []:
            kind = attachment.get("type", "").rsplit(".", 1)[-1]
            inner = attachment.get("attachment") or {}
            if kind == "Text":
                texts.append(plain_text(inner.get("text", "")))
                for option in (inner.get("quickReply") or {}).get("options") or []:
                    options.append(option.get("label") or option.get("text") or str(option))
            elif kind == "MultiSource":
                sources += [s.get("text", "") for s in inner.get("multipleSourceDetails") or []]
            elif kind != "FillerText":
                texts.append(f"[{kind}]")

    reply_text = "\n".join(t for t in texts if t)
    if options:
        reply_text += "\nOptions: " + " | ".join(options)
    return {"text": reply_text, "sources": sources}
