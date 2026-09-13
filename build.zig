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
    const example = b.addExecutable(.{ .name = "counter", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/counter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigui", .module = mod }},
    }) });
    b.installArtifact(example);
    const run = b.addRunArtifact(example);
    b.step("run", "Run the headless counter example").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run framework and Yoga integration tests").dependOn(&b.addRunArtifact(tests).step);
}
