"""逐步测试查询、开、关。对外只有 switch 的 on/off。每一步按回车才发送。"""
from __future__ import annotations

import json
import socket
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TOKEN_PATH = ROOT / "lan.token"
PORT = 9753
TIMEOUT = 70


def load_token() -> str:
    if not TOKEN_PATH.is_file():
        raise SystemExit(f"找不到 {TOKEN_PATH.name}，先启动 tcp_server.py")
    token = TOKEN_PATH.read_text(encoding="utf-8").strip()
    if not token:
        raise SystemExit(f"{TOKEN_PATH.name} 是空的")
    return token


def request(host: str, token: str, fields: dict) -> dict:
    payload = {"token": token, **fields}
    raw = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
    try:
        with socket.create_connection((host, PORT), TIMEOUT) as sock:
            sock.settimeout(TIMEOUT)
            sock.sendall(raw)
            chunks: list[bytes] = []
            while True:
                part = sock.recv(4096)
                if not part:
                    break
                chunks.append(part)
    except OSError as exc:
        raise SystemExit(f"连不上 {host}:{PORT}，先在另一个窗口运行 python .\\tcp_server.py") from exc
    text = b"".join(chunks).decode("utf-8", errors="replace").strip()
    if not text:
        raise RuntimeError("服务没有返回")
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(text) from exc
    if not isinstance(data, dict):
        raise RuntimeError(text)
    return data


def show(title: str, data: dict) -> None:
    print(f"\n{title}")
    print(json.dumps(data, ensure_ascii=False, indent=2))
    name = {"on": "开", "off": "关"}.get(data.get("switch"))
    if name:
        print(f"开关 {name}")
    if data.get("ok") is not True:
        raise SystemExit("这一步失败，已停止。")


def pause(prompt: str) -> None:
    input(f"\n{prompt}\n按回车发送...")


def main() -> None:
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    token = load_token()
    print(f"目标 {host}:{PORT}")
    print("请保证先在另一个窗口运行：python .\\tcp_server.py")
    show("1. 查询状态", request(host, token, {"cmd": "status"}))
    pause("下一步：打开开关。请看着开关。")
    show("2. 打开", request(host, token, {"cmd": "switch", "value": "on"}))
    pause("下一步：关闭开关。")
    show("3. 关闭", request(host, token, {"cmd": "switch", "value": "off"}))
    show("结束状态", request(host, token, {"cmd": "status"}))
    print("\n查询、打开、关闭都已发送。")


if __name__ == "__main__":
    main()
