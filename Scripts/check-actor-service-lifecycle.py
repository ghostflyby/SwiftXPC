#!/usr/bin/env python3
"""Exercise real launchd Session entry, preparation barriers, and awaited exit policy.

Run after build-demo-bundle.sh. Bundle-based C entry runs in the companion CI step.
"""
from pathlib import Path
import os
import plistlib
import subprocess
import tempfile
import time
import uuid

workspace = Path(__file__).resolve().parents[1]
bundle = workspace / "Examples/DistributedXPCDemo/.build/demo/DistributedXPCDemo.app/Contents"
server = bundle / "XPCServices/DemoService.xpc/Contents/MacOS/DemoService"
client = bundle / "MacOS/DemoApp"
domain = f"gui/{os.getuid()}"


def wait_until(predicate, description):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise RuntimeError("Timed out: " + description)


def tool(*arguments):
    return subprocess.run(arguments, capture_output=True, text=True, timeout=30, check=True).stdout


for client_transport in ("c", "session"):
    for fail_cleanup in (False, True):
        with tempfile.TemporaryDirectory(prefix="SwiftXPC-lifecycle-") as temporary:
            directory = Path(temporary)
            name = "org.swiftxpc.demo.lifecycle." + uuid.uuid4().hex
            log = directory / "service.log"
            errors = directory / "service-errors.log"
            start_gate = directory / "start"
            shutdown_gate = directory / "shutdown"
            job = directory / "job.plist"
            arguments = [str(server), "--session-service", name,
                         "--startup-gate", str(start_gate), "--shutdown-gate", str(shutdown_gate)]
            if fail_cleanup:
                arguments.append("--fail-shutdown")
            job.write_bytes(plistlib.dumps({
                "Label": name, "ProgramArguments": arguments, "MachServices": {name: True},
                "RunAtLoad": True, "StandardOutPath": str(log), "StandardErrorPath": str(errors),
            }))
            process = None
            try:
                tool("/bin/launchctl", "bootstrap", domain, str(job))
                events = lambda: log.read_text().splitlines() if log.exists() else []
                wait_until(lambda: "factory" in events(), "asynchronous factory entry")
                assert "will-start" not in events()
                command = [str(client), "--mach-service", name, "--retire"]
                if client_transport == "session":
                    command.append("--session")
                process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                start_gate.touch()
                wait_until(lambda: "will-shutdown" in events(), "shutdown hook")
                assert "did-shutdown" not in events() and "shutdown-error" not in events()
                assert "state = running" in tool("/bin/launchctl", "print", domain + "/" + name)
                shutdown_gate.touch()
                output, error_output = process.communicate(timeout=25)
                assert process.returncode == 0, output + error_output
                assert "root injection and preparation ok" in output
                assert "cooperative retirement observed" in output
                terminal = "shutdown-error" if fail_cleanup else "did-shutdown"
                wait_until(lambda: terminal in events(), "awaited terminal hook")
                expected_status = 1 if fail_cleanup else 0
                wait_until(lambda: f"last exit code = {expected_status}" in
                           tool("/bin/launchctl", "print", domain + "/" + name), "process exit status")
                sequence = events()
                for before, after in (("factory", "will-start"), ("will-start", "did-start"),
                                      ("did-start", "will-bind"), ("will-bind", "did-bind"),
                                      ("did-bind", "peer-end"), ("peer-end", "will-shutdown"),
                                      ("will-shutdown", terminal)):
                    assert sequence.index(before) < sequence.index(after), sequence
                assert sequence.count(terminal) == sequence.count("will-shutdown") == 1
                print(f"Session entry / {client_transport} client / exit {expected_status}: PASS")
            except BaseException:
                if log.exists():
                    print(log.read_text())
                if errors.exists():
                    print(errors.read_text())
                raise
            finally:
                if process is not None and process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)
                subprocess.run(["/bin/launchctl", "bootout", domain + "/" + name],
                               capture_output=True, timeout=10)
