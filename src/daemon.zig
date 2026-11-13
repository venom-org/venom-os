//! The venom-os daemon (the agent contract: daemon and CLI are one binary).
//!
//! `venom-os serve` runs the agent-contract daemon alone: socket, verbs,
//! events, config, grants, doctor and skill. `venom-os up` runs the same
//! daemon and adds the bundle's job: it installs the curated venomx defaults
//! and supervises a persistent `venomx serve` next to its own serving thread
//! (see up.zig). Both write the supervisor status file next to the socket.
//! `serve` never starts venomx, so a bare `serve` (tests, conformance, a
//! second instance on another socket) cannot touch a user's venomx.
const std = @import("std");
const cli = @import("cli");
const proto = @import("proto");
const cfg = @import("cfg");
const log = @import("log");
const supervisor = @import("supervisor");
const xdg = @import("xdg");
const up = @import("up.zig");
const services = @import("services.zig");
const login = @import("login.zig");

pub const tool = "venom-os";

pub const Config = struct {
    /// Capability-grant policy for callers without a token; read-only by default.
    grants: proto.grants.Policy = .{},
    /// Log levels and formats; applied live on `config set` and reloads.
    log: log.Config = .{},
};
pub const ConfigStore = cfg.Store(Config, &.{});

pub fn validateConfig(value: Config) ?cfg.Validation {
    value.grants.check() catch return .{ .key = "grants" };
    return null;
}

pub const input = @import("verbs.zon");
const manifest = .{ .format = input.format, .tool = input.tool, .summary = input.summary, .verbs = input.verbs ++ .{proto.events.manifest} };

/// Local commands: they run in the CLI process, never as daemon verbs.
pub const local = .{ .{
    .name = "up",
    .summary = "Start the venom-os daemon in up mode: what `serve` does, plus install the curated venomx defaults into venom-os's own XDG data directory and supervise a persistent `venomx serve` (restarted with backoff after any exit) until SIGTERM or SIGINT. venomx is skipped when `service disable --name=venomx` was run.",
    .params = .{
        .{ .name = "venomx", .summary = "venomx binary to supervise (looked up in PATH unless it contains a slash)", .type = .{ .kind = .string }, .default = "venomx" },
    },
    .result = .{ .kind = .object, .fields = .{} },
    .errors = .{
        .{ .code = "conflict.already_running", .summary = "A venom-os daemon already serves the selected socket" },
        .{ .code = "conflict.not_a_socket", .summary = "The socket path exists and is not a socket" },
        .{ .code = "denied.insecure_path", .summary = "The runtime directory is not private to this user" },
        .{ .code = "unavailable.path_too_long", .summary = "The socket path is too long" },
        .{ .code = "invalid_params.socket", .summary = "The socket path is invalid" },
        .{ .code = "invalid_params.venomx", .summary = "The venomx path is empty or contains NUL" },
        .{ .code = "unavailable.defaults", .summary = "The venomx defaults could not be installed" },
        .{ .code = "conflict.venomx_running", .summary = "A venomx that venom-os did not start already serves venomx's socket" },
    },
    .examples = .{.{ .params = .{}, .result = .{} }},
}, .{
    .name = "defaults",
    .summary = "Print the curated venomx defaults.zon (raw, or as content with --json), or install it as <dir>/venomx/defaults.zon (packagers: --dir=/etc/xdg). Never needs a daemon.",
    .params = .{
        .{ .name = "dir", .summary = "Absolute directory to install into as <dir>/venomx/defaults.zon", .type = .{ .kind = .string } },
    },
    .result = .{ .kind = .object, .fields = .{
        .{ .name = "content", .summary = "The defaults file (without --dir)", .type = .{ .kind = .string } },
        .{ .name = "path", .summary = "The installed file (with --dir)", .type = .{ .kind = .string } },
    } },
    .errors = .{
        .{ .code = "invalid_params.dir", .summary = "--dir is not an absolute path" },
        .{ .code = "unavailable.defaults", .summary = "The file could not be written" },
    },
    .examples = .{.{ .params = .{ .dir = "/etc/xdg" }, .result = .{ .path = "/etc/xdg/venomx/defaults.zon" } }},
}, .{
    .name = "login.install",
    .summary = "Start `venom-os up` at login and give login sessions venom-os's $XDG_CONFIG_DIRS: write a systemd user unit (and the default.target.wants link `systemctl --user enable` would make) and an environment.d snippet under $XDG_CONFIG_HOME, and install the venomx defaults. Never runs systemctl; files another tool wrote are left alone. Never needs a daemon.",
    .params = .{
        .{ .name = "venomx", .summary = "venomx binary the unit supervises (a bare name is resolved in PATH now)", .type = .{ .kind = .string }, .default = "venomx" },
        .{ .name = "enable", .summary = "Also link the unit into default.target.wants so it starts at login", .type = .{ .kind = .boolean }, .default = true },
    },
    .result = .{ .kind = .object, .fields = .{
        .{ .name = "unit", .summary = "The systemd user unit written", .type = .{ .kind = .string }, .required = true },
        .{ .name = "wants", .summary = "The default.target.wants link (with --enable)", .type = .{ .kind = .string } },
        .{ .name = "env", .summary = "The environment.d snippet written", .type = .{ .kind = .string }, .required = true },
        .{ .name = "defaults", .summary = "The installed venomx defaults.zon", .type = .{ .kind = .string }, .required = true },
        .{ .name = "config_dirs", .summary = "The directory put first in $XDG_CONFIG_DIRS", .type = .{ .kind = .string }, .required = true },
        .{ .name = "next", .summary = "Command that starts the unit in the running session (not run)", .type = .{ .kind = .string }, .required = true },
    } },
    .errors = .{
        .{ .code = "conflict.not_ours", .summary = "A unit or environment.d file of the same name exists and was not written by login install" },
        .{ .code = "invalid_params.path", .summary = "A path cannot be written into the unit or environment.d safely (relative, or contains whitespace, quotes, $, : or control characters)" },
        .{ .code = "unavailable.login_files", .summary = "A file could not be written" },
    },
}, .{
    .name = "login.uninstall",
    .summary = "Remove the files `login install` wrote (unit, wants link, environment.d snippet); a running unit keeps running until `systemctl --user stop venom-os.service`. Never needs a daemon.",
    .result = .{ .kind = .object, .fields = .{
        .{ .name = "removed", .summary = "Paths removed", .type = .{ .kind = .array, .items = .{ .kind = .string } }, .required = true },
        .{ .name = "next", .summary = "Command that stops a running unit (not run)", .type = .{ .kind = .string }, .required = true },
    } },
    .errors = .{
        .{ .code = "conflict.not_ours", .summary = "A file of the same name exists and was not written by login install; nothing was removed" },
        .{ .code = "unavailable.login_files", .summary = "A file could not be removed" },
    },
}, .{
    .name = "env",
    .summary = "Print a POSIX shell snippet that puts venom-os's directory first in $XDG_CONFIG_DIRS (idempotent), for shells and sessions that do not read environment.d: `eval \"$(venom-os env)\"` in a shell rc. With --json, the directory and the snippet. Never needs a daemon.",
    .result = .{ .kind = .object, .fields = .{
        .{ .name = "config_dirs", .summary = "The directory put first in $XDG_CONFIG_DIRS", .type = .{ .kind = .string }, .required = true },
        .{ .name = "sh", .summary = "The shell snippet", .type = .{ .kind = .string }, .required = true },
    } },
    .errors = .{
        .{ .code = "invalid_params.path", .summary = "The directory cannot be written into a shell snippet safely" },
    },
    .examples = .{.{ .params = .{}, .result = .{ .config_dirs = "/h/x", .sh = "case" } }},
} };

pub const App = cli.WithBootstrap(cfg.merge(cli.manifest.normalize(manifest)), cli.manifest.examples(manifest), .{ .local = local });

pub const skill_notes =
    \\venom-os is the Venom bundle. `venom-os up` is its daemon in up mode: it
    \\installs the curated venomx defaults (into venom-os's own XDG data
    \\directory, put first in venomx's $XDG_CONFIG_DIRS; never the user's config
    \\or /etc) and supervises a persistent `venomx serve`, restarting it after
    \\any exit. `venom-os serve` is the same daemon without venomx. Every verb is
    \\read-only unless a grant allows more; use named flags and `--json`.
    \\`venom-os status` and `venom-os doctor` report the supervised venomx (from
    \\the supervisor status file) and whether it answers; drive venomx itself
    \\with the `venomx` CLI. `venom-os service disable --name=venomx` makes the
    \\next `up` skip venomx (it never stops a running one). `venom-os login
    \\install` makes `up` start at login (a systemd user unit and an
    \\environment.d snippet under $XDG_CONFIG_HOME; it never runs systemctl),
    \\`login uninstall` removes them, and `venom-os env` prints the same
    \\$XDG_CONFIG_DIRS for a shell rc. Its side effects are
    \\its socket, status file, audit and daemon logs, the installed defaults
    \\file, service markers in its XDG state directory, the login files, the supervised venomx,
    \\ZON configuration (change it with `venom-os config set`) and installed
    \\skills.
;

/// What `up` adds to `serve`.
pub const UpMode = struct { plan: up.Plan };

/// `status` (read).
const Status = struct {
    io: std.Io,
    mode: ?UpMode,
    status_path: []const u8,
    venomx: bool,
    pub fn call(self: *Status, c: *proto.Call) anyerror!void {
        const a = c.arena();
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "mode", .{ .string = if (self.mode == null) "serve" else "up" });
        if (self.mode) |m| {
            try o.put(a, "defaults", .{ .string = m.plan.defaults_path });
            if (self.venomx) {
                const w = services.readWorker(a, self.io, self.status_path, "venomx") orelse services.Worker{ .state = "pending" };
                var x: std.json.ObjectMap = .empty;
                try x.put(a, "state", .{ .string = w.state });
                if (w.pid) |p| try x.put(a, "pid", .{ .integer = p });
                try x.put(a, "restarts", .{ .integer = w.restarts });
                try o.put(a, "venomx", .{ .object = x });
            }
        }
        try c.ok(std.json.Value{ .object = o });
    }
};

/// Product doctor check: persisted configuration validity.
const ConfigCheck = struct {
    config: *ConfigStore,
    pub fn run(self: *ConfigCheck, r: *cli.doctor.Report) anyerror!void {
        const fix = try r.command("{s} config check --json", r.tool);
        self.config.check() catch |err| {
            if (err == error.OutOfMemory) return err;
            const code = if (err == error.InvalidConfig) self.config.failure.code else @errorName(err);
            return r.add("config.valid", .fail, try r.print("configuration is invalid: {s} (key '{s}')", .{ code, self.config.failure.key() }), fix);
        };
        try r.add("config.valid", .ok, "configuration is valid", fix);
    }
};

/// Product doctor check: event log retention and watermarks.
const EventsCheck = struct {
    events: *proto.events.Log,
    pub fn run(self: *EventsCheck, r: *cli.doctor.Report) anyerror!void {
        const st = self.events.status();
        try r.add("events.log", .ok, try r.print("event log {s} retains seq {d}..{d} ({d} of {d} bytes)", .{ st.source, st.low, st.high, st.bytes, st.limits.bytes }), try r.command("{s} events --follow=false --json", r.tool));
    }
};

/// Product doctor checks for the bundle: the installed defaults, the
/// supervised venomx (from the status file) and whether it answers.
const BundleCheck = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    mode: ?UpMode,
    status_path: []const u8,
    venomx: bool,
    pub fn run(self: *BundleCheck, r: *cli.doctor.Report) anyerror!void {
        const recheck = try r.command("{s} status --json", r.tool);
        const m = self.mode orelse {
            try r.add("defaults.installed", .ok, "not installed: `venom-os serve` leaves the venomx defaults alone (`venom-os up` installs them)", try r.command("{s} defaults", r.tool));
            try r.add("venomx.supervised", .ok, "venomx is not supervised: this daemon runs as `venom-os serve` (`venom-os up` supervises it)", recheck);
            return;
        };
        try self.defaults(r, m.plan.defaults_path);
        if (!self.venomx) {
            try r.add("venomx.supervised", .ok, "venomx is disabled: `venom-os up` started without it", try r.command("{s} service enable --name=venomx --json", r.tool));
            return;
        }
        const w = services.readWorker(r.arena, self.io, self.status_path, "venomx") orelse {
            return r.add("venomx.supervised", .warn, try r.print("venomx is not in the supervisor status file {s} yet", .{self.status_path}), recheck);
        };
        const exit = w.last_exit orelse "none";
        if (std.mem.eql(u8, w.state, "running")) {
            try r.add("venomx.supervised", .ok, try r.print("venomx running (pid {d}, {d} restarts, last exit {s})", .{ w.pid orelse 0, w.restarts, exit }), recheck);
        } else if (std.mem.eql(u8, w.state, "pending") or std.mem.eql(u8, w.state, "backoff")) {
            try r.add("venomx.supervised", .warn, try r.print("venomx is {s} ({d} restarts, last exit {s}); the supervisor restarts it", .{ w.state, w.restarts, exit }), recheck);
        } else {
            try r.add("venomx.supervised", .fail, try r.print("venomx is {s} ({d} restarts, last exit {s}) and will not be restarted", .{ w.state, w.restarts, exit }), "venomx doctor --json");
        }
        // Whether the supervised venomx completes a hello on its socket.
        const socket = proto.os.socketPath(r.arena, "venomx", .{ .environ = self.environ }) catch "the default venomx socket";
        if (services.probe(self.gpa, "venomx", self.environ, 1000)) |err| {
            try r.add("venomx.answers", .fail, try r.print("venomx does not answer at {s}: {s}", .{ socket, cli.runtime.transportCode(err) }), "venomx ping --json");
        } else {
            try r.add("venomx.answers", .ok, try r.print("venomx answers at {s}", .{socket}), "venomx ping --json");
        }
    }
    fn defaults(self: *BundleCheck, r: *cli.doctor.Report, path: []const u8) !void {
        const recheck = try r.command("test -f {s}", path);
        const got = std.Io.Dir.cwd().readFileAlloc(self.io, path, r.arena, .limited(1 << 20)) catch |err| {
            return r.add("defaults.installed", .fail, try r.print("venomx defaults missing at {s}: {s} (restart `venom-os up` to reinstall)", .{ path, @errorName(err) }), recheck);
        };
        if (!std.mem.eql(u8, got, up.venomx_defaults))
            return r.add("defaults.installed", .warn, try r.print("venomx defaults at {s} differ from the shipped file (restart `venom-os up` to reinstall)", .{path}), recheck);
        try r.add("defaults.installed", .ok, try r.print("venomx defaults installed at {s}", .{path}), recheck);
    }
};

fn samePolicy(a: proto.grants.Policy, b: proto.grants.Policy) bool {
    if (a.max_token_ttl != b.max_token_ttl) return false;
    for ([_][]const proto.grants.Grant{ a.unknown, a.interactive }, [_][]const proto.grants.Grant{ b.unknown, b.interactive }) |left, right| {
        if (left.len != right.len) return false;
        for (left, right) |l, r| if (l.right != r.right or !std.mem.eql(u8, l.scope, r.scope)) return false;
    }
    return true;
}

/// The serving loop, run as a supervised thread: a failed poll is restarted
/// with backoff instead of taking the daemon down.
const ServeLoop = struct {
    io: std.Io,
    server: *proto.Server,
    events: *proto.events.Log,
    config: *ConfigStore,
    registry: *proto.grants.Registry,
    logger: *log.Logger,
    pub fn run(self: *ServeLoop, stop: *const supervisor.Stop) anyerror!void {
        while (!stop.requested()) {
            try self.server.poll(100);
            const now_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .awake).nanoseconds, std.time.ns_per_ms));
            self.config.watch(now_ms) catch |err| {
                if (err == error.OutOfMemory) return err;
                // Report only the refinement code; never dump a secret value.
                self.logger.warn("config watcher: reload failed", .{ .code = self.config.failure.code });
            };
            const current = self.config.current();
            if (!samePolicy(self.registry.policy, current.grants)) try self.registry.setPolicy(current.grants);
            self.logger.setConfig(current.log);
            try self.events.tick();
        }
    }
};

pub const Daemon = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    stderr: *std.Io.Writer,
    stopped: *const std.atomic.Value(bool),

    /// `venom-os serve` (cli.Bootstrap).
    pub fn serve(self: *Daemon, path: proto.SocketOptions) anyerror!void {
        return self.run(path, null);
    }

    /// Serve until `stopped`; with `mode`, also install the defaults and
    /// supervise venomx (`venom-os up`).
    pub fn run(self: *Daemon, path: proto.SocketOptions, mode: ?UpMode) anyerror!void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        // Records go to $XDG_STATE_HOME/venom/venom-os/venom-os.log; stderr only
        // shows warnings and errors unless the `log` config says otherwise.
        var logger = log.Logger.init(.{ .source = tool, .stderr = self.stderr, .file = self.openLog() });
        defer logger.deinit();
        var events = try proto.events.Log.init(self.gpa, tool, .{}, null);
        defer events.deinit();
        const config_path = try cfg.configPath(self.gpa, tool, self.environ);
        defer self.gpa.free(config_path);
        const defaults_paths = try cfg.defaultsPaths(self.gpa, tool, self.environ);
        defer cfg.freePaths(self.gpa, defaults_paths);
        var config = try ConfigStore.init(self.gpa, .{ .io = self.io, .path = config_path, .defaults = defaults_paths, .validate = validateConfig, .events = &events });
        defer config.deinit();
        events.snapshot = proto.events.Snapshot.init(&config);
        logger.setConfig(config.current().log);
        var registry = try proto.grants.Registry.init(self.gpa, tool, config.current().grants);
        defer registry.deinit();

        const state = try services.State.init(a, self.io, self.environ);
        // Latched at start, like systemd: enable/disable apply to the next up.
        const venomx = mode != null and state.enabled("venomx");
        var list: services.List = .{ .state = &state };
        var enable: services.Toggle = .{ .state = &state, .on = true };
        var disable: services.Toggle = .{ .state = &state, .on = false };
        var status: Status = .{ .io = self.io, .mode = mode, .status_path = "", .venomx = venomx };

        var events_check: EventsCheck = .{ .events = &events };
        var config_check: ConfigCheck = .{ .config = &config };
        var server_check: cli.doctor.ServerCheck = .{ .server = undefined };
        var bundle_check: BundleCheck = .{ .gpa = self.gpa, .io = self.io, .environ = self.environ, .mode = mode, .status_path = "", .venomx = venomx };
        const checks = [_]cli.doctor.Check{ .init("config", &config_check), .init("runtime", &server_check), .init("events", &events_check), .init("bundle", &bundle_check) };
        // The verb-schema digest: advertised in hello and compared by doctor, so a
        // client built against another schema is detected.
        const digest = try App.digest(self.gpa);
        var standard: cli.Standard(App) = .init(.{ .notes = skill_notes, .home = self.environ.getPosix("HOME"), .checks = &checks, .schema = &digest });
        const handlers = [_]proto.Binding{
            .{ .verb = "status", .handler = proto.VerbHandler.init(&status) },
            .{ .verb = "service.list", .handler = proto.VerbHandler.init(&list) },
            .{ .verb = "service.enable", .handler = proto.VerbHandler.typed(services.Toggle.Params, &enable) },
            .{ .verb = "service.disable", .handler = proto.VerbHandler.typed(services.Toggle.Params, &disable) },
            .{ .verb = "events", .handler = proto.VerbHandler.init(&events) },
        } ++ config.bindings() ++ standard.bindings();
        var dispatcher = try proto.Dispatcher.init(self.gpa, &App.schema, &handlers, .{}, null);
        defer dispatcher.deinit();
        // Holds the socket lock: a second daemon fails here, before any effect.
        var server = try proto.Server.init(self.gpa, .{
            .hello = .{ .identity = .{ .name = tool, .version = "0.0.0" }, .caps = &.{"cancel"}, .schema = &digest },
            .path = path,
            .registry = &registry,
        }, dispatcher.handler());
        defer server.deinit();
        server_check.server = &server;
        // The status file sits next to the socket, so it follows --socket.
        const status_path = try xdg.siblingPath(a, server.path, "status.json");
        status.status_path = status_path;
        bundle_check.status_path = status_path;
        // A venomx that venom-os did not start already holds venomx's socket:
        // supervising a second one would only restart it with backoff forever.
        if (mode != null and venomx) if (services.probe(self.gpa, "venomx", self.environ, 1000) == null) {
            const socket = proto.os.socketPath(a, "venomx", .{ .environ = self.environ }) catch "the venomx socket";
            logger.err("an unsupervised venomx already serves its socket; stop it (or let venom-os up own it) and start up again", .{ .socket = socket });
            return error.VenomxRunning;
        };
        if (mode) |m| _ = up.installDefaults(a, self.io, m.plan.config_dir) catch |err| {
            logger.err("installing the venomx defaults failed", .{ .path = m.plan.defaults_path, .reason = @errorName(err) });
            return error.DefaultsUnavailable;
        };
        logger.info("listening", .{ .socket = server.path, .pid = std.c.getpid(), .mode = if (mode == null) "serve" else "up" });
        {
            var sup = supervisor.Supervisor.init(self.gpa, .{ .status_path = status_path, .logger = &logger });
            defer sup.deinit();
            var loop: ServeLoop = .{ .io = self.io, .server = &server, .events = &events, .config = &config, .registry = &registry, .logger = &logger };
            try sup.addThread("serve", supervisor.Task.init(&loop), .{});
            if (mode) |m| {
                if (venomx) try sup.addProcess("venomx", m.plan.argv, up.venomx_policy) else logger.warn("venomx is disabled; not supervising it", .{});
            }
            sup.run(self.stopped, .{});
        }
        dispatcher.cancelAll();
        server.shutdown();
        while (server.connections.items.len != 0) try server.poll(100);
        logger.info("stopped", .{});
    }

    fn openLog(self: *Daemon) ?std.c.fd_t {
        const file = xdg.path(self.gpa, .state, tool, tool ++ ".log", .{ .environ = self.environ, .uid = std.c.getuid() }) catch return null;
        defer self.gpa.free(file);
        return log.openFile(self.gpa, file) catch null;
    }
};
