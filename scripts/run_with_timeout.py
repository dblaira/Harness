#!/usr/bin/env python3
"""Run one command in a tracked job and leave no descendants behind."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


IDENTITY_ENV = "HARNESS_PROCESS_IDENTITY"
_IDENTITY_CACHE: dict[str, tuple[float, list[dict[str, object]]]] = {}


def launchd_child_mode() -> int | None:
    """Run one command while keeping its launchd service alive for cleanup."""
    if len(sys.argv) < 4 or sys.argv[1] != "--launchd-child":
        return None
    state = Path(sys.argv[2])
    command = sys.argv[4:] if sys.argv[3] == "--" else []
    if not command:
        return 127
    try:
        process = subprocess.Popen(command, start_new_session=True)
    except OSError as error:
        write_json(state / "result.json", {"returncode": 127, "error": str(error)})
        while True:
            time.sleep(60)
    write_json(
        state / "ready.json",
        {"pid": process.pid, "process_group": os.getpgid(process.pid)},
    )
    returncode = process.wait()
    write_json(state / "result.json", {"returncode": returncode})
    # The service stays alive after the command returns so launchd still owns
    # every descendant coalition member until the trusted parent removes it.
    while True:
        time.sleep(60)


def group_members(pgid: int) -> list[dict[str, object]]:
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,pgid=,uid=,command="],
        text=True,
        capture_output=True,
        check=False,
    )
    members: list[dict[str, object]] = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) < 3:
            continue
        try:
            pid, process_group, uid = int(fields[0]), int(fields[1]), int(fields[2])
        except ValueError:
            continue
        if process_group == pgid:
            members.append({"pid": pid, "uid": uid, "command": fields[3] if len(fields) == 4 else ""})
    return members


def process_table() -> list[dict[str, object]]:
    command = ["/bin/ps", "-axo", "pid=,ppid=,pgid=,uid=,command="]
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    members: list[dict[str, object]] = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 4)
        if len(fields) < 4:
            continue
        try:
            pid, ppid, pgid, uid = map(int, fields[:4])
        except ValueError:
            continue
        members.append({
            "pid": pid,
            "ppid": ppid,
            "pgid": pgid,
            "uid": uid,
            "command": fields[4] if len(fields) == 5 else "",
        })
    return members


def tokenized_command(command: list[str], token: str) -> list[str]:
    assignment = f"{IDENTITY_ENV}={token}"
    if command and command[0] in ("/usr/bin/env", "/bin/env", "env"):
        try:
            clean_index = command.index("-i")
        except ValueError:
            clean_index = -1
        if clean_index >= 0:
            return [*command[:clean_index + 1], assignment, *command[clean_index + 1:]]
    return ["/usr/bin/env", assignment, *command]


def process_environment_contains(pid: int, marker: bytes) -> bool:
    if sys.platform == "darwin":
        libc = ctypes.CDLL(None, use_errno=True)
        mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2, pid
        size = ctypes.c_size_t(0)
        if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or not 0 < size.value < 8_000_000:
            return False
        buffer = ctypes.create_string_buffer(size.value)
        if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
            return False
        return marker + b"\0" in buffer.raw[:size.value]
    try:
        return marker + b"\0" in Path(f"/proc/{pid}/environ").read_bytes() + b"\0"
    except OSError:
        return False


def identity_members(token: str, *, force: bool = False) -> list[dict[str, object]]:
    now = time.monotonic()
    cached = _IDENTITY_CACHE.get(token)
    if not force and cached and now - cached[0] < 0.2:
        return cached[1]
    marker = f"{IDENTITY_ENV}={token}".encode()
    members = [
        member
        for member in process_table()
        if int(member["uid"]) == os.getuid()
        and process_environment_contains(int(member["pid"]), marker)
    ]
    _IDENTITY_CACHE[token] = (now, members)
    return members


def descendant_pids(root_pid: int, known: set[int], table: list[dict[str, object]]) -> set[int]:
    descendants = set(known)
    descendants.add(root_pid)
    changed = True
    while changed:
        changed = False
        for member in table:
            pid = int(member["pid"])
            if int(member["ppid"]) in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True
    return descendants


def observe_job(
    root_pid: int,
    pgid: int,
    token: str,
    known: set[int],
    *,
    force_identity: bool = False,
) -> set[int]:
    table = process_table()
    observed = descendant_pids(root_pid, known, table)
    observed.update(int(member["pid"]) for member in table if int(member["pgid"]) == pgid)
    observed.update(int(member["pid"]) for member in identity_members(token, force=force_identity))
    observed.discard(os.getpid())
    return observed


def process_details(pids: set[int]) -> list[dict[str, object]]:
    wanted = set(pids)
    return [
        {
            "pid": int(member["pid"]),
            "ppid": int(member["ppid"]),
            "pgid": int(member["pgid"]),
            "uid": int(member["uid"]),
            "command": str(member["command"]),
        }
        for member in process_table()
        if int(member["pid"]) in wanted
    ]


def signal_group(pgid: int, signum: signal.Signals) -> None:
    try:
        os.killpg(pgid, signum)
        return
    except ProcessLookupError:
        return
    except PermissionError:
        # Some Apple test services can momentarily join the command group under
        # a protected identity. Never crash cleanup: signal every process that
        # this user owns and leave any protected survivor visible in evidence.
        pass
    for member in group_members(pgid):
        if member.get("uid") != os.getuid():
            continue
        try:
            os.kill(int(member["pid"]), signum)
        except (ProcessLookupError, PermissionError):
            pass


def signal_pids(pids: set[int], signum: signal.Signals) -> None:
    owned = {
        int(member["pid"])
        for member in process_table()
        if int(member["pid"]) in pids and int(member["uid"]) == os.getuid()
    }
    for pid in sorted(owned, reverse=True):
        try:
            os.kill(pid, signum)
        except (ProcessLookupError, PermissionError):
            pass


def terminate_job(
    root_pid: int,
    pgid: int,
    token: str,
    known: set[int],
) -> tuple[list[dict[str, object]], list[dict[str, object]], set[int]]:
    observed = observe_job(root_pid, pgid, token, known, force_identity=True)
    before = process_details(observed)
    if observed:
        signal_group(pgid, signal.SIGTERM)
        signal_pids(observed, signal.SIGTERM)
        for _ in range(40):
            observed = observe_job(root_pid, pgid, token, observed)
            alive = {
                int(member["pid"])
                for member in process_details(observed)
                if int(member["pid"]) != root_pid
            }
            if not alive:
                break
            time.sleep(0.025)
        alive = {
            int(member["pid"])
            for member in process_details(observed)
            if int(member["pid"]) != root_pid
        }
        if alive:
            signal_group(pgid, signal.SIGKILL)
            signal_pids(alive, signal.SIGKILL)
            for _ in range(40):
                observed = observe_job(root_pid, pgid, token, observed)
                alive = {
                    int(member["pid"])
                    for member in process_details(observed)
                    if int(member["pid"]) != root_pid
                }
                if not alive:
                    break
                time.sleep(0.025)
    retained = [
        member
        for member in process_details(
            observe_job(root_pid, pgid, token, observed, force_identity=True)
        )
        if int(member["pid"]) != root_pid
    ]
    return before, retained, observed


def write_json(path: Path | None, payload: dict[str, object]) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def normalize_returncode(returncode: int | None) -> int:
    if returncode is None:
        return 125
    return 128 - returncode if returncode < 0 else returncode


def pump_log(path: Path, stream: object, offset: int) -> int:
    try:
        with path.open("rb") as handle:
            handle.seek(offset)
            payload = handle.read()
    except OSError:
        return offset
    if not payload:
        return offset
    binary = getattr(stream, "buffer", None)
    if binary is not None:
        binary.write(payload)
        binary.flush()
    else:
        stream.write(payload.decode("utf-8", errors="replace"))
        stream.flush()
    return offset + len(payload)


def launchctl(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/launchctl", *arguments],
        text=True,
        capture_output=True,
        check=False,
    )


def launchd_coalition_id(target: str) -> int | None:
    result = launchctl("print", target)
    if result.returncode:
        return None
    match = re.search(r"resource coalition = \{.*?\bID = (\d+)", result.stdout, re.DOTALL)
    return int(match.group(1)) if match else None


def coalition_pids(coalition_id: int) -> set[int]:
    libc = ctypes.CDLL(None, use_errno=True)
    function = libc.coalition_info_pid_list
    function.argtypes = [
        ctypes.c_uint64,
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    function.restype = ctypes.c_int
    pids = (ctypes.c_int * 65536)()
    size = ctypes.c_size_t(ctypes.sizeof(pids))
    if function(coalition_id, pids, ctypes.byref(size)) != 0:
        return set()
    count = min(size.value // ctypes.sizeof(ctypes.c_int), len(pids))
    return {int(pid) for pid in pids[:count] if int(pid) > 0}


def remove_launchd_service(
    label: str,
    target: str,
    coalition_id: int,
) -> tuple[bool, list[str], set[int]]:
    errors: list[str] = []
    observed = coalition_pids(coalition_id)
    signal_pids(observed, signal.SIGTERM)
    launchctl("kill", "SIGTERM", target)
    for _ in range(20):
        members = coalition_pids(coalition_id)
        observed.update(members)
        if not members:
            break
        time.sleep(0.025)
    members = coalition_pids(coalition_id)
    observed.update(members)
    if members:
        signal_pids(members, signal.SIGKILL)
        launchctl("kill", "SIGKILL", target)
    launchctl("remove", label)
    for _ in range(40):
        members = coalition_pids(coalition_id)
        observed.update(members)
        if launchctl("print", target).returncode != 0 and not members:
            return True, errors, observed
        time.sleep(0.025)
    members = coalition_pids(coalition_id)
    observed.update(members)
    errors.append(
        f"launchd service coalition survived removal: {target}; members={sorted(members)}"
    )
    return False, errors, observed


def run_launchd_job(args: argparse.Namespace, command: list[str]) -> int:
    identity_token = uuid.uuid4().hex
    launched_command = tokenized_command(command, identity_token)
    state_parent = (
        args.process_report.parent
        if args.process_report is not None
        else Path.home() / ".local" / "share" / "harness-process-jobs"
    )
    state_parent.mkdir(parents=True, exist_ok=True)
    state = Path(tempfile.mkdtemp(prefix=".process-state-", dir=state_parent))
    state.chmod(0o700)
    stdout_path = state / "stdout.log"
    stderr_path = state / "stderr.log"
    stdout_path.touch(mode=0o600)
    stderr_path.touch(mode=0o600)
    label = f"com.adamblair.harness.job.{os.getpid()}.{uuid.uuid4().hex}"
    target = f"gui/{os.getuid()}/{label}"
    submit = launchctl(
        "submit",
        "-l", label,
        "-o", str(stdout_path),
        "-e", str(stderr_path),
        "--",
        sys.executable,
        str(Path(__file__).resolve()),
        "--launchd-child",
        str(state),
        "--",
        *launched_command,
    )
    if submit.returncode:
        shutil.rmtree(state, ignore_errors=True)
        print(submit.stderr.strip() or "could not submit launchd process job", file=sys.stderr)
        return 125
    coalition_id: int | None = None
    for _ in range(40):
        coalition_id = launchd_coalition_id(target)
        if coalition_id is not None:
            break
        time.sleep(0.025)
    if coalition_id is None:
        launchctl("remove", label)
        shutil.rmtree(state, ignore_errors=True)
        print("launchd process job lacks a resource coalition", file=sys.stderr)
        return 125

    ready_path = state / "ready.json"
    result_path = state / "result.json"
    interrupted_signal = 0

    def interrupt(signum: int, _frame: object) -> None:
        nonlocal interrupted_signal
        interrupted_signal = signum

    previous_handlers = {
        signum: signal.signal(signum, interrupt)
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    }
    timed_out = False
    stdout_offset = 0
    stderr_offset = 0
    tracking_errors: list[str] = []
    original_returncode: int | None = None
    root_pid = 0
    pgid = 0
    observed_pids: set[int] = set()
    deadline = time.monotonic() + args.seconds
    try:
        while not ready_path.exists() and not interrupted_signal:
            stdout_offset = pump_log(stdout_path, sys.stdout, stdout_offset)
            stderr_offset = pump_log(stderr_path, sys.stderr, stderr_offset)
            if time.monotonic() >= deadline:
                timed_out = True
                break
            if launchctl("print", target).returncode != 0:
                tracking_errors.append("launchd process job exited before publishing its command PID")
                break
            time.sleep(0.025)
        if ready_path.exists():
            try:
                ready = json.loads(ready_path.read_text(encoding="utf-8"))
                root_pid = int(ready["pid"])
                pgid = int(ready["process_group"])
                observed_pids.add(root_pid)
                write_json(args.ready_file, ready)
            except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
                tracking_errors.append(f"invalid launchd process readiness proof: {error}")
        while root_pid and not result_path.exists() and not timed_out and not interrupted_signal:
            observed_pids = observe_job(root_pid, pgid, identity_token, observed_pids)
            observed_pids.update(coalition_pids(coalition_id))
            stdout_offset = pump_log(stdout_path, sys.stdout, stdout_offset)
            stderr_offset = pump_log(stderr_path, sys.stderr, stderr_offset)
            if time.monotonic() >= deadline:
                timed_out = True
                break
            time.sleep(0.025)
        if result_path.exists():
            try:
                original_returncode = int(
                    json.loads(result_path.read_text(encoding="utf-8"))["returncode"]
                )
            except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
                tracking_errors.append(f"invalid launchd process result proof: {error}")
        if root_pid:
            observed_pids = observe_job(
                root_pid, pgid, identity_token, observed_pids, force_identity=True
            )
        observed_pids.update(coalition_pids(coalition_id))
        observed = process_details(observed_pids)
        removed, removal_errors, coalition_observed = remove_launchd_service(
            label, target, coalition_id
        )
        observed_pids.update(coalition_observed)
        tracking_errors.extend(removal_errors)
        time.sleep(0.1)
        stdout_offset = pump_log(stdout_path, sys.stdout, stdout_offset)
        stderr_offset = pump_log(stderr_path, sys.stderr, stderr_offset)
        if root_pid:
            observed_pids = observe_job(
                root_pid, pgid, identity_token, observed_pids, force_identity=True
            )
        retained_ids = coalition_pids(coalition_id)
        retained_ids.update(
            int(member["pid"])
            for member in process_details(observed_pids)
        )
        retained = process_details(retained_ids)
        if retained:
            tracking_errors.append("launchd service removal retained known process members")
        if timed_out:
            returncode = 124
        elif interrupted_signal:
            returncode = 128 + interrupted_signal
        else:
            returncode = normalize_returncode(original_returncode)
        successful = returncode == 0 or (
            args.termination_ok
            and interrupted_signal == 0
            and not timed_out
            and returncode in (129, 130, 143)
        )
        report = {
            "schema_version": 3,
            "label": args.label,
            "command": command,
            "pid": root_pid,
            "process_group": pgid,
            "job_boundary": {
                "type": "launchd-service-coalition",
                "label": label,
                "coalition_id": coalition_id,
                "removed": removed,
            },
            "timed_out": timed_out,
            "interrupted_signal": interrupted_signal,
            "command_returncode": original_returncode,
            "returncode": returncode,
            "members_observed_at_cleanup": observed,
            "tracked_pids": sorted(observed_pids),
            "tracking_errors": tracking_errors,
            "retained_pids": retained,
            "status": "PASS" if successful and removed and not retained and not tracking_errors else "FAIL",
        }
        write_json(args.process_report, report)
        if tracking_errors:
            print("; ".join(tracking_errors), file=sys.stderr)
            return 125
        if timed_out:
            print(f"Command exceeded the {args.seconds:g}-second evidence deadline", file=sys.stderr)
        return int(returncode)
    finally:
        if launchctl("print", target).returncode == 0:
            remove_launchd_service(label, target, coalition_id)
        shutil.rmtree(state, ignore_errors=True)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


def run_portable_job(args: argparse.Namespace, command: list[str]) -> int:
    identity_token = uuid.uuid4().hex
    launched_command = tokenized_command(command, identity_token)
    process = subprocess.Popen(launched_command, start_new_session=True)
    pgid = os.getpgid(process.pid)
    write_json(args.ready_file, {"pid": process.pid, "process_group": pgid})
    interrupted_signal = 0
    observed_pids: set[int] = {process.pid}

    def interrupt(signum: int, _frame: object) -> None:
        nonlocal interrupted_signal
        interrupted_signal = signum
        signal_group(pgid, signal.SIGTERM)

    previous_handlers = {
        signum: signal.signal(signum, interrupt)
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    }
    timed_out = False
    try:
        deadline = time.monotonic() + args.seconds
        while process.poll() is None and not interrupted_signal:
            observed_pids = observe_job(process.pid, pgid, identity_token, observed_pids)
            if time.monotonic() >= deadline:
                timed_out = True
                break
            time.sleep(0.025)
        original_returncode = process.poll()
        observed_pids = observe_job(
            process.pid, pgid, identity_token, observed_pids, force_identity=True
        )
        observed, retained, observed_pids = terminate_job(
            process.pid, pgid, identity_token, observed_pids
        )
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        if timed_out:
            returncode = 124
        elif interrupted_signal:
            returncode = 128 + interrupted_signal
        else:
            returncode = original_returncode if original_returncode is not None else process.returncode
            if returncode is not None and returncode < 0:
                returncode = 128 - returncode
        successful = returncode == 0 or (
            args.termination_ok and interrupted_signal == 0 and not timed_out and returncode in (129, 130, 143)
        )
        report = {
            "schema_version": 2,
            "label": args.label,
            "command": command,
            "pid": process.pid,
            "process_group": pgid,
            "timed_out": timed_out,
            "interrupted_signal": interrupted_signal,
            "command_returncode": original_returncode,
            "returncode": returncode,
            "members_observed_at_cleanup": observed,
            "tracked_pids": sorted(observed_pids),
            "tracking_errors": [],
            "retained_pids": retained,
            "status": "PASS" if successful and not retained else "FAIL",
        }
        write_json(args.process_report, report)
        if retained:
            print(f"Tracked process job {pgid} retained descendants: {retained}", file=sys.stderr)
            return 125
        if timed_out:
            print(f"Command exceeded the {args.seconds:g}-second evidence deadline", file=sys.stderr)
        return int(returncode)
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


def main() -> int:
    child_result = launchd_child_mode()
    if child_result is not None:
        return child_result
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--process-report", type=Path)
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--label", default="proposal-command")
    parser.add_argument("--termination-ok", action="store_true")
    parser.add_argument("--launchd-coalition", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    if sys.platform == "darwin" and args.launchd_coalition:
        return run_launchd_job(args, command)
    return run_portable_job(args, command)


if __name__ == "__main__":
    raise SystemExit(main())
