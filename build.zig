const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const Backend = enum { auto, stub };
    const backend = b.option(Backend, "backend", "Renderer implementation (auto currently selects stub on every platform)") orelse .auto;
    const options = b.addOptions();
    // Extend this target policy when platform backends are introduced.
    const selected: Backend = if (backend != .auto) backend else switch (target.result.os.tag) {
        .macos, .ios => .stub,
        .windows => .stub,
        else => .stub,
    };
    options.addOption(Backend, "backend", selected);
    const Platform = enum { auto, macos, stub };
    const platform = b.option(Platform, "platform", "Windowing implementation") orelse .auto;
    const selected_platform: Platform = if (platform == .auto) (if (target.result.os.tag == .macos) .macos else .stub) else platform;
    if (selected_platform == .macos and target.result.os.tag != .macos) @panic("macos platform requires a macOS target");
    options.addOption(Platform, "platform", selected_platform);
    const native_tests = b.option(bool, "native-tests", "Include AppKit/Metal integration tests (opens windows)") orelse false;
    if (native_tests and selected_platform != .macos) @panic("native tests require the macOS platform");
    options.addOption(bool, "native_tests", native_tests);
    const yoga = b.dependency("yoga", .{});
    const native = b.addLibrary(.{
        .name = "yoga",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true }),
    });
    native.root_module.addIncludePath(yoga.path(""));
    native.root_module.addCSourceFiles(.{ .root = yoga.path(""), .files = &.{
        "yoga/YGConfig.cpp",            "yoga/YGEnums.cpp",                   "yoga/YGNode.cpp",
        "yoga/YGNodeLayout.cpp",        "yoga/YGNodeStyle.cpp",               "yoga/YGPixelGrid.cpp",
        "yoga/YGValue.cpp",             "yoga/algorithm/AbsoluteLayout.cpp",  "yoga/algorithm/Baseline.cpp",
        "yoga/algorithm/Cache.cpp",     "yoga/algorithm/CalculateLayout.cpp", "yoga/algorithm/FlexLine.cpp",
        "yoga/algorithm/PixelGrid.cpp", "yoga/config/Config.cpp",             "yoga/debug/AssertFatal.cpp",
        "yoga/debug/Log.cpp",           "yoga/event/event.cpp",               "yoga/node/LayoutResults.cpp",
        "yoga/node/Node.cpp",
    }, .flags = &.{ "-std=c++20", "-fno-exceptions", "-fno-rtti" } });
    const mod = b.addModule("zigui", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    mod.addOptions("build_options", options);
    mod.addIncludePath(yoga.path(""));
    mod.linkLibrary(native);
    if (selected_platform == .macos) {
        mod.addImport("objc", b.dependency("zig_objc", .{ .target = target, .optimize = optimize }).module("objc"));
        mod.linkSystemLibrary("objc", .{});
        for ([_][]const u8{ "Foundation", "AppKit", "Metal", "QuartzCore", "CoreText", "CoreGraphics", "CoreFoundation" }) |framework| mod.linkFramework(framework, .{});
    }
    const example = b.addExecutable(.{ .name = "counter", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/counter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigui", .module = mod }},
    }) });
    b.installArtifact(example);
    const run = b.addRunArtifact(example);
    b.step("run", "Run the headless counter example").dependOn(&run.step);
    if (selected_platform == .macos) {
        const desktop = b.addExecutable(.{ .name = "desktop", .root_module = b.createModule(.{
            .root_source_file = b.path("examples/desktop.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigui", .module = mod }},
        }) });
        b.installArtifact(desktop);
        const desktop_run = b.addRunArtifact(desktop);
        if (b.args) |args| desktop_run.addArgs(args);
        b.step("run-desktop", "Run the native interactive counter").dependOn(&desktop_run.step);
    }
    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run framework, Yoga and enabled multiplexer tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    if (b.lazyDependency("ghostty", .{ .target = target, .optimize = optimize })) |ghostty| {
        const imports: []const std.Build.Module.Import = &.{
            std.Build.Module.Import{ .name = "zigui", .module = mod },
            .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
            .{ .name = "objc", .module = b.dependency("zig_objc", .{ .target = target, .optimize = optimize }).module("objc") },
        };
        const terminal = b.addExecutable(.{ .name = "terminal", .root_module = b.createModule(.{
            .root_source_file = b.path("examples/terminal/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
            .link_libc = true,
        }) });
        b.installArtifact(terminal);
        const run_terminal = b.addRunArtifact(terminal);
        if (b.args) |args| run_terminal.addArgs(args);
        b.step("run-terminal", "Run the terminal example").dependOn(&run_terminal.step);
        const terminal_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("examples/terminal/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
            .link_libc = true,
        }) });
        b.step("test-terminal", "Test the terminal model and real PTY").dependOn(&b.addRunArtifact(terminal_tests).step);
    }
    if (b.option(bool, "multiplexer", "Build the persistent QUIC terminal server and CLI") orelse false) {
        const quic = b.lazyDependency("quic", .{ .target = target, .optimize = optimize });
        // Keep the existing terminal example's Ghostty revision unchanged.
        const ghostty = b.lazyDependency("multiplexer_ghostty", .{
            .target = target,
            .optimize = optimize,
            .simd = false,
            .@"vt-features" = "-kitty_graphics",
        });
        if (quic != null and ghostty != null) {
            const root = b.createModule(.{
                .root_source_file = b.path("src/multiplexer/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            // glibc's fortified inline wrappers do not translate under Zig 0.16.
            root.addCMacro("_FORTIFY_SOURCE", "0");
            root.addImport("quic", quic.?.module("quic"));
            root.addImport("ghostty-vt", ghostty.?.module("ghostty-vt"));
            const exe = b.addExecutable(.{ .name = "multiplexer-zig", .root_module = root });
            b.installArtifact(exe);
            const run_multiplexer = b.addRunArtifact(exe);
            if (b.args) |args| run_multiplexer.addArgs(args);
            b.step("run-multiplexer", "Run the multiplexer (-Dmultiplexer=true)").dependOn(&run_multiplexer.step);
            const multiplexer_tests = b.addRunArtifact(b.addTest(.{ .root_module = root }));
            b.step("test-multiplexer", "Test the multiplexer (-Dmultiplexer=true)").dependOn(&multiplexer_tests.step);
            test_step.dependOn(&multiplexer_tests.step);
        }
    }
}
