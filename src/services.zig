//! The daemons `venom-os up` can supervise, and what the venom-os daemon
//! knows about them (`status`, `service.*`, doctor).
//!
//! * Enabled/disabled is persisted like `systemctl enable`: a marker file
//!   `$XDG_STATE_HOME/venom/venom-os/<name>.disabled`. It is read when `up`
//!   starts; changing it never stops or starts a running service.
//! * Live state comes from the supervisor status file next to the socket
//!   (`venom-os.status.json`), which the supervisor rewrites atomically on
//!   every change. The serving thread never touches the supervisor itself.
const std = @import("std");
const proto = @import("proto");
const xdg = @import("xdg");

pub const tool = "venom-os";

/// Every service venom-os knows, in `service.list` order. Keep in sync with
/// the `choices` of `service.enable|disable` in verbs.zon.
pub const names = [_][]const u8{"venomx"};

pub const State = struct {
    io: std.Io,
    /// `$XDG_STATE_HOME/venom/venom-os`; created on the first write.
    dir: []const u8,

    pub fn init(a: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !State {
        return .{ .io = io, .dir = try xdg.venomDir(a, .state, tool, .{ .environ = environ, .uid = std.c.getuid() }) };
    }

    fn marker(self: State, buf: []u8, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}.disabled", .{ self.dir, name });
    }

    pub fn enabled(self: State, name: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = self.marker(&buf, name) catch return true;
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return true;
        return false;
    }

    /// Returns whether the value changed.
    pub fn set(self: State, name: []const u8, on: bool) !bool {
        if (self.enabled(name) == on) return false;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try self.marker(&buf, name);
        const cwd = std.Io.Dir.cwd();
        if (on) {
            cwd.deleteFile(self.io, path) catch |err| if (err != error.FileNotFound) return err;
        } else {
            _ = try cwd.createDirPathStatus(self.io, self.dir, .fromMode(0o700));
            const file = try cwd.createFile(self.io, path, .{ .permissions = .fromMode(0o600) });
            file.close(self.io);
        }
        return true;
    }
};

/// `service.list` (read).
pub const List = struct {
    state: *const State,
    pub fn call(self: *List, c: *proto.Call) anyerror!void {
        const Item = struct { name: []const u8, enabled: bool };
        var items: [names.len]Item = undefined;
        for (names, &items) |name, *item| item.* = .{ .name = name, .enabled = self.state.enabled(name) };
        try c.ok(.{ .services = items });
    }
};

/// `service.enable` / `service.disable` (write).
pub const Toggle = struct {
    state: *const State,
    on: bool,
    pub const Params = struct { name: []const u8 };
    pub fn call(self: *Toggle, c: *proto.Call, params: Params) anyerror!void {
        const changed = self.state.set(params.name, self.on) catch |err| {
            if (err == error.OutOfMemory) return err;
            return c.fail("unavailable.service_state", "the service state file could not be written", .{ .name = params.name, .reason = @errorName(err) });
        };
        try c.ok(.{ .name = params.name, .enabled = self.on, .changed = changed });
    }
};

/// One worker of the supervisor status file.
pub const Worker = struct {
    state: []const u8,
    pid: ?i64 = null,
    restarts: i64 = 0,
    last_exit: ?[]const u8 = null,
};

/// Reads worker `name` from a supervisor status file. null when the file or
/// the worker is missing or unreadable. Memory belongs to `a`.
pub fn readWorker(a: std.mem.Allocator, io: std.Io, status_path: []const u8, name: []const u8) ?Worker {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, status_path, a, .limited(1 << 20)) catch return null;
    return parseWorker(a, bytes, name);
}

pub fn parseWorker(a: std.mem.Allocator, bytes: []const u8, name: []const u8) ?Worker {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return null;
    if (doc != .object) return null;
    const workers = doc.object.get("workers") orelse return null;
    if (workers != .array) return null;
    for (workers.array.items) |w| {
        if (w != .object) continue;
        const n = w.object.get("name") orelse continue;
        if (n != .string or !std.mem.eql(u8, n.string, name)) continue;
        const state = w.object.get("state") orelse return null;
        if (state != .string) return null;
        var out: Worker = .{ .state = state.string };
        if (w.object.get("pid")) |p| if (p == .integer and p.integer > 0) {
            out.pid = p.integer;
        };
        if (w.object.get("restarts")) |r| if (r == .integer) {
            out.restarts = r.integer;
        };
        if (w.object.get("last_exit")) |e| if (e != .null) {
            out.last_exit = std.json.Stringify.valueAlloc(a, e, .{}) catch null;
        };
        return out;
    }
    return null;
}

/// Whether a daemon of `daemon_tool` completes the hello handshake on its
/// default socket within `budget_ms`. Returns null on success, else the
/// error. Never sends a verb.
pub fn probe(gpa: std.mem.Allocator, daemon_tool: []const u8, environ: std.process.Environ, budget_ms: i64) ?anyerror {
    var client = proto.Client.init(gpa, .{
        .tool = daemon_tool,
        .path = .{ .environ = environ },
        .hello = .{ .identity = .{ .name = tool, .version = "0.0.0" } },
    }) catch |err| return err;
    defer client.deinit();
    const deadline = proto.os.nowMs() + budget_ms;
    while (true) {
        const left = deadline - proto.os.nowMs();
        if (left <= 0) return error.Timeout;
        if (client.pollHello(@intCast(@min(left, 100)))) |done| {
            if (done) return null;
        } else |err| return err;
    }
}

const t = std.testing;

test "parseWorker reads one worker of a supervisor status document" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const doc =
        \\{"pid":10,"updated_ms":1,"stopping":false,"workers":[
        \\{"name":"serve","kind":"thread","state":"running","pid":null,"restarts":0,"failures":0,"last_exit":null},
        \\{"name":"venomx","kind":"process","state":"backoff","pid":null,"restarts":2,"failures":1,"last_exit":{"signal":9}}]}
    ;
    const w = parseWorker(arena.allocator(), doc, "venomx").?;
    try t.expectEqualStrings("backoff", w.state);
    try t.expectEqual(@as(?i64, null), w.pid);
    try t.expectEqual(@as(i64, 2), w.restarts);
    try t.expectEqualStrings("{\"signal\":9}", w.last_exit.?);
    try t.expect(parseWorker(arena.allocator(), doc, "nope") == null);
    try t.expect(parseWorker(arena.allocator(), "not json", "venomx") == null);
}

test "State persists disabled services as marker files" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(base);
    const dir = try std.fmt.allocPrint(t.allocator, "{s}/state/venom/venom-os", .{base});
    defer t.allocator.free(dir);
    const s: State = .{ .io = t.io, .dir = dir };
    try t.expect(s.enabled("venomx"));
    try t.expect(try s.set("venomx", false));
    try t.expect(!s.enabled("venomx"));
    try t.expect(!try s.set("venomx", false));
    try t.expect(try s.set("venomx", true));
    try t.expect(s.enabled("venomx"));
    try t.expect(!try s.set("venomx", true));
}
