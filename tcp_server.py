"""局域网 TCP 服务：查询状态，开关 on/off。"""
from __future__ import annotations

import hmac
import json
import os
import secrets
import socketserver
import subprocess
import sys
import threading
from pathlib import Path


def app_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


ROOT = app_dir()
SCRIPT = ROOT / "MiSwitch.ps1"
TOKEN_PATH = ROOT / "lan.token"
CONFIG_PATH = ROOT / "config.json"
POWERSHELL = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
COMMAND_TIMEOUT = 45
READ_TIMEOUT = 10

_SWITCH = {"on": "LeftOn", "off": "RightOn"}
_ACTION = {"LeftOn": "on", "RightOn": "off", "Status": "status"}


def load_config() -> dict:
    if not CONFIG_PATH.is_file():
        raise SystemExit(f"找不到 {CONFIG_PATH.name}")
    data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit("config.json 必须是 JSON 对象")
    device_ip = data.get("deviceIp")
    device_id = data.get("deviceId")
    listen_host = data.get("listenHost")
    listen_port = data.get("listenPort")
    if not isinstance(device_ip, str) or not device_ip:
        raise SystemExit("config.json 的 deviceIp 无效")
    if isinstance(device_id, bool) or not isinstance(device_id, int) or device_id <= 0:
        raise SystemExit("config.json 的 deviceId 无效")
    if not isinstance(listen_host, str) or not listen_host:
        raise SystemExit("config.json 的 listenHost 无效")
    if isinstance(listen_port, bool) or not isinstance(listen_port, int) or not 1 <= listen_port <= 65535:
        raise SystemExit("config.json 的 listenPort 无效")
    return {
        "deviceIp": device_ip,
        "deviceId": device_id,
        "listenHost": listen_host,
        "listenPort": listen_port,
    }


def load_token() -> str:
    if not TOKEN_PATH.is_file():
        token = secrets.token_urlsafe(18)
        TOKEN_PATH.write_text(token + "\n", encoding="utf-8")
        print(f"已生成本地口令文件 {TOKEN_PATH}", flush=True)
        return token
    token = TOKEN_PATH.read_text(encoding="utf-8").strip()
    if not token:
        raise SystemExit(f"{TOKEN_PATH.name} 是空的")
    return token


def parse_request(line: str, token: str) -> str:
    try:
        data = json.loads(line)
    except json.JSONDecodeError as exc:
        raise ValueError("请求不是 JSON") from exc
    if not isinstance(data, dict):
        raise ValueError("请求必须是 JSON 对象")
    given = data.get("token")
    if not isinstance(given, str) or not hmac.compare_digest(given.encode(), token.encode()):
        raise ValueError("口令错误")
    cmd = data.get("cmd")
    if cmd == "status":
        return "Status"
    if cmd != "switch":
        raise ValueError("cmd 只能是 status 或 switch")
    value = data.get("value")
    action = _SWITCH.get(value)
    if action is None:
        raise ValueError("switch 的 value 只能是 on 或 off")
    return action


def decode_output(raw: bytes) -> str:
    if not raw:
        return ""
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        return raw.decode("utf-16").strip()
    if len(raw) >= 2 and raw[1] == 0:
        return raw.decode("utf-16-le").strip()
    return raw.decode("utf-8", errors="replace").strip()


def _host_command(device_ip: str, device_id: int) -> str:
    script = str(SCRIPT).replace("'", "''")
    safe_ip = device_ip.replace("'", "''")
    return "\n".join([
        "[Console]::InputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)",
        f". '{script}' -DeviceIP '{safe_ip}' -DeviceID {device_id}",
        "[Console]::Out.WriteLine('READY')",
        "[Console]::Out.Flush()",
        "while ($true) {",
        "  $line = [Console]::ReadLine()",
        "  if ([string]::IsNullOrEmpty($line) -or $line -eq 'QUIT') { break }",
        "  $code = Invoke-SwitchAction $line.Trim()",
        "  [Console]::Out.WriteLine('EXIT ' + $code)",
        "  [Console]::Out.Flush()",
        "}",
    ])


def _read_line(proc: subprocess.Popen, timeout: float) -> bytes:
    chunk: list[bytes] = []

    def read() -> None:
        assert proc.stdout is not None
        chunk.append(proc.stdout.readline())

    thread = threading.Thread(target=read, daemon=True)
    thread.start()
    thread.join(timeout)
    if thread.is_alive():
        proc.kill()
        raise subprocess.TimeoutExpired(proc.args, timeout)
    if not chunk or chunk[0] == b"":
        raise RuntimeError("PowerShell 已退出")
    return chunk[0]


class SwitchWorker:
    def __init__(self, device_ip: str, device_id: int) -> None:
        self._device_ip = device_ip
        self._device_id = device_id
        self._proc: subprocess.Popen | None = None

    def start(self) -> None:
        if self._proc is not None and self._proc.poll() is None:
            return
        proc = subprocess.Popen(
            [
                str(POWERSHELL), "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-Command", _host_command(self._device_ip, self._device_id),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=ROOT,
        )
        threading.Thread(target=self._drain, args=(proc,), daemon=True).start()
        self._proc = proc
        ready = decode_output(_read_line(proc, 30))
        if ready != "READY":
            proc.kill()
            self._proc = None
            raise RuntimeError(ready or "PowerShell 没有就绪")

    def close(self) -> None:
        proc = self._proc
        self._proc = None
        if proc is None or proc.poll() is not None or proc.stdin is None:
            return
        proc.stdin.write(b"QUIT\n")
        proc.stdin.flush()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()

    def run(self, action: str) -> dict:
        self.start()
        proc = self._proc
        if proc is None or proc.stdin is None:
            raise RuntimeError("PowerShell 没有就绪")
        proc.stdin.write((action + "\n").encode("utf-8"))
        proc.stdin.flush()
        payload = _payload(decode_output(_read_line(proc, COMMAND_TIMEOUT)))
        exit_line = decode_output(_read_line(proc, 5))
        if exit_line.startswith("EXIT "):
            payload["exitCode"] = int(exit_line.removeprefix("EXIT ").strip())
        return present(payload)

    @staticmethod
    def _drain(proc: subprocess.Popen) -> None:
        if proc.stderr is None:
            return
        proc.stderr.read()


def present(payload: dict) -> dict:
    shown = dict(payload)
    state = shown.pop("state", None)
    action = shown.get("action")
    if isinstance(action, str) and action in _ACTION:
        shown["action"] = _ACTION[action]
    if isinstance(state, dict):
        shown["switch"] = switch_name(state)
    return shown


def switch_name(state: dict) -> str:
    if state.get("left") is True:
        return "on"
    if state.get("right") is True:
        return "off"
    return "unknown"


def _payload(text: str) -> dict:
    if not text:
        return {"ok": False, "error": "脚本没有输出"}
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return {"ok": False, "error": text}
    if not isinstance(parsed, dict):
        return {"ok": False, "error": text}
    return parsed


class SwitchServer(socketserver.TCPServer):
    allow_reuse_address = True

    def __init__(self, token: str, worker: SwitchWorker, host: str, port: int) -> None:
        super().__init__((host, port), SwitchHandler)
        self.lan_token = token
        self.worker = worker
        self.listen_host = host
        self.listen_port = port

    def server_close(self) -> None:
        self.worker.close()
        super().server_close()


class SwitchHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        self.connection.settimeout(READ_TIMEOUT)
        try:
            raw = self.rfile.readline(4096)
        except TimeoutError:
            return
        if not raw:
            return
        server = self.server
        if not isinstance(server, SwitchServer):
            raise RuntimeError("服务类型错误")
        payload = self._dispatch(raw.decode("utf-8", errors="replace"))
        self.wfile.write((json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))

    def _dispatch(self, line: str) -> dict:
        server = self.server
        if not isinstance(server, SwitchServer):
            raise RuntimeError("服务类型错误")
        try:
            return server.worker.run(parse_request(line, server.lan_token))
        except ValueError as exc:
            return {"ok": False, "error": str(exc)}
        except subprocess.TimeoutExpired:
            return {"ok": False, "error": "设备命令超时。设备可能已经执行，先查询 status 再决定是否重试"}
        except RuntimeError as exc:
            return {"ok": False, "error": str(exc)}


def open_server() -> SwitchServer:
    if not SCRIPT.is_file():
        raise SystemExit(f"找不到 {SCRIPT.name}")
    config = load_config()
    worker = SwitchWorker(config["deviceIp"], config["deviceId"])
    worker.start()
    try:
        server = SwitchServer(load_token(), worker, config["listenHost"], config["listenPort"])
    except Exception:
        worker.close()
        raise
    server.device_label = f"{config['deviceIp']} / {config['deviceId']}"
    return server


def main() -> None:
    server = open_server()
    print(f"监听 {server.listen_host}:{server.listen_port}，设备 {server.device_label}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
