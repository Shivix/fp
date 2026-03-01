import os
import pty
import select
import subprocess
import time
import re
import fcntl
import struct
import termios
import unicodedata
import sys

# Control Characters
CR = b"\x0d"
LF = b"\x0a"
ESC = b"\x1b"
BS = "\x7f"
CTRL_A = b"\x01"
CTRL_C = b"\x03"
CTRL_D = b"\x04"
CTRL_E = b"\x05"
CTRL_U = b"\x15"
CTRL_W = b"\x17"

# Escape Sequences
UP = ESC + b"[A"
DOWN = ESC + b"[B"
RIGHT = ESC + b"[C"
LEFT = ESC + b"[D"
UP_SS3 = ESC + b"OA"
DOWN_SS3 = ESC + b"OB"


def get_char_width(char):
    if unicodedata.east_asian_width(char) in ("F", "W"):
        return 2
    return 1


class VirtualTerminal:
    def __init__(self, rows=24, cols=80):
        self.rows = rows
        self.cols = cols
        self.screen = [[" " for _ in range(cols)] for _ in range(rows)]
        self.cursor_x = 0
        self.cursor_y = 0

    def feed(self, data):
        i = 0
        while i < len(data):
            if data[i : i + 1] == ESC:
                # CSI
                match = re.match(rb"^\x1b\[([0-9;?]*)([A-GJKmHhln~])", data[i:])
                if match:
                    params = match.group(1).decode().split(";")
                    cmd = match.group(2).decode()
                    self._handle_escape(cmd, params)
                    i += len(match.group(0))
                    continue
                # SS3
                match = re.match(rb"^\x1bO([A-D])", data[i:])
                if match:
                    self._handle_escape(match.group(1).decode(), [])
                    i += len(match.group(0))
                    continue

            char_byte = data[i]
            if char_byte == ord(CR):
                self.cursor_x = 0
                i += 1
            elif char_byte == ord(LF):
                self.cursor_y += 1
                if self.cursor_y >= self.rows:
                    self.cursor_y = self.rows - 1
                    self.screen.pop(0)
                    self.screen.append([" " for _ in range(self.cols)])
                i += 1
            elif char_byte == ord(b"\b"):
                self.cursor_x = max(0, self.cursor_x - 1)
                i += 1
            elif char_byte < 32:
                i += 1
            else:
                for length in range(1, 5):
                    if i + length > len(data):
                        break
                    try:
                        char_str = data[i : i + length].decode("utf-8")
                        width = get_char_width(char_str)
                        if self.cursor_y < self.rows and self.cursor_x < self.cols:
                            self.screen[self.cursor_y][self.cursor_x] = char_str
                            if width == 2 and self.cursor_x + 1 < self.cols:
                                self.screen[self.cursor_y][self.cursor_x + 1] = ""
                            self.cursor_x += width
                        i += length
                        break
                    except UnicodeDecodeError:
                        if length == 4:
                            i += 1
                else:
                    i += 1

    def _handle_escape(self, cmd, params):
        p1 = int(params[0]) if params and params[0] and params[0].isdigit() else 1
        if cmd == "A":
            self.cursor_y = max(0, self.cursor_y - p1)
        elif cmd == "B":
            self.cursor_y = min(self.rows - 1, self.cursor_y + p1)
        elif cmd == "C":
            self.cursor_x = min(self.cols - 1, self.cursor_x + p1)
        elif cmd == "D":
            self.cursor_x = max(0, self.cursor_x - p1)
        elif cmd == "G":
            self.cursor_x = p1 - 1
        elif cmd == "K":
            for x in range(self.cursor_x, self.cols):
                self.screen[self.cursor_y][x] = " "
        elif cmd == "H":
            self.cursor_y = (
                (int(params[0]) - 1)
                if len(params) > 0 and params[0] and params[0].isdigit()
                else 0
            )
            self.cursor_x = (
                (int(params[1]) - 1)
                if len(params) > 1 and params[1] and params[1].isdigit()
                else 0
            )

    def __str__(self):
        lines = ["".join(c for c in row if c != "").rstrip() for row in self.screen]
        while lines and not lines[-1]:
            lines.pop()
        return "\n".join(lines)


class FpProcess:
    def __init__(self, input_data=None, before=None, args=None, cmd_override=None):
        self.master, slave = pty.openpty()
        slave_name = os.ttyname(slave)
        buf = struct.pack("HHHH", 24, 80, 0, 0)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, buf)

        self.vt = VirtualTerminal()

        if cmd_override:
            full_cmd = cmd_override.replace("fp", f"./zig-out/bin/fp -t {slave_name}")
        else:
            fp_cmd = f"./zig-out/bin/fp -t {slave_name} " + " ".join(args or [])
            input_str = "\\n".join(input_data or [])
            full_cmd = f"printf '{input_str}' | {fp_cmd}"
            if before:
                full_cmd = f"echo '{before}'; {full_cmd}"

        self.proc = subprocess.Popen(
            ["bash", "-c", full_cmd], stdout=slave, stderr=slave, start_new_session=True
        )
        os.close(slave)

    def read(self, timeout=0.2):
        deadline = time.time() + timeout
        while time.time() < deadline:
            r, _, _ = select.select([self.master], [], [], 0.02)
            if r:
                try:
                    data = os.read(self.master, 4096)
                    if not data:
                        break
                    self.vt.feed(data)
                except OSError:
                    break
            elif self.proc.poll() is not None:
                break

    def send(self, data):
        os.write(self.master, data if isinstance(data, bytes) else data.encode())
        self.read(0.05)

    def assert_cursor(self, y, x):
        if self.vt.cursor_y != y or self.vt.cursor_x != x:
            raise AssertionError(
                f"Cursor mismatch: expected ({y}, {x}), got ({self.vt.cursor_y}, {self.vt.cursor_x})"
            )

    def assert_matches(self, expected):
        if expected.strip() not in str(self.vt).strip():
            raise AssertionError(
                f"Match failure.\nEXPECTED:\n{expected}\n\nACTUAL:\n{self.vt}"
            )


def run_test(name, func):
    print(f"Running {name}...", end=" ", flush=True)
    try:
        func()
        print("PASS")
    except Exception as e:
        print("FAIL")
        print(f"Error: {e}")
        # import traceback; traceback.print_exc()
        sys.exit(1)


def test_exit_keys():
    fp = FpProcess(input_data=["foo"])
    fp.read()
    fp.send(CTRL_C)
    fp.proc.wait()
    assert fp.proc.returncode != 0
    fp = FpProcess(input_data=["foo"])
    fp.read()
    fp.send(CTRL_D)
    fp.proc.wait()
    assert fp.proc.returncode != 0


def test_flags():
    # Lines
    fp = FpProcess(input_data=[str(i) for i in range(1, 11)], args=["-l", "5"])
    fp.read()
    fp.assert_matches(">\n1\n2\n3\n4\n5")
    assert "6" not in str(fp.vt)
    fp.send(CTRL_C)

    # Prompt
    fp = FpProcess(args=["-p", "C:\\"])
    fp.read()
    fp.send("foo")
    fp.assert_matches("C:\\foo")
    fp.send(CTRL_C)

    # Scores
    fp = FpProcess(input_data=["foo"], args=["-s"])
    fp.read()
    fp.send("f")
    fp.assert_matches("0.890 | foo")
    fp.send(CTRL_C)


def test_slow_stdin():
    cmd = "(sleep 0.5; echo aa; echo bc; echo bd) | fp"
    fp = FpProcess(cmd_override=cmd)
    time.sleep(0.1)
    fp.send("b\r")
    fp.proc.wait()
    fp.read()
    fp.assert_matches("bc")


def test_bracketed_paste():
    fp = FpProcess(input_data=["foo", "bar"])
    fp.read()
    fp.send(ESC + b"[200~foo" + ESC + b"[201~")
    fp.assert_matches("> foo\nfoo")
    fp.send(CTRL_C)


def test_help():
    fp = FpProcess(cmd_override="fp --help")
    fp.read()
    fp.assert_matches("Usage: fp")
    fp.assert_matches("-l, --lines")


def test_empty_list():
    fp = FpProcess(input_data=[], before="placeholder")
    fp.read()
    fp.assert_cursor(1, 2)
    fp.assert_matches("placeholder\n>")

    fp.send("t")
    fp.assert_cursor(1, 3)
    fp.assert_matches("placeholder\n> t")

    fp.send("z")
    fp.assert_cursor(1, 4)
    fp.assert_matches("placeholder\n> tz")

    fp.send("\r")
    fp.assert_cursor(1, 0)
    fp.assert_matches("placeholder\n")


def test_one_item():
    fp = FpProcess(input_data=["test"])
    fp.read()
    fp.assert_matches(">\ntest")
    fp.assert_cursor(0, 2)

    fp.send("t")
    fp.assert_cursor(0, 3)
    fp.assert_matches("> t\ntest")

    fp.send("z")
    fp.assert_cursor(0, 4)
    fp.assert_matches("> tz")

    fp.send("\r")
    fp.assert_cursor(0, 0)
    fp.assert_matches("")


def test_two_items():
    fp = FpProcess(input_data=["test", "foo"], before="placeholder")
    fp.read()
    fp.assert_cursor(1, 2)
    fp.assert_matches("placeholder\n>\ntest\nfoo")

    fp.send("t")
    fp.assert_cursor(1, 3)
    fp.assert_matches("placeholder\n> t\ntest")

    fp.send("z")
    fp.assert_cursor(1, 4)
    fp.assert_matches("placeholder\n> tz")

    fp.send("\r")
    fp.assert_matches("placeholder\n")
    fp.assert_cursor(1, 0)


def test_multi():
    fp = FpProcess(input_data=["test", "foo", "bar"])
    fp.send("\t")
    fp.send("\t")
    fp.assert_matches(">\n* test\n* foo\nbar")


def test_editing():
    fp = FpProcess(input_data=["test", "foo"], before="placeholder")
    fp.read()
    fp.assert_cursor(1, 2)
    fp.assert_matches("placeholder\n>\ntest\nfoo")

    fp.send("foo bar baz")
    fp.assert_cursor(1, 13)
    fp.assert_matches("placeholder\n> foo bar baz")

    fp.send("\x7f")
    fp.assert_cursor(1, 12)
    fp.assert_matches("placeholder\n> foo bar ba")

    fp.send(CTRL_W)
    fp.assert_cursor(1, 10)
    fp.assert_matches("placeholder\n> foo bar")

    fp.send(CTRL_U)
    fp.assert_cursor(1, 2)
    fp.assert_matches("placeholder\n>\ntest\nfoo")


def test_ctrl_d():
    fp = FpProcess(input_data=["foo", "bar"])
    fp.read()
    fp.assert_matches(">\nfoo\nbar")

    fp.send("foo")
    fp.assert_matches("> foo\nfoo")

    fp.send(CTRL_D)
    fp.assert_matches("")
    fp.assert_cursor(0, 0)


def test_ctrl_c():
    fp = FpProcess(input_data=["foo", "bar"])
    fp.read()
    fp.assert_matches(">\nfoo\nbar")

    fp.send("foo")
    fp.assert_matches("> foo\nfoo")

    fp.send(CTRL_C)
    fp.assert_matches("")
    fp.assert_cursor(0, 0)


def test_down_arrow():
    fp = FpProcess(input_data=["foo", "bar"])
    fp.read()
    fp.assert_matches(">\nfoo\nbar")
    fp.send(UP + CR)
    fp.assert_matches("bar")

    fp = FpProcess(input_data=["foo", "bar"])
    fp.read()
    fp.assert_matches(">\nfoo\nbar")
    fp.send(UP_SS3 + CR)
    fp.assert_matches("bar")


def test_up_arrow():
    fp = FpProcess(input_data=["foo", "bar"])
    fp.read()
    fp.assert_matches(">\nfoo\nbar")
    fp.send(UP)
    fp.send(DOWN + CR)
    fp.assert_matches("foo")

    fp = FpProcess(input_data=["foo", "bar"])
    fp.read()
    fp.assert_matches(">\nfoo\nbar")
    fp.send(UP_SS3)
    fp.send(DOWN + CR)
    fp.assert_matches("foo")


def test_lines():
    input10 = [str(i) for i in range(1, 11)]
    input20 = [str(i) for i in range(1, 21)]

    fp = FpProcess(input_data=input10)
    fp.read()
    fp.assert_matches(">\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10")

    fp = FpProcess(input_data=input20)
    fp.read()
    fp.assert_matches(">\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10")

    fp = FpProcess(input_data=input10, args=["-l", "5"])
    fp.read()
    fp.assert_matches(">\n1\n2\n3\n4\n5")

    fp = FpProcess(input_data=input10, args=["--lines=5"])
    fp.read()
    fp.assert_matches(">\n1\n2\n3\n4\n5")


def test_prompt():
    fp = FpProcess()
    fp.send("foo")
    fp.assert_matches("> foo")

    fp = FpProcess(args=["-p", "C:\\"])
    fp.read()
    fp.send("foo")
    fp.assert_matches("C:\\foo")

    fp = FpProcess(args=['--prompt="foo bar "'])
    fp.read()
    fp.send("baz")
    fp.assert_matches("foo bar baz")


def test_show_scores():
    fp = FpProcess(input_data=["foo", "bar"], args=["-s"])
    fp.read()
    fp.send("foo")
    fp.assert_matches("> foo\ninf | foo")

    fp = FpProcess(input_data=["foo", "bar"], args=["--show-scores"])
    fp.read()
    fp.send("foo")
    fp.assert_matches("> foo\ninf | foo")

    fp = FpProcess(input_data=["foo", "bar"], args=["-s"])
    fp.read()
    fp.send("f")
    fp.assert_matches("> f\n0.890 | foo")


def test_initial_query():
    fp = FpProcess(input_data=["foo", "bar"], args=["-q", "fo"])
    fp.read()
    fp.assert_matches("> fo\nfoo")
    fp.send("o")
    fp.assert_matches("> foo\nfoo")
    fp.send("o")
    fp.assert_matches("> fooo")

    fp = FpProcess(input_data=["foo", "bar"], args=["-q", "asdf"])
    fp.read()
    fp.assert_matches("> asdf")


def test_moving_text_cursor():
    fp = FpProcess(input_data=["foo", "bar"])
    fp.read()
    fp.send("br")
    fp.assert_matches("> br\nbar")
    fp.assert_cursor(0, 4)

    fp.send(LEFT)
    fp.assert_cursor(0, 3)
    fp.assert_matches("> br\nbar")
    fp.send("a")
    fp.assert_cursor(0, 4)
    fp.assert_matches("> bar\nbar")

    fp.send("\x1b[1~")
    fp.assert_cursor(0, 2)
    fp.assert_matches("> bar\nbar")
    fp.send("foo")
    fp.assert_cursor(0, 5)
    fp.assert_matches("> foobar")

    fp.send("\x1b[4~")
    fp.assert_cursor(0, 8)
    fp.assert_matches("> foobar")
    fp.send("baz")
    fp.assert_cursor(0, 11)
    fp.assert_matches("> foobarbaz")


# More info;
# https://github.com/jhawthorn/fp/issues/42
# https://cirw.in/blog/bracketed-paste
def test_bracketed_paste_characters():
    fp = FpProcess(input_data=["foo", "bar"])
    fp.read()
    fp.assert_matches(">\nfoo\nbar")
    fp.send(ESC + b"[200~foo" + ESC + b"[201~")
    fp.assert_matches("> foo\nfoo")


def test_unicode():
    fp = FpProcess(input_data=["English", "Français", "日本語"])
    fp.read()
    fp.assert_matches(">\nEnglish\nFrançais\n日本語")
    fp.assert_cursor(0, 2)

    fp.send("ç")
    fp.assert_matches("> ç\nFrançais")
    fp.assert_cursor(0, 3)

    fp.send("\r")
    fp.assert_matches("Français")


def test_unicode_backspace():
    fp = FpProcess()
    fp.send("Français")
    fp.assert_matches("> Français")
    fp.assert_cursor(0, 10)

    fp.send(BS)
    fp.send(BS)
    fp.send(BS)
    fp.assert_matches("> Franç")
    fp.assert_cursor(0, 7)

    fp.send(BS)
    fp.assert_matches("> Fran")
    fp.assert_cursor(0, 6)

    fp.send("ce")
    fp.assert_matches("> France")

    fp = FpProcess()
    fp.send("日本語")
    fp.assert_matches("> 日本語")
    fp.send(BS)
    fp.assert_matches("> 日本")
    fp.send(BS)
    fp.assert_matches("> 日")
    fp.send(BS)
    fp.assert_matches("> ")
    fp.assert_cursor(0, 2)


def test_unicode_delete_word():
    fp = FpProcess()
    fp.send("Je parle Français")
    fp.assert_matches("> Je parle Français")
    fp.assert_cursor(0, 19)

    fp.send(CTRL_W)
    fp.assert_matches("> Je parle")
    fp.assert_cursor(0, 11)


def test_unicode_cursor_movement():
    fp = FpProcess()
    fp.send("Français")
    fp.assert_cursor(0, 10)

    fp.send(LEFT * 5)
    fp.assert_cursor(0, 5)

    fp.send(RIGHT * 3)
    fp.assert_cursor(0, 8)

    fp = FpProcess()
    fp.send("日本語")
    fp.read(timeout = 0.5)
    fp.assert_matches("> 日本語")
    fp.assert_cursor(0, 8)
    fp.send(LEFT)
    fp.assert_cursor(0, 6)
    fp.send(LEFT)
    fp.assert_cursor(0, 4)
    fp.send(LEFT)
    fp.assert_cursor(0, 2)
    fp.send(LEFT)
    fp.assert_cursor(0, 2)
    fp.send(RIGHT * 3)
    fp.assert_cursor(0, 8)
    fp.send(RIGHT)
    fp.assert_cursor(0, 8)


def test_long_strings():
    ascii = "LongStringOfText" * 6
    unicode = "ＬｏｎｇＳｔｒｉｎｇＯｆＴｅｘｔ" * 3

    fp = FpProcess(input_data=[ascii, unicode])
    fp.read()
    fp.assert_matches(
        ">\nLongStringOfTextLongStringOfTextLongStringOfTextLongStringOfTextLongStringOfText\nＬｏｎｇＳｔｒｉｎｇＯｆＴｅｘｔＬｏｎｇＳｔｒｉｎｇＯｆＴｅｘｔＬｏｎｇＳｔｒｉ"
    )


def test_show_info():
    fp = FpProcess(input_data=["foo", "bar", "baz"], args=["-i"])
    fp.read()
    fp.assert_matches(">\n[3/3]\nfoo\nbar\nbaz")
    fp.send("ba")
    fp.assert_matches("> ba\n[2/3]\nbar\nbaz")
    fp.send("q")
    fp.assert_matches("> baq\n[0/3]")


if __name__ == "__main__":
    tests = [
        ("Exit Keys", test_exit_keys),
        ("Flags", test_flags),
        ("Slow STDIN", test_slow_stdin),
        ("Bracketed Paste", test_bracketed_paste),
        ("Help", test_help),
        ("Empty List", test_empty_list),
        ("One Item", test_one_item),
        ("Two Items", test_two_items),
        ("Multi", test_multi),
        ("Editing", test_editing),
        ("Ctrl-D", test_ctrl_d),
        ("Ctrl-C", test_ctrl_c),
        ("Down Arrow", test_down_arrow),
        ("Up Arrow", test_up_arrow),
        ("Lines", test_lines),
        ("Prompt", test_prompt),
        ("Show Scores", test_show_scores),
        ("Initial Query", test_initial_query),
        ("Moving Text Cursor", test_moving_text_cursor),
        ("Bracketed Paste Characters", test_bracketed_paste_characters),
        ("Long Strings", test_long_strings),
        ("Show Info", test_show_info),
        ("Unicode", test_unicode),
        ("Unicode Backspace", test_unicode_backspace),
        ("Unicode Delete Word", test_unicode_delete_word),
        ("Unicode Cursor Movement", test_unicode_cursor_movement),
    ]
    for name, func in tests:
        run_test(name, func)
