#!/usr/bin/env python3
"""Exercise the compiled shell through its public CLI, with real native builds."""

import os
from pathlib import Path
import subprocess
import tempfile


repo = Path(__file__).resolve().parent.parent
compiler = str(Path(os.environ.get("IYI", repo / "bin" / "iyi")).resolve())
banner = "Each input reruns the whole session and :reset starts fresh."


def run(cwd, source, *flags, success=True):
    result = subprocess.run(
        [compiler, "shell", *flags], input=source, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=cwd, timeout=90,
    )
    if success:
        assert result.returncode == 0, result.stderr
        assert result.stdout.splitlines()[0] == banner, result.stdout
        return result.stdout.splitlines()[1:], result.stderr
    assert result.returncode != 0, result.stdout
    assert "Unhandled exception" not in result.stderr, result.stderr
    return result.stdout, result.stderr


with tempfile.TemporaryDirectory(prefix="iyi-shell-test-") as scratch:
    root = Path(scratch)
    (root / "iyi.mod").write_text("module demo\n")
    (root / "maths.iyi").write_text(
        "module maths\npub def twice(value : Int32) : Int32\n  value * 2\nend\n"
    )
    original = set(root.iterdir())

    output, errors = run(root, "x = 39\nx + 3\n:state\n:quit\n")
    assert output == ["42", "session: 2 input block(s)"], (output, errors)
    assert not errors, errors

    for command in ("exit", ":q", ":quit"):
        output, errors = run(root, command + '\nputs "must not run"\n')
        assert not output and not errors, (command, output, errors)
    output, errors = run(root, 'exit(0)\n:state\nexit\n')
    assert output == ["session: 1 input block(s)"] and not errors, (output, errors)
    output, errors = run(root, 'puts "exit"\nexit\n')
    assert output == ["exit"] and not errors, (output, errors)

    output, errors = run(root, "(21 + 21)\nbegin\n  40 + 2\nend\n")
    assert output == ["42", "42"], (output, errors)
    assert not errors, errors

    output, errors = run(root, "42.is_a?(Int32)\n42.as(Int32)\nnil.nil?\n")
    assert output == ["true", "42", "true"], (output, errors)
    assert not errors, errors

    # A declaration stays at module scope; only the latest expression prints.
    output, errors = run(root, "def twice(x : Int32) : Int32\n  x * 2\nend\ntwice(21)\n")
    assert output == ["42"], (output, errors)
    assert not errors, errors

    output, errors = run(root, "def recovered : Int32 | Panicked\n  42\nend\nrecovered.or_panic\n")
    assert output == ["42"], (output, errors)
    assert not errors, errors

    output, errors = run(root, 'import maths::{twice}\ntwice(21)\n')
    assert output == ["42"], (output, errors)
    assert not errors, errors

    # Quoted delimiters/comments are not mistaken for multiline structure.
    output, errors = run(root, '"end # ["\n[1,\n2].size\n"ü".size\n')
    assert output == ["end # [", "2", "1"], (output, errors)
    assert not errors, errors

    # Errors drop only the candidate input; accepted variables still resolve.
    output, errors = run(root, "x = 41\nmissing_name\nx + 1\n:state\n")
    assert output == ["42", "session: 2 input block(s)"], (output, errors)
    assert "missing_name" in errors, errors
    output, errors = run(root, "x = 41\n)\nx + 1\n")
    assert output == ["42"], (output, errors)
    assert "unexpected token" in errors, errors
    output, errors = run(root, 'x = 41\nassert false\nx + 1\n')
    assert output == ["42"], (output, errors)
    assert "input was not retained" in errors, errors

    # Reset clears bindings/history; an incomplete input has its own reset.
    output, errors = run(root, "x = 41\n:reset\n:state\nx\n1 + 1\n")
    assert output == ["session: 0 input block(s)", "2"], (output, errors)
    assert "undefined" in errors, errors
    output, errors = run(root, "x = 41\nif true\n:reset\nx + 1\n")
    assert output == ["42"], (output, errors)
    assert not errors, errors
    output, errors = run(root, "if true\n")
    assert not output, output
    assert "incomplete input discarded at EOF" in errors, errors

    # Demonstrate replay explicitly, including file-writing side effects.
    output, errors = run(root, 'File.write("effects.txt", File.exists?("effects.txt") ? File.read("effects.txt") + "x" : "x")\n1\n')
    assert output == ["1"], (output, errors)
    assert (root / "effects.txt").read_text() == "xx"
    (root / "effects.txt").unlink()

    preload = root / "prepare.iyi"
    preload.write_text("module prepare\nimport maths::{twice}\nx = 21\n")
    output, errors = run(root, "twice(x)\n:reset\ntwice(x)\n", "--preload", str(preload))
    assert output == ["42", "42"], (output, errors)
    assert not errors, errors
    preload.unlink()

    # Setup may live outside the project; imports still resolve from cwd.
    with tempfile.TemporaryDirectory(prefix="iyi-shell-preload-") as other:
        preload = Path(other) / "prepare.iyi"
        preload.write_text("module prepare\nimport maths::{twice}\nx = 21\n")
        output, errors = run(root, "twice(x)\n", "--preload", str(preload))
        assert output == ["42"], (output, errors)
        assert not errors, errors

    output, errors = run(root, "1 + 1\nputs 42\n", "--no-print")
    assert output == ["42"], (output, errors)
    assert not errors, errors

    # Candidate code cannot eat later commands from shell stdin.
    output, errors = run(root, "puts stdin.read_all.size\n42\n")
    assert output == ["0", "0", "42"], (output, errors)
    assert not errors, errors
    assert set(root.iterdir()) == original, set(root.iterdir())

    for args in [("--unknown",), ("--preload",), ("--preload", "missing.iyi"), ("extra",)]:
        run(root, "", *args, success=False)

    help_result = subprocess.run(
        [compiler, "help", "shell"], text=True, capture_output=True, timeout=15,
    )
    assert help_result.returncode == 0, help_result.stderr
    assert "Usage:" in help_result.stdout and ":reset" in help_result.stdout
    assert help_result.stdout.count("Usage:") == 1, help_result.stdout

    # Exercise the actual terminal-only greeting and numbered prompts.
    if os.name == "posix":
        import pty
        import select
        import time

        master, slave = pty.openpty()
        terminal_env = dict(os.environ, TERM="xterm-256color")
        terminal_env.pop("NO_COLOR", None)
        process = subprocess.Popen(
            [compiler, "shell"], cwd=root, stdin=slave, stdout=slave, stderr=slave,
            env=terminal_env,
        )
        os.close(slave)
        pending = bytearray()

        def until(needle):
            deadline = time.monotonic() + 30
            needle = needle.encode()
            while needle not in pending:
                remaining = deadline - time.monotonic()
                assert remaining > 0, bytes(pending)
                ready, _, _ = select.select([master], [], [], remaining)
                assert ready, bytes(pending)
                pending.extend(os.read(master, 65536))
            end = pending.index(needle) + len(needle)
            result = bytes(pending[:end]).decode()
            del pending[:end]
            return result

        try:
            greeting = until("iyi(main):001> ")
            assert "\x1b[34m" in greeting and "\x1b[39m" in greeting, greeting
            assert greeting.count("+-----+") == 2 and "| iyi |" in greeting, greeting
            assert "iyi shell v" in greeting, greeting
            assert '":help" for commands, ":q" or "exit" to quit' in greeting, greeting
            assert str(root) in greeting, greeting
            assert banner in greeting, greeting
            os.write(master, b"x = 41\n")
            until("iyi(main):002> ")
            os.write(master, b")\n")
            assert "unexpected token" in until("iyi(main):003> ")
            os.write(master, b"if true\n")
            until("iyi(main):004* ")
            os.write(master, b"x + 1\n")
            until("iyi(main):005* ")
            os.write(master, b"end\n")
            assert "42" in until("iyi(main):006> ")
            os.write(master, b":reset\n")
            until("iyi(main):001> ")
            os.write(master, b":q\n")
            assert process.wait(timeout=10) == 0
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
            os.close(master)

print("Compiled shell: native results, replay, reset, multiline input, errors, imports, preload and terminal UI OK")
