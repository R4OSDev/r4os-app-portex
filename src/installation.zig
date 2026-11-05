//! Durable Portex orchestration. The SDK Engine alone changes application
//! payloads and MODULES.JSON; R4STD alone defines R4LNK bytes.
const std = @import("std");
const r = @import("r4os");
const backend = @import("system_update_engine");
const shortcut = @import("r4std").shortcut;
const m = @import("model.zig");
const state = @import("state.zig");
const catalog = @import("catalog_client.zig");
const download = @import("download.zig");
const job_path = "C:\\R4OS\\DATA\\PORTEX\\JOB.JSON";
const lock_path: [*:0]const u8 = "C:\\R4OS\\DATA\\PORTEX\\INSTALL.LCK";
pub const Phase = enum(u8) { downloading, recording, installing, linking, binding, installed, failed, cancelled };
pub const Progress = struct {
    phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.downloading)),
    cause: std.atomic.Value(u16) = .init(0),
    fn set(self: *Progress, value: Phase) void {
        self.phase.store(@intFromEnum(value), .release);
    }
    pub fn describe(self: *const Progress, buffer: []u8) []const u8 {
        const phase: Phase = @enumFromInt(self.phase.load(.acquire));
        const label = switch (phase) {
            .downloading => "Originaldatei laden und pruefen",
            .recording => "Installationsauftrag sichern",
            .installing => "Update-Backend installiert",
            .linking => "Desktop-Verknuepfung erstellen",
            .binding => "Tatsaechlichen Bestand zuordnen",
            .installed => "Installation und Zuordnung bestaetigt",
            .failed => "Installation nicht abgeschlossen",
            .cancelled => "Vor der Installation abgebrochen",
        };
        const cause = self.cause.load(.acquire);
        return if (cause == 0) label else std.fmt.bufPrint(buffer, "{s}: {s}", .{ @errorName(@errorFromInt(cause)), label }) catch label;
    }
};
pub const Intent = struct {
    schema: u32 = 1,
    request: []const u8,
    catalog: download.Plan,
    source: []const u8,
    destination: []const u8,
    version: []const u8,
    size: u64,
    sha256: []const u8,
    previous: ?backend.asset.Digest,
    adopted: bool,
    phase: enum { requested, committed, linked, completed } = .requested,
    backend_generation: u64 = 0,
    last_backend_reason: []const u8 = "",
    link_path: []const u8,
    link_bytes: []const u8,
    link_sha256: []const u8,

    fn plan(self: Intent) backend.asset.Plan {
        return .{ .source = self.source, .target = self.destination, .name = self.catalog.target, .version = self.version, .size = self.size, .sha256 = self.sha256, .previous = self.previous };
    }
    fn validate(self: Intent) !void {
        if (self.schema != 1 or self.catalog.kind != .application or self.request.len != 64 or self.link_sha256.len != 64) return error.InstallIntentInvalid;
        try backend.asset.validate(self.plan());
        const link = try r.AbsoluteFilePath.parse(self.link_path);
        if (!std.ascii.startsWithIgnoreCase(link.bytes(), "C:\\R4OS\\DESKTOP\\") or !std.ascii.endsWithIgnoreCase(link.bytes(), ".LNK")) return error.InstallLinkScope;
        var parsed: shortcut.Shortcut = .{};
        try parsed.loadFromBytes(self.link_bytes);
        const target = try r.AbsoluteFilePath.parse(parsed.targetText());
        const destination = try r.AbsoluteFilePath.parse(self.destination);
        if (!std.mem.eql(u8, target.bytes(), destination.bytes()) or !std.mem.eql(u8, &hash(self.link_bytes), self.link_sha256)) return error.InstallLinkBinding;
    }
};
pub fn readIntent(files: *const r.Files, allocator: std.mem.Allocator) !?std.json.Parsed(Intent) {
    const bytes = (try state.readBytes(files, allocator, job_path, state.max_bytes)) orelse return null;
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Intent, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
pub fn pending(files: *const r.Files, allocator: std.mem.Allocator) !bool {
    const saved = (try readIntent(files, allocator)) orelse return false;
    defer saved.deinit();
    return saved.value.phase != .completed;
}
fn saveIntent(files: *const r.Files, allocator: std.mem.Allocator, value: Intent) !void {
    try value.validate();
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    try state.writeBytes(files, allocator, job_path, bytes, state.max_bytes);
}
pub const Job = struct {
    app: *r.App,
    allocator: std.mem.Allocator,
    download_job: ?download.Job = null,
    stop: r.app_contract.StopFlag = .{},
    destination: ?r.AbsoluteFilePath = null,
    title: []const u8 = "",
    adopt: bool = false,
    resuming: bool = false,
    progress: Progress = .{},
    failure: ?anyerror = null,
    receipt: ?backend.Result = null,

    pub fn entry(raw: u64) callconv(.c) i32 {
        const self: *Job = @ptrFromInt(raw);
        self.run() catch |err| {
            self.failure = err;
            self.progress.cause.store(@intFromError(err), .release);
            self.progress.set(if (err == error.Cancelled) .cancelled else .failed);
            self.logFailure(err);
        };
        return 0;
    }
    fn logFailure(self: *Job, err: anyerror) void {
        const files = self.app.files() orelse return;
        const ctx = self.app.system();
        const log_lock: [*:0]const u8 = "C:\\R4OS\\DATA\\PORTEX\\ILOG.LCK";
        if (ctx.fileStreamBegin(log_lock, r.abi.file_stream_open_create | r.r4sys.file_stream_open_lease) != 0) return;
        defer _ = ctx.fileStreamAbort(log_lock);
        if (ctx.fileStreamFinish(log_lock, 0, r.r4sys.file_stream_finish_keep_ownership) != 0) return;
        const record = std.json.Stringify.valueAlloc(self.allocator, .{ .cause = @errorName(err), .destination = if (self.destination) |path| path.bytes() else null, .resuming = self.resuming, .backend_reason = if (self.receipt) |*result| result.reasonText() else "" }, .{}) catch return;
        defer self.allocator.free(record);
        const line = std.fmt.allocPrint(self.allocator, "{s}\n", .{record}) catch return;
        defer self.allocator.free(line);
        const path = r.AbsoluteFilePath.parse("C:\\R4OS\\DATA\\PORTEX\\INSTALL.LOG") catch return;
        switch (files.info(path.asZ())) {
            .missing => {
                if (files.write(path.asZ(), "") != .bytes) return;
            },
            .value => |v| if (v.is_dir != 0) return,
            .failure => return,
        }
        _ = files.append(path.asZ(), line);
    }
    fn run(self: *Job) !void {
        const files = self.app.files() orelse return error.FilesUnavailable;
        try catalog.cacheDirectory(&files);
        const ctx = self.app.system();
        if (ctx.fileStreamBegin(lock_path, r.abi.file_stream_open_create | r.r4sys.file_stream_open_lease) != 0) return error.InstallBusy;
        defer _ = ctx.fileStreamAbort(lock_path);
        if (ctx.fileStreamFinish(lock_path, 0, r.r4sys.file_stream_finish_keep_ownership) != 0) return error.InstallLock;
        const saved = try readIntent(&files, self.allocator);
        defer if (saved) |value| value.deinit();
        if (self.resuming) {
            const old = saved orelse return error.InstallIntentMissing;
            return self.execute(&files, old.value);
        }
        const destination = self.destination orelse return error.InstallTarget;
        const dl = if (self.download_job) |*value| value else return error.InstallDownloadMissing;
        const request = try std.json.Stringify.valueAlloc(self.allocator, .{ dl.plan, destination.bytes(), self.adopt }, .{});
        defer self.allocator.free(request);
        const request_hash = hash(request);
        if (saved) |value| {
            if (std.mem.eql(u8, value.value.request, &request_hash)) return self.execute(&files, value.value);
            if (value.value.phase != .completed) return error.InstallationPending;
        }
        if (dl.plan.kind != .application) return error.InstallApplicationOnly;
        const existing = switch (files.info(destination.asZ())) {
            .value => true,
            .missing => false,
            .failure => return error.InstallTargetInfo,
        };
        if (existing and !self.adopt) return error.InstallTargetOccupied;
        if (!existing and self.adopt) return error.AssetMissing;
        var source: r.AbsoluteFilePath = undefined;
        if (self.adopt) source = destination else {
            _ = download.Job.entry(@intFromPtr(dl));
            if (dl.result.failure) |err| return err;
            source = dl.result.path orelse return error.InstallDownloadMissing;
        }
        if (self.stop.requested() or dl.stop.requested()) return error.Cancelled;
        const scratch = try self.allocator.alloc(u8, 64 * 1024);
        defer self.allocator.free(scratch);
        const observed = try backend.asset.digest(&files, source, scratch);
        const identity = try backend.asset.inspect(&files, source);
        if (identity.kind != .r4x or !std.ascii.eqlIgnoreCase(identity.nameText(), dl.plan.target)) return error.InstallIdentityMismatch;
        if (!self.adopt and (!backend.asset.matches(observed, dl.plan.size, dl.plan.sha256) or !std.mem.eql(u8, identity.versionText(), dl.plan.version))) return error.InstallIdentityMismatch;
        var link = try shortcut.Shortcut.init(destination.bytes());
        try link.setTitle(if (self.title.len <= shortcut.title_max) self.title else identity.nameText());
        const end = std.mem.lastIndexOfScalar(u8, destination.bytes(), '\\') orelse return error.InstallTarget;
        if (end > 2) try link.setWorkdir(destination.bytes()[0..end]);
        var link_buffer: [4096]u8 = undefined;
        const link_bytes = try link.writeTo(&link_buffer);
        const link_hash = hash(link_bytes);
        const package_hash = hash(dl.plan.package_id);
        var link_path_buffer: [160]u8 = undefined;
        const link_path = try std.fmt.bufPrint(&link_path_buffer, "C:\\R4OS\\DESKTOP\\P{s}.LNK", .{package_hash[0..7]});
        const link_target = try r.AbsoluteFilePath.parse(link_path);
        // A pre-existing link, even with identical bytes, is not ours merely
        // because we could have generated it. Previous bindings prove reuse.
        switch (files.info(link_target.asZ())) {
            .missing => {},
            .failure => return error.InstallLinkInfo,
            .value => {
                const bindings = try state.load(&files, self.allocator, state.default_path);
                defer bindings.deinit();
                const owned = bindings.value.find(dl.plan.package_id) orelse return error.InstallForeignLink;
                var matched = false;
                for (owned.links) |old| if (std.mem.eql(u8, old.path, link_path) and std.mem.eql(u8, old.sha256, &link_hash)) {
                    matched = true;
                };
                if (!matched) return error.InstallForeignLink;
            },
        }
        var intent = Intent{ .request = &request_hash, .catalog = dl.plan, .source = source.bytes(), .destination = destination.bytes(), .version = identity.versionText(), .size = observed.size, .sha256 = &observed.sha256, .previous = if (self.adopt) observed else null, .adopted = self.adopt, .link_path = link_path, .link_bytes = link_bytes, .link_sha256 = &link_hash };
        self.progress.set(.recording);
        try saveIntent(&files, self.allocator, intent);
        // Reparse owned slices: source.bytes()/identity above are stack loans.
        const stable = (try readIntent(&files, self.allocator)) orelse return error.InstallIntentMissing;
        defer stable.deinit();
        intent = stable.value;
        try self.execute(&files, intent);
    }
    fn execute(self: *Job, files: *const r.Files, saved: Intent) !void {
        try saved.validate();
        var intent = saved;
        if (!try installed(files, self.allocator, intent)) {
            if (intent.phase != .requested) return error.InstallCommittedStateChanged;
            if (self.stop.requested()) return error.Cancelled;
            self.progress.set(.installing);
            var engine = backend.Engine.init(self.app);
            var result = try engine.installAsset(intent.plan());
            if (result.exit_code != 0 and std.mem.eql(u8, result.reasonText(), "resume-required")) result = try engine.resumeAsset(intent.plan());
            self.receipt = result;
            if (result.exit_code != 0 or result.state != .installed or !result.inventory_consistent) {
                intent.last_backend_reason = result.reasonText();
                try saveIntent(files, self.allocator, intent);
                if (std.mem.eql(u8, result.reasonText(), "asset-target-changed")) return error.InstallTargetChanged;
                if (std.mem.eql(u8, result.reasonText(), "program-running")) return error.InstallProgramRunning;
                return error.InstallBackendIncomplete;
            }
            if (!try installed(files, self.allocator, intent)) return error.InstallReadback;
            intent.backend_generation = result.transaction_generation;
        }
        intent.phase = .committed;
        intent.last_backend_reason = "";
        try saveIntent(files, self.allocator, intent);
        self.progress.set(.linking);
        try publishLink(files, self.allocator, intent);
        intent.phase = .linked;
        try saveIntent(files, self.allocator, intent);
        self.progress.set(.binding);
        const old = try state.load(files, self.allocator, state.default_path);
        defer old.deinit();
        var bindings: std.ArrayList(m.Binding) = .empty;
        defer bindings.deinit(self.allocator);
        for (old.value.bindings) |value| if (!std.mem.eql(u8, value.package_id, intent.catalog.package_id)) try bindings.append(self.allocator, value);
        const exact_asset = !intent.adopted or (std.mem.eql(u8, intent.version, intent.catalog.version) and intent.size == intent.catalog.size and std.ascii.eqlIgnoreCase(intent.sha256, intent.catalog.sha256));
        const owned_links = [_]m.Link{.{ .path = intent.link_path, .sha256 = intent.link_sha256 }};
        try bindings.append(self.allocator, .{ .package_id = intent.catalog.package_id, .package_type = .application, .target = intent.catalog.target, .installed_version = intent.version, .release_id = if (exact_asset) intent.catalog.release_id else null, .asset_id = if (exact_asset) intent.catalog.asset_id else null, .sha256 = intent.sha256, .actual_path = intent.destination, .links = &owned_links });
        try state.save(files, self.allocator, state.default_path, .{ .bindings = bindings.items });
        intent.phase = .completed;
        try saveIntent(files, self.allocator, intent);
        self.progress.set(.installed);
    }
};
fn installed(files: *const r.Files, allocator: std.mem.Allocator, intent: Intent) !bool {
    const target = try r.AbsoluteFilePath.parse(intent.destination);
    if (files.info(target.asZ()) == .missing) return false;
    const observed = backend.asset.inspect(files, target) catch return false;
    if (observed.kind != .r4x or !std.ascii.eqlIgnoreCase(observed.nameText(), intent.catalog.target) or !std.mem.eql(u8, observed.versionText(), intent.version)) return false;
    const scratch = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(scratch);
    if (!backend.asset.matches(try backend.asset.digest(files, target, scratch), intent.size, intent.sha256)) return false;
    const bytes = (try state.readBytes(files, allocator, "C:\\R4OS\\CONFIG\\MODULES.JSON", r.system_update_inventory.max_bytes)) orelse return false;
    defer allocator.free(bytes);
    const inventory = try allocator.create(r.system_update_inventory.Inventory);
    defer allocator.destroy(inventory);
    if (!r.system_update_inventory.Inventory.parse(bytes, inventory)) return error.InventoryInvalid;
    var canonical: [1024]u8 = undefined;
    const path = r.r4u_manifest.canonicalInventoryTarget(&canonical, intent.destination) orelse return error.InstallTarget;
    for (inventory.entries[0..inventory.count]) |entry| if (entry.kind == .r4x and std.ascii.eqlIgnoreCase(entry.name, intent.catalog.target) and r.r4u_manifest.targetEquals(entry.target, path) and std.mem.eql(u8, entry.version, intent.version)) return true;
    return false;
}
fn publishLink(files: *const r.Files, allocator: std.mem.Allocator, intent: Intent) !void {
    const target = try r.AbsoluteFilePath.parse(intent.link_path);
    try backend.asset.ensureParents(files, try r.AbsoluteFilePath.parse("C:\\R4OS\\DESKTOP"));
    if (try state.readBytes(files, allocator, intent.link_path, 4096)) |current| {
        defer allocator.free(current);
        if (!std.mem.eql(u8, current, intent.link_bytes)) return error.InstallForeignLink;
        return;
    }
    var stage_buffer: [160]u8 = undefined;
    const stage = try r.AbsoluteFilePath.parse(try std.fmt.bufPrint(&stage_buffer, "{s}.NEW", .{intent.link_path[0 .. intent.link_path.len - 4]}));
    var backup_buffer: [160]u8 = undefined;
    const backup = try r.AbsoluteFilePath.parse(try std.fmt.bufPrint(&backup_buffer, "{s}.BAK", .{intent.link_path[0 .. intent.link_path.len - 4]}));
    if (try state.readBytes(files, allocator, stage.bytes(), 4096)) |old| {
        defer allocator.free(old);
        if (!std.mem.eql(u8, old, intent.link_bytes)) return error.InstallLinkStageConflict;
    } else {
        var writer = switch (files.streamWriter(stage.asZ(), r.abi.file_stream_open_create)) {
            .writer => |v| v,
            else => return error.InstallLinkStage,
        };
        var complete = false;
        defer if (!complete) {
            _ = writer.abort();
        };
        if (writer.write(intent.link_bytes) != .ok or writer.finish() != .ok) return error.InstallLinkStage;
        complete = true;
    }
    if (files.replaceAtomic(target.asZ(), stage.asZ(), backup.asZ(), .{ .require_target_absent = true }) != .ok) return error.InstallLinkPublish;
    const actual = (try state.readBytes(files, allocator, intent.link_path, 4096)) orelse return error.InstallLinkReadback;
    defer allocator.free(actual);
    if (!std.mem.eql(u8, actual, intent.link_bytes)) return error.InstallLinkReadback;
}
fn hash(bytes: []const u8) [64]u8 {
    var value: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &value, .{});
    return std.fmt.bytesToHex(value, .lower);
}
