#!/usr/bin/env python3
"""Connect to the local OpenClaw gateway and capture real event shapes."""

import json
import websocket
import time
import sys

GATEWAY_URL = "ws://127.0.0.1:18789"

# Get token from openclaw config
try:
    with open("/Users/openclaw/.openclaw/openclaw.json") as f:
        config = json.load(f)
    token = config.get("gateway", {}).get("auth", {}).get("token", "")
    if not token:
        # Try to find token from environment or other config paths
        print("No gateway token found in config, trying without token")
        token = ""
except Exception as e:
    print(f"Config read error: {e}")
    token = ""

url = f"{GATEWAY_URL}?token={token}" if token else GATEWAY_URL

events = []
max_wait = 30  # seconds to listen

def on_message(ws, message):
    try:
        data = json.loads(message)
        events.append(data)
        event_type = data.get("type", "unknown")
        event_name = data.get("event", "")
        print(f"\n--- Received: type={event_type} event={event_name} ---")
        print(json.dumps(data, indent=2)[:2000])
        
        # If we got a challenge, respond with connect
        if event_name == "connect.challenge":
            print("\n[Got challenge - sending connect request]")
            connect_req = {
                "type": "req",
                "id": "probe-1",
                "method": "connect",
                "params": {
                    "minProtocol": 3,
                    "maxProtocol": 3,
                    "client": {"id": "beechat-probe", "version": "0.1.0", "platform": "macos", "mode": "operator"},
                    "role": "operator",
                    "scopes": ["operator.read", "operator.write"],
                    "auth": {"token": token}
                }
            }
            ws.send(json.dumps(connect_req))
        
        # If we got hello-ok, subscribe to sessions and request session list
        if data.get("type") == "res" and data.get("id") == "probe-1":
            print("\n[Got response to connect - requesting sessions.list]")
            sessions_req = {
                "type": "req",
                "id": "probe-2",
                "method": "sessions.list",
                "params": {}
            }
            ws.send(json.dumps(sessions_req))
            
    except json.JSONDecodeError:
        print(f"[Non-JSON message: {message[:200]}]")

def on_error(ws, error):
    print(f"\nWebSocket error: {error}")

def on_close(ws, close_code, close_msg):
    print(f"\n--- Connection closed: code={close_code} msg={close_msg} ---")

def on_open(ws):
    print("--- Connected to gateway ---")

print(f"Connecting to {GATEWAY_URL}...")
print(f"Listening for {max_wait} seconds...\n")

ws = websocket.WebSocketApp(
    url,
    on_open=on_open,
    on_message=on_message,
    on_error=on_error,
    on_close=on_close
)

ws.run_forever(timeout=max_wait)

print(f"\n\n=== SUMMARY: Captured {len(events)} events ===")
print("Event types seen:", set(e.get("type") for e in events))
print("Event names seen:", set(e.get("event", "N/A") for e in events))