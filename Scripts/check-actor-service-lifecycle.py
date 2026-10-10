#!/usr/bin/env python3
"""Check real C/Session entries, preparation gates, and server exit status.

Run after build-demo-bundle.sh. C fixtures use isolated signed bundles and a
kernel process-exit observer; Session fixtures use isolated launchd jobs.
"""
from contextlib import closing
from pathlib import Path
import os
import plistlib
import select
import shutil
import subprocess
import tempfile
import time
import uuid

workspace = Path(__file__).resolve().parents[1]
bundle = workspace / "Examples/DistributedXPCDemo/.build/demo/DistributedXPCDemo.app"
client = bundle / "Contents/MacOS/DemoApp"
server = bundle / "Contents/MacOS/DemoSessionService"
domain = f"gui/{os.getuid()}"
# sys/event.h: include the wait status in NOTE_EXIT's data. Python exposes
# NOTE_EXIT but omits NOTE_EXITSTATUS on some macOS versions.
NOTE_EXITSTATUS = 0x04000000


def wait_until(predicate, description):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise RuntimeError("Timed out: " + description)


def tool(*arguments):
    return subprocess.run(arguments, capture_output=True, text=True, timeout=30, check=True).stdout


def finish_client(process, mode):
    output, errors = process.communicate(timeout=25)
    assert process.returncode == 0, output + errors
    if mode == "cancel":
        assert "service rejection observed" in output, output
    else:
        assert "root injection and preparation ok" in output, output
        assert "cooperative retirement observed" in output, output


def verify_events(sequence, mode):
    stages = ["factory", "will-start", "did-start", "will-bind", "did-bind"]
    if mode == "cancel":
        assert not any(event in sequence for event in
                       ("peer-end", "will-shutdown", "did-shutdown", "shutdown-error")), sequence
    else:
        terminal = "shutdown-error" if mode == "fail" else "did-shutdown"
        stages += ["peer-end", "will-shutdown", terminal]
    assert all(sequence.count(stage) == 1 for stage in stages), sequence
    assert [sequence.index(stage) for stage in stages] == sorted(sequence.index(stage) for stage in stages), sequence


def command(executable, flag, name, transport, mode):
    arguments = [str(executable), flag, name,
                 "--expect-rejection" if mode == "cancel" else "--retire"]
    if transport == "session":
        arguments.append("--session")
    return arguments


def cleanup_client(process):
    if process is not None and process.poll() is None:
        process.kill()
        process.communicate(timeout=5)


def check_c_entry(transport, mode):
    with tempfile.TemporaryDirectory(prefix="SwiftXPC-C-entry-") as temporary:
        directory = Path(temporary)
        fixture = directory / "Demo.app"
        shutil.copytree(bundle, fixture)
        name = "org.swiftxpc.demo.lifecycle." + uuid.uuid4().hex
        service = fixture / "Contents/XPCServices/DemoService.xpc"
        for path, identifier in ((fixture / "Contents/Info.plist", name + ".container"),
                                 (service / "Contents/Info.plist", name)):
            value = plistlib.loads(path.read_bytes())
            value["CFBundleIdentifier"] = identifier
            path.write_bytes(plistlib.dumps(value))
        log = directory / "events.log"
        log.touch()
        start_gate = directory / "start"
        shutdown_gate = directory / "shutdown"
        arguments = ["--startup-gate", str(start_gate), "--shutdown-gate", str(shutdown_gate),
                     "--event-log", str(log)]
        if mode != "normal":
            arguments.append("--cancel" if mode == "cancel" else "--fail-shutdown")
        resources = service / "Contents/Resources"
        resources.mkdir(exist_ok=True)
        (resources / "lifecycle-arguments.plist").write_bytes(plistlib.dumps(arguments))
        for item in (service, fixture):
            tool("/usr/bin/codesign", "--force", "--sign", "-", str(item))
        process = None
        events = lambda: log.read_text().splitlines()
        try:
            process = subprocess.Popen(command(fixture / "Contents/MacOS/DemoApp", "--xpc-service",
                                               name, transport, mode),
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            wait_until(lambda: any(event.startswith("pid:") for event in events()), "C factory entry")
            assert "will-start" not in events()
            pid = int(next(event.split(":")[1] for event in events() if event.startswith("pid:")))
            with closing(select.kqueue()) as queue:
                queue.control([select.kevent(pid, filter=select.KQ_FILTER_PROC,
                                             flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE,
                                             fflags=select.KQ_NOTE_EXIT | NOTE_EXITSTATUS)], 0)
                start_gate.touch()
                if mode != "cancel":
                    wait_until(lambda: "will-shutdown" in events(), "C shutdown hook")
                    assert "did-shutdown" not in events() and "shutdown-error" not in events()
                    assert not queue.control(None, 1, 0), "C process exited before cleanup gate opened"
                    shutdown_gate.touch()
                notification = queue.control(None, 1, 25)
                assert len(notification) == 1, "No C server exit notification"
                assert notification[0].fflags & NOTE_EXITSTATUS, "Kernel did not provide exit status"
                status = notification[0].data
                expected = 0 if mode == "normal" else 1
                assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == expected, status
            finish_client(process, mode)
            verify_events(events(), mode)
            print(f"C entry / {transport} client / {mode} / exit {expected}: PASS", flush=True)
        except BaseException:
            print(log.read_text(), flush=True)
            raise
        finally:
            start_gate.touch()
            shutdown_gate.touch()
            cleanup_client(process)


def check_session_entry(transport, mode):
    with tempfile.TemporaryDirectory(prefix="SwiftXPC-Session-entry-") as temporary:
        directory = Path(temporary)
        name = "org.swiftxpc.demo.lifecycle." + uuid.uuid4().hex
        log = directory / "service.log"
        errors = directory / "service-errors.log"
        start_gate = directory / "start"
        shutdown_gate = directory / "shutdown"
        job = directory / "job.plist"
        arguments = [str(server), "--session-service", name,
                     "--startup-gate", str(start_gate), "--shutdown-gate", str(shutdown_gate)]
        if mode != "normal":
            arguments.append("--cancel" if mode == "cancel" else "--fail-shutdown")
        job.write_bytes(plistlib.dumps({
            "Label": name, "ProgramArguments": arguments, "MachServices": {name: True},
            "RunAtLoad": True, "StandardOutPath": str(log), "StandardErrorPath": str(errors),
        }))
        process = None
        try:
            tool("/bin/launchctl", "bootstrap", domain, str(job))
            events = lambda: log.read_text().splitlines() if log.exists() else []
            wait_until(lambda: "factory" in events(), "Session asynchronous factory entry")
            assert "will-start" not in events()
            process = subprocess.Popen(command(client, "--mach-service", name, transport, mode),
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            start_gate.touch()
            if mode != "cancel":
                wait_until(lambda: "will-shutdown" in events(), "Session shutdown hook")
                assert "did-shutdown" not in events() and "shutdown-error" not in events()
                assert "state = running" in tool("/bin/launchctl", "print", domain + "/" + name)
                shutdown_gate.touch()
            finish_client(process, mode)
            expected = 0 if mode == "normal" else 1
            wait_until(lambda: f"last exit code = {expected}" in
                       tool("/bin/launchctl", "print", domain + "/" + name), "Session server exit status")
            verify_events(events(), mode)
            print(f"Session entry / {transport} client / {mode} / exit {expected}: PASS", flush=True)
        except BaseException:
            if log.exists():
                print(log.read_text(), flush=True)
            if errors.exists():
                print(errors.read_text(), flush=True)
            raise
        finally:
            start_gate.touch()
            shutdown_gate.touch()
            cleanup_client(process)
            subprocess.run(["/bin/launchctl", "bootout", domain + "/" + name],
                           capture_output=True, timeout=10)


for arguments in (("--mach-service",), ("--mach-service", "--session")):
    result = subprocess.run([str(client), *arguments], capture_output=True, text=True, timeout=10)
    assert result.returncode == 1 and "MissingArgument" in result.stderr, result.stderr
print("Demo argument validation: PASS", flush=True)

for client_transport in ("c", "session"):
    for mode in ("normal", "fail", "cancel"):
        check_c_entry(client_transport, mode)
        check_session_entry(client_transport, mode)
