# claude-p

> **Use at your own risk.** This package and repository exist for
> **educational purposes** and demonstrates why client-side restrictions
> on how a product is used are fundamentally unenforceable.

A drop-in replacement for `claude -p` that drives the interactive
`claude` UI inside an in-process [zmux][zmux] PTY session.

[zmux]: https://github.com/smithersai/zmux

## Use

```bash
npx claude-p "your prompt here"
```

Output on stdout matches `claude -p` byte-for-byte.

```bash
npx claude-p --output-format json "summarize this commit" < commit.diff
npx claude-p --output-format stream-json "audit src/" --verbose | jq .
npx claude-p --model opus "explain quicksort to a 10-year-old"
```

## How it works

1. Spawns `claude` interactively inside a [zmux][zmux] `NativeSession`
   (a real PTY with a reader thread and bounded scrollback).
2. A small ANSI scanner answers the DA1 / DA2 / DSR / XTVERSION /
   window-size queries Ink (the React-for-terminals runtime Claude
   Code uses) issues at startup. Without these, the TUI hangs.
3. Registers two hooks via `--settings '<inline-json>'` — never
   touches your `~/.claude/` config:
   - **`SessionStart`** — the wrapper types the prompt + Enter.
   - **`Stop`** — fires when the model finishes; payload carries
     `transcript_path`.
4. Reads the transcript JSONL, extracts the final assistant message
   plus usage, and prints in the requested format.

## Flags

```
--output-format <text|json|stream-json>   default: text
--model <name>
--max-turns <N>
--allowedTools <list>
--dangerously-skip-permissions
--resume <id> | --continue | --session-id <uuid>
--cwd <path>
--input-file <path>
--verbose
--timeout <seconds>                       default: 300
--debug
```

Unrecognized flags are forwarded verbatim to `claude`.

## Exit codes

| Code  | Meaning                                                               |
| ----- | --------------------------------------------------------------------- |
| `0`   | Success.                                                              |
| `1`   | Assistant returned an error (`is_error: true`) or transcript missing. |
| `2`   | Wrapper internal error (PTY failure, spawn failed, etc.).             |
| `124` | Timed out or `--max-turns` exceeded.                                  |
| `130` | Interrupted (SIGINT).                                                 |

## Caveats

- **macOS / Linux only.** No Windows (no `forkpty`).
- **Requires `claude` on `$PATH`.** The wrapper invokes the real CLI.
- **Not true streaming.** Tokens are not streamed live — `claude-p`
  waits for the model's turn to finish and then prints. For real-time
  streaming, use `claude -p --output-format stream-json` directly.
- **Adds ~50–200 ms** over `claude -p` due to PTY + Ink startup
  overhead.
- **Multiline prompts** must come via `--input-file` or stdin to keep
  shell escaping sane.
- **API instability.** `claude` is not designed to be driven this way.
  A future Claude Code release that changes the hook payload schema or
  adds a new terminal probe at startup can break us; the wrapper will
  surface the failure rather than hide it.

## From source

```bash
git clone https://github.com/smithersai/claude-p
cd claude-p
zig build -Doptimize=ReleaseSafe
```

Requires Zig **0.15.2**. Dependencies are fetched by `zig build`.

## As a Zig library

```sh
zig fetch --save=claude_p git+https://github.com/smithersai/claude-p
```

```zig
const std = @import("std");
const claude_p = @import("claude_p");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var result = try claude_p.run(alloc, .{
        .prompt = "what is the capital of France?",
        .output_format = .text,
        .skip_permissions = true,
    });
    defer result.deinit(alloc);

    std.debug.print("{s}\n", .{result.summary.final_text});
}
```

The `Options` struct mirrors the CLI flags 1:1. See `src/root.zig` and
[`SPEC.md`](./SPEC.md) for the full API.

## License

MIT.
