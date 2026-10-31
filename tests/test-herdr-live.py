#!/usr/bin/env python3
"""Opt-in, isolated POSIX smoke test: --herdr-binary /path/to/herdr."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import runpy
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time


ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--herdr-binary", required=True, type=Path)
    binary = parser.parse_args().herdr_binary.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="cpcv-h-live-", dir="/tmp") as temporary:
        root = Path(temporary)
        home = root / "home with spaces-é"
        config_dir = home / ".config/herdr"
        config_dir.mkdir(parents=True)
        capture = root / "capture.py"
        capture.write_text("#!" + sys.executable + "\n" + '''import os, pathlib, tty
root = pathlib.Path(__file__).parent
pane = os.environ["HERDR_PANE_ID"]
tty.setraw(0)
mode = b"\\x1b[?2004h" if os.environ.get("CPCV_CANARY_BRACKETED") == "1" else b"\\x1b[?2004l"
os.write(1, mode + b"cpcv-canary-ready")
while True:
    data = os.read(0, 4096)
    if not data:
        break
    with (root / (pane + ".input")).open("ab") as stream:
        stream.write(data)
''', encoding="utf-8")
        capture.chmod(0o700)
        (config_dir / "config.toml").write_text(
            "onboarding = false\n\n[terminal]\ndefault_shell = " + json.dumps(str(capture)) +
            '\nshell_mode = "non_login"\n\n' +
            runpy.run_path(str(ROOT / "remote/cpcv-herdr.py"))["BINDING"],
            encoding="utf-8",
        )
        environment = {
            "HOME": str(home), "PATH": os.defpath, "SHELL": "/bin/sh", "TERM": "xterm-256color",
            "XDG_CONFIG_HOME": str(home / ".config"), "XDG_CACHE_HOME": str(home / ".cache"),
            "HERDR_SOCKET_PATH": str(config_dir / "sessions/cpcv-canary/herdr.sock"),
        }

        def cli(*args):
            result = subprocess.run(
                [str(binary), *args], cwd=root, env=environment,
                capture_output=True, text=True, timeout=5, check=True,
            )
            return json.loads(result.stdout) if result.stdout.strip() else None

        def wait_until(condition, message):
            deadline = time.monotonic() + 5
            while not condition():
                if time.monotonic() >= deadline:
                    raise AssertionError(message)
                time.sleep(0.02)

        # The server is a child of this foreground test; its only home, socket,
        # panes, logs, and state belong to the temporary fixture.
        with (root / "server.log").open("wb") as log:
            client = None
            master = None
            server = subprocess.Popen(
                [str(binary), "--session", "cpcv-canary", "server"],
                cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT,
            )
            try:
                wait_until(
                    lambda: Path(environment["HERDR_SOCKET_PATH"]).is_socket(),
                    "Herdr did not start its isolated socket",
                )
                panes = []
                for enabled in (True, False):
                    response = cli(
                        "workspace", "create", "--cwd", str(root), "--focus",
                        "--env", "CPCV_CANARY_BRACKETED=" + ("1" if enabled else "0"),
                    )
                    panes.append(response["result"]["root_pane"]["pane_id"])
                for pane in panes:
                    wait_until(
                        lambda: "cpcv-canary-ready" in subprocess.run(
                            [str(binary), "pane", "read", pane, "--source", "visible"],
                            env=environment, capture_output=True, text=True, timeout=5, check=True,
                        ).stdout,
                        "capture terminal did not become ready",
                    )
                subprocess.run(
                    [sys.executable, str(ROOT / "remote/cpcv-herdr.py"), "install"],
                    env=environment, capture_output=True, timeout=5, check=True,
                )
                image = home / "clipboard-images/latest.png"
                image.write_bytes(b"synthetic-image")
                helper = home / ".local/lib/cpcv/herdr/cpcv-herdr.py"
                for index, pane in enumerate(panes):
                    context = dict(environment, HERDR_ACTIVE_PANE_ID=pane, TMUX_PANE="%999")
                    subprocess.run(
                        [sys.executable, str(helper), "paste"],
                        env=context, capture_output=True, timeout=5, check=True,
                    )
                    captured = root / (pane + ".input")
                    expected = str(image).encode("utf-8")
                    if index == 0:
                        expected = b"\x1b[200~" + expected + b"\x1b[201~"
                    wait_until(
                        lambda: captured.exists() and captured.stat().st_size >= len(expected),
                        "paste did not reach the originating pane",
                    )
                    actual = captured.read_bytes()
                    if actual != expected:
                        raise AssertionError("paste bytes differ or include Enter: " + repr(actual))
                    if index == 0 and (root / (panes[1] + ".input")).exists():
                        raise AssertionError("paste went to the later focused pane")

                # Exercise the documented keybinding through a real client,
                # including Herdr's supplied ACTIVE_PANE_ID/socket environment.
                response = cli(
                    "workspace", "create", "--cwd", str(root), "--focus",
                    "--env", "CPCV_CANARY_BRACKETED=1",
                )
                pane = response["result"]["root_pane"]["pane_id"]
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
                try:
                    client = subprocess.Popen(
                        [str(binary), "--session", "cpcv-canary"], env=environment, cwd=root,
                        stdin=slave, stdout=slave, stderr=slave,
                    )
                finally:
                    os.close(slave)
                output = bytearray()

                def ready():
                    if select.select([master], [], [], 0)[0]:
                        output.extend(os.read(master, 65536))
                    return b"cpcv-canary-ready" in output

                wait_until(ready, "Herdr terminal client did not become ready")
                os.write(master, b"\x02")  # Default Herdr prefix: Ctrl-B.
                time.sleep(0.02)
                os.write(master, b"\x1bv")  # Alt-V.
                captured = root / (pane + ".input")
                expected = b"\x1b[200~" + str(image).encode("utf-8") + b"\x1b[201~"
                wait_until(
                    lambda: captured.exists() and captured.stat().st_size >= len(expected),
                    "Herdr custom keybinding did not paste the image path",
                )
                if captured.read_bytes() != expected:
                    raise AssertionError("custom keybinding sent unexpected bytes")
                print("PASS: live Herdr targeted the originating pane in a named session,")
                print("      honored bracketed paste on/off, and sent no Enter or outer tmux input.")
                print("PASS: Herdr prefix then Alt-V invoked the installed helper through a real client.")
            finally:
                if client is not None:
                    client.terminate()
                    try:
                        client.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        client.kill()
                        client.wait(timeout=5)
                if master is not None:
                    os.close(master)
                try:
                    cli("server", "stop")
                except (OSError, subprocess.SubprocessError, ValueError):
                    server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)


if __name__ == "__main__":
    main()
