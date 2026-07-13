#!/usr/bin/env python3
"""Run one command in a tracked process group and leave no descendants behind."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


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


def terminate_group(pgid: int) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    before = group_members(pgid)
    if before:
        signal_group(pgid, signal.SIGTERM)
        for _ in range(20):
            if not group_members(pgid):
                break
            time.sleep(0.05)
        remaining = group_members(pgid)
        if remaining:
            signal_group(pgid, signal.SIGKILL)
            for _ in range(20):
                if not group_members(pgid):
                    break
                time.sleep(0.05)
    return before, group_members(pgid)


def write_json(path: Path | None, payload: dict[str, object]) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--process-report", type=Path)
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--label", default="proposal-command")
    parser.add_argument("--termination-ok", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")

    process = subprocess.Popen(command, start_new_session=True)
    pgid = os.getpgid(process.pid)
    write_json(args.ready_file, {"pid": process.pid, "process_group": pgid})
    interrupted_signal = 0

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
            if time.monotonic() >= deadline:
                timed_out = True
                break
            time.sleep(0.05)
        original_returncode = process.poll()
        observed, retained = terminate_group(pgid)
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
            "schema_version": 1,
            "label": args.label,
            "command": command,
            "pid": process.pid,
            "process_group": pgid,
            "timed_out": timed_out,
            "interrupted_signal": interrupted_signal,
            "command_returncode": original_returncode,
            "returncode": returncode,
            "members_observed_at_cleanup": observed,
            "retained_pids": retained,
            "status": "PASS" if successful and not retained else "FAIL",
        }
        write_json(args.process_report, report)
        if retained:
            print(f"Tracked process group {pgid} retained descendants: {retained}", file=sys.stderr)
            return 125
        if timed_out:
            print(f"Command exceeded the {args.seconds:g}-second evidence deadline", file=sys.stderr)
        return int(returncode)
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    raise SystemExit(main())
