const std = @import("std");
const m = @import("model.zig");
const j = @import("job.zig");
const allocator = std.testing.allocator;
const sha = "a" ** 64;
const state = @import("state.zig");
const client = @import("catalog_client.zig");
const cache = @import("catalog_cache.zig");
const policy = @import("catalog_policy.zig");
const view = @import("view.zig");
const download = @import("download.zig");
const updates = @import("update_queue.zig");

test "update selection includes all kinds and preserves actual renamed paths; stale and unavailable are not authorization" {
    const r = @import("r4os");
    const load = @import("load_job.zig");
    var snapshot: load.Snapshot = .{};
    defer snapshot.deinit();
    snapshot.result.snapshot = try cache.Snapshot.init(allocator, "https://138.201.253.143:4022", "public", "\"updates\"", example_catalog);
    snapshot.result.snapshot.?.fresh = true;
    const catalog_value = snapshot.result.snapshot.?.catalog;
    const inventory = try allocator.create(r.system_update_inventory.Inventory);
    defer allocator.destroy(inventory);
    inventory.* = .{ .count = 3 };
    var paths: [3][1024]u8 = undefined;
    for (catalog_value.packages, 0..) |p, i| {
        const target = switch (p.package_type) {
            .application => "/Manual/CUSTOM.R4X",
            .library => try std.fmt.bufPrint(&paths[i], "/R4OS/LIBS/{s}.R4L", .{p.target}),
            .kernel => "/boot/r4os.elf",
        };
        inventory.entries[i] = .{ .name = p.target, .kind = switch (p.package_type) { .application => .r4x, .library => .r4l, .kernel => .kernel }, .version = "0.0.1", .target = target };
    }
    snapshot.projection = try view.Projection.build(allocator, catalog_value, .{}, inventory, true);
    const all = try updates.select(allocator, &snapshot, null);
    defer allocator.free(all);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    var kinds = [_]bool{false} ** 3;
    for (all) |item| {
        kinds[@intFromEnum(item.plan.kind)] = true;
        if (item.plan.kind == .application) try std.testing.expectEqualStrings("C:\\Manual\\CUSTOM.R4X", item.destination);
    }
    try std.testing.expect(kinds[0] and kinds[1] and kinds[2]);
    const one = try updates.select(allocator, &snapshot, 1);
    defer allocator.free(one);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqual(m.Kind.library, one[0].plan.kind);
    snapshot.projection.?.rows[0].status = .unavailable;
    const available = try updates.select(allocator, &snapshot, null);
    defer allocator.free(available);
    try std.testing.expectEqual(@as(usize, 2), available.len);
    snapshot.result.snapshot.?.fresh = false;
    try std.testing.expectError(error.UpdateSelectionUnavailable, updates.select(allocator, &snapshot, null));
}

test "durable update queue retains per-package success and rejects changed frozen targets or downgrades" {
    var plan = try download.Plan.init(package(), "https://138.201.253.143:4022", "public");
    var items = [_]updates.Item{.{ .frozen = .{ .selection = .{ .plan = plan, .destination = "D:\\Manual\\CUSTOM.R4X", .title = "Original selection", .installed_version = "0.1.9" }, .previous = .{ .size = 10, .sha256 = @splat('c'), .checksum = 42 } }, .status = .installed }, undefined, undefined };
    items[1] = items[0];
    items[1].frozen.selection.plan.package_id = "second";
    items[1].frozen.selection.destination = "D:\\Manual\\SECOND.R4X";
    items[1].status = .failed;
    items[1].failure = "ConnectionInterrupted";
    items[2] = items[0];
    items[2].frozen.selection.plan.package_id = "third";
    items[2].frozen.selection.destination = "D:\\Manual\\THIRD.R4X";
    items[2].status = .queued;
    var id = try updates.identity(allocator, &items);
    const queue = updates.Queue{ .id = &id, .items = &items };
    try queue.validate(allocator);
    try std.testing.expectEqual(@as(?usize, 1), queue.current());
    try std.testing.expectEqual(@as(usize, 1), queue.installedCount());
    var disk: Disk = .{};
    try updates.save(&disk, allocator, queue);
    var reopened = (try updates.read(&disk, allocator)).?;
    defer reopened.deinit();
    try std.testing.expectEqual(@as(?usize, 1), reopened.value.current());
    try std.testing.expectEqualStrings("ConnectionInterrupted", reopened.value.items[1].failure.?);
    items[1].status = .working;
    items[1].failure = null;
    try queue.validate(allocator); // Mutable outcome never changes selection.
    disk.fail_commit = true;
    try std.testing.expectError(error.BindingCommit, updates.save(&disk, allocator, queue));
    disk.fail_commit = false;
    try updates.save(&disk, allocator, queue);
    items[1].frozen.selection.destination = "D:\\Foreign\\SECOND.R4X";
    try std.testing.expectError(error.UpdateQueueChanged, queue.validate(allocator));
    items[1].frozen.selection.destination = "D:\\Manual\\SECOND.R4X";
    plan.version = "0.1.8";
    items[1].frozen.selection.plan = plan;
    id = try updates.identity(allocator, &items);
    try std.testing.expectError(error.UpdateNotNewer, queue.validate(allocator));
    std.testing.refAllDecls(updates.Job);
}

test "original artifact adapter checks create-only plans without adding dependency admission" {
    const engine = @import("system_update_engine");
    try engine.asset.validate(.{ .source = "C:\\TEMP\\ORIG.R4X", .target = "D:\\Games\\Grüße\\APP.R4X", .name = "APP", .version = "0.1.0", .size = 12, .sha256 = sha });
    try std.testing.expectError(error.AssetPlan, engine.asset.validate(.{ .source = "C:\\TEMP\\ORIG.R4X", .target = "C:\\BOOT\\APP.R4X", .name = "APP", .version = "0.1.0", .size = 12, .sha256 = sha }));
    std.testing.refAllDecls(engine.Engine);
    std.testing.refAllDecls(@import("installation.zig").Job);
    std.testing.refAllDecls(@import("uninstall.zig").Job);
    std.testing.refAllDecls(@import("load_job.zig"));
    std.testing.refAllDecls(@import("download_buffer.zig"));
}

test "installation uses the real R4STD link writer and preserves a chosen Unicode target" {
    try @import("r4std_test").ensure();
    const shortcut = @import("r4std").shortcut;
    const target = "D:\\Software\\Grüße\\MINESWEEPER_665F9DD0.R4X";
    var link = try shortcut.Shortcut.init(target);
    try link.setTitle("Minesweeper");
    try link.setWorkdir("D:\\Software\\Grüße");
    var buffer: [4096]u8 = undefined;
    const bytes = try link.writeTo(&buffer);
    var parsed: shortcut.Shortcut = .{};
    try parsed.loadFromBytes(bytes);
    try std.testing.expectEqualStrings(target, parsed.targetText());
    try std.testing.expectEqualStrings("D:\\Software\\Grüße", parsed.workdirText());
}

test "download head validates immutable metadata and full or resumed lengths before writing" {
    var p = package();
    const plan = try download.Plan.init(p, "https://138.201.253.143:4022", "public");
    var headers: [200]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&headers, "ETag: \"{s}\"\r\nX-Checksum-SHA256: {s}\r\n", .{ sha, sha });
    var h = @import("r4os").app_web.DownloadHeadObservation{ .headers = bytes, .requested_offset = 0, .response = .{ .status = 200, .transfer = .content_length, .content_length = 12, .location = null, .content_type = null, .content_range = null } };
    try std.testing.expectEqual(download.Head.accept, try download.head(plan, h));
    h.requested_offset = 3;
    try std.testing.expectEqual(download.Head.restart, try download.head(plan, h));
    h.response.status = 206;
    h.response.content_length = 9;
    h.response.content_range = .{ .satisfied = true, .start = 3, .end = 11, .total = 12 };
    try std.testing.expectEqual(download.Head.accept, try download.head(plan, h));
    h.response.content_range.?.start = 4;
    try std.testing.expectError(error.RangeMismatch, download.head(plan, h));
    h.response.status = 416;
    h.response.content_range = .{ .satisfied = false, .start = 0, .end = 0, .total = 12 };
    try std.testing.expectEqual(download.Head.range_end, try download.head(plan, h));
    h.response.content_range.?.total = 13;
    try std.testing.expectError(error.RangeMismatch, download.head(plan, h));
    h.response.status = 200;
    h.requested_offset = 0;
    h.response.content_range = null;
    h.response.content_length = 11;
    try std.testing.expectError(error.LengthMismatch, download.head(plan, h));
    h.response.content_length = 12;
    h.headers = "ETag: \"wrong\"\r\nX-Checksum-SHA256: wrong\r\n";
    try std.testing.expectError(error.AssetMetadataChanged, download.head(plan, h));
    h.response.status = 403;
    try std.testing.expectError(error.ServerBlocked, download.head(plan, h));
    var resolved: [512]u8 = undefined;
    try std.testing.expectError(error.DownloadOriginChanged, download.resolve(plan.origin, "https://example.org/asset", &resolved));
    try std.testing.expectError(error.DownloadOriginChanged, download.resolve(plan.origin, "http://138.201.253.143:4022/asset", &resolved));
    const first = try plan.encode(allocator);
    defer allocator.free(first);
    p.release.id = "999";
    const changed = try (try download.Plan.init(p, plan.origin, plan.profile)).encode(allocator);
    defer allocator.free(changed);
    try std.testing.expect(!std.mem.eql(u8, first, changed));
}

const DownloadStoreFixture = struct {
    bytes: [12]u8 = @splat(0),
    length: usize = 0,
    valid: bool = true,
    resets: usize = 0,
    checks: usize = 0,
    pub fn size(self: *@This()) !u64 {
        return self.length;
    }
    pub fn reset(self: *@This()) !void {
        self.length = 0;
        self.resets += 1;
    }
    pub fn verify(self: *@This()) !bool {
        self.checks += 1;
        return self.valid and self.length == 12 and std.mem.eql(u8, &self.bytes, "Hello World!");
    }
};
const DownloadDriverFixture = struct {
    attempts: []const download.Attempt,
    offsets: [8]u64 = @splat(0),
    calls: usize = 0,
    registrations: usize = 0,
    delays: usize = 0,
    stopped: bool = false,
    shortened: bool = false,
    pub fn cancelled(self: *@This()) bool {
        return self.stopped;
    }
    pub fn authenticate(self: *@This(), _: bool) !void {
        self.registrations += 1;
    }
    pub fn delay(self: *@This(), _: u32) void {
        self.delays += 1;
    }
    pub fn request(self: *@This(), store: *DownloadStoreFixture, _: download.Plan, offset: u64) download.Attempt {
        self.offsets[self.calls] = offset;
        const attempt = self.attempts[self.calls];
        self.calls += 1;
        const amount: usize = if (attempt == .complete) (if (self.shortened) 11 else 12) else if (attempt == .failure and download.retryable(attempt.failure)) @min(12, store.length + 3) else store.length;
        @memcpy(store.bytes[store.length..amount], "Hello World!"[store.length..amount]);
        store.length = amount;
        return attempt;
    }
};
test "download transaction resumes, restarts, reconciles ranges and bounds failure and cancellation" {
    const plan = try download.Plan.init(package(), "https://138.201.253.143:4022", "public");
    var progress = download.Progress{ .total = 12 };
    var store = DownloadStoreFixture{};
    var driver = DownloadDriverFixture{ .attempts = &.{ .{ .failure = .read_peer_closed }, .complete } };
    try download.receive(&driver, &store, plan, &progress);
    try std.testing.expectEqualSlices(u64, &.{ 0, 3 }, driver.offsets[0..2]);
    try std.testing.expect(store.checks == 1 and driver.delays == 1);
    for ([_]download.Attempt{ .restart, .{ .range_end = 12 } }) |first| {
        store = .{ .length = 3 };
        @memcpy(store.bytes[0..3], "Hel");
        driver = .{ .attempts = &.{ first, .complete } };
        try download.receive(&driver, &store, plan, &progress);
        try std.testing.expectEqualSlices(u64, &.{ 3, 0 }, driver.offsets[0..2]);
        try std.testing.expectEqual(@as(usize, 1), store.resets);
    }
    store = .{ .valid = false };
    driver = .{ .attempts = &.{.complete} };
    try std.testing.expectError(error.HashMismatch, download.receive(&driver, &store, plan, &progress));
    store = .{};
    driver = .{ .attempts = &.{.complete}, .shortened = true };
    try std.testing.expectError(error.LengthMismatch, download.receive(&driver, &store, plan, &progress));
    store = .{};
    driver = .{ .attempts = &.{ .{ .http = 503 }, .{ .failure = .read_reset }, .{ .http = 429 }, .{ .http = 503 } } };
    try std.testing.expectError(error.RetriesExhausted, download.receive(&driver, &store, plan, &progress));
    try std.testing.expect(driver.calls == 4 and driver.delays == 3);
    store = .{};
    driver = .{ .attempts = &.{.{ .failure = .tls_certificate_root_rejected }} };
    try std.testing.expectError(error.TransportRejected, download.receive(&driver, &store, plan, &progress));
    try std.testing.expect(driver.calls == 1 and driver.delays == 0);
    driver = .{ .attempts = &.{}, .stopped = true };
    try std.testing.expectError(error.Cancelled, download.receive(&driver, &store, plan, &progress));
    try std.testing.expectEqual(@as(usize, 0), driver.calls);
    driver = .{ .attempts = &.{ .{ .http = 401 }, .{ .http = 401 } } };
    try std.testing.expectError(error.HttpRejected, download.receive(&driver, &store, plan, &progress));
    try std.testing.expectEqual(@as(usize, 1), driver.registrations);
    progress.done.store(6, .release);
    progress.rate.store(1536 * 1024, .release);
    progress.retries.store(2, .release);
    var text: [256]u8 = undefined;
    try std.testing.expectEqualStrings("6/12 B | 50% | 1.5 MB/s | Retry 2/3", progress.counts(&text));
}

test "GUI Unicode scalars with command-like low bytes stay text; CR and LF remain Enter" {
    const r = @import("r4os");
    const ui = @import("ui.zig");
    for ([_]u32{ 0x109, 0x10a, 0x10d, 0x11b, 0x1f60d }) |codepoint| {
        try std.testing.expectEqual(@as(u8, 0), ui.navigationKey(.{ .window_id = 1, .key = @truncate(codepoint), .codepoint = codepoint, .modifiers = 0, .tick = 0 }));
    }
    for ([_]u8{ '\r', '\n' }) |key| try std.testing.expectEqual(r.gui.Key.enter, ui.navigationKey(.{ .window_id = 1, .key = key, .codepoint = key, .modifiers = 0, .tick = 0 }));
    try std.testing.expectEqual(r.gui.Key.ctrl_a, ui.navigationKey(.{ .window_id = 1, .key = 1, .codepoint = 1, .modifiers = 0, .tick = 0 }));
}

fn package() m.Package {
    return .{ .package_id = "gh-123-APP", .package_type = .application, .target = "APP", .format = .R4X, .display_name = "A new name", .category = "Tools", .version = "0.1.10", .release = .{ .id = "18446744073709551617", .tag = "v0.1.10", .commit = "b" ** 40 }, .installation = .{ .role = .application, .path = "C:\\Changed", .path_kind = .directory, .activation = .client_managed, .requires_client_plan = false }, .assets = &.{.{ .asset_id = "18446744073709551618", .name = "APP.R4X", .role = "artifact", .size_bytes = 12, .sha256 = sha, .download_url = "/api/v1/packages/gh-123-APP/files/18446744073709551618" }} };
}
fn binding() m.Binding {
    return .{ .package_id = "gh-123-APP", .package_type = .application, .target = "APP", .installed_version = "0.1.9", .release_id = "10", .asset_id = "20", .sha256 = sha, .actual_path = "C:\\Chosen\\APP.R4X" };
}

test "owned GUI projection preserves real paths, stale state and local/unavailable packages" {
    const r = @import("r4os");
    const inventory = try allocator.create(r.system_update_inventory.Inventory);
    defer allocator.destroy(inventory);
    inventory.* = .{ .count = 3 };
    inventory.entries[0] = .{ .name = "APP", .kind = .r4x, .version = "0.1.9", .target = "/Chosen/APP.R4X" };
    inventory.entries[1] = .{ .name = "KERNEL", .kind = .kernel, .version = "0.1.458", .target = "/boot/r4os.elf" };
    inventory.entries[2] = .{ .name = "SSHD", .kind = .r4x, .version = "0.1.0", .target = "/R4OS/SERVICES/SSHD.R4X" };
    var later = package();
    later.display_name = "Zeta";
    var first = package();
    first.package_id = "gh-555-OTHER";
    first.target = "OTHER";
    first.display_name = "Alpha";
    var projection = try view.Projection.build(allocator, .{ .schema_version = 1, .packages = &.{ later, first }, .unavailable = &.{.{ .package_id = "gh-900-MISSING", .reason = "local_files_unavailable" }} }, .{ .bindings = &.{binding()} }, inventory, false);
    defer projection.deinit();
    try std.testing.expect(!projection.fresh and projection.inventory_known);
    try std.testing.expectEqual(@as(usize, 4), projection.rows.len); // Services are not store apps.
    try std.testing.expectEqualStrings("Alpha", projection.rows[0].name);
    const zeta = projection.rows[3];
    try std.testing.expectEqual(view.Status.update, zeta.status);
    try std.testing.expectEqualStrings("C:\\Chosen\\APP.R4X", zeta.actual_path.?);
    try std.testing.expectEqualStrings("C:\\Chosen\\APP.R4X", zeta.proposed_path.?);
    try std.testing.expect(zeta.visible(.updates, .application, null, "ZeTa"));
    try std.testing.expect(!zeta.visible(.discover, .library, null, ""));
    try std.testing.expect(!zeta.visible(.installed, .application, "Games", ""));
    try std.testing.expectEqual(view.Status.unavailable, projection.rows[1].status);
    try std.testing.expectEqual(view.Status.local, projection.rows[2].status);
    try std.testing.expectEqualStrings("/boot/r4os.elf", projection.rows[2].actual_path.?);
    try std.testing.expect(projection.rows[1].kind == null);
    var unknown = try view.Projection.build(allocator, .{ .schema_version = 1, .packages = &.{later}, .unavailable = &.{} }, .{ .bindings = &.{binding()} }, null, true);
    defer unknown.deinit();
    try std.testing.expectEqual(view.Status.unverified, unknown.rows[0].status);
    try std.testing.expect(!unknown.inventory_known);
}

test "new destinations use client path rules, preserve original filename and never guess a boot target" {
    const p = package();
    const standard = try view.resolveNew(p, null);
    try std.testing.expectEqualStrings("C:\\Changed\\APP.R4X", standard.bytes());
    const custom = try view.resolveNew(p, "D:\\Software\\Grüße");
    try std.testing.expectEqualStrings("D:\\Software\\Grüße\\APP.R4X", custom.bytes());
    try std.testing.expectError(error.ExpectedAbsolute, view.resolveNew(p, "relative"));
    try std.testing.expectError(error.RootTraversal, view.resolveNew(p, "C:\\..\\Other"));
    var library = p;
    library.package_type = .library;
    library.format = .R4L;
    var asset = p.assets[0];
    asset.name = "APP.R4L";
    library.assets = &.{asset};
    library.installation = .{ .role = .runtime_library, .path = "/R4OS/LIBS/APP.R4L", .path_kind = .file, .activation = .client_managed, .requires_client_plan = false };
    const target = try view.resolveNew(library, null);
    try std.testing.expectEqualStrings("C:\\R4OS\\LIBS\\APP.R4L", target.bytes());
    try std.testing.expectError(error.OriginalFilenameRequired, view.resolveNew(library, "D:\\LIBS\\OTHER.R4L"));
    library.package_type = .kernel;
    try std.testing.expectError(error.BootPlanRequired, view.resolveNew(library, "C:\\guessed.elf"));
}

test "unimplemented, busy and stale GUI actions remain disabled; uninstall is app-only" {
    const absent = j.Capabilities{};
    try std.testing.expect(!absent.allows(.install, true, false, false, true, false));
    const enabled = j.Capabilities{ .install = true, .update = true, .uninstall = true, .update_all = true };
    try std.testing.expect(enabled.allows(.install, true, false, false, true, false));
    try std.testing.expect(!enabled.allows(.install, false, false, false, true, false));
    try std.testing.expect(!enabled.allows(.update, true, true, true, true, true));
    try std.testing.expect(!enabled.allows(.update, true, false, true, true, false));
    try std.testing.expect(!enabled.allows(.uninstall, true, false, true, false, false));
    try std.testing.expect(enabled.allows(.uninstall, false, false, true, true, false));
}

test "catalog identity and numeric versions survive rename, changed paths and large string IDs" {
    const p = package();
    try p.validate();
    const json = try std.json.Stringify.valueAlloc(allocator, m.Catalog{ .schema_version = 1, .packages = &.{p}, .unavailable = &.{} }, .{});
    defer allocator.free(json);
    const parsed = try m.Catalog.parse(allocator, json);
    defer parsed.deinit();
    const saved = try (m.Bindings{ .bindings = &.{binding()} }).encode(allocator);
    defer allocator.free(saved);
    const reopened = try m.Bindings.parse(allocator, saved);
    defer reopened.deinit();
    const b = reopened.value.find(p.package_id).?.*;
    try std.testing.expect(m.updateAvailable(parsed.value.packages[0], b));
    try std.testing.expectEqualStrings("18446744073709551617", parsed.value.packages[0].release.id);
    try std.testing.expectEqualStrings("C:\\Chosen\\APP.R4X", try m.destination(p, b, "C:\\Other"));
    try std.testing.expect(!b.matchesInventory(.{ .name = "OTHER", .kind = .r4x, .version = b.installed_version, .target = b.actual_path }));
    try std.testing.expect(!b.matchesInventory(.{ .name = "APP", .kind = .r4x, .version = "0.1.8", .target = b.actual_path }));
    try std.testing.expect(b.matchesInventory(.{ .name = "APP", .kind = .r4x, .version = b.installed_version, .target = b.actual_path }));
    try std.testing.expect(b.matchesInventory(.{ .name = "APP", .kind = .r4x, .version = b.installed_version, .target = "/Chosen/APP.R4X" }));
    try std.testing.expect(!b.matchesInventory(.{ .name = "APP", .kind = .r4x, .version = b.installed_version, .target = "D:\\Chosen\\APP.R4X" }));
}

test "all package types retain their own destination and boot activation rules" {
    var p = package();
    try std.testing.expectEqualStrings("C:\\Custom", try m.destination(p, null, "C:\\Custom"));
    p.package_type = .library;
    p.format = .R4L;
    p.installation = .{ .role = .runtime_library, .path = "/R4OS/LIBS/TEST.R4L", .path_kind = .file, .activation = .client_managed, .requires_client_plan = false };
    try p.validate();
    try std.testing.expectEqualStrings("/R4OS/LIBS/TEST.R4L", try m.destination(p, null, null));
    p.package_type = .kernel;
    p.format = .ELF;
    p.installation = .{ .role = .boot_kernel, .path = null, .path_kind = .file, .activation = .boot_configuration, .requires_client_plan = true };
    try p.validate();
    try std.testing.expectError(error.BootPlanRequired, m.destination(p, null, "/guessed"));
    p.installation.requires_client_plan = false;
    try std.testing.expectError(error.MissingClientPlan, p.validate());
}

test "bad schemas, ambiguous artifacts, duplicate bindings and partial JSON never become empty success" {
    try std.testing.expectError(error.UnsupportedSchema, m.Catalog.parse(allocator, "{\"schema_version\":2,\"packages\":[],\"unavailable\":[]}"));
    try std.testing.expectError(error.UnexpectedEndOfInput, m.Bindings.parse(allocator, "{"));
    try std.testing.expectError(error.MissingField, m.Bindings.parse(allocator, "{}"));
    try std.testing.expectError(error.MissingField, m.Bindings.parse(allocator, "{\"schema_version\":1}"));
    try std.testing.expectError(error.DuplicateBinding, (m.Bindings{ .bindings = &.{ binding(), binding() } }).validate());
    var p = package();
    p.assets = &.{ p.assets[0], p.assets[0] };
    try std.testing.expectError(error.InvalidArtifact, p.validate());
}

test "cancel requests and stale worker receipts cannot report durable installation completion" {
    const token: j.Token = .{ .request = 1, .process = 17, .generation = 4 };
    var job: j.Job = .{ .token = token };
    try std.testing.expect(!job.observe(token, .{ .backend_job = 0, .phase = .installed }));
    try std.testing.expect(job.observe(token, .{ .backend_job = 9, .phase = .staging }));
    job.requestCancel();
    try std.testing.expectEqual(j.Phase.staging, job.phase);
    try std.testing.expect(!job.observe(.{ .request = 1, .process = 17, .generation = 5 }, .{ .backend_job = 9, .phase = .installed }));
    try std.testing.expect(!job.observe(token, .{ .backend_job = 10, .phase = .installed }));
    try std.testing.expect(job.observe(token, .{ .backend_job = 9, .phase = .pending_restart }));
    try std.testing.expect(!job.terminal());
    try std.testing.expect(job.observe(token, .{ .backend_job = 9, .phase = .installed }));
    try std.testing.expect(!job.observe(token, .{ .backend_job = 9, .phase = .downloading }));
}

const Disk = struct {
    current: [32768]u8 = undefined,
    stage: [32768]u8 = undefined,
    backup: [32768]u8 = undefined,
    intent: [512]u8 = undefined,
    current_len: usize = 0,
    stage_len: usize = 0,
    backup_len: usize = 0,
    intent_len: usize = 0,
    fail_commit: bool = false,
    fail_delete: bool = false,
    writes: usize = 0,

    fn staged(path: anytype) bool {
        return std.mem.endsWith(u8, path.bytes(), ".NEW");
    }
    fn slice(self: *Disk, path: anytype) []u8 {
        if (staged(path)) return self.stage[0..self.stage_len];
        if (std.mem.endsWith(u8, path.bytes(), ".BAK")) return self.backup[0..self.backup_len];
        if (std.mem.endsWith(u8, path.bytes(), ".TXN")) return self.intent[0..self.intent_len];
        return self.current[0..self.current_len];
    }
    pub fn info(self: *Disk, path: anytype) union(enum) { value: struct { size: u64, is_dir: u8 = 0 }, missing, failure: i32 } {
        const n = self.slice(path).len;
        return if (n == 0) .missing else .{ .value = .{ .size = n } };
    }
    pub fn read(self: *Disk, path: anytype, out: []u8) union(enum) { bytes: u32, end, failure: i32 } {
        const bytes = self.slice(path);
        if (out.len != bytes.len) return .{ .failure = -1 };
        @memcpy(out, bytes);
        return .{ .bytes = @intCast(bytes.len) };
    }
    const Writer = struct {
        disk: *Disk,
        intent: bool,
        pub fn write(self: *Writer, bytes: []const u8) enum { ok, failure } {
            if (self.intent) {
                if (bytes.len > self.disk.intent.len) return .failure;
                @memcpy(self.disk.intent[0..bytes.len], bytes);
                self.disk.intent_len = bytes.len;
            } else {
                if (bytes.len > self.disk.stage.len) return .failure;
                @memcpy(self.disk.stage[0..bytes.len], bytes);
                self.disk.stage_len = bytes.len;
            }
            self.disk.writes += 1;
            return .ok;
        }
        pub fn finish(_: *Writer) enum { ok, failure } {
            return .ok;
        }
        pub fn abort(self: *Writer) enum { ok, failure } {
            if (self.intent) self.disk.intent_len = 0 else self.disk.stage_len = 0;
            return .ok;
        }
    };
    pub fn streamWriter(self: *Disk, path: anytype, _: u32) union(enum) { writer: Writer, failure: i32 } {
        return .{ .writer = .{ .disk = self, .intent = std.mem.endsWith(u8, path.bytes(), ".TXN") } };
    }
    pub fn delete(self: *Disk, path: anytype) enum { ok, failure } {
        if (self.fail_delete) return .failure;
        if (staged(path)) self.stage_len = 0 else if (std.mem.endsWith(u8, path.bytes(), ".BAK")) self.backup_len = 0 else if (std.mem.endsWith(u8, path.bytes(), ".TXN")) self.intent_len = 0 else return .failure;
        return .ok;
    }
    pub fn replaceAtomic(self: *Disk, _: anytype, stage_path: anytype, backup_path: anytype, _: struct {}) enum { ok, failure } {
        // Preserve the real atomic owner's stage/backup short-name contract.
        for ([_][]const u8{ stage_path.bytes(), backup_path.bytes() }) |path| {
            const start = (std.mem.lastIndexOfScalar(u8, path, '\\') orelse return .failure) + 1;
            const name = path[start..];
            const dot = std.mem.indexOfScalar(u8, name, '.') orelse return .failure;
            if (dot == 0 or dot > 8 or name.len - dot - 1 > 3 or
                std.mem.indexOfScalar(u8, name[dot + 1 ..], '.') != null) return .failure;
        }
        if (self.fail_commit or self.backup_len != 0) return .failure;
        @memcpy(self.backup[0..self.current_len], self.current[0..self.current_len]);
        self.backup_len = self.current_len;
        @memcpy(self.current[0..self.stage_len], self.stage[0..self.stage_len]);
        self.current_len = self.stage_len;
        self.stage_len = 0;
        return .ok;
    }
};

test "binding storage preserves old data on failed commit and resumes its exact completed stage" {
    var disk: Disk = .{};
    const empty = try state.load(&disk, allocator, state.default_path);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.bindings.len);
    try state.save(&disk, allocator, state.default_path, .{});
    const original = try allocator.dupe(u8, disk.current[0..disk.current_len]);
    defer allocator.free(original);
    disk.fail_commit = true;
    try std.testing.expectError(error.BindingCommit, state.save(&disk, allocator, state.default_path, .{ .bindings = &.{binding()} }));
    try std.testing.expectEqualSlices(u8, original, disk.current[0..disk.current_len]);
    const writes = disk.writes;
    disk.fail_commit = false;
    try state.save(&disk, allocator, state.default_path, .{ .bindings = &.{binding()} });
    try std.testing.expectEqual(writes, disk.writes);
    const reopened = try state.load(&disk, allocator, state.default_path);
    defer reopened.deinit();
    try std.testing.expectEqualStrings(binding().actual_path, reopened.value.find(binding().package_id).?.actual_path);
    // A third distinct write used to fail because .BAK was never settled.
    disk.fail_delete = true;
    try std.testing.expectError(error.BindingCleanup, state.save(&disk, allocator, state.default_path, .{}));
    try std.testing.expect(disk.backup_len > 0 and disk.intent_len > 0);
    disk.fail_delete = false;
    try state.save(&disk, allocator, state.default_path, .{});
    try std.testing.expect(disk.backup_len == 0 and disk.intent_len == 0);
    try state.save(&disk, allocator, state.default_path, .{ .bindings = &.{binding()} });
    @memcpy(disk.backup[0..7], "foreign");
    disk.backup_len = 7;
    try std.testing.expectError(error.BindingBackupConflict, state.save(&disk, allocator, state.default_path, .{}));
    try std.testing.expectEqualStrings("foreign", disk.backup[0..disk.backup_len]);
}

const empty_catalog = "{\"schema_version\":1,\"packages\":[],\"unavailable\":[]}";
const example_catalog = @embedFile("Fixtures/catalog-schema1.json");
const FakeTransport = struct {
    statuses: []const u16,
    body: []const u8 = empty_catalog,
    calls: usize = 0,
    auth: usize = 0,
    forced: usize = 0,
    delayed: usize = 0,
    conditional: usize = 0,
    stop: bool = false,

    pub fn origin(_: *FakeTransport) []const u8 {
        return "https://138.201.253.143:4022";
    }
    pub fn profileName(_: *FakeTransport) []const u8 {
        return "public";
    }
    pub fn cancelled(self: *FakeTransport) bool {
        return self.stop;
    }
    pub fn authenticate(self: *FakeTransport, force: bool) ?client.Failure {
        self.auth += 1;
        if (force) self.forced += 1;
        return null;
    }
    pub fn fetch(self: *FakeTransport, etag: ?[]const u8) client.Fetch {
        if (etag != null) self.conditional += 1;
        const code = self.statuses[@min(self.calls, self.statuses.len - 1)];
        self.calls += 1;
        return .{ .response = .{ .status = code, .body = if (code == 401) "{\"error\":\"registration_required\"}" else self.body, .headers = "ETag: \"catalog-v1\"\r\n", .content_type = "application/json", .secure = true } };
    }
    pub fn delay(self: *FakeTransport, _: u32) void {
        self.delayed += 1;
    }
};

test "real schema-1 fixture retains apps, libraries, kernel and persists an origin-bound catalog" {
    var transport = FakeTransport{ .statuses = &.{200}, .body = example_catalog };
    var result = try client.retrieve(&transport, allocator, null);
    defer result.deinit();
    try std.testing.expect(result.failure == null);
    const snapshot = &result.snapshot.?;
    try std.testing.expect(snapshot.fresh and !snapshot.cached);
    try std.testing.expectEqual(@as(usize, 3), snapshot.catalog.packages.len);
    try std.testing.expectEqual(m.Kind.application, snapshot.catalog.packages[0].package_type);
    try std.testing.expectEqual(m.Kind.library, snapshot.catalog.packages[1].package_type);
    try std.testing.expectEqual(m.Kind.kernel, snapshot.catalog.packages[2].package_type);
    var disk: Disk = .{};
    try snapshot.save(&disk, allocator);
    var reopened = (try cache.Snapshot.load(&disk, allocator, transport.origin(), transport.profileName())).?;
    defer reopened.deinit();
    try std.testing.expectEqualStrings(snapshot.body, reopened.body);
    try std.testing.expect(!reopened.fresh and reopened.cached);
    try std.testing.expect(try cache.Snapshot.load(&disk, allocator, "https://172.27.254.3:4022", "lan") == null);
}

test "304 requires the actual validated conditional cache and remains a successful empty catalog" {
    var transport = FakeTransport{ .statuses = &.{304} };
    var previous = try cache.Snapshot.init(allocator, transport.origin(), transport.profileName(), "\"catalog-v1\"", empty_catalog);
    previous.fresh = true;
    var result = try client.retrieve(&transport, allocator, previous);
    defer result.deinit();
    try std.testing.expect(result.failure == null and result.snapshot.?.fresh and result.snapshot.?.cached);
    try std.testing.expectEqual(@as(usize, 1), transport.conditional);
    var missing = try client.retrieve(&transport, allocator, null);
    defer missing.deinit();
    try std.testing.expectEqual(client.Reason.invalid_cache, missing.failure.?.reason);
    try std.testing.expect(missing.snapshot == null);
}

test "401 repeats registration once while 403 never forces registration or discards cached software" {
    var transport = FakeTransport{ .statuses = &.{ 401, 200 } };
    var success = try client.retrieve(&transport, allocator, null);
    defer success.deinit();
    try std.testing.expect(success.failure == null);
    try std.testing.expectEqual(@as(usize, 1), transport.forced);
    transport = .{ .statuses = &.{ 401, 401 } };
    var denied = try client.retrieve(&transport, allocator, null);
    defer denied.deinit();
    try std.testing.expectEqual(@as(usize, 2), transport.calls);
    try std.testing.expectEqual(@as(usize, 1), transport.forced);
    transport = .{ .statuses = &.{403} };
    var previous = try cache.Snapshot.init(allocator, transport.origin(), transport.profileName(), "\"catalog-v1\"", example_catalog);
    previous.fresh = true;
    var blocked = try client.retrieve(&transport, allocator, previous);
    defer blocked.deinit();
    try std.testing.expectEqual(client.Reason.blocked, blocked.failure.?.reason);
    try std.testing.expectEqual(@as(usize, 0), transport.forced);
    try std.testing.expect(!blocked.snapshot.?.fresh and blocked.snapshot.?.catalog.packages.len == 3);
}

test "rate limits, outages and invalid replacement bodies preserve the last good catalog with bounded attempts" {
    var transport = FakeTransport{ .statuses = &.{ 429, 503, 503, 503 } };
    var previous = try cache.Snapshot.init(allocator, transport.origin(), transport.profileName(), "\"catalog-v1\"", example_catalog);
    var outage = try client.retrieve(&transport, allocator, previous);
    defer outage.deinit();
    try std.testing.expectEqual(@as(usize, 4), transport.calls);
    try std.testing.expectEqual(@as(usize, 3), transport.delayed);
    try std.testing.expectEqual(client.Reason.server_error, outage.failure.?.reason);
    try std.testing.expectEqualStrings(example_catalog, outage.snapshot.?.body);
    transport = .{ .statuses = &.{200}, .body = "{}" };
    previous = try cache.Snapshot.init(allocator, transport.origin(), transport.profileName(), "\"catalog-v1\"", example_catalog);
    var invalid = try client.retrieve(&transport, allocator, previous);
    defer invalid.deinit();
    try std.testing.expectEqual(client.Reason.invalid_catalog, invalid.failure.?.reason);
    try std.testing.expectEqualStrings(example_catalog, invalid.snapshot.?.body);
    try std.testing.expect(!policy.validEtag("\"ok\"\r\nInjected:yes"));
    try std.testing.expect(policy.header("ETag: \"a\"\nETag: \"b\"\n", "etag") == null);
}
