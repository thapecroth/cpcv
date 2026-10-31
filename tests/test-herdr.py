#!/usr/bin/env python3
"""Network-free Herdr integration checks using a disposable Unix socket."""

from contextlib import contextmanager
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "remote/cpcv-herdr.py"
SPEC = importlib.util.spec_from_file_location("cpcv_herdr", SOURCE)
HERDR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HERDR)


class HerdrTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cpcv-h-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home with spaces-é"
        self.home.mkdir()
        self.environment = patch.dict(os.environ, {"HOME": str(self.home)}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        output = patch("sys.stdout", new_callable=io.StringIO)
        output.start()
        self.addCleanup(output.stop)
        HERDR.install("images/clipboard")
        self.helper, self.config = HERDR.locations(self.home)
        self.image = self.home / "images/clipboard/latest.png"
        self.image.write_bytes(b"synthetic-image")
        self.socket = str(self.root / "herdr.sock")

    @contextmanager
    def server(self, response=None):
        requests, failures = [], []
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.socket)
        listener.listen(1)
        listener.settimeout(2)

        def serve():
            try:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(2)
                    data = bytearray()
                    while b"\n" not in data:
                        chunk = connection.recv(4096)
                        if not chunk:
                            raise AssertionError("helper closed before sending a complete request")
                        data.extend(chunk)
                    requests.append(json.loads(data.split(b"\n", 1)[0]))
                    if callable(response):
                        response(connection)
                    else:
                        payload = response if response is not None else {
                            "id": "cpcv-paste", "result": {"type": "ok"}
                        }
                        connection.sendall(json.dumps(payload).encode() + b"\n")
            except BaseException as error:
                failures.append(error)

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        try:
            yield requests
        finally:
            worker.join(3)
            listener.close()
            os.unlink(self.socket)
            self.assertFalse(worker.is_alive(), "fake Herdr server did not finish")
            if failures:
                raise failures[0]

    def context(self, pane="wA:pZ"):
        os.environ["HERDR_ACTIVE_PANE_ID"] = pane
        os.environ["HERDR_SOCKET_PATH"] = self.socket
        # Outer multiplexers and inherited pane variables must never retarget it.
        os.environ["HERDR_PANE_ID"] = "w1:p2"
        os.environ["TMUX_PANE"] = "%77"

    def test_installed_helper_pastes_once_into_originating_named_session(self):
        self.context()
        with self.server() as requests:
            result = subprocess.run(
                [sys.executable, str(self.helper), "paste"],
                env=dict(os.environ), capture_output=True, timeout=5,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, [{
            "id": "cpcv-paste", "method": "pane.send_input",
            "params": {"pane_id": "wA:pZ", "text": str(self.image), "keys": []},
        }])
        self.assertEqual(self.image.read_bytes(), b"synthetic-image")

    def test_latest_symlink_uses_stable_path(self):
        uploaded = self.image.with_name("clip-test.png")
        self.image.rename(uploaded)
        self.image.symlink_to(uploaded.name)
        self.assertEqual(HERDR.latest_image(self.home), str(self.image))

    def test_missing_or_empty_image_never_sends_input(self):
        self.context()
        for kind in ("empty", "missing", "broken-link"):
            with self.subTest(kind=kind), patch.object(HERDR, "send_paste") as send:
                if self.image.exists() or self.image.is_symlink():
                    self.image.unlink()
                if kind == "empty":
                    self.image.touch()
                elif kind == "broken-link":
                    self.image.symlink_to("missing.png")
                with self.assertRaisesRegex(HERDR.CpcvError, "no uploaded image"):
                    HERDR.paste()
                send.assert_not_called()

    def test_missing_or_invalid_pane_never_falls_back_to_current_focus(self):
        for pane in ("", "p1", "%42", "w1:p1\n", "--help"):
            self.context(pane)
            with self.subTest(pane=pane), patch.object(HERDR, "send_paste") as send:
                with self.assertRaisesRegex(HERDR.CpcvError, "HERDR_ACTIVE_PANE_ID"):
                    HERDR.paste()
                send.assert_not_called()

    def test_missing_socket_does_not_guess_default_server(self):
        self.context("w0:p11")
        del os.environ["HERDR_SOCKET_PATH"]
        with self.assertRaisesRegex(HERDR.CpcvError, "HERDR_SOCKET_PATH"):
            HERDR.paste()

    def test_rejects_image_directory_escape_and_control_characters(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "latest.png").write_bytes(b"private")
        linked = self.home / "linked"
        linked.symlink_to(outside, target_is_directory=True)
        for value in (str(outside), str(linked), "relative", str(self.home) + "/bad\npath"):
            self.config.write_text(json.dumps({"managedBy": HERDR.OWNER, "imageDir": value}))
            with self.subTest(value=value), self.assertRaises(HERDR.CpcvError):
                HERDR.latest_image(self.home)

    def test_rejects_invalid_config_and_linked_config(self):
        for content in ("not json", "[]", '{}', '{"managedBy":"other","imageDir":"/tmp"}'):
            self.config.write_text(content)
            with self.subTest(content=content), self.assertRaises((HERDR.CpcvError, ValueError)):
                HERDR.latest_image(self.home)
        self.config.unlink()
        self.config.symlink_to(self.image)
        with self.assertRaises(HERDR.CpcvError):
            HERDR.latest_image(self.home)

    def test_rejects_control_characters_after_symlink_resolution(self):
        destination = self.home / "bad\nname"
        destination.mkdir()
        (destination / "latest.png").write_bytes(b"private")
        linked = self.home / "linked"
        linked.symlink_to(destination, target_is_directory=True)
        self.config.write_text(json.dumps({"managedBy": HERDR.OWNER, "imageDir": str(linked)}))
        with self.assertRaises(HERDR.CpcvError):
            HERDR.latest_image(self.home)

    def test_missing_image_sends_notification_without_input(self):
        self.context()
        self.image.unlink()
        with self.server({"id": "cpcv-notify", "result": {"type": "notification_show", "shown": True}}) as requests:
            result = subprocess.run(
                [sys.executable, str(self.helper), "paste"],
                env=dict(os.environ), capture_output=True, timeout=5,
            )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0]["method"], "notification.show")
        self.assertIn("no uploaded image", requests[0]["params"]["body"])
        self.assertNotIn(str(self.home), result.stderr.decode())

    def test_rejects_unacknowledged_or_rejected_paste_without_retry(self):
        self.context()
        for response in (
            {"id": "wrong", "result": {"type": "ok"}},
            {"id": "cpcv-paste", "error": {"code": "pane_not_found", "message": "private"}},
            {"id": "cpcv-paste", "result": {"type": "pong"}},
            [],
        ):
            with self.subTest(response=response), self.server(response) as requests:
                with self.assertRaises(HERDR.CpcvError):
                    HERDR.paste()
            self.assertEqual(len(requests), 1)

    def test_bounds_and_validates_response(self):
        self.context()
        def oversized(connection):
            try:
                connection.sendall(b"x" * (HERDR.MAX_RESPONSE + 1))
            except BrokenPipeError:
                pass

        for response in (oversized, lambda c: c.sendall(b"invalid\n"), lambda c: None):
            with self.subTest(response=response), self.server(response) as requests:
                with self.assertRaises((HERDR.CpcvError, ValueError)):
                    HERDR.paste()
            self.assertEqual(len(requests), 1)

    def test_socket_timeout_is_bounded(self):
        self.context()
        release = threading.Event()
        with patch.object(HERDR, "TIMEOUT", 0.05), self.server(lambda c: release.wait(1)):
            try:
                with self.assertRaises((HERDR.CpcvError, OSError)):
                    HERDR.paste()
            finally:
                release.set()

    def test_rejects_socket_symlink_or_regular_file(self):
        self.context()
        for linked in (False, True):
            path = Path(self.socket)
            if linked:
                path.symlink_to(self.image)
            else:
                path.write_text("not a socket")
            with self.subTest(linked=linked), self.assertRaises(HERDR.CpcvError):
                HERDR.paste()
            path.unlink()

    def test_install_is_private_idempotent_and_preserves_other_config(self):
        herdr_config = self.home / ".config/herdr/config.toml"
        herdr_config.parent.mkdir()
        herdr_config.write_text("# existing Herdr configuration\n")
        tmux_config = self.home / ".tmux.conf"
        tmux_config.write_text("# existing tmux configuration\n")
        HERDR.install("images/clipboard")
        self.assertEqual(self.helper.read_bytes(), SOURCE.read_bytes())
        self.assertEqual(stat.S_IMODE(self.helper.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
        self.assertEqual(herdr_config.read_text(), "# existing Herdr configuration\n")
        self.assertEqual(tmux_config.read_text(), "# existing tmux configuration\n")

    def test_install_refuses_unowned_files_before_mutating(self):
        for path in (self.helper, self.config):
            original = path.read_bytes()
            path.write_text("unrelated user file")
            other = self.config if path == self.helper else self.helper
            other_original = other.read_bytes()
            with self.subTest(path=path), self.assertRaises((HERDR.CpcvError, ValueError)):
                HERDR.install("another-dir")
            self.assertEqual(path.read_text(), "unrelated user file")
            self.assertEqual(other.read_bytes(), other_original)
            self.assertFalse((self.home / "another-dir").exists())
            path.write_bytes(original)

    def test_install_refuses_symlinked_ancestor_and_invalid_remote_dir(self):
        for remote_dir in ("../outside", "/absolute", "images/../../outside", "bad\npath", "bad;command"):
            with self.subTest(remote_dir=remote_dir), self.assertRaises(HERDR.CpcvError):
                HERDR.install(remote_dir)
        (self.root / "outside").mkdir()
        (self.home / "linked").symlink_to(self.root / "outside", target_is_directory=True)
        with self.assertRaises(HERDR.CpcvError):
            HERDR.install("linked/images")
        self.assertEqual(list((self.root / "outside").iterdir()), [])


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cpcv-h-deploy-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.stage = Path(tempfile.mkdtemp(prefix="cpcv-herdr.", dir="/tmp"))
        self.addCleanup(lambda: shutil.rmtree(self.stage, ignore_errors=True))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.log = self.root / "calls.jsonl"
        self.environment = {
            **os.environ, "HOME": str(self.home), "PATH": str(self.bin) + os.pathsep + os.defpath,
            "FAKE_STAGE": str(self.stage), "FAKE_LOG": str(self.log), "FAKE_FAIL": "",
        }
        transport = '''import json, os, pathlib, shutil, subprocess, sys
with open(os.environ["FAKE_LOG"], "a") as stream:
    stream.write(json.dumps([pathlib.Path(sys.argv[0]).name] + sys.argv[1:]) + "\\n")
if pathlib.Path(sys.argv[0]).name == "scp":
    if os.environ.get("FAKE_FAIL") == "copy":
        sys.exit(1)
    shutil.copyfile(sys.argv[-2], pathlib.Path(os.environ["FAKE_STAGE"]) / "cpcv-herdr.py")
elif sys.argv[-1].startswith("command -v python3"):
    print("/tmp/not-a-cpcv-stage" if os.environ.get("FAKE_FAIL") == "stage" else os.environ["FAKE_STAGE"])
elif " install --remote-dir " in sys.argv[-1]:
    if os.environ.get("FAKE_FAIL") == "install":
        sys.exit(1)
    sys.exit(subprocess.call(["/bin/sh", "-c", sys.argv[-1]], env=os.environ))
elif sys.argv[-1].startswith("rm -f "):
    sys.exit(subprocess.call(["/bin/sh", "-c", sys.argv[-1]], env=os.environ))
else:
    sys.exit("unexpected SSH request")
'''
        for name in ("ssh", "scp"):
            executable = self.bin / name
            executable.write_text("#!" + sys.executable + "\n" + transport)
            executable.chmod(0o700)

    def deploy(self, *args):
        return subprocess.run(
            ["/bin/bash", "deploy-herdr.sh", *args], cwd=ROOT, env=self.environment,
            capture_output=True, text=True, timeout=5,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_deploy_from_root_installs_and_cleans_stage(self):
        result = self.deploy("--host", "image-box", "--remote-dir", "images/custom")
        self.assertEqual(result.returncode, 0, result.stderr)
        helper, config = HERDR.locations(self.home)
        self.assertEqual(helper.read_bytes(), SOURCE.read_bytes())
        self.assertEqual(json.loads(config.read_text())["imageDir"], str(self.home / "images/custom"))
        self.assertFalse(self.stage.exists())
        self.assertIn(HERDR.BINDING, result.stdout)
        self.assertEqual([call[0] for call in self.calls()], ["ssh", "scp", "ssh", "ssh"])

    def test_failed_copy_or_install_still_cleans_only_its_stage(self):
        for failure in ("copy", "install"):
            self.stage.mkdir(exist_ok=True)
            self.environment["FAKE_FAIL"] = failure
            with self.subTest(failure=failure):
                result = self.deploy("--host", "image-box")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.stage.exists())
                self.assertTrue(self.calls()[-1][-1].startswith("rm -f "))

    def test_invalid_stage_never_copies_or_removes_untrusted_path(self):
        self.environment["FAKE_FAIL"] = "stage"
        result = self.deploy("--host", "image-box")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 1)
        self.assertTrue(self.stage.exists())

    def test_invalid_arguments_never_start_ssh(self):
        for args in (
            ("--host", "-option"), ("--host", "host;command"),
            ("--host", "image-box", "--remote-dir", "../outside"),
            ("--host", "image-box", "--remote-dir", "bad\npath"),
        ):
            with self.subTest(args=args):
                self.assertNotEqual(self.deploy(*args).returncode, 0)
                self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
