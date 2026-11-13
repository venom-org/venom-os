const std = @import("std");

/// venom-std modules venom-os imports.
const shared_modules = [_][]const u8{ "proto", "cli", "cfg", "log", "supervisor", "xdg" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const std_dep = b.dependency("venom_std", .{ .target = target, .optimize = optimize });

    // share/venomx/defaults.zon is embedded as bytes (it lives outside src/).
    const files = b.addWriteFiles();
    _ = files.addCopyFile(b.path("share/venomx/defaults.zon"), "defaults.zon");
    const defaults_file = b.createModule(.{ .root_source_file = files.add("defaults_file.zig", "pub const bytes = @embedFile(\"defaults.zon\");\n") });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "defaults_file", .module = defaults_file }},
    });
    inline for (shared_modules) |name| mod.addImport(name, std_dep.module(name));
    // One binary: the daemon (`venom-os serve` / `venom-os up`) and its CLI.
    const exe = b.addExecutable(.{ .name = "venom-os", .root_module = mod });
    b.installArtifact(exe);
    // Packagers copy this to /etc/xdg/venomx/defaults.zon (or run `venom-os defaults --dir`).
    b.installFile("share/venomx/defaults.zon", "share/venom-os/venomx/defaults.zon");

    const test_step = b.step("test", "Run unit tests, the agent-contract conformance suite and the venom-os up integration test");
    const unit_step = b.step("test-unit", "Run unit tests");
    unit_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(unit_step);

    // Agent-contract conformance: venom-std's packaged suite against
    // `venom-os serve` (which never starts venomx).
    const conformance = @import("venom_std").addConformance(b, .{ .suite = std_dep.path("conformance/agent_contract.py"), .exe = exe, .profile = b.path("conformance/venom-os.json") });
    b.step("test-conformance", "Run the venom-std agent-contract conformance suite against venom-os").dependOn(&conformance.step);
    test_step.dependOn(&conformance.step);

    // The integration test drives a real venomx; by default the sibling
    // checkout's build (`zig build` in ../venomx).
    const venomx = b.option([]const u8, "venomx", "venomx binary for the integration test (default ../venomx/zig-out/bin/venomx)") orelse "../venomx/zig-out/bin/venomx";
    const integration = b.addSystemCommand(&.{"python3"});
    integration.addFileArg(b.path("test/up.py"));
    integration.addArtifactArg(exe);
    integration.addArg(venomx); // relative paths resolve against this repo
    integration.has_side_effects = true;
    integration.expectExitCode(0);
    b.step("test-up", "Run venom-os up against a real venomx in temp XDG dirs").dependOn(&integration.step);
    test_step.dependOn(&integration.step);
}
