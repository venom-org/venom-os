//! `venom-os up`: install the curated venomx defaults and supervise a
//! persistent `venomx serve`.
//!
//! * The defaults file is installed at
//!   `$XDG_DATA_HOME/venom/venom-os/xdg/venomx/defaults.zon`, a directory
//!   venom-os owns, and that directory is put **first** in the supervised
//!   daemon's `$XDG_CONFIG_DIRS` (followed by the inherited value, or
//!   `/etc/xdg`). Nothing is written to the user's config or to `/etc`;
//!   `venom-os defaults --dir=/etc/xdg` is the packager's path.
//! * venomx runs as `venomx serve --json`: lifetime `persistent`, origin
//!   `serve` (both the serve defaults, so `doctor` reports exactly that). Its
//!   panes inherit the daemon's environment, so a `venomx` typed inside one
//!   sees the same defaults.
//! * The supervisor (venom-std `supervisor`) restarts venomx after any exit
//!   with exponential backoff. Sessions do not survive a crash in memory;
//!   the defaults enable venomx's durable checkpoints so they can be
//!   restored. On SIGTERM/SIGINT venomx gets SIGTERM, then SIGKILL after the
//!   grace period, and `up` returns.
//! * `up` is `serve` plus this: the same daemon (socket, verbs, doctor)
//!   with venomx added to its supervisor (see daemon.zig). Status:
//!   `venom-os.status.json` next to the socket (supervisor format), removed
//!   on shutdown.
const std = @import("std");
const supervisor = @import("supervisor");
const xdg = @import("xdg");

/// The curated venomx defaults shipped in `share/venomx/defaults.zon`.
pub const venomx_defaults: []const u8 = @import("defaults_file").bytes;

pub const tool = "venom-os";

/// Writes `<dir>/venomx/defaults.zon` atomically (mode 0644, parents made)
/// and returns its path.
pub fn installDefaults(a: std.mem.Allocator, io: std.Io, dir: []const u8) ![]const u8 {
    std.debug.assert(std.fs.path.isAbsolute(dir));
    const path = try std.fmt.allocPrint(a, "{s}/venomx/defaults.zon", .{std.mem.trimEnd(u8, dir, "/")});
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true, .permissions = .fromMode(0o644) });
    defer file.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.file.writer(io, &buffer);
    try writer.interface.writeAll(venomx_defaults);
    try writer.interface.flush();
    try file.file.sync(io);
    try file.replace(io);
    return path;
}

/// `$XDG_CONFIG_DIRS` for supervised children: venom-os's directory first,
/// then the inherited list (or the XDG default `/etc/xdg`). An inherited
/// list that already names venom-os's directory (a login session set up by
/// `venom-os login install`) keeps its other entries, without a duplicate.
pub fn configDirs(a: std.mem.Allocator, ours: []const u8, inherited: ?[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, ours);
    var rest: usize = 0;
    var it = std.mem.splitScalar(u8, inherited orelse "", ':');
    while (it.next()) |dir| {
        if (dir.len == 0 or std.mem.eql(u8, dir, ours)) continue;
        try out.append(a, ':');
        try out.appendSlice(a, dir);
        rest += 1;
    }
    if (rest == 0) try out.appendSlice(a, ":/etc/xdg");
    return out.toOwnedSlice(a);
}

/// venom-os's own `$XDG_CONFIG_DIRS` entry,
/// `$XDG_DATA_HOME/venom/venom-os/xdg`; it holds `venomx/defaults.zon`.
pub fn configDir(a: std.mem.Allocator, environ: std.process.Environ) ![]const u8 {
    const data = try xdg.venomDir(a, .data, tool, .{ .environ = environ, .uid = @intCast(std.c.getuid()) });
    defer a.free(data);
    return std.fmt.allocPrint(a, "{s}/xdg", .{data});
}

/// Everything `up` needs, resolved from the environment before any effect.
pub const Plan = struct {
    /// Directory placed first in `$XDG_CONFIG_DIRS`; holds `venomx/defaults.zon`.
    config_dir: []const u8,
    /// `<config_dir>/venomx/defaults.zon`, once installed.
    defaults_path: []const u8,
    /// `env XDG_CONFIG_DIRS=… <venomx> serve --json`.
    argv: []const []const u8,

    pub fn resolve(a: std.mem.Allocator, environ: std.process.Environ, venomx: []const u8) !Plan {
        const config_dir = try configDir(a, environ);
        const dirs = try configDirs(a, config_dir, environ.getPosix("XDG_CONFIG_DIRS"));
        return .{
            .config_dir = config_dir,
            .defaults_path = try std.fmt.allocPrint(a, "{s}/venomx/defaults.zon", .{config_dir}),
            .argv = try serveArgv(a, dirs, venomx),
        };
    }
};

pub fn serveArgv(a: std.mem.Allocator, config_dirs: []const u8, venomx: []const u8) ![]const []const u8 {
    const list = try a.alloc([]const u8, 5);
    list[0..5].* = .{ "env", try std.fmt.allocPrint(a, "XDG_CONFIG_DIRS={s}", .{config_dirs}), venomx, "serve", "--json" };
    return list;
}

/// Restart venomx after any exit; back off up to 30 s, healthy after 10 s up.
pub const venomx_policy: supervisor.Policy = .{ .restart = .always, .initial_ms = 200, .max_ms = 30_000, .reset_after_ms = 10_000 };

const t = std.testing;

test "configDirs puts venom-os first and keeps the inherited list or /etc/xdg" {
    const a = t.allocator;
    const x = try configDirs(a, "/d/venom-os/xdg", null);
    defer a.free(x);
    try t.expectEqualStrings("/d/venom-os/xdg:/etc/xdg", x);
    const y = try configDirs(a, "/d/venom-os/xdg", "");
    defer a.free(y);
    try t.expectEqualStrings("/d/venom-os/xdg:/etc/xdg", y);
    const z = try configDirs(a, "/d/venom-os/xdg", "/opt/xdg:/etc/xdg");
    defer a.free(z);
    try t.expectEqualStrings("/d/venom-os/xdg:/opt/xdg:/etc/xdg", z);
    // Under a session from `login install`, ours is already in the list.
    const w = try configDirs(a, "/d/venom-os/xdg", "/d/venom-os/xdg:/etc/xdg");
    defer a.free(w);
    try t.expectEqualStrings("/d/venom-os/xdg:/etc/xdg", w);
    const v = try configDirs(a, "/d/venom-os/xdg", "/d/venom-os/xdg");
    defer a.free(v);
    try t.expectEqualStrings("/d/venom-os/xdg:/etc/xdg", v);
}

test "serve argv: persistent serve with the default origin, under env" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const argv = try serveArgv(arena.allocator(), "/d:/etc/xdg", "/opt/venomx");
    try t.expectEqual(@as(usize, 5), argv.len);
    try t.expectEqualStrings("env", argv[0]);
    try t.expectEqualStrings("XDG_CONFIG_DIRS=/d:/etc/xdg", argv[1]);
    try t.expectEqualStrings("/opt/venomx", argv[2]);
    try t.expectEqualStrings("serve", argv[3]);
    // No --lifetime and no --origin: the serve defaults are persistent/serve.
    try t.expectEqualStrings("--json", argv[4]);
}

test "installDefaults writes <dir>/venomx/defaults.zon with the shipped bytes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const path = try installDefaults(arena.allocator(), t.io, base);
    try t.expect(std.mem.endsWith(u8, path, "/venomx/defaults.zon"));
    // Installing twice replaces the file in place.
    _ = try installDefaults(arena.allocator(), t.io, base);
    const got = try tmp.dir.readFileAlloc(t.io, "venomx/defaults.zon", t.allocator, .limited(1 << 20));
    defer t.allocator.free(got);
    try t.expectEqualStrings(venomx_defaults, got);
}

test "shipped defaults set the keys venom-os relies on" {
    for ([_][]const u8{ ".interactive_start = false", ".position = .top", ".name = \"venom-os\"", ".recovery = .{ .enabled = true }" }) |needle|
        try t.expect(std.mem.indexOf(u8, venomx_defaults, needle) != null);
}

test "Plan.resolve: the defaults paths follow the XDG env" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const block = [_:null]?[*:0]const u8{ "XDG_DATA_HOME=/h/data", "XDG_RUNTIME_DIR=/run/u", "XDG_CONFIG_DIRS=/opt/xdg", "HOME=/h" };
    const environ: std.process.Environ = .{ .block = .{ .slice = &block } };
    const plan = try Plan.resolve(arena.allocator(), environ, "venomx");
    try t.expectEqualStrings("/h/data/venom/venom-os/xdg", plan.config_dir);
    try t.expectEqualStrings("/h/data/venom/venom-os/xdg/venomx/defaults.zon", plan.defaults_path);
    try t.expectEqualStrings("XDG_CONFIG_DIRS=/h/data/venom/venom-os/xdg:/opt/xdg", plan.argv[1]);
}
