//! End-to-end driver: spawn `claude` under a zmux NativeSession, drive the UI
//! with our prompt, wait for the Stop hook, and return a Result.
const std = @import("std");
const zmux = @import("zmux");

const args_mod = @import("args.zig");
const transcript_mod = @import("transcript.zig");
const emit_mod = @import("emit.zig");
const hook_mod = @import("hook.zig");
const terminal_mod = @import("terminal.zig");

pub const Options = struct {
    prompt: []const u8,
    output_format: args_mod.OutputFormat = .text,
    model: ?[]const u8 = null,
    max_turns: ?u32 = null,
    allowed_tools: ?[]const u8 = null,
    skip_permissions: bool = false,
    resume_session: ?[]const u8 = null,
    cont: bool = false,
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    verbose: bool = false,
    timeout_ms: u64 = 300_000,
    /// Override `claude` binary path (testing).
    claude_path: ?[]const u8 = null,
    cols: u16 = 120,
    rows: u16 = 40,
    debug: bool = false,
};

pub const Result = struct {
    summary: transcript_mod.Summary,
    duration_ms: u64,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        self.summary.deinit(allocator);
    }

    pub fn write(
        self: *const Result,
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        fmt: args_mod.OutputFormat,
    ) !void {
        try emit_mod.emit(allocator, writer, fmt, .{
            .summary = &self.summary,
            .duration_ms = self.duration_ms,
        });
    }

    pub fn exitCode(self: *const Result) u8 {
        return if (self.summary.is_error) 1 else 0;
    }
};

pub const RunError = error{
    SessionStartTimeout,
    StopTimeout,
    TranscriptUnavailable,
    SpawnFailed,
    NoPromptSupplied,
} || std.mem.Allocator.Error;

/// Build the argv for the child `claude` invocation.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    binary: []const u8,
    settings_json: []const u8,
    opts: Options,
) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .{};
    errdefer argv.deinit(allocator);

    try argv.append(allocator, binary);
    try argv.append(allocator, "--settings");
    try argv.append(allocator, settings_json);
    if (opts.model) |m| {
        try argv.append(allocator, "--model");
        try argv.append(allocator, m);
    }
    if (opts.max_turns) |n| {
        try argv.append(allocator, "--max-turns");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{n}));
    }
    if (opts.allowed_tools) |t| {
        try argv.append(allocator, "--allowedTools");
        try argv.append(allocator, t);
    }
    if (opts.skip_permissions) {
        try argv.append(allocator, "--dangerously-skip-permissions");
    }
    if (opts.resume_session) |id| {
        try argv.append(allocator, "--resume");
        try argv.append(allocator, id);
    }
    if (opts.cont) try argv.append(allocator, "--continue");
    if (opts.session_id) |id| {
        try argv.append(allocator, "--session-id");
        try argv.append(allocator, id);
    }
    if (opts.verbose) try argv.append(allocator, "--verbose");
    for (opts.extra_args) |a| try argv.append(allocator, a);
    return argv;
}

/// Join argv into a single shell-safe command line (single-quoting each arg).
pub fn shellQuoteArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    for (argv, 0..) |a, idx| {
        if (idx > 0) try buf.append(allocator, ' ');
        try shellQuoteOne(allocator, &buf, a);
    }
    return try buf.toOwnedSlice(allocator);
}

fn shellQuoteOne(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
}

// Thread-shared state between the NativeSession reader thread and the
// driver's main loop.
const SharedState = struct {
    session: *zmux.NativeSession,
    debug: bool,
    // Bytes the DEC responder wants written back to the PTY. Mutex-guarded.
    write_mutex: std.Thread.Mutex = .{},
    pending_to_pty: std.ArrayList(u8) = .{},
    bytes_seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn onZmuxEvent(ctx: *anyopaque, event: zmux.native.Event) void {
    const shared: *SharedState = @ptrCast(@alignCast(ctx));
    switch (event) {
        .pane_output => |po| {
            _ = shared.bytes_seen.fetchAdd(po.data.len, .seq_cst);
            // Run the DEC-query responder; queue responses for the main loop.
            var resp: std.ArrayList(u8) = .{};
            defer resp.deinit(std.heap.page_allocator);
            terminal_mod.respondToDecQueries(std.heap.page_allocator, po.data, &resp) catch {};
            if (resp.items.len > 0) {
                shared.write_mutex.lock();
                shared.pending_to_pty.appendSlice(std.heap.page_allocator, resp.items) catch {};
                shared.write_mutex.unlock();
            }
            if (shared.debug) std.debug.print("zmux pane_output: {d} bytes\n", .{po.data.len});
        },
        .session_exited => |se| {
            shared.exited.store(true, .seq_cst);
            if (shared.debug) std.debug.print("zmux session_exited: code={?d} signal={?d}\n", .{ se.exit_code, se.signal });
        },
        .pane_activity, .pane_bell, .foreground_changed => {},
    }
}

pub fn run(allocator: std.mem.Allocator, opts: Options) !Result {
    if (opts.prompt.len == 0) return RunError.NoPromptSupplied;

    var harness = try hook_mod.create(allocator);
    defer harness.deinit();

    const claude_bin = opts.claude_path orelse "claude";

    var argv = try buildArgv(allocator, claude_bin, harness.settings_json, opts);
    defer {
        // Some entries (max-turns) are heap-allocated by buildArgv. We can't
        // tell which without tracking, so we just leak the small strings —
        // the process is short-lived. (TODO: refactor buildArgv to track
        // owned entries.)
        argv.deinit(allocator);
    }

    const shell_cmd = try shellQuoteArgv(allocator, argv.items);
    defer allocator.free(shell_cmd);

    // Compose env: forward the FIFO path; force TERM; include the existing
    // environment so PATH etc. is preserved.
    var env_list: std.ArrayList([]const u8) = .{};
    defer {
        for (env_list.items) |s| allocator.free(s);
        env_list.deinit(allocator);
    }
    // Inherit existing environment.
    var env_iter = try std.process.getEnvMap(allocator);
    defer env_iter.deinit();
    var it = env_iter.iterator();
    while (it.next()) |e| {
        try env_list.append(
            allocator,
            try std.fmt.allocPrint(allocator, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }),
        );
    }
    try env_list.append(
        allocator,
        try std.fmt.allocPrint(allocator, "CLAUDE_P_FIFO={s}", .{harness.fifo_path}),
    );
    try env_list.append(allocator, try allocator.dupe(u8, "TERM=xterm-256color"));

    // Open the FIFO for reading BEFORE spawning so the child's hook never
    // blocks trying to open the write side.
    const fifo_z = try allocator.dupeZ(u8, harness.fifo_path);
    defer allocator.free(fifo_z);
    const fifo_fd = std.posix.openZ(fifo_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch return RunError.SpawnFailed;
    defer std.posix.close(fifo_fd);

    var shared: SharedState = .{
        .session = undefined, // set after create
        .debug = opts.debug,
    };
    defer {
        shared.write_mutex.lock();
        shared.pending_to_pty.deinit(std.heap.page_allocator);
        shared.write_mutex.unlock();
    }

    const sink: zmux.native.EventSink = .{
        .context = @ptrCast(&shared),
        .emit = onZmuxEvent,
    };

    const session = zmux.NativeSession.create(allocator, .{
        .id = "claude-p",
        .shell = "/bin/sh",
        .command = shell_cmd,
        .cwd = opts.cwd,
        .env = env_list.items,
        .rows = opts.rows,
        .cols = opts.cols,
        .event_sink = sink,
    }) catch return RunError.SpawnFailed;
    shared.session = session;
    defer session.destroy();

    const start_ns: i128 = std.time.nanoTimestamp();
    var state: enum { waiting_for_ready, awaiting_stop } = .waiting_for_ready;

    var fifo_buf: std.ArrayList(u8) = .{};
    defer fifo_buf.deinit(allocator);
    var fifo_read_buf: [4096]u8 = undefined;

    var transcript_path: ?[]u8 = null;
    defer if (transcript_path) |p| allocator.free(p);
    var stop_payload_owned: ?[]u8 = null;
    defer if (stop_payload_owned) |p| allocator.free(p);

    while (true) {
        const now: i128 = std.time.nanoTimestamp();
        const elapsed_ms: u64 = @intCast(@divTrunc(now - start_ns, std.time.ns_per_ms));
        if (elapsed_ms > opts.timeout_ms) {
            if (state == .waiting_for_ready) return RunError.SessionStartTimeout;
            return RunError.StopTimeout;
        }
        if (shared.exited.load(.seq_cst) and state == .waiting_for_ready) {
            return RunError.SpawnFailed;
        }

        // Flush any DEC-responder bytes back to the PTY.
        shared.write_mutex.lock();
        const to_write = if (shared.pending_to_pty.items.len > 0)
            try allocator.dupe(u8, shared.pending_to_pty.items)
        else
            null;
        if (to_write != null) shared.pending_to_pty.clearRetainingCapacity();
        shared.write_mutex.unlock();
        if (to_write) |bytes| {
            session.writeInput(bytes) catch {};
            allocator.free(bytes);
        }

        // Drain the FIFO.
        const fifo_n = std.posix.read(fifo_fd, &fifo_read_buf) catch |e| switch (e) {
            error.WouldBlock => 0,
            else => 0,
        };
        if (fifo_n > 0) {
            try fifo_buf.appendSlice(allocator, fifo_read_buf[0..fifo_n]);
            while (true) {
                const nl = std.mem.indexOfScalar(u8, fifo_buf.items, '\n') orelse break;
                const line = fifo_buf.items[0..nl];
                if (hook_mod.parseLine(line)) |ev| {
                    if (opts.debug) std.debug.print("hook: {s} payload={s}\n", .{ @tagName(ev.event), ev.payload });
                    switch (ev.event) {
                        .session_start => {
                            if (state == .waiting_for_ready) {
                                session.send(opts.prompt, true) catch {};
                                state = .awaiting_stop;
                            }
                        },
                        .stop => {
                            transcript_path = try hook_mod.extractTranscriptPath(allocator, ev.payload);
                            stop_payload_owned = try allocator.dupe(u8, ev.payload);
                        },
                        .unknown => {},
                    }
                }
                std.mem.copyForwards(u8, fifo_buf.items, fifo_buf.items[nl + 1 ..]);
                fifo_buf.shrinkRetainingCapacity(fifo_buf.items.len - (nl + 1));
                if (transcript_path != null) break;
            }
        }

        if (transcript_path != null) break;

        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    const tp = transcript_path orelse return RunError.TranscriptUnavailable;

    // The Stop hook can fire a few milliseconds before claude flushes the
    // assistant message line into the transcript JSONL. Retry briefly, then
    // fall back to `last_assistant_message` from the Stop payload.
    var summary = blk: {
        var attempt: u32 = 0;
        while (attempt < 20) : (attempt += 1) {
            const s = transcript_mod.parseFile(allocator, tp) catch |e| switch (e) {
                error.NoAssistantMessage, error.FileNotFound => null,
                else => return e,
            };
            if (s) |valid| break :blk valid;
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
        if (stop_payload_owned) |payload| {
            const last = try hook_mod.extractLastAssistantMessage(allocator, payload);
            if (last) |text| {
                const sid = (try hook_mod.extractSessionId(allocator, payload)) orelse try allocator.dupe(u8, "");
                break :blk transcript_mod.Summary{
                    .final_text = text,
                    .session_id = sid,
                    .is_error = false,
                    .num_turns = 1,
                    .total_cost_usd = 0.0,
                    .duration_api_ms = 0,
                    .usage = .{},
                    .jsonl_replay = try allocator.dupe(u8, ""),
                };
            }
        }
        return RunError.TranscriptUnavailable;
    };
    errdefer summary.deinit(allocator);

    // Tear down the child immediately — we already have the answer.
    session.terminate();

    const total_ns: i128 = std.time.nanoTimestamp() - start_ns;
    return Result{
        .summary = summary,
        .duration_ms = @intCast(@divTrunc(total_ns, std.time.ns_per_ms)),
    };
}

// -------- tests --------

const testing = std.testing;

test "buildArgv: minimal" {
    var argv = try buildArgv(testing.allocator, "/bin/claude", "{}", .{
        .prompt = "hi",
    });
    defer argv.deinit(testing.allocator);
    try testing.expectEqualStrings("/bin/claude", argv.items[0]);
    try testing.expectEqualStrings("--settings", argv.items[1]);
    try testing.expectEqualStrings("{}", argv.items[2]);
}

test "buildArgv: with model + verbose" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "hi",
        .model = "opus",
        .verbose = true,
    });
    defer argv.deinit(testing.allocator);
    var saw_model = false;
    var saw_verbose = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--model")) saw_model = true;
        if (std.mem.eql(u8, a, "--verbose")) saw_verbose = true;
    }
    try testing.expect(saw_model);
    try testing.expect(saw_verbose);
}

test "buildArgv: dangerously-skip-permissions" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "x",
        .skip_permissions = true,
    });
    defer argv.deinit(testing.allocator);
    var saw = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--dangerously-skip-permissions")) saw = true;
    }
    try testing.expect(saw);
}

test "buildArgv: passthrough extra args" {
    var argv = try buildArgv(testing.allocator, "claude", "{}", .{
        .prompt = "x",
        .extra_args = &.{ "--include-hook-events", "--bare" },
    });
    defer argv.deinit(testing.allocator);
    var saw_hook = false;
    var saw_bare = false;
    for (argv.items) |a| {
        if (std.mem.eql(u8, a, "--include-hook-events")) saw_hook = true;
        if (std.mem.eql(u8, a, "--bare")) saw_bare = true;
    }
    try testing.expect(saw_hook);
    try testing.expect(saw_bare);
}

test "shellQuoteArgv: simple" {
    const q = try shellQuoteArgv(testing.allocator, &.{ "echo", "hi" });
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("'echo' 'hi'", q);
}

test "shellQuoteArgv: embeds single-quote" {
    const q = try shellQuoteArgv(testing.allocator, &.{"can't"});
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("'can'\\''t'", q);
}

test "shellQuoteArgv: json with double quotes survives" {
    const q = try shellQuoteArgv(testing.allocator, &.{ "claude", "--settings", "{\"hooks\":{}}" });
    defer testing.allocator.free(q);
    // Round-trip via sh -c
    try testing.expect(std.mem.indexOf(u8, q, "{\"hooks\":{}}") != null);
}

test "run: empty prompt rejected" {
    try testing.expectError(RunError.NoPromptSupplied, run(testing.allocator, .{ .prompt = "" }));
}
