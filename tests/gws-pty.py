#!/usr/bin/env python3
"""Drive omarchy-gws-picker under a real pseudo-terminal, so the real gum runs.

usage: gws-pty.py PICKER KEYS...
Waits for the checklist to draw, sends each key, then prints the picker's exit status.
Keys: ENTER, SPACE, CTRL_C, or literal text. Exit 0 = the status was printed, 3 = timed out.
"""
import fcntl, os, pty, select, struct, sys, termios, time

KEYS = {"ENTER": "\r", "CTRL_C": "\x03", "DOWN": "\x1b[B"}
PROMPT = b"Relaunch?"


def main():
    picker, keys = sys.argv[1], sys.argv[2:]
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execv(picker, [picker])
    # gum draws nothing in a 0x0 terminal, so give the pty a real size first.
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    out, sent, deadline = b"", False, time.time() + 25
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:  # the child closed the pty
                break
            out += chunk
        if not sent and PROMPT in out:
            time.sleep(1.5)  # let gum finish drawing before the keys arrive
            for k in keys:
                os.write(fd, KEYS.get(k, k).encode())
                time.sleep(0.8)
            sent = True
    _, status = os.waitpid(pid, 0)
    if not sent:
        sys.stderr.write("prompt never appeared; output tail: %r\n" % out[-300:])
        print("timeout")
        return 3
    print(os.waitstatus_to_exitcode(status))
    return 0


sys.exit(main())
