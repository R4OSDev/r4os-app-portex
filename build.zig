const std = @import("std");

pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    const libraries_build = sdk_build.systemLibrariesBuild(sdk_dep) orelse return;
    const libraries_dep = sdk_dep.builder.dependencyFromBuildZig(libraries_build, .{});
    _ = sdk.addR4MFWithOptions(b.path("module.R4MF"), .{ .zig_module_roots = &.{ sdk_dep.namedLazyPath("system_update_engine"), libraries_dep.namedLazyPath("r4std_zig_binding") } });
    const host = sdk.createR4osModule(b.graph.host, .Debug);
    const engine = b.createModule(.{ .root_source_file = sdk_dep.namedLazyPath("system_update_engine"), .target = b.graph.host, .optimize = .Debug });
    engine.addImport("r4os", host);
    const tests = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = b.graph.host });
    tests.addImport("r4os", host);
    tests.addImport("system_update_engine", engine);
    const standard = b.createModule(.{ .root_source_file = libraries_dep.namedLazyPath("r4std_zig_binding"), .target = b.graph.host, .optimize = .Debug });
    standard.addImport("r4os", host);
    tests.addImport("r4std", standard);
    const provider = b.createModule(.{ .root_source_file = libraries_dep.path("R4STD/Source/main.zig"), .target = b.graph.host, .optimize = .Debug });
    provider.addImport("r4os", host);
    const implementation = b.createModule(.{ .root_source_file = libraries_dep.path("R4STD/Contract/Generated/implementation_abi.zig"), .target = b.graph.host, .optimize = .Debug });
    implementation.addImport("r4os", host);
    provider.addImport("r4l_contract", implementation);
    const runtime = b.createModule(.{ .root_source_file = libraries_dep.path("R4STD/Tests/consumer_runtime.zig"), .target = b.graph.host, .optimize = .Debug });
    runtime.addImport("r4os", host);
    runtime.addImport("r4std", standard);
    runtime.addImport("provider", provider);
    tests.addImport("r4std_test", runtime);
    b.step("test", "Portex catalog identities, durable bindings and job receipts")
        .dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tests })).step);
}
