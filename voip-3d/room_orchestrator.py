#!/usr/bin/env python3
"""
ROOM ORCHESTRATOR BOT for voip-3d (matrix.gamebler.xyz)

Listens for `xyz.gamebler.room_request` to-device messages on Matrix
and spawns dedicated Godot game server processes with custom ports and
single-use join tokens. Sends `xyz.gamebler.room_invite` back to players.
"""

import os
import sys
import time
import json
import random
import string
import urllib.request
import urllib.parse
import subprocess
import socket
from typing import Dict, List, Any, Optional

HOMESERVER = os.getenv("MATRIX_HOMESERVER", "https://matrix.gamebler.xyz")
BOT_USERNAME = os.getenv("MATRIX_BOT_USER", "gamebler")
BOT_PASSWORD = os.getenv("MATRIX_BOT_PASS", "gamebler_secret")
BOT_TOKEN = os.getenv("MATRIX_BOT_TOKEN", "")
PUBLIC_ADDRESS = os.getenv("PUBLIC_ADDRESS", "matrix.gamebler.xyz")

GODOT_BIN = os.getenv("GODOT_BIN", "godot")
PROJECT_DIR = os.getenv("PROJECT_DIR", os.path.dirname(os.path.abspath(__file__)))

PORT_RANGE_START = int(os.getenv("PORT_START", "12850"))
PORT_RANGE_END = int(os.getenv("PORT_END", "12881"))

OVERLAND_PORT = int(os.getenv("OVERLAND_PORT", "12806"))

active_processes: Dict[int, Dict[str, Any]] = {}
txn_id = 0


def generate_token(length: int = 16) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(random.choice(alphabet) for _ in range(length))


def is_port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


def allocate_port() -> Optional[int]:
    used_ports = {info["port"] for info in active_processes.values()}
    for port in range(PORT_RANGE_START, PORT_RANGE_END + 1):
        if port not in used_ports and not is_port_in_use(port):
            return port
    return None


class MatrixBot:
    def __init__(self, homeserver: str):
        self.homeserver = homeserver.rstrip("/")
        self.access_token = BOT_TOKEN
        self.user_id = ""
        self.since_token = ""

    def request(self, method: str, path: str, data: Any = None, authed: bool = True) -> Dict[str, Any]:
        url = self.homeserver + path
        headers = {"Content-Type": "application/json"}
        if authed and self.access_token:
            headers["Authorization"] = f"Bearer {self.access_token}"

        payload = None
        if data is not None:
            payload = json.dumps(data).encode("utf-8")

        req = urllib.request.Request(url, data=payload, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw else {}
        except Exception as e:
            if hasattr(e, "read"):
                try:
                    err_raw = e.read().decode("utf-8")
                    return json.loads(err_raw)
                except Exception:
                    pass
            print(f"[HTTP Error] {method} {path}: {e}", file=sys.stderr)
            return {}

    def login(self, username: str, password: str) -> bool:
        body = {
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": username},
            "password": password,
            "initial_device_display_name": "voip-3d-orchestrator"
        }
        res = self.request("POST", "/_matrix/client/v3/login", body, authed=False)
        if "access_token" in res:
            self.access_token = res["access_token"]
            self.user_id = res.get("user_id", "")
            print(f"[MatrixBot] Logged in as {self.user_id}")
            return True
        print(f"[MatrixBot] Login failed: {res}", file=sys.stderr)
        return False

    def send_to_device(self, target_user_id: str, event_type: str, content: Dict[str, Any]):
        global txn_id
        txn_id += 1
        txn_str = f"bot.{int(time.time()*1000)}.{txn_id}"
        path = f"/_matrix/client/v3/sendToDevice/{urllib.parse.quote(event_type)}/{txn_str}"
        body = {
            "messages": {
                target_user_id: {
                    "*": content
                }
            }
        }
        self.request("PUT", path, body, authed=True)

    def sync_loop(self):
        print("[MatrixBot] Starting sync loop...")
        filter_str = json.dumps({"room": {"timeline": {"limit": 0}}, "presence": {"types": []}})
        while True:
            self.cleanup_finished_processes()
            qs = f"?timeout=20000&filter={urllib.parse.quote(filter_str)}"
            if self.since_token:
                qs += f"&since={urllib.parse.quote(self.since_token)}"

            res = self.request("GET", "/_matrix/client/v3/sync" + qs, authed=True)
            if "next_batch" in res:
                self.since_token = res["next_batch"]
                to_device = res.get("to_device", {}).get("events", [])
                for ev in to_device:
                    self.handle_to_device(ev)
            else:
                time.sleep(3)

    def handle_to_device(self, ev: Dict[str, Any]):
        sender = ev.get("sender", "")
        ev_type = ev.get("type", "")
        content = ev.get("content", {})

        print(f"[ToDevice] Received {ev_type} from {sender}")

        if ev_type == "xyz.gamebler.room_request":
            self.handle_room_request(sender, content)
        elif ev_type == "xyz.gamebler.world_request":
            self.handle_world_request(sender, content)

    def handle_room_request(self, sender: str, content: Dict[str, Any]):
        mode = content.get("mode", "free_kick")
        match_minutes = int(content.get("match_minutes", 5))
        invitees = content.get("invitees", [])
        from_display = content.get("from_display", sender)

        all_players = list(set([sender] + invitees))
        port = allocate_port()
        if not port:
            print("[Error] No available ports for new room server!", file=sys.stderr)
            return

        tokens_by_user: Dict[str, str] = {}
        tokens_list: List[str] = []
        for user in all_players:
            tok = generate_token()
            tokens_by_user[user] = tok
            tokens_list.append(tok)

        tokens_arg = ",".join(tokens_list)
        cmd = [
            GODOT_BIN,
            "--headless",
            "--path", PROJECT_DIR,
            "--",
            "--server",
            "--port", str(port),
            "--mode", mode,
            "--minutes", str(match_minutes),
            "--tokens", tokens_arg,
            "--transport", "ws"
        ]

        print(f"[Orchestrator] Spawning server process for mode '{mode}' on port {port}: {' '.join(cmd)}")
        try:
            proc = subprocess.Popen(cmd, cwd=PROJECT_DIR)
            active_processes[proc.pid] = {
                "port": port,
                "mode": mode,
                "proc": proc,
                "start_time": time.time(),
                "players": all_players
            }
        except Exception as e:
            print(f"[Error] Failed to spawn Godot server: {e}", file=sys.stderr)
            return

        time.sleep(0.5)

        for user, tok in tokens_by_user.items():
            invite_payload = {
                "address": PUBLIC_ADDRESS,
                "port": port,
                "transport": "ws",
                "tls": False,
                "token": tok,
                "mode": mode,
                "match_minutes": match_minutes,
                "from_display": from_display,
                "host_user": sender
            }
            print(f"[Orchestrator] Sending room_invite to {user} (port={port}, token={tok})")
            self.send_to_device(user, "xyz.gamebler.room_invite", invite_payload)

    def handle_world_request(self, sender: str, content: Dict[str, Any]):
        world_payload = {
            "address": PUBLIC_ADDRESS,
            "port": OVERLAND_PORT,
            "transport": "ws",
            "tls": False,
            "mode": "overland"
        }
        self.send_to_device(sender, "xyz.gamebler.world_info", world_payload)

    def cleanup_finished_processes(self):
        now = time.time()
        to_delete = []
        for pid, info in active_processes.items():
            proc: subprocess.Popen = info["proc"]
            ret = proc.poll()
            if ret is not None:
                print(f"[Orchestrator] Process {pid} on port {info['port']} exited with code {ret}")
                to_delete.append(pid)
            elif now - info["start_time"] > 7200:
                print(f"[Orchestrator] Process {pid} on port {info['port']} timed out (>2h), terminating...")
                proc.terminate()
                to_delete.append(pid)

        for pid in to_delete:
            del active_processes[pid]


def main():
    print("=== VOIP-3D ROOM ORCHESTRATOR BOT ===")
    bot = MatrixBot(HOMESERVER)

    if not bot.access_token:
        if not bot.login(BOT_USERNAME, BOT_PASSWORD):
            print("[Error] Could not authenticate Matrix bot.", file=sys.stderr)
            sys.exit(1)

    try:
        bot.sync_loop()
    except KeyboardInterrupt:
        print("[Orchestrator] Shutting down...")
        for pid, info in active_processes.items():
            info["proc"].terminate()


if __name__ == "__main__":
    main()
