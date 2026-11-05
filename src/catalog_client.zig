//! Software reads only. Registration and TLS remain shared R4OS owners.
const std = @import("std");
const r4os = @import("r4os");
const cache = @import("catalog_cache.zig");
const policy = @import("catalog_policy.zig");
const Allocator = std.mem.Allocator;
pub const Reason = enum { configuration, registration, registration_credentials, registration_unavailable, registration_response, transport, blocked, unavailable, conflict, unauthorized, invalid_cache, server_error, unexpected_status, invalid_catalog, insecure_response, cancelled, unavailable_web };
pub const Failure = struct {
    reason: Reason,
    http_status: u16 = 0,
    detail: i32 = 0,
    transport: ?r4os.app_web.Error = null,
    cause: ?anyerror = null,
};
pub const Result = struct {
    snapshot: ?cache.Snapshot = null,
    failure: ?Failure = null,
    cache_error: ?anyerror = null,

    pub fn deinit(self: *Result) void {
        if (self.snapshot) |*s| s.deinit();
        self.* = .{};
    }
};
pub const Response = struct { status: u16, body: []const u8, headers: []const u8, content_type: ?[]const u8, secure: bool };
pub const Fetch = union(enum) { response: Response, failure: Failure };

fn retain(previous: *?cache.Snapshot, failure: Failure) Result {
    if (previous.*) |*snapshot| snapshot.fresh = false;
    const result = Result{ .snapshot = previous.*, .failure = failure };
    previous.* = null;
    return result;
}

/// Same policy is exercised by owner fixtures and the real SDK adapter.
/// Consumes previous, including on failure. A stale view never means uninstall.
pub fn retrieve(transport: anytype, allocator: Allocator, old: ?cache.Snapshot) !Result {
    var previous = old;
    defer if (previous) |*s| s.deinit();
    if (transport.authenticate(false)) |failure| return retain(&previous, failure);
    var attempt: policy.Attempt = .{};
    while (true) {
        if (transport.cancelled()) return retain(&previous, .{ .reason = .cancelled });
        const tag = if (previous) |p| p.etag else null;
        const response = switch (transport.fetch(tag)) {
            .response => |r| r,
            .failure => |failure| return retain(&previous, failure),
        };
        if (!response.secure) return retain(&previous, .{ .reason = .insecure_response });
        var registration_required = false;
        if (response.status == 401) {
            const error_doc = std.json.parseFromSlice(struct { @"error": []const u8 }, allocator, response.body, .{ .ignore_unknown_fields = true }) catch null;
            if (error_doc) |parsed| {
                defer parsed.deinit();
                registration_required = std.mem.eql(u8, parsed.value.@"error", "registration_required");
            }
        }
        const action = attempt.response(response.status, registration_required, previous != null and tag != null);
        switch (action) {
            .body => {
                const content_type = response.content_type orelse return retain(&previous, .{ .reason = .invalid_catalog, .http_status = 200 });
                const separator = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
                if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, content_type[0..separator], " \t"), "application/json"))
                    return retain(&previous, .{ .reason = .invalid_catalog, .http_status = 200 });
                var snapshot = cache.Snapshot.init(allocator, transport.origin(), transport.profileName(), policy.header(response.headers, "ETag"), response.body) catch |err|
                    return retain(&previous, .{ .reason = .invalid_catalog, .http_status = 200, .cause = err });
                snapshot.fresh = true;
                return .{ .snapshot = snapshot };
            },
            .cached => {
                var snapshot = previous.?;
                previous = null;
                snapshot.fresh = true;
                snapshot.cached = true;
                return .{ .snapshot = snapshot };
            },
            .register_once => if (transport.authenticate(true)) |failure| return retain(&previous, failure),
            .backoff => transport.delay(attempt.delayMilliseconds()),
            else => return retain(&previous, .{ .reason = switch (action) {
                .blocked => .blocked,
                .unavailable => .unavailable,
                .conflict => .conflict,
                .unauthorized => .unauthorized,
                .invalid_cache => .invalid_cache,
                .server_error => .server_error,
                else => .unexpected_status,
            }, .http_status = response.status }),
        }
    }
}

/// Shared per-request server session for catalog and original-asset reads.
/// No credential material leaves R4SRV. Buffers belong to the joined worker.
pub const Native = struct {
    app: *r4os.App,
    stop: *r4os.app_contract.StopFlag,
    target: r4os.server_targets.Target,
    profile: r4os.server_profile.Profile,
    origin_text: [64]u8 = undefined,
    origin_len: usize = 0,
    url: [128]u8 = undefined,
    url_len: usize = 0,
    generation: u32 = 0,
    raw: []u8,
    body: []u8,
    scratch: []u8,

    pub fn origin(self: *Native) []const u8 {
        return self.origin_text[0..self.origin_len];
    }
    pub fn profileName(self: *Native) []const u8 {
        return @tagName(self.profile);
    }
    pub fn cancelled(self: *Native) bool {
        return self.stop.requested();
    }

    pub fn authenticate(self: *Native, retry: bool) ?Failure {
        if (self.cancelled()) return .{ .reason = .cancelled };
        const services = self.app.services() orelse return .{ .reason = .registration_unavailable };
        const client = r4os.server_access.Client{ .services = services };
        const response = switch (if (retry) client.retryAfterRegistrationRequired(.app_center, self.generation) else client.ensure(.app_center)) {
            .response => |r| r,
            else => return .{ .reason = .registration_unavailable },
        };
        if (response.code != @intFromEnum(r4os.server_access.Code.ok)) return .{
            .reason = switch (response.code) {
                @intFromEnum(r4os.server_access.Code.credentials) => .registration_credentials,
                @intFromEnum(r4os.server_access.Code.invalid_secret), @intFromEnum(r4os.server_access.Code.invalid_reply) => .registration_response,
                else => .registration,
            },
            .detail = response.detail,
            .transport = if (response.code == @intFromEnum(r4os.server_access.Code.transport) and response.detail >= 0 and response.detail < std.meta.tags(r4os.app_web.Error).len) @enumFromInt(@as(u8, @intCast(response.detail))) else null,
        };
        if (response.generation == 0 or response.port != self.target.port or response.profile != @intFromEnum(self.profile) or
            !std.mem.eql(u8, &response.target_ip, &self.target.ip.octets)) return .{ .reason = .configuration };
        self.generation = response.generation;
        return null;
    }

    pub fn fetch(self: *Native, etag: ?[]const u8) Fetch {
        var web = self.app.web() orelse return .{ .failure = .{ .reason = .unavailable_web } };
        var conditional: [300]u8 = undefined;
        const header = if (etag) |tag| std.fmt.bufPrint(&conditional, "if-none-match:{s}\n", .{tag}) catch
            return .{ .failure = .{ .reason = .invalid_cache } } else "";
        return switch (web.fetch(self.url[0..self.url_len], self.raw, self.body, self.scratch, .{
            .timeout = r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(15_000_000_000)),
            .redirect = .error_mode,
            .redirect_limit = 0,
            .stop = &self.stop.storage,
            .headers = "accept:application/json\n",
            .conditional_headers = header,
        })) {
            .response => |r| .{ .response = .{ .status = r.status, .body = r.body, .headers = r.headers, .content_type = r.content_type, .secure = r.secure and std.mem.eql(u8, r.final_url.bytes(), self.url[0..self.url_len]) } },
            .failure => |e| .{ .failure = .{ .reason = if (e == .cancelled) .cancelled else .transport, .transport = e } },
        };
    }

    pub fn delay(self: *Native, milliseconds: u32) void {
        const sys = self.app.system();
        var left = milliseconds;
        while (left > 0 and !self.cancelled()) {
            const slice = @min(left, 50);
            sys.sleepTicks(@max(1, sys.monotonicHz() * slice / 1000));
            left -= slice;
        }
    }
};

pub fn cacheDirectory(files: *const r4os.Files) !void {
    for ([_][]const u8{ "C:\\R4OS\\DATA", "C:\\R4OS\\DATA\\PORTEX" }) |name| {
        const directory = try r4os.AbsoluteFilePath.parse(name);
        switch (files.info(directory.asZ())) {
            .value => |info| {
                if (info.is_dir == 0) return error.CacheDirectory;
                continue;
            },
            .missing => {},
            .failure => return error.CacheDirectory,
        }
        _ = files.createDirectory(directory.asZ());
        const info = switch (files.info(directory.asZ())) {
            .value => |v| v,
            else => return error.CacheDirectory,
        };
        if (info.is_dir == 0) return error.CacheDirectory;
    }
}

pub fn refresh(app: *r4os.App, allocator: Allocator, stop: *r4os.app_contract.StopFlag) Result {
    return refreshImpl(app, allocator, stop) catch |err| .{ .failure = .{ .reason = .configuration, .cause = err } };
}

pub fn describe(result: *const Result, output: []u8) [:0]const u8 {
    if (result.failure) |failure| {
        const reason = switch (failure.reason) {
            .configuration => "Serverkonfiguration ungueltig",
            .registration => "Registrierung fehlgeschlagen",
            .registration_credentials => "Registrierungsschluessel fehlt",
            .registration_unavailable => "R4SRV nicht erreichbar",
            .registration_response => "Registrierungsantwort ungueltig",
            .transport => "Verbindung fehlgeschlagen",
            .blocked => "Zugriff vom Server gesperrt",
            .unavailable => "Softwarekatalog nicht verfuegbar",
            .conflict => "Widerspruechliche Serverfreigabe",
            .unauthorized => "Registrierung nicht akzeptiert",
            .invalid_cache => "Keine passende gespeicherte Katalogansicht",
            .server_error => "Server voruebergehend nicht nutzbar",
            .unexpected_status => "Unerwartete Serverantwort",
            .invalid_catalog => "Softwarekatalog ungueltig",
            .insecure_response => "Unzulaessige Antwortadresse",
            .cancelled => "Abgebrochen",
            .unavailable_web => "HTTPS nicht verfuegbar",
        };
        const detail = if (failure.transport) |e| @tagName(e) else if (failure.cause) |e| @errorName(e) else "";
        if (failure.http_status == 0) return std.fmt.bufPrintZ(output, "{s}{s}{s}{s}", .{ reason, if (detail.len != 0) "; " else "", detail, if (result.snapshot != null) "; gespeicherter Katalog ist veraltet" else "" }) catch "Katalogabruf fehlgeschlagen";
        return std.fmt.bufPrintZ(output, "{s}; HTTP {d} {s}{s}", .{ reason, failure.http_status, detail, if (result.snapshot != null) "; gespeicherter Katalog ist veraltet" else "" }) catch "Katalogabruf fehlgeschlagen";
    }
    if (result.snapshot) |s| return std.fmt.bufPrintZ(output, "Katalog aktuell: {d} Pakete{s}{s}{s}", .{
        s.catalog.packages.len,                                if (s.cached) " (unveraendert)" else "", if (result.cache_error != null) "; Cachefehler: " else "",
        if (result.cache_error) |err| @errorName(err) else "",
    }) catch "Katalog geladen";
    return "Kein Katalog verfuegbar";
}

fn refreshImpl(app: *r4os.App, allocator: Allocator, stop: *r4os.app_contract.StopFlag) !Result {
    const files = app.files() orelse return error.FilesUnavailable;
    const raw = try allocator.alloc(u8, cache.max_catalog_bytes + r4os.http.max_header_bytes);
    defer allocator.free(raw);
    const body = try allocator.alloc(u8, cache.max_catalog_bytes);
    defer allocator.free(body);
    const scratch = try allocator.alloc(u8, r4os.app_web.tls_scratch_bytes);
    defer allocator.free(scratch);
    var native = try open(app, stop, raw, body, scratch);
    const origin = native.origin();
    var cache_error: ?anyerror = null;
    const previous = cache.Snapshot.load(&files, allocator, origin, native.profileName()) catch |err| bad_cache: {
        cache_error = err;
        break :bad_cache null;
    };
    var result = try retrieve(&native, allocator, previous);
    result.cache_error = cache_error;
    if (result.snapshot) |*snapshot| if (snapshot.fresh and !snapshot.cached) {
        cacheDirectory(&files) catch |err| {
            result.cache_error = err;
            return result;
        };
        snapshot.save(&files, allocator) catch |err| {
            result.cache_error = err;
            return result;
        };
        result.cache_error = null;
    };
    return result;
}

pub fn open(app: *r4os.App, stop: *r4os.app_contract.StopFlag, raw: []u8, body: []u8, scratch: []u8) !Native {
    const sys = app.system();
    const target = try r4os.server_targets.read(&sys, .app_center);
    const profile = try r4os.server_profile.load(&sys);
    var native = Native{ .app = app, .stop = stop, .target = target, .profile = profile, .raw = raw, .body = body, .scratch = scratch };
    const origin = try std.fmt.bufPrint(&native.origin_text, "https://{s}:{d}", .{ target.host(), target.port });
    native.origin_len = origin.len;
    native.url_len = (try std.fmt.bufPrint(&native.url, "{s}/api/v1/packages", .{origin})).len;
    return native;
}
