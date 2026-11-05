//! Original assets only. A ready receipt requires a complete file readback.
const std = @import("std");
const r = @import("r4os");
const m = @import("model.zig");
const state = @import("state.zig");
const catalog = @import("catalog_client.zig");
const policy = @import("catalog_policy.zig");
const Allocator = std.mem.Allocator;
const root = "C:\\R4OS\\DATA\\PORTEX\\DOWNLOADS";
const lock_path = root ++ "\\DOWNLOAD.LCK";
pub const Phase = enum(u8) { idle, connecting, downloading, retrying, verifying, ready, failed, cancelled };

/// Slices borrow one immutable catalog until the worker really joins.
/// Encoding includes every field; a different origin/profile/release gets
/// a different private filename and can never append to this asset.
pub const Plan = struct {
    schema: u32 = 1,
    origin: []const u8,
    profile: []const u8,
    package_id: []const u8,
    kind: m.Kind,
    target: []const u8,
    version: []const u8,
    release_id: []const u8,
    commit: []const u8,
    asset_id: []const u8,
    name: []const u8,
    size: u64,
    sha256: []const u8,
    download_url: []const u8,

    pub fn init(package: m.Package, origin: []const u8, profile: []const u8) !Plan {
        try package.validate();
        const asset = package.artifact().?;
        // Existing R4SYS filesystem offsets are u32. Reject before effects.
        if (asset.size_bytes > std.math.maxInt(u32)) return error.AssetTooLarge;
        var url: [1024]u8 = undefined;
        _ = try resolve(origin, asset.download_url, &url);
        return .{ .origin = origin, .profile = profile, .package_id = package.package_id, .kind = package.package_type, .target = package.target, .version = package.version, .release_id = package.release.id, .commit = package.release.commit, .asset_id = asset.asset_id, .name = asset.name, .size = asset.size_bytes, .sha256 = asset.sha256, .download_url = asset.download_url };
    }
    pub fn encode(self: Plan, allocator: Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }
};

pub fn resolve(origin: []const u8, url: []const u8, output: []u8) ![]const u8 {
    const base = switch (r.http.parseUrl(origin)) {
        .value => |v| v,
        else => return error.InvalidOrigin,
    };
    if (base.scheme != .https or std.mem.indexOfAny(u8, url, "\r\n\t\\#") != null) return error.InvalidDownloadUrl;
    const resolved = switch (r.http.resolveRedirect(base, url, output)) {
        .url => |v| v,
        else => return error.InvalidDownloadUrl,
    };
    const parsed = switch (r.http.parseUrl(resolved)) {
        .value => |v| v,
        else => return error.InvalidDownloadUrl,
    };
    if (parsed.scheme != .https or parsed.port != base.port or !std.ascii.eqlIgnoreCase(parsed.host, base.host)) return error.DownloadOriginChanged;
    return resolved;
}

pub const Progress = struct {
    phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.idle)),
    done: std.atomic.Value(u64) = .init(0),
    rate: std.atomic.Value(u64) = .init(0),
    retries: std.atomic.Value(u8) = .init(0),
    http: std.atomic.Value(u16) = .init(0),
    cause: std.atomic.Value(u16) = .init(0),
    network: std.atomic.Value(u16) = .init(0),
    total: u64 = 0, // Published before createThread; never changes during work.

    pub fn set(self: *Progress, phase: Phase) void {
        self.phase.store(@intFromEnum(phase), .release);
    }
    pub fn current(self: *const Progress) Phase {
        return @enumFromInt(self.phase.load(.acquire));
    }
    pub fn failure(self: *Progress, err: anyerror) void {
        self.cause.store(@intFromError(err), .release);
    }
    pub fn describe(self: *const Progress, buffer: []u8) []const u8 {
        const phase = self.current();
        const label = switch (phase) {
            .idle => "Bereit",
            .connecting => "Verbinden",
            .downloading => "Download",
            .retrying => "Wiederholung",
            .verifying => "SHA-256 pruefen",
            .ready => "Geprueft; bereit zur Installation",
            .failed => "Download fehlgeschlagen",
            .cancelled => "Vom Nutzer abgebrochen",
        };
        const cause = self.cause.load(.acquire);
        const network = self.network.load(.acquire);
        var http: [24]u8 = undefined;
        const status = self.http.load(.acquire);
        const suffix = if (status == 0) "" else std.fmt.bufPrint(&http, " | HTTP {d}", .{status}) catch "";
        return std.fmt.bufPrint(buffer, "{s}{s}{s}{s}{s}{s}", .{ label, if (cause == 0) "" else " | ", if (cause == 0) "" else @errorName(@errorFromInt(cause)), if (network == 0) "" else ": ", if (network == 0) "" else @tagName(@as(r.app_web.Error, @enumFromInt(network - 1))), suffix }) catch label;
    }
    pub fn counts(self: *const Progress, buffer: []u8) []const u8 {
        const done = @min(self.done.load(.acquire), self.total);
        const rate = self.rate.load(.acquire);
        const unit: u64 = if (rate >= 1024 * 1024) 1024 * 1024 else 1024;
        const percent: u64 = if (self.total == 0) 0 else @intCast(@as(u128, done) * 100 / self.total);
        return std.fmt.bufPrint(buffer, "{d}/{d} B | {d}% | {d}.{d} {s}/s | Retry {d}/3", .{ done, self.total, percent, rate / unit, rate % unit * 10 / unit, if (unit == 1024) "KB" else "MB", self.retries.load(.acquire) }) catch "Downloadfortschritt";
    }
};

pub const Head = enum { accept, restart, range_end, retry, register, reject };
/// The same pre-write decision is used by native HTTP and owner fixtures.
pub fn head(plan: Plan, observation: r.app_web.DownloadHeadObservation) !Head {
    const response = observation.response;
    switch (response.status) {
        401 => return .register,
        429, 503 => return .retry,
        416 => {
            const range = response.content_range orelse return error.RangeMissing;
            if (range.satisfied or range.total != plan.size) return error.RangeMismatch;
            return .range_end;
        },
        200, 206 => {},
        403 => return error.ServerBlocked,
        404 => return error.AssetUnavailable,
        409 => return error.ServerConflict,
        else => return error.UnexpectedHttpStatus,
    }
    const tag = policy.header(observation.headers, "ETag") orelse return error.MissingEtag;
    const checksum = policy.header(observation.headers, "X-Checksum-SHA256") orelse return error.MissingChecksum;
    if (tag.len != 66 or tag[0] != '"' or tag[65] != '"' or !std.ascii.eqlIgnoreCase(tag[1..65], plan.sha256) or !std.ascii.eqlIgnoreCase(checksum, plan.sha256)) return error.AssetMetadataChanged;
    if (response.transfer != .content_length) return error.ContentLengthMissing;
    if (response.status == 200) {
        if (response.content_length != plan.size or response.content_range != null) return error.LengthMismatch;
        return if (observation.requested_offset == 0) .accept else .restart;
    }
    const range = response.content_range orelse return error.RangeMissing;
    if (observation.requested_offset == 0 or !range.satisfied or range.start != observation.requested_offset or range.start >= plan.size or range.total != plan.size or range.end != plan.size - 1 or response.content_length != plan.size - range.start) return error.RangeMismatch;
    return .accept;
}

pub const Attempt = union(enum) { complete, restart, range_end: u64, http: u16, failure: r.app_web.Error, invalid: anyerror };
pub fn retryable(err: r.app_web.Error) bool {
    return switch (err) {
        .dns_timeout, .dns_failed, .connect_timeout, .connect_failed, .write_failed, .read_failed, .read_timeout, .read_reset, .read_peer_closed, .tls_close_notify => true,
        else => false,
    };
}

/// One bounded policy over HTTP and transport retries. Store checkpoints are
/// durable; only a successful full readback can return from this function.
pub fn receive(driver: anytype, store: anytype, plan: Plan, progress: *Progress) !void {
    var retries: u8 = 0;
    var registered = false;
    var reset = false;
    while (true) {
        if (driver.cancelled()) return error.Cancelled;
        const offset = try store.size();
        progress.done.store(offset, .release);
        if (offset == plan.size) {
            progress.set(.verifying);
            if (try store.verify()) return;
            return error.HashMismatch;
        }
        if (offset > plan.size) return error.PartialSizeInvalid;
        progress.set(.connecting);
        const response = driver.request(store, plan, offset);
        switch (response) {
            .complete => {
                if (try store.size() != plan.size) return error.LengthMismatch;
                progress.set(.verifying);
                if (!try store.verify()) return error.HashMismatch;
                return;
            },
            .restart, .range_end => {
                if (response == .range_end and response.range_end != plan.size) return error.RangeMismatch;
                if (try store.size() == plan.size) {
                    progress.set(.verifying);
                    if (try store.verify()) return;
                    return error.HashMismatch;
                }
                if (reset) return error.RangeRestartRepeated;
                reset = true;
                try store.reset();
                progress.done.store(0, .release);
                continue;
            },
            .invalid => |err| return err,
            .http => |status| {
                progress.http.store(status, .release);
                if (status == 401 and !registered) {
                    registered = true;
                    try driver.authenticate(true);
                    continue;
                }
                if (status != 429 and status != 503) return error.HttpRejected;
                progress.failure(error.ServerTemporarilyUnavailable);
            },
            .failure => |err| {
                progress.network.store(@as(u16, @intFromEnum(err)) + 1, .release);
                if (driver.cancelled() or err == .cancelled) return error.Cancelled;
                if (!retryable(err)) return error.TransportRejected;
                progress.failure(error.ConnectionInterrupted);
            },
        }
        if (retries == 3) return error.RetriesExhausted;
        retries += 1;
        progress.retries.store(retries, .release);
        progress.rate.store(0, .release);
        progress.set(.retrying);
        driver.delay(@as(u32, 250) << @as(u5, @intCast(retries - 1)));
    }
}

pub const Result = struct {
    path: ?r.AbsoluteFilePath = null,
    failure: ?anyerror = null,
    log_error: ?anyerror = null,
};
pub const Job = struct {
    app: *r.App,
    allocator: Allocator,
    plan: Plan,
    stop: r.app_contract.StopFlag = .{},
    progress: Progress = .{},
    result: Result = .{},

    pub fn entry(raw: u64) callconv(.c) i32 {
        const self: *Job = @ptrFromInt(raw);
        self.run() catch |err| {
            self.result.failure = err;
            self.progress.failure(err);
            self.progress.set(if (err == error.Cancelled) .cancelled else .failed);
        };
        var message: [384]u8 = undefined;
        var description: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&message, "asset={s} {s}", .{ self.plan.asset_id, self.progress.describe(&description) }) catch "Download result could not be formatted";
        // Includes failures before a cache/lease exists. No secrets, response
        // headers or credential-bearing URLs enter the shared log service.
        _ = self.app.system().logServiceWrite(if (self.result.failure == null) r.abi.log_severity_info else r.abi.log_severity_warn, "Portex", text);
        return 0;
    }
    fn run(self: *Job) anyerror!void {
        const files = self.app.files() orelse return error.FilesUnavailable;
        try catalog.cacheDirectory(&files);
        const directory = try r.AbsoluteFilePath.parse(root);
        switch (files.info(directory.asZ())) {
            .missing => if (files.createDirectory(directory.asZ()) != .ok) return error.DownloadDirectory,
            .value => |info| if (info.is_dir == 0) return error.DownloadDirectory,
            .failure => return error.DownloadDirectory,
        }
        const sys = self.app.system();
        if (sys.fileStreamBegin(lock_path, r.abi.file_stream_open_create | r.r4sys.file_stream_open_lease) != 0) return error.DownloadBusy;
        defer _ = sys.fileStreamAbort(lock_path);
        if (sys.fileStreamFinish(lock_path, 0, r.r4sys.file_stream_finish_keep_ownership) != 0) return error.DownloadLock;
        var store = try Store.open(files, self.allocator, self.plan, &self.stop, &self.progress);
        defer store.deinit();
        defer self.saveLog(&files, &store) catch |err| {
            self.result.log_error = err;
        };
        errdefer |err| {
            // Interrupted bytes remain resumable. A known corrupt complete
            // object is discarded; another attempt still needs user action.
            if (err == error.HashMismatch) _ = files.delete(store.part.asZ());
            self.progress.failure(err);
            self.progress.set(if (err == error.Cancelled) .cancelled else .failed);
        }
        const scratch = try self.allocator.alloc(u8, r.app_web.tls_scratch_bytes);
        defer self.allocator.free(scratch);
        const raw = try self.allocator.alloc(u8, r.http.max_header_bytes);
        defer self.allocator.free(raw);
        const io = try self.allocator.alloc(u8, 64 * 1024);
        defer self.allocator.free(io);
        var session = try catalog.open(self.app, &self.stop, raw, &.{}, scratch);
        if (!std.mem.eql(u8, session.origin(), self.plan.origin) or !std.mem.eql(u8, session.profileName(), self.plan.profile)) return error.ServerTargetChanged;
        var driver = Driver{ .session = &session, .io = io, .progress = &self.progress };
        try driver.authenticate(false);
        try receive(&driver, &store, self.plan, &self.progress);
        self.result.path = store.part;
        self.progress.cause.store(0, .release);
        self.progress.network.store(0, .release);
        self.progress.set(.ready);
    }
    fn saveLog(self: *Job, files: *const r.Files, store: *const Store) !void {
        const log = try std.json.Stringify.valueAlloc(self.allocator, .{
            .schema = @as(u32, 1),
            .package_id = self.plan.package_id,
            .release_id = self.plan.release_id,
            .asset_id = self.plan.asset_id,
            .phase = @tagName(self.progress.current()),
            .done = self.progress.done.load(.acquire),
            .total = self.plan.size,
            .http_status = self.progress.http.load(.acquire),
            .retries = self.progress.retries.load(.acquire),
            .cause = if (self.progress.cause.load(.acquire) == 0) "" else @errorName(@errorFromInt(self.progress.cause.load(.acquire))),
            .transport = if (self.progress.network.load(.acquire) == 0) "" else @tagName(@as(r.app_web.Error, @enumFromInt(self.progress.network.load(.acquire) - 1))),
        }, .{});
        defer self.allocator.free(log);
        try state.writeBytes(files, self.allocator, store.log.bytes(), log, 4096);
    }
};

const Store = struct {
    files: r.Files,
    allocator: Allocator,
    plan: Plan,
    part: r.AbsoluteFilePath,
    log: r.AbsoluteFilePath,
    stop: *r.app_contract.StopFlag,
    progress: *Progress,

    fn open(files: r.Files, allocator: Allocator, plan: Plan, stop: *r.app_contract.StopFlag, progress: *Progress) !Store {
        const metadata = try plan.encode(allocator);
        defer allocator.free(metadata);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(metadata, &digest, .{});
        const key = std.fmt.bytesToHex(digest, .lower);
        var name: [256]u8 = undefined;
        const directory = try r.AbsoluteFilePath.parse(try std.fmt.bufPrint(&name, "{s}\\{s}", .{ root, key }));
        switch (files.info(directory.asZ())) {
            .missing => if (files.createDirectory(directory.asZ()) != .ok) return error.DownloadDirectory,
            .value => |info| if (info.is_dir == 0) return error.DownloadDirectory,
            .failure => return error.DownloadDirectory,
        }
        // Atomic stage/backup leaves retain the native short-name contract.
        const part = try r.AbsoluteFilePath.parse(try std.fmt.bufPrint(&name, "{s}\\ASSET.PRT", .{directory.bytes()}));
        const meta = try r.AbsoluteFilePath.parse(try std.fmt.bufPrint(&name, "{s}\\ASSET.JSN", .{directory.bytes()}));
        const log = try r.AbsoluteFilePath.parse(try std.fmt.bufPrint(&name, "{s}\\STATUS.LOG", .{directory.bytes()}));
        const old = try state.readBytes(&files, allocator, meta.bytes(), 16384);
        defer if (old) |bytes| allocator.free(bytes);
        if (old) |bytes| {
            if (!std.mem.eql(u8, metadata, bytes)) return error.PartialIdentityChanged;
        } else {
            if (files.info(part.asZ()) != .missing) return error.UnownedPartial;
            try state.writeBytes(&files, allocator, meta.bytes(), metadata, 16384);
        }
        var store = Store{ .files = files, .allocator = allocator, .plan = plan, .part = part, .log = log, .stop = stop, .progress = progress };
        if (files.info(part.asZ()) == .missing) try store.reset();
        return store;
    }
    fn deinit(_: *Store) void {}
    fn size(self: *Store) !u64 {
        return switch (self.files.info(self.part.asZ())) {
            .value => |v| if (v.is_dir == 0) v.size else error.PartialIsDirectory,
            else => error.PartialRead,
        };
    }
    fn reset(self: *Store) !void {
        // Only our exact sidecar binding under the exclusive lease reaches here.
        switch (self.files.write(self.part.asZ(), "")) {
            .bytes => |n| if (n != 0) return error.PartialWrite,
            else => return error.PartialWrite,
        }
    }
    fn append(self: *Store, offset: u64, bytes: []const u8) !void {
        if (self.stop.requested()) return error.Cancelled;
        if (offset != try self.size() or offset > self.plan.size or bytes.len > self.plan.size - offset) return error.PartialOffset;
        switch (self.files.append(self.part.asZ(), bytes)) {
            .bytes => |n| if (n != bytes.len) return error.PartialWrite,
            else => return error.PartialWrite,
        }
        if (try self.size() != offset + bytes.len) return error.PartialWrite;
        self.progress.done.store(offset + bytes.len, .release);
    }
    fn verify(self: *Store) !bool {
        if (try self.size() != self.plan.size) return false;
        const buffer = try self.allocator.alloc(u8, 64 * 1024);
        defer self.allocator.free(buffer);
        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        var offset: u64 = 0;
        while (offset < self.plan.size) {
            if (self.stop.requested()) return error.Cancelled;
            const output = buffer[0..@intCast(@min(buffer.len, self.plan.size - offset))];
            const count = switch (self.files.readAt(self.part.asZ(), @intCast(offset), output)) {
                .bytes => |n| n,
                else => return error.PartialRead,
            };
            if (count != output.len) return error.PartialRead;
            sha.update(output);
            offset += count;
        }
        const actual = std.fmt.bytesToHex(sha.finalResult(), .lower);
        return std.ascii.eqlIgnoreCase(&actual, self.plan.sha256) and try self.size() == self.plan.size;
    }
};

const Driver = struct {
    session: *catalog.Native,
    io: []u8,
    progress: *Progress,
    decision: ?Head = null,
    invalid: ?anyerror = null,
    status: u16 = 0,
    plan: Plan = undefined,
    store: *Store = undefined,
    started: u64 = 0,
    started_bytes: u64 = 0,

    fn cancelled(self: *Driver) bool {
        return self.session.cancelled();
    }
    fn authenticate(self: *Driver, retry: bool) !void {
        if (self.session.authenticate(retry)) |failure| {
            if (failure.transport) |transport| self.progress.network.store(@as(u16, @intFromEnum(transport)) + 1, .release);
            return switch (failure.reason) {
                .cancelled => error.Cancelled,
                .registration_credentials => error.RegistrationCredentialsMissing,
                .registration_unavailable => error.RegistrationServiceUnavailable,
                .registration_response => error.RegistrationResponseInvalid,
                .configuration => error.ServerTargetChanged,
                else => error.RegistrationFailed,
            };
        }
    }
    fn delay(self: *Driver, ms: u32) void {
        self.session.delay(ms);
    }
    fn allow(raw: ?*anyopaque, url: []const u8) bool {
        const self: *Driver = @ptrCast(@alignCast(raw.?));
        var expected: [1024]u8 = undefined;
        const exact = resolve(self.plan.origin, self.plan.download_url, &expected) catch return false;
        return std.mem.eql(u8, exact, url);
    }
    fn observe(raw: ?*anyopaque, observation: r.app_web.DownloadHeadObservation) bool {
        const self: *Driver = @ptrCast(@alignCast(raw.?));
        self.status = observation.response.status;
        self.progress.http.store(self.status, .release);
        self.decision = head(self.plan, observation) catch |err| {
            self.invalid = err;
            return false;
        };
        return self.decision == .accept or self.decision == .range_end;
    }
    fn write(raw: ?*anyopaque, offset: u64, bytes: []const u8) bool {
        const self: *Driver = @ptrCast(@alignCast(raw.?));
        self.store.append(offset, bytes) catch |err| {
            self.invalid = err;
            return false;
        };
        self.progress.set(.downloading);
        const sys = self.session.app.system();
        const elapsed = sys.ticks() -| self.started;
        if (elapsed != 0) self.progress.rate.store(@intCast(@min(std.math.maxInt(u64), @as(u128, offset + bytes.len - self.started_bytes) * sys.monotonicHz() / elapsed)), .release);
        return !self.cancelled();
    }
    fn request(self: *Driver, store: *Store, plan: Plan, offset: u64) Attempt {
        self.plan = plan;
        self.store = store;
        self.decision = null;
        self.invalid = null;
        self.status = 0;
        self.started = self.session.app.system().ticks();
        self.started_bytes = offset;
        self.progress.rate.store(0, .release);
        var url: [1024]u8 = undefined;
        const exact = resolve(plan.origin, plan.download_url, &url) catch |err| return .{ .invalid = err };
        var headers: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&headers, "Accept:application/octet-stream\nIf-Range:\"{s}\"\n", .{plan.sha256}) catch return .{ .invalid = error.RequestHeaders };
        var web = self.session.app.web() orelse return .{ .invalid = error.HttpsUnavailable };
        const response = web.download(exact, self.session.raw, self.io, self.session.scratch, .{ .context = self, .write_fn = write }, .{
            .headers = text,
            .expected_size = plan.size,
            .resume_from = offset,
            .max_retries = 0,
            .redirect_limit = 0,
            .stop = &self.session.stop.storage,
            .timeout = r.time_contract.timeoutFinite(r.time_contract.durationFromNanoseconds(120_000_000_000)),
            .head_observer = observe,
            .head_context = self,
            .target_authorizer = allow,
            .target_authorization_context = self,
        });
        if (self.invalid) |err| return .{ .invalid = err };
        if (self.decision) |decision| switch (decision) {
            .restart => return .restart,
            .retry, .register => return .{ .http = self.status },
            else => {},
        };
        return switch (response) {
            .response => |v| if (v.secure and std.mem.eql(u8, v.final_url.bytes(), exact) and (v.status == 200 or v.status == 206) and v.total_size == plan.size) .complete else .{ .invalid = error.DownloadResponseMismatch },
            .range_not_satisfiable => |n| .{ .range_end = n },
            .failure => |err| .{ .failure = err },
        };
    }
};
