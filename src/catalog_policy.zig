//! Software read policy, independent of GUI and transport implementation.
const std = @import("std");
pub const Decision = enum { body, cached, register_once, backoff, blocked, unavailable, conflict, unauthorized, invalid_cache, server_error, unexpected_status };
pub const Attempt = struct {
    registration_retried: bool = false,
    retries: u8 = 0,

    pub fn response(self: *Attempt, status: u16, registration_required: bool, conditional_cache_available: bool) Decision {
        return switch (status) {
            200 => .body,
            304 => if (conditional_cache_available) .cached else .invalid_cache,
            401 => if (registration_required and !self.registration_retried) once: {
                self.registration_retried = true;
                break :once .register_once;
            } else .unauthorized,
            403 => .blocked,
            404 => .unavailable,
            409 => .conflict,
            429, 503 => if (self.retries < 3) retry: {
                self.retries += 1;
                break :retry .backoff;
            } else .server_error,
            else => .unexpected_status,
        };
    }

    pub fn delayMilliseconds(self: Attempt) u32 {
        return switch (self.retries) {
            1 => 250,
            2 => 500,
            else => 1000,
        };
    }
};

pub fn validEtag(value: []const u8) bool {
    if (value.len < 2 or value.len > 256 or value[0] != '"' or value[value.len - 1] != '"') return false;
    for (value[1 .. value.len - 1]) |byte| if (byte < 0x21 or byte > 0x7e or byte == '"') return false;
    return true;
}

pub fn header(bytes: []const u8, name: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            if (result != null) return null;
            result = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        }
    }
    return result;
}
