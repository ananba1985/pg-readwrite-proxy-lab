#!/usr/bin/env python
"""Run inside one CentOS 7 VM and verify root/password SSH to peer IPs."""

from __future__ import print_function

import errno
import crypt
import os
import pty
import select
import signal
import subprocess
import sys
import time


def fail(message):
    sys.stderr.write(message + "\n")
    raise SystemExit(1)


def verify_target(source_ip, target_ip, password):
    command = [
        "ssh",
        "-o", "PreferredAuthentications=password",
        "-o", "PubkeyAuthentication=no",
        "-o", "NumberOfPasswordPrompts=1",
        "-o", "ConnectTimeout=8",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "root@" + target_ip,
        "printf 'uid='; id -u; /sbin/ip -o -4 addr show dev eth1",
    ]
    child_pid, master_fd = pty.fork()
    if child_pid == 0:
        os.execvp(command[0], command)

    output = ""
    password_sent = False
    deadline = time.time() + 20
    try:
        while time.time() < deadline:
            readable, _, _ = select.select([master_fd], [], [], 0.5)
            if not readable:
                waited_pid, _ = os.waitpid(child_pid, os.WNOHANG)
                if waited_pid == child_pid:
                    break
                continue
            try:
                data = os.read(master_fd, 4096)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not data:
                break
            output += data
            if not password_sent and "password:" in output.lower():
                os.write(master_fd, password + "\n")
                password_sent = True
        else:
            os.kill(child_pid, signal.SIGKILL)
            fail("timeout: %s -> root@%s" % (source_ip, target_ip))
    finally:
        try:
            os.close(master_fd)
        except OSError:
            pass

    try:
        os.waitpid(child_pid, 0)
    except OSError as exc:
        if exc.errno != errno.ECHILD:
            raise

    clean_output = output.replace("\r", "")
    if "uid=0\n" not in clean_output or target_ip + "/24" not in clean_output:
        prompt = "yes" if "password:" in clean_output.lower() else "no"
        denied = "yes" if "permission denied" in clean_output.lower() else "no"
        fail(
            "authentication failed: %s -> root@%s; prompt=%s; denied=%s"
            % (source_ip, target_ip, prompt, denied)
        )
    print("PASS %s -> root@%s" % (source_ip, target_ip))


def main():
    if len(sys.argv) < 3:
        fail("usage: verifier.py SOURCE_IP TARGET_IP [TARGET_IP...]")
    source_ip = sys.argv[1]
    target_ips = sys.argv[2:]
    password = sys.stdin.readline().rstrip("\r\n")
    if not password:
        fail("empty password input")
    shadow_line = subprocess.check_output(["sudo", "getent", "shadow", "root"])
    root_hash = shadow_line.split(":", 2)[1]
    if crypt.crypt(password, root_hash) != root_hash:
        fail(
            "input password does not match source root shadow hash; length=%d; last_code=%d"
            % (len(password), ord(password[-1]))
        )
    for target_ip in target_ips:
        verify_target(source_ip, target_ip, password)


if __name__ == "__main__":
    main()
