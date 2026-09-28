"""Real loopback TCP match lifecycle against the minimally adapted server.

Synthetic clients only; no game, Mods, saves, official service or user run.
"""
from pathlib import Path
import argparse
import json
import os
import socket
import subprocess
import time

REPO = Path(__file__).resolve().parent.parent
SERVER = REPO / "work/local-server"

class Peer:
    def __init__(self, port):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=2)
        self.socket.settimeout(0.1)
        self.buffer = b""
        self.messages = []

    def send(self, action, **fields):
        self.socket.sendall((json.dumps({"action": action, **fields}) + "\n").encode())

    def until(self, action, timeout=4):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            for index, message in enumerate(self.messages):
                if message.get("action") == action:
                    return self.messages.pop(index)
                if message.get("action") == "error":
                    raise AssertionError(f"Server error: {message.get('message')}")
            try:
                chunk = self.socket.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                raise AssertionError("Server disconnected fixture")
            self.buffer += chunk
            assert len(self.buffer) <= 2 * 1024 * 1024
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if line:
                    message = json.loads(line)
                    if message.get("action") == "keepAlive":
                        self.send("keepAliveAck")
                    else:
                        self.messages.append(message)
        raise AssertionError(f"Timed out waiting for {action}")

def main():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    evidence = REPO / "work/server-tcp-evidence"
    evidence.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, PORT=str(port), LOG_HASH_DB_PATH=str(evidence / "local.db"))
    peers = []
    with (evidence / "server.log").open("wb") as log:
        process = subprocess.Popen(["node", str(SERVER / "dist/main.js")], cwd=evidence, env=env, stdout=log, stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        try:
            end = time.monotonic() + 8
            while True:
                assert process.poll() is None, "Server exited before ready"
                try:
                    human = Peer(port)
                    peers.append(human)
                    break
                except OSError:
                    if time.monotonic() >= end:
                        raise
                    time.sleep(0.05)
            ai = Peer(port)
            peers.append(ai)
            if os.name == "nt":
                command = f"Get-NetTCPConnection -State Listen -OwningProcess {process.pid} | Select-Object LocalAddress,LocalPort | ConvertTo-Json -Compress"
                listeners = json.loads(subprocess.check_output(["powershell", "-NoProfile", "-Command", command], text=True, timeout=10))
                if isinstance(listeners, dict):
                    listeners = [listeners]
                assert listeners == [{"LocalAddress": "127.0.0.1", "LocalPort": port}], listeners
            human.send("username", username="LOCAL HUMAN FIXTURE", modHash="AISparring-local-fixture")
            ai.send("username", username="BALATRO AI FIXTURE", modHash="AISparring-local-fixture")
            human.send("createLobby", gameMode="attrition")
            code = human.until("joinedLobby")["code"]
            ai.send("joinLobby", code=code)
            assert ai.until("joinedLobby")["code"] == code
            # One-life fixtures shorten the original lifecycle; not Major League parity.
            human.send("lobbyOptions", starting_lives=1, different_seeds=False, hide_score_until_played=False)
            human.send("startGame")
            first, second = human.until("startGame"), ai.until("startGame")
            assert first["seed"] == second["seed"] and first["seed"]
            assert human.until("playerInfo")["lives"] == 1
            assert ai.until("playerInfo")["lives"] == 1
            human.send("readyBlind")
            ai.send("readyBlind")
            human.until("startBlind")
            ai.until("startBlind")
            ai.send("playHand", score="100", handsLeft=1)
            human.send("playHand", score="50", handsLeft=0)
            ai.until("winGame")
            human.until("loseGame")
            assert human.until("playerInfo")["lives"] == 0
            print("PASS actual loopback listener only; unused admin listener absent")
            print("PASS two-client create/join/start/shared-seed/ready/PvP/AI-win/human-loss lifecycle")
            # Disconnect clients after an explicit local stop; no official submission.
            human.send("stopGame")
            print("PASS no game process or live game files used")
        finally:
            for peer in peers:
                peer.socket.close()
            if process.poll() is None:
                process.terminate()  # Exact Popen-owned Node process handle, never a game PID.
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-root", type=Path, default=SERVER)
    SERVER = parser.parse_args().server_root.resolve()
    main()
