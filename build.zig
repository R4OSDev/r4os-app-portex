const std = @import("std");

pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));
    const tests = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = b.graph.host });
    tests.addImport("r4os", sdk.createR4osModule(b.graph.host, .Debug));
    b.step("test", "Portex catalog identities, durable bindings and job receipts")
        .dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tests })).step);
}
