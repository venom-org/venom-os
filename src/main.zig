//! venom-os: the bundle, and the agent contract's one binary.
//! The verb schema in `verbs.zon` plus venom-std's shared bundles (config,
//! events, grants, skill, doctor) generates the CLI, the MCP server
//! (`venom-os mcp`), the docs and the completions.
//!
//! * `venom-os serve`: the daemon (socket, verbs, supervisor status file).
//! * `venom-os up`: the same daemon in up mode; it also installs the curated
//!   venomx defaults and supervises a persistent `venomx serve` (daemon.zig,
//!   up.zig). It is a local command because it is the daemon, not a request
//!   to one.
//! * `venom-os defaults`: print or install the defaults file; local, no daemon.
//! * `venom-os login install|uninstall`, `venom-os env`: login/session
//!   integration (login.zig); local, no daemon, never runs systemctl.
const std = @import("std");
const cli = @import("cli");
const supervisor = @import("supervisor");
const daemon = @import("daemon.zig");
const up = @import("up.zig");
const login = @import("login.zig");

pub const App = daemon.App;

/// The local commands `up`, `defaults`, `login install|uninstall` and `env`:
/// they run in the CLI process, never as daemon verbs.
const Local = struct {
    pub const commands = .{ "up", "defaults", "login.install", "login.uninstall", "env" };
    daemon: *daemon.Daemon,
    /// From the parsed invocation: `defaults` prints raw bytes without it.
    json: bool,

    pub fn call(self: *Local, ctx: cli.Local.Context) anyerror!cli.Local.Outcome {
        if (std.mem.eql(u8, ctx.name, "defaults")) return self.defaults(ctx);
        if (std.mem.eql(u8, ctx.name, "login.install")) return self.loginInstall(ctx);
        if (std.mem.eql(u8, ctx.name, "login.uninstall")) return self.loginUninstall(ctx);
        if (std.mem.eql(u8, ctx.name, "env")) return self.env(ctx);
        const venomx = ctx.params.object.get("venomx").?.string;
        if (venomx.len == 0 or std.mem.indexOfScalar(u8, venomx, 0) != null) return failure("invalid_params.venomx", "--venomx must be a non-empty path");
        const plan = try up.Plan.resolve(ctx.allocator, ctx.path.environ orelse self.daemon.environ, venomx);
        self.daemon.run(ctx.path, .{ .plan = plan }) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (err == error.DefaultsUnavailable) return failure("unavailable.defaults", "the venomx defaults could not be installed");
            if (err == error.VenomxRunning) return failure("conflict.venomx_running", "a venomx that venom-os did not start already serves venomx's socket; stop it and run venom-os up again");
            const code = cli.runtime.transportCode(err);
            inline for (daemon.local[0].errors) |e| if (std.mem.eql(u8, code, e.code)) return failure(e.code, cli.runtime.transportMessage(err));
            return err;
        };
        return .{ .result = .{ .object = .empty } };
    }

    fn defaults(self: *Local, ctx: cli.Local.Context) !cli.Local.Outcome {
        var o: std.json.ObjectMap = .empty;
        if (ctx.params.object.get("dir")) |d| {
            if (!std.fs.path.isAbsolute(d.string)) return failure("invalid_params.dir", "--dir must be an absolute path");
            const path = up.installDefaults(ctx.allocator, self.daemon.io, d.string) catch |err| {
                if (err == error.OutOfMemory) return err;
                return .{ .failure = .{ .code = "unavailable.defaults", .message = "the venomx defaults could not be installed", .data = try reason(ctx.allocator, err) } };
            };
            if (!self.json) {
                try ctx.stdout.print("{s}\n", .{path});
                return .{ .status = 0 };
            }
            try o.put(ctx.allocator, "path", .{ .string = path });
        } else {
            // Raw, so `venom-os defaults > defaults.zon` works.
            if (!self.json) {
                try ctx.stdout.writeAll(up.venomx_defaults);
                return .{ .status = 0 };
            }
            try o.put(ctx.allocator, "content", .{ .string = up.venomx_defaults });
        }
        return .{ .result = .{ .object = o } };
    }

    fn environ(self: *Local, ctx: cli.Local.Context) std.process.Environ {
        return ctx.path.environ orelse self.daemon.environ;
    }

    fn loginPaths(self: *Local, ctx: cli.Local.Context) !?login.Paths {
        const paths = login.Paths.resolve(ctx.allocator, self.environ(ctx)) catch |err| {
            if (err == error.OutOfMemory) return err;
            return null;
        };
        return if (login.plainPath(paths.config_dir)) paths else null;
    }

    fn loginInstall(self: *Local, ctx: cli.Local.Context) !cli.Local.Outcome {
        const a = ctx.allocator;
        const io = self.daemon.io;
        const p = try self.loginPaths(ctx) orelse return failure("invalid_params.path", "venom-os's XDG directories cannot be resolved or quoted safely (set HOME or XDG_DATA_HOME to a plain absolute path)");
        const venomx = ctx.params.object.get("venomx").?.string;
        if (venomx.len == 0) return failure("invalid_params.path", "--venomx must be a non-empty path");
        const enable = ctx.params.object.get("enable").?.bool;
        for ([_][]const u8{ p.unit, p.env }) |path| if (login.owner(a, io, path) == .foreign) return notOurs(a, path);
        const exe = std.process.executablePathAlloc(io, a) catch return failure("unavailable.login_files", "the venom-os executable path could not be read");
        const resolved = try login.resolveVenomx(a, io, self.environ(ctx), venomx);
        const unit = try login.unitText(a, exe, resolved) orelse return failure("invalid_params.path", "the venom-os or venomx path contains control characters");
        const defaults_path = up.installDefaults(a, io, p.config_dir) catch |err| return filesFailed(a, err);
        login.writeFile(io, p.unit, unit) catch |err| return filesFailed(a, err);
        login.writeFile(io, p.env, try login.envText(a, p.config_dir)) catch |err| return filesFailed(a, err);
        if (enable) login.link(io, p.wants, p.unit) catch |err| return filesFailed(a, err);
        if (!self.json) {
            try ctx.stdout.print("wrote {s}\nwrote {s}\n", .{ p.unit, p.env });
            if (enable) try ctx.stdout.print("linked {s}\n", .{p.wants});
            try ctx.stdout.print("installed {s}\nvenom-os up starts at your next login{s}; to start it now: {s}\n", .{ defaults_path, if (enable) "" else " once enabled (systemctl --user enable venom-os.service)", login.start_hint });
            return .{ .status = 0 };
        }
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "unit", .{ .string = p.unit });
        if (enable) try o.put(a, "wants", .{ .string = p.wants });
        try o.put(a, "env", .{ .string = p.env });
        try o.put(a, "defaults", .{ .string = defaults_path });
        try o.put(a, "config_dirs", .{ .string = p.config_dir });
        try o.put(a, "next", .{ .string = login.start_hint });
        return .{ .result = .{ .object = o } };
    }

    fn loginUninstall(self: *Local, ctx: cli.Local.Context) !cli.Local.Outcome {
        const a = ctx.allocator;
        const io = self.daemon.io;
        const p = try self.loginPaths(ctx) orelse return failure("invalid_params.path", "venom-os's XDG directories cannot be resolved or quoted safely (set HOME or XDG_DATA_HOME to a plain absolute path)");
        // Check everything first, so a foreign file means nothing is removed.
        for ([_][]const u8{ p.unit, p.env }) |path| if (login.owner(a, io, path) == .foreign) return notOurs(a, path);
        var removed: std.json.Array = .init(a);
        const cwd = std.Io.Dir.cwd();
        if (login.linksTo(io, p.wants, p.unit)) {
            cwd.deleteFile(io, p.wants) catch |err| return filesFailed(a, err);
            try removed.append(.{ .string = p.wants });
        }
        for ([_][]const u8{ p.unit, p.env }) |path| if (login.owner(a, io, path) == .ours) {
            cwd.deleteFile(io, path) catch |err| return filesFailed(a, err);
            try removed.append(.{ .string = path });
        };
        if (!self.json) {
            for (removed.items) |r| try ctx.stdout.print("removed {s}\n", .{r.string});
            if (removed.items.len == 0) try ctx.stdout.writeAll("nothing to remove\n");
            try ctx.stdout.print("a running unit keeps running; to stop it: {s}\n", .{login.stop_hint});
            return .{ .status = 0 };
        }
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "removed", .{ .array = removed });
        try o.put(a, "next", .{ .string = login.stop_hint });
        return .{ .result = .{ .object = o } };
    }

    fn env(self: *Local, ctx: cli.Local.Context) !cli.Local.Outcome {
        const a = ctx.allocator;
        const dir = up.configDir(a, self.environ(ctx)) catch |err| {
            if (err == error.OutOfMemory) return err;
            return failure("invalid_params.path", "venom-os's XDG data directory cannot be resolved (set HOME or XDG_DATA_HOME)");
        };
        if (!login.plainPath(dir)) return failure("invalid_params.path", "venom-os's XDG data directory cannot be quoted safely in a shell snippet");
        const sh = try login.shText(a, dir);
        if (!self.json) {
            try ctx.stdout.writeAll(sh);
            return .{ .status = 0 };
        }
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "config_dirs", .{ .string = dir });
        try o.put(a, "sh", .{ .string = sh });
        return .{ .result = .{ .object = o } };
    }

    fn notOurs(a: std.mem.Allocator, path: []const u8) !cli.Local.Outcome {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "path", .{ .string = path });
        return .{ .failure = .{ .code = "conflict.not_ours", .message = "a file of that name exists and was not written by venom-os login install; move it away first", .data = .{ .object = o } } };
    }

    fn filesFailed(a: std.mem.Allocator, err: anyerror) !cli.Local.Outcome {
        if (err == error.OutOfMemory) return err;
        return .{ .failure = .{ .code = "unavailable.login_files", .message = "a login integration file could not be written or removed", .data = try reason(a, err) } };
    }

    fn failure(code: []const u8, message: []const u8) cli.Local.Outcome {
        return .{ .failure = .{ .code = code, .message = message } };
    }
    fn reason(a: std.mem.Allocator, err: anyerror) !std.json.Value {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "reason", .{ .string = @errorName(err) });
        return .{ .object = o };
    }
};

pub fn main(init: std.process.Init) !void {
    const stopped = supervisor.installSignalHandlers();
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var err = std.Io.File.stderr().writer(init.io, &err_buf);
    var d: daemon.Daemon = .{ .gpa = init.gpa, .io = init.io, .environ = init.minimal.environ, .stderr = &err.interface, .stopped = stopped };
    const parsed = try App.parse(init.arena.allocator(), argv[1..]);
    var local: Local = .{ .daemon = &d, .json = parsed.json };
    const status = try App.run(init.gpa, argv[1..], .{
        .stdout = &out.interface,
        .stderr = &err.interface,
        .environ = init.minimal.environ,
        .bootstrap = cli.Bootstrap.init(&d),
        .local = cli.Local.init(&local),
        .interrupted = stopped,
    });
    try out.interface.flush();
    try err.interface.flush();
    if (status != 0) std.process.exit(status);
}

test {
    _ = up;
    _ = login;
    _ = daemon;
    _ = @import("services.zig");
}

const t = std.testing;

fn runCli(args: []const []const u8, json: bool, out: *std.Io.Writer.Allocating, err: *std.Io.Writer.Allocating) !u8 {
    var d: daemon.Daemon = .{ .gpa = t.allocator, .io = t.io, .environ = .empty, .stderr = &err.writer, .stopped = undefined };
    var local: Local = .{ .daemon = &d, .json = json };
    return App.run(t.allocator, args, .{ .stdout = &out.writer, .stderr = &err.writer, .local = cli.Local.init(&local), .stdin = @as(std.c.fd_t, -1), .stdout_fd = @as(std.c.fd_t, -1) });
}

test "defaults: raw without --json, content with it, absolute --dir only" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(t.allocator);
    defer err.deinit();
    try t.expectEqual(@as(u8, 0), try runCli(&.{"defaults"}, false, &out, &err));
    try t.expectEqualStrings(up.venomx_defaults, out.written());
    out.clearRetainingCapacity();
    try t.expectEqual(@as(u8, 0), try runCli(&.{ "defaults", "--json" }, true, &out, &err));
    const parsed = try std.json.parseFromSlice(struct { content: []const u8 }, t.allocator, out.written(), .{});
    defer parsed.deinit();
    try t.expectEqualStrings(up.venomx_defaults, parsed.value.content);
    out.clearRetainingCapacity();
    try t.expectEqual(@as(u8, 2), try runCli(&.{ "defaults", "--dir=rel", "--json" }, true, &out, &err));
    try t.expect(std.mem.indexOf(u8, out.written(), "invalid_params.dir") != null);
    try t.expectEqualStrings("", err.written());
}

test "up: unknown options and an empty --venomx are usage errors before any effect" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(t.allocator);
    defer err.deinit();
    try t.expectEqual(@as(u8, 2), try runCli(&.{ "up", "--bogus=1", "--json" }, true, &out, &err));
    out.clearRetainingCapacity();
    try t.expectEqual(@as(u8, 2), try runCli(&.{ "up", "--venomx=", "--json" }, true, &out, &err));
    try t.expect(std.mem.indexOf(u8, out.written(), "invalid_params.venomx") != null);
}

test "generated docs and skill cover the product verbs and local commands" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try cli.docs.writeMarkdown(App, &out.writer);
    const skill = try cli.skill.render(App, arena.allocator(), daemon.skill_notes);
    for ([_][]const u8{ "`venom-os up`", "`venom-os defaults`", "`venom-os status`", "`venom-os service list`", "`venom-os service enable`", "`venom-os service disable`", "`venom-os doctor`", "`venom-os login install`", "`venom-os login uninstall`", "`venom-os env`" }) |cmd| {
        try t.expect(std.mem.indexOf(u8, out.written(), cmd) != null);
        try t.expect(std.mem.indexOf(u8, skill, cmd) != null);
    }
    try t.expect(App.schema.find("up") == null and App.schema.find("status") != null);
}
