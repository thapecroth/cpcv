#!/usr/bin/env python3
# Managed by ctrl-ccv Herdr integration
"""Install or paste through Herdr on a POSIX SSH target (Python 3.8+)."""

import argparse
import json
import os
from pathlib import Path
import re
import socket
import stat
import sys
import tempfile
import time


MARKER = "# Managed by ctrl-ccv Herdr integration"
OWNER = "ctrl-ccv Herdr integration"
TIMEOUT = 3.0
MAX_RESPONSE = 65536
BINDING = '''[[keys.command]]
key = "prefix+alt+v"
type = "shell"
command = 'python3 "$HOME/.local/lib/ctrl-ccv/herdr/ctrl-ccv-herdr.py" paste'
description = "Paste latest ctrl-ccv image path"
'''


class CtrlCcvError(Exception):
    pass


def safe_text(value):
    return isinstance(value, str) and bool(value) and not any(
        ord(char) < 32 or 127 <= ord(char) <= 159 for char in value
    )


def home_dir():
    value = os.environ.get("HOME", "")
    if not safe_text(value) or not Path(value).is_absolute():
        raise CtrlCcvError("HOME must be an absolute path without control characters")
    home = Path(value).resolve(strict=True)
    if not safe_text(str(home)):
        raise CtrlCcvError("resolved HOME contains control characters")
    return home


def locations(home):
    return (
        home / ".local/lib/ctrl-ccv/herdr/ctrl-ccv-herdr.py",
        home / ".config/ctrl-ccv/herdr-paste.json",
    )


def check_parents(path, home):
    """Refuse linked installer paths, including linked ancestor directories."""
    for parent in reversed(path.relative_to(home).parents):
        candidate = home / parent
        if candidate.is_symlink() or (candidate.exists() and not candidate.is_dir()):
            raise CtrlCcvError("refusing a symlink or non-directory in the installation path")


def read_config(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 8192:
        raise CtrlCcvError("missing or invalid Herdr configuration; reinstall the helper")
    with path.open(encoding="utf-8") as stream:
        config = json.load(stream)
    if not isinstance(config, dict) or set(config) != {"managedBy", "imageDir"}:
        raise CtrlCcvError("invalid Herdr configuration")
    if config["managedBy"] != OWNER or not safe_text(config["imageDir"]):
        raise CtrlCcvError("unrecognized Herdr configuration")
    return config


def owned_helper(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open(encoding="utf-8") as stream:
        return MARKER in [stream.readline().rstrip("\n") for _ in range(2)]


def atomic_write(path, content, mode):
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            os.fchmod(stream.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install(remote_dir):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", remote_dir) or ".." in remote_dir:
        raise CtrlCcvError("remote directory must be a relative POSIX path without parent traversal")
    home = home_dir()
    helper, config_path = locations(home)
    image_dir = home / remote_dir
    # Preflight every destination before changing any existing files.
    for path in (helper, config_path, image_dir / "latest.png"):
        check_parents(path, home)
    if helper.exists() or helper.is_symlink():
        if not owned_helper(helper):
            raise CtrlCcvError("refusing to replace an unrelated Herdr helper")
    if config_path.exists() or config_path.is_symlink():
        read_config(config_path)
    source = Path(__file__).read_bytes()
    for directory in (helper.parent, config_path.parent, image_dir):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(helper.parent, 0o700)
    os.chmod(config_path.parent, 0o700)
    atomic_write(helper, source, 0o700)
    config = {"managedBy": OWNER, "imageDir": str(image_dir)}
    atomic_write(config_path, (json.dumps(config) + "\n").encode("utf-8"), 0o600)
    print("Installed ctrl-ccv Herdr helper. Add this to the Herdr config on this host:")
    print("# ~/.config/herdr/config.toml\n" + BINDING)
    print("Then run herdr server reload-config in the intended Herdr session.")
    print("Press the Herdr prefix, then Alt-V. For --remote, add --remote-keybindings server.")


def latest_image(home):
    _, config_path = locations(home)
    check_parents(config_path, home)
    value = read_config(config_path)["imageDir"]
    image_dir = Path(value)
    if not image_dir.is_absolute():
        raise CtrlCcvError("image directory must be absolute")
    image_dir = image_dir.resolve(strict=True)
    if not safe_text(str(image_dir)) or home not in image_dir.parents:
        raise CtrlCcvError("image directory must stay inside HOME")
    latest = image_dir / "latest.png"
    if not latest.is_file() or latest.stat().st_size == 0:
        raise CtrlCcvError("no uploaded image is ready; copy an image and wait for its upload")
    return str(latest)


def request(socket_path, payload):
    if not safe_text(socket_path) or not Path(socket_path).is_absolute():
        raise CtrlCcvError("run paste from a Herdr keybinding with HERDR_SOCKET_PATH")
    metadata = os.lstat(socket_path)
    if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise CtrlCcvError("Herdr socket must be a socket owned by the current user")
    # Never retry an uncertain write: it could paste into the pane twice.
    deadline = time.monotonic() + TIMEOUT
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(TIMEOUT)
        connection.connect(socket_path)
        connection.settimeout(max(0.001, deadline - time.monotonic()))
        connection.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        response = bytearray()
        while b"\n" not in response:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CtrlCcvError("Herdr did not acknowledge the paste before the timeout")
            connection.settimeout(remaining)
            chunk = connection.recv(min(4096, MAX_RESPONSE + 1 - len(response)))
            if not chunk:
                raise CtrlCcvError("Herdr closed the connection before acknowledging the paste")
            response.extend(chunk)
            if len(response) > MAX_RESPONSE:
                raise CtrlCcvError("Herdr response exceeded the size limit")
    result = json.loads(response.split(b"\n", 1)[0])
    if not isinstance(result, dict) or result.get("id") != payload["id"]:
        raise CtrlCcvError("Herdr returned an invalid paste acknowledgment")
    return result


def send_paste(socket_path, pane, text):
    # A single request preserves bracketed-paste mode without sending Enter.
    result = request(socket_path, {
        "id": "ctrl-ccv-paste",
        "method": "pane.send_input",
        "params": {"pane_id": pane, "text": text, "keys": []},
    })
    if "error" in result or result.get("result") != {"type": "ok"}:
        raise CtrlCcvError("Herdr rejected the paste; check the pane and Herdr API compatibility")


def paste():
    # Capture the originating pane, never a later global focus or outer tmux pane.
    pane = os.environ.get("HERDR_ACTIVE_PANE_ID", "")
    if not re.fullmatch(r"w[0-9A-HJKMNP-TV-Z]+:p[0-9A-HJKMNP-TV-Z]+", pane):
        raise CtrlCcvError("run paste from a Herdr keybinding with HERDR_ACTIVE_PANE_ID")
    text = latest_image(home_dir())
    send_paste(os.environ.get("HERDR_SOCKET_PATH", ""), pane, text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    setup = commands.add_parser("install", help="install only ctrl-ccv-owned remote helper files")
    setup.add_argument("--remote-dir", default="clipboard-images")
    commands.add_parser("paste", help="paste into the pane supplied by a Herdr keybinding")
    args = parser.parse_args()
    try:
        if args.action == "install":
            install(args.remote_dir)
        else:
            paste()
    except (CtrlCcvError, OSError, ValueError) as error:
        # Do not echo paths, socket responses, or raw subprocess diagnostics.
        detail = str(error) if isinstance(error, CtrlCcvError) else "configuration, image, or Herdr socket is unavailable or invalid"
        print("ctrl-ccv Herdr: " + detail, file=sys.stderr)
        if args.action == "paste" and isinstance(error, CtrlCcvError):
            # Detached Herdr commands discard stderr. Report useful failures in
            # the TUI too; unavailable notifications must never retry the paste.
            try:
                request(os.environ.get("HERDR_SOCKET_PATH", ""), {
                    "id": "ctrl-ccv-notify", "method": "notification.show",
                    "params": {"title": "ctrl-ccv: paste unavailable", "body": detail},
                })
            except (CtrlCcvError, OSError, ValueError):
                pass
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
