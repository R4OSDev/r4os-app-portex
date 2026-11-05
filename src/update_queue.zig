//! Durable explicit update selection. The shared asset owner keeps payloads,
//! inventory, rollback and restart authority; this file only tracks selection.
const std = @import("std");
const r = @import("r4os");
const backend = @import("system_update_engine");
const download = @import("download.zig");
const installation = @import("installation.zig");
const state = @import("state.zig");
pub const path = "C:\\R4OS\\DATA\\PORTEX\\UPDATES.JSON";
pub const Status = enum { queued, working, pending_restart, installed, failed, cancelled };
pub const Selection = struct {
    plan: download.Plan,
    destination: []const u8,
    title: []const u8,
    installed_version: []const u8,
};
/// Selection borrows the immutable snapshot until the worker joins.
/// All updates ignores the current kind/category/search view filters.
pub fn select(allocator: std.mem.Allocator, snapshot: anytype, only: ?usize) ![]Selection {
    if (snapshot.failure != null) return error.UpdateSelectionUnavailable;
    const projection = snapshot.projection orelse return error.UpdateSelectionUnavailable;
    const cached = snapshot.result.snapshot orelse return error.UpdateSelectionUnavailable;
    if (!projection.fresh or !projection.inventory_known or !cached.fresh) return error.UpdateSelectionUnavailable;
    var result: std.ArrayList(Selection) = .empty;
    errdefer result.deinit(allocator);
    for (projection.rows) |row| {
        if (row.status != .update or row.actual_path == null or row.installed_version == null or row.package_index == null) continue;
        if (only) |index| if (row.package_index.? != index) continue;
        const index = row.package_index.?;
        if (index >= cached.catalog.packages.len) return error.UpdateSelectionUnavailable;
        const package = cached.catalog.packages[index];
        try result.append(allocator, .{ .plan = try download.Plan.init(package, cached.origin, cached.profile),
            .destination = row.actual_path.?, .title = package.display_name, .installed_version = row.installed_version.? });
    }
    if (result.items.len == 0) return error.UpdateSelectionEmpty;
    return result.toOwnedSlice(allocator);
}
pub const Frozen = struct {
    selection: Selection,
    previous: backend.asset.Digest,
    boot: ?backend.asset.system.BootProof = null,
};
pub const Item = struct {
    frozen: Frozen,
    status: Status = .queued,
    failure: ?[]const u8 = null,
};
pub const Queue = struct {
    schema: u32 = 1,
    id: []const u8,
    items: []Item,

    pub fn completed(self: Queue) bool {
        for (self.items) |item| if (item.status != .installed) return false;
        return true;
    }
    pub fn current(self: Queue) ?usize {
        for (self.items, 0..) |item, i| if (item.status != .installed) return i;
        return null;
    }
    pub fn installedCount(self: Queue) usize {
        var count: usize = 0;
        for (self.items) |item| if (item.status == .installed) { count += 1; };
        return count;
    }
    pub fn validate(self: Queue, allocator: std.mem.Allocator) !void {
        if (self.schema != 1 or self.items.len == 0 or self.id.len != 64) return error.UpdateQueueInvalid;
        const expected = try identity(allocator, self.items);
        if (!std.mem.eql(u8, self.id, &expected)) return error.UpdateQueueChanged;
        for (self.items, 0..) |item, i| {
            const s = item.frozen.selection;
            if ((r.r4u_manifest.compareVersions(s.plan.version, s.installed_version) orelse return error.UpdateVersion) <= 0) return error.UpdateNotNewer;
            if (!backend.asset.system.targetSupported(installation.componentKind(s.plan.kind), s.destination, s.plan.target) or
                ((s.plan.kind == .kernel) != (item.frozen.boot != null))) return error.UpdateTarget;
            if (item.frozen.previous.size == 0) return error.UpdateOldFile;
            for (self.items[0..i]) |old| if (std.mem.eql(u8, old.frozen.selection.plan.package_id, s.plan.package_id) or
                r.r4u_manifest.targetEquals(old.frozen.selection.destination, s.destination)) return error.UpdateDuplicate;
        }
    }
};
pub fn identity(allocator: std.mem.Allocator, items: []const Item) ![64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("Portex/update-selection/v1\x00");
    for (items) |item| {
        const bytes = try std.json.Stringify.valueAlloc(allocator, item.frozen, .{});
        defer allocator.free(bytes);
        hash.update(bytes);
        hash.update("\x00");
    }
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}
pub fn samePlan(allocator: std.mem.Allocator, left: download.Plan, right: download.Plan) !bool {
    const a = try left.encode(allocator);
    defer allocator.free(a);
    const b = try right.encode(allocator);
    defer allocator.free(b);
    return std.mem.eql(u8, a, b);
}
pub fn bound(allocator: std.mem.Allocator, item: Item, intent: installation.Intent) !bool {
    return try samePlan(allocator, item.frozen.selection.plan, intent.catalog) and
        r.r4u_manifest.targetEquals(item.frozen.selection.destination, intent.destination) and
        intent.previous != null and std.meta.eql(item.frozen.previous, intent.previous.?) and
        std.meta.eql(item.frozen.boot, intent.boot);
}
pub fn read(files: anytype, allocator: std.mem.Allocator) !?std.json.Parsed(Queue) {
    const bytes = (try state.readBytes(files, allocator, path, state.max_bytes)) orelse return null;
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Queue, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate(allocator);
    return parsed;
}
pub fn save(files: anytype, allocator: std.mem.Allocator, value: Queue) !void {
    try value.validate(allocator);
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    try state.writeBytes(files, allocator, path, bytes, state.max_bytes);
}

pub const Progress = struct {
    pub const Phase = enum(u8) { preparing, working, pending_restart, installed, failed, cancelled };
    total: usize = 0, // Fixed before the joined worker starts.
    done: std.atomic.Value(usize) = .init(0),
    current: std.atomic.Value(usize) = .init(0),
    phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.preparing)),
    cause: std.atomic.Value(u16) = .init(0),
    transfer_active: std.atomic.Value(bool) = .init(false),
    bytes: std.atomic.Value(u64) = .init(0),
    byte_total: std.atomic.Value(u64) = .init(0),
    rate: std.atomic.Value(u64) = .init(0),
    retries: std.atomic.Value(u8) = .init(0),
    detail: [256]u8 = @splat(0),
    detail_len: usize = 0,
    pub fn set(self: *Progress, value: Phase) void { self.phase.store(@intFromEnum(value), .release); }
    pub fn describe(self: *const Progress, out: []u8) []const u8 {
        const value: Phase = @enumFromInt(self.phase.load(.acquire));
        const label = switch (value) {
            .preparing => "Auswahl pruefen", .working => "Update ausfuehren",
            .pending_restart => "Neustart erforderlich; restliche Pakete warten",
            .installed => "Alle ausgewaehlten Updates installiert",
            .failed => "Angehalten; erfolgreiche Pakete bleiben erhalten",
            .cancelled => "Abgebrochen; Fortsetzung moeglich",
        };
        const cause = self.cause.load(.acquire);
        if (value == .failed and self.detail_len != 0)
            return std.fmt.bufPrint(out, "{d}/{d} installiert | {s}", .{self.done.load(.acquire), self.total, self.detail[0..self.detail_len]}) catch label;
        return std.fmt.bufPrint(out, "{d}/{d} installiert | Auftrag {d} | {s}{s}{s}", .{
            self.done.load(.acquire), self.total, @min(self.current.load(.acquire) + 1, self.total), label,
            if (cause == 0) "" else " | ", if (cause == 0) "" else @errorName(@errorFromInt(cause)),
        }) catch label;
    }
    fn observe(raw: ?*anyopaque, transfer: *const download.Progress) void {
        const self: *Progress = @ptrCast(@alignCast(raw.?));
        self.bytes.store(transfer.done.load(.acquire), .monotonic);
        self.byte_total.store(transfer.total, .monotonic);
        self.rate.store(transfer.rate.load(.acquire), .monotonic);
        self.retries.store(transfer.retries.load(.acquire), .monotonic);
        self.transfer_active.store(transfer.current() != .ready and transfer.current() != .failed and transfer.current() != .cancelled, .release);
    }
    pub fn counts(self: *const Progress, out: []u8) []const u8 {
        if (!self.transfer_active.load(.acquire)) return "";
        const total = self.byte_total.load(.acquire);
        const done = @min(self.bytes.load(.acquire), total);
        const rate = self.rate.load(.acquire);
        const unit: u64 = if (rate >= 1024 * 1024) 1024 * 1024 else 1024;
        return std.fmt.bufPrint(out, "{d}/{d} B | {d}% | {d}.{d} {s}/s | R{d}/3", .{
            done, total, if (total == 0) 0 else @as(u64, @intCast(@as(u128, done) * 100 / total)),
            rate / unit, rate % unit * 10 / unit, if (unit == 1024) "KB" else "MB", self.retries.load(.acquire),
        }) catch "Downloadfortschritt";
    }
};
const lock_path: [*:0]const u8 = "C:\\R4OS\\DATA\\PORTEX\\QUEUE.LCK";
fn lease(ctx: *const r.r4sys.Context) !void {
    if (ctx.fileStreamBegin(lock_path, r.abi.file_stream_open_create | r.r4sys.file_stream_open_lease) != 0) return error.UpdateQueueBusy;
    if (ctx.fileStreamFinish(lock_path, 0, r.r4sys.file_stream_finish_keep_ownership) != 0) {
        _ = ctx.fileStreamAbort(lock_path);
        return error.UpdateQueueLock;
    }
}
/// Only reconcile a completed own receipt. No download, stage, commit or reboot.
pub fn reconcile(app: *r.App, allocator: std.mem.Allocator) !void {
    const files = app.files() orelse return error.FilesUnavailable;
    const ctx = app.system();
    lease(&ctx) catch |err| { if (err == error.UpdateQueueBusy) return; return err; };
    defer _ = ctx.fileStreamAbort(lock_path);
    const parsed = (try read(&files, allocator)) orelse return;
    defer parsed.deinit();
    var value = parsed.value;
    const index = value.current() orelse return;
    const intent = (try installation.readIntent(&files, allocator)) orelse return;
    defer intent.deinit();
    if (try bound(allocator, value.items[index], intent.value)) {
        const desired: ?Status = if (intent.value.phase == .completed) .installed else if (intent.value.phase == .pending_restart) .pending_restart else if (value.items[index].status == .pending_restart) .queued else null;
        if (desired) |status| if (value.items[index].status != status) {
            value.items[index].status = status;
            if (status == .installed) value.items[index].failure = null;
            try save(&files, allocator, value);
        };
    }
}

pub const Job = struct {
    app: *r.App,
    allocator: std.mem.Allocator,
    selection: ?[]const Selection = null,
    activate: bool = false,
    stop: r.app_contract.StopFlag = .{},
    progress: Progress = .{},
    failure: ?anyerror = null,

    pub fn entry(raw: u64) callconv(.c) i32 {
        const self: *Job = @ptrFromInt(raw);
        self.run() catch |err| {
            self.failure = err;
            self.progress.cause.store(@intFromError(err), .release);
            self.progress.set(if (err == error.Cancelled) .cancelled else .failed);
        };
        return 0;
    }
    fn run(self: *Job) !void {
        const files = self.app.files() orelse return error.FilesUnavailable;
        try @import("catalog_client.zig").cacheDirectory(&files);
        const ctx = self.app.system();
        try lease(&ctx);
        defer _ = ctx.fileStreamAbort(lock_path);
        const old = try read(&files, self.allocator);
        defer if (old) |p| p.deinit();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var id: [64]u8 = undefined;
        var queue: Queue = undefined;
        if (self.selection) |selection| {
            if (old) |p| if (!p.value.completed()) return error.UpdateQueuePending;
            if (selection.len == 0) return error.UpdateSelectionEmpty;
            const items = try a.alloc(Item, selection.len);
            const scratch = try a.alloc(u8, 64 * 1024);
            // Capture every actual old target before the first installation.
            for (selection, 0..) |s, i| {
                if (self.stop.requested()) return error.Cancelled;
                const actual = try backend.asset.system.inspect(&ctx, s.destination);
                if (actual.kind != installation.componentKind(s.plan.kind) or
                    !std.ascii.eqlIgnoreCase(actual.nameText(), s.plan.target) or
                    !std.mem.eql(u8, actual.versionText(), s.installed_version)) return error.UpdateTargetChanged;
                items[i] = .{ .frozen = .{
                    .selection = s,
                    .previous = try backend.asset.system.digest(&ctx, s.destination, scratch),
                    .boot = if (s.plan.kind == .kernel) try backend.asset.system.bootPlan(&ctx) else null,
                } };
            }
            id = try identity(a, items);
            queue = .{ .id = &id, .items = items };
            try save(&files, self.allocator, queue);
        } else queue = (old orelse return error.UpdateQueueMissing).value;
        try queue.validate(self.allocator);
        self.progress.done.store(queue.installedCount(), .release);
        while (queue.current()) |index| {
            var item = &queue.items[index];
            self.progress.current.store(index, .release);
            if (self.stop.requested()) return error.Cancelled;
            const intent = try installation.readIntent(&files, self.allocator);
            defer if (intent) |p| p.deinit();
            var resuming = false;
            if (intent) |p| {
                if (try bound(self.allocator, item.*, p.value)) {
                    if (p.value.phase == .completed) {
                        item.status = .installed;
                        item.failure = null;
                        try save(&files, self.allocator, queue);
                        self.progress.done.store(queue.installedCount(), .release);
                        continue;
                    }
                    resuming = true;
                } else if (p.value.phase != .completed) return error.UpdateForeignInstallation;
            }
            if (self.activate and (!resuming or intent.?.value.phase != .pending_restart)) return error.UpdateNotRestartReady;
            item.status = .working;
            item.failure = null;
            try save(&files, self.allocator, queue);
            self.progress.set(.working);
            const s = item.frozen.selection;
            var child = installation.Job{
                .app = self.app, .allocator = self.allocator,
                .destination = if (s.plan.kind == .kernel) null else try r.AbsoluteFilePath.parse(s.destination),
                .title = s.title, .replace = true, .resuming = resuming, .commit_restart = self.activate,
                .external_stop = &self.stop,
                .expected_previous = item.frozen.previous,
                .expected_version = s.installed_version,
                .expected_boot = item.frozen.boot,
                .download_job = if (resuming) null else .{
                    .app = self.app, .allocator = self.allocator, .plan = s.plan,
                    .external_stop = &self.stop, .progress = .{ .total = s.plan.size, .observer = Progress.observe, .observer_context = &self.progress },
                },
            };
            _ = installation.Job.entry(@intFromPtr(&child));
            self.progress.transfer_active.store(false, .release);
            self.activate = false;
            if (child.failure) |err| {
                item.status = if (err == error.Cancelled) .cancelled else .failed;
                var reason: [512]u8 = undefined;
                const detail = if (child.download_job) |*dl| blk: {
                    const http = dl.progress.http.load(.acquire);
                    if (http >= 400) break :blk try std.fmt.bufPrint(&reason, "HTTP {d}", .{http});
                    const network = dl.progress.network.load(.acquire);
                    if (network != 0) break :blk @tagName(@as(r.app_web.Error, @enumFromInt(network - 1)));
                    break :blk dl.progress.describe(&reason);
                } else if (child.receipt) |*receipt| receipt.reasonText() else "";
                item.failure = try std.fmt.allocPrint(a, "{s}{s}{s}", .{detail, if (detail.len == 0) "" else " | ", @errorName(err)});
                self.progress.detail_len = @min(item.failure.?.len, self.progress.detail.len);
                @memcpy(self.progress.detail[0..self.progress.detail_len], item.failure.?[0..self.progress.detail_len]);
                try save(&files, self.allocator, queue);
                return err;
            }
            if (child.progress.current() == .pending_restart) {
                item.status = .pending_restart;
                try save(&files, self.allocator, queue);
                self.progress.set(.pending_restart);
                return;
            }
            if (child.progress.current() != .installed) return error.UpdateIncomplete;
            item.status = .installed;
            try save(&files, self.allocator, queue);
            self.progress.done.store(queue.installedCount(), .release);
        }
        self.progress.set(.installed);
    }
};

