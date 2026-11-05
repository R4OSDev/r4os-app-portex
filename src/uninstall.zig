//! Portex owns only its binding and unchanged links. SYSUPD owns payload and
//! inventory removal. No directory or user-data sweep is performed.
const std = @import("std");
const r = @import("r4os");
const backend = @import("system_update_engine");
const m = @import("model.zig");
const state = @import("state.zig");
const installation = @import("installation.zig");
const updates = @import("update_queue.zig");
const path = "C:\\R4OS\\DATA\\PORTEX\\REMOVE.JSON";
const lock: [*:0]const u8 = "C:\\R4OS\\DATA\\PORTEX\\INSTALL.LCK";
pub const Intent = struct {
    schema: u32 = 1,
    plan: backend.removal.Plan,
    package_id: []const u8,
    binding: ?m.Binding = null,
    phase: enum { requested, waiting_for_close, backend_removed, completed, cancelled } = .requested,
    retained_links: usize = 0,
    pub fn terminal(self: Intent) bool {
        return self.phase == .completed or self.phase == .cancelled;
    }
    fn validate(self: Intent) !void {
        if (self.schema != 1 or self.package_id.len == 0) return error.RemoveIntent;
        try self.plan.validate();
        if (self.binding) |binding| {
            try binding.validate();
            if (binding.package_type != .application or !std.mem.eql(u8, binding.package_id, self.package_id) or
                !r.r4u_manifest.targetEquals(binding.actual_path, self.plan.target) or
                !std.ascii.eqlIgnoreCase(binding.target, self.plan.name) or
                !std.mem.eql(u8, binding.installed_version, self.plan.version) or
                !std.ascii.eqlIgnoreCase(binding.sha256, &self.plan.previous.sha256)) return error.RemoveBindingChanged;
        }
    }
};
pub fn read(files: *const r.Files, allocator: std.mem.Allocator) !?std.json.Parsed(Intent) {
    const bytes = (try state.readBytes(files, allocator, path, state.max_bytes)) orelse return null;
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Intent, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
fn save(files: *const r.Files, allocator: std.mem.Allocator, intent: Intent) !void {
    try intent.validate();
    const bytes = try std.json.Stringify.valueAlloc(allocator, intent, .{});
    defer allocator.free(bytes);
    try state.writeBytes(files, allocator, path, bytes, state.max_bytes);
}
pub const Progress = struct {
    phase: std.atomic.Value(u8) = .init(0),
    cause: std.atomic.Value(u16) = .init(0),
    pub fn describe(self: *const Progress, buffer: []u8) []const u8 {
        const label: []const u8 = switch (self.phase.load(.acquire)) {
            0 => "Entfernung vorbereiten",
            1 => "App zuerst schliessen, dann Wiederaufnehmen",
            2 => "App entfernt; eigene Verknuepfungen abgleichen",
            3 => "App entfernt; Nutzerdaten bleiben erhalten",
            4 => "Entfernung vor Dateiaenderung abgebrochen",
            6 => "App entfernt; geaenderte Links und Nutzerdaten erhalten",
            else => "Entfernung nicht abgeschlossen",
        };
        const cause = self.cause.load(.acquire);
        return if (cause == 0) label else std.fmt.bufPrint(buffer, "{s}: {s}", .{ @errorName(@errorFromInt(cause)), label }) catch label;
    }
};
pub const Job = struct {
    app: *r.App,
    allocator: std.mem.Allocator,
    target: ?[]const u8 = null,
    name: []const u8 = "",
    version: []const u8 = "",
    package_id: []const u8 = "",
    resuming: bool = false,
    cancel: bool = false,
    stop: r.app_contract.StopFlag = .{},
    progress: Progress = .{},
    failure: ?anyerror = null,
    pub fn entry(raw: u64) callconv(.c) i32 {
        const self: *Job = @ptrFromInt(raw);
        self.run() catch |err| {
            self.failure = err;
            self.progress.cause.store(@intFromError(err), .release);
            self.progress.phase.store(5, .release);
        };
        return 0;
    }
    fn run(self: *Job) !void {
        const files = self.app.files() orelse return error.FilesUnavailable;
        const ctx = self.app.system();
        if (ctx.fileStreamBegin(lock, r.abi.file_stream_open_create | r.r4sys.file_stream_open_lease) != 0) return error.RemoveBusy;
        defer _ = ctx.fileStreamAbort(lock);
        if (ctx.fileStreamFinish(lock, 0, r.r4sys.file_stream_finish_keep_ownership) != 0) return error.RemoveBusy;
        if (try installation.pending(&files, self.allocator)) return error.InstallationPending;
        const queue = try updates.read(&files, self.allocator);
        defer if (queue) |value| value.deinit();
        if (queue) |value| if (!value.value.completed()) return error.UpdateQueuePending;
        const saved = try read(&files, self.allocator);
        defer if (saved) |value| value.deinit();
        var intent: Intent = undefined;
        var request_hash: [64]u8 = undefined;
        const bindings = try state.load(&files, self.allocator, state.default_path);
        defer bindings.deinit();
        if (self.resuming) {
            intent = if (saved) |value| value.value else return error.RemoveIntentMissing;
        } else {
            if (saved) |value| if (!value.value.terminal()) return error.RemovalPending;
            const target = self.target orelse return error.RemoveTarget;
            const scratch = try self.allocator.alloc(u8, 64 * 1024);
            defer self.allocator.free(scratch);
            const original = try backend.asset.system.digest(&ctx, target, scratch);
            const request = try std.json.Stringify.valueAlloc(self.allocator, .{ target, self.name, self.version, original, ctx.ticks(), if (saved) |value| value.value.plan.request_id else "" }, .{});
            defer self.allocator.free(request);
            request_hash = hash(request);
            intent = .{ .plan = .{ .request_id = &request_hash, .target = target, .name = self.name, .version = self.version, .previous = original }, .package_id = self.package_id, .binding = if (bindings.value.find(self.package_id)) |binding| binding.* else null };
            try save(&files, self.allocator, intent);
        }
        if (intent.terminal()) {
            self.progress.phase.store(if (intent.phase == .completed) 3 else 4, .release);
            return;
        }
        if (intent.binding) |binding| {
            if (bindings.value.find(intent.package_id)) |current| try sameBinding(self.allocator, binding, current.*) else if (intent.phase != .backend_removed) return error.RemoveBindingChanged;
        }
        if (self.cancel) self.stop.request();
        if (intent.phase != .backend_removed) {
            var engine = backend.Engine.init(self.app);
            const outcome = try engine.removeApplication(intent.plan, &self.stop);
            intent.phase = switch (outcome.state) {
                .waiting_for_close => .waiting_for_close,
                .removed => .backend_removed,
                .cancelled => .cancelled,
            };
            try save(&files, self.allocator, intent);
            self.progress.phase.store(switch (outcome.state) {
                .waiting_for_close => 1,
                .removed => 2,
                .cancelled => 4,
            }, .release);
            if (outcome.state != .removed) return;
        }
        if (intent.binding) |binding| {
            for (binding.links) |link| {
                // A binding's path alone never authorizes deleting changed or
                // foreign link bytes. The atomic native gate closes the read /
                // delete race after the full SHA check.
                const bytes = (state.readBytes(&files, self.allocator, link.path, 4096) catch |err| {
                    if (err != error.BindingSize) return err;
                    intent.retained_links += 1;
                    continue;
                }) orelse continue;
                defer self.allocator.free(bytes);
                if (!std.ascii.eqlIgnoreCase(&hash(bytes), link.sha256)) {
                    intent.retained_links += 1;
                    continue;
                }
                const link_path = try r.AbsoluteFilePath.parse(link.path);
                if (!std.ascii.startsWithIgnoreCase(link_path.bytes(), "C:\\R4OS\\DESKTOP\\") or !std.ascii.endsWithIgnoreCase(link_path.bytes(), ".LNK")) return error.RemoveLinkScope;
                var checksum: u32 = 2166136261;
                for (bytes) |byte| checksum = (checksum ^ byte) *% 16777619;
                if (ctx.fileDeleteIfMatch(link_path.asZ().ptr, bytes.len, checksum) < 0) return error.RemoveLinkChanged;
                if ((try backend.asset.system.info(&ctx, link.path)) != null) return error.RemoveLinkReadback;
            }
            const latest = try state.load(&files, self.allocator, state.default_path);
            defer latest.deinit();
            if (latest.value.find(intent.package_id)) |current| {
                try sameBinding(self.allocator, binding, current.*);
                var kept: std.ArrayList(m.Binding) = .empty;
                defer kept.deinit(self.allocator);
                for (latest.value.bindings) |item| if (!std.mem.eql(u8, item.package_id, intent.package_id)) {
                    try kept.append(self.allocator, item);
                };
                try state.save(&files, self.allocator, state.default_path, .{ .bindings = kept.items });
            }
        }
        intent.phase = .completed;
        try save(&files, self.allocator, intent);
        self.progress.phase.store(if (intent.retained_links == 0) 3 else 6, .release);
    }
};
fn sameBinding(allocator: std.mem.Allocator, old: m.Binding, current: m.Binding) !void {
    const old_bytes = try std.json.Stringify.valueAlloc(allocator, old, .{});
    defer allocator.free(old_bytes);
    const new_bytes = try std.json.Stringify.valueAlloc(allocator, current, .{});
    defer allocator.free(new_bytes);
    if (!std.mem.eql(u8, old_bytes, new_bytes)) return error.RemoveBindingChanged;
}
fn hash(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
