//! Client-local invalidation; a regional frame always replaces the whole scene.
const r = @import("r4os");
const Rect = r.gui.Rect;
pub const Damage = struct {
    full: bool = true,
    count: usize = 0,
    regions: [r.abi.gui_frame_max_damage_regions]r.abi.DisplayDamageRect = undefined,

    pub fn active(self: *const Damage) bool {
        return self.full or self.count != 0;
    }
    pub fn all(self: *Damage) void {
        self.full = true;
        self.count = 0;
    }
    pub fn clear(self: *Damage) void {
        self.full = false;
        self.count = 0;
    }
    pub fn add(self: *Damage, rect: Rect, width: i32, height: i32) void {
        if (self.full or rect.isEmpty()) return;
        var x: i32 = @max(0, rect.x);
        var y: i32 = @max(0, rect.y);
        var right = @min(width, rect.right());
        var bottom = @min(height, rect.bottom());
        if (right <= x or bottom <= y) return;
        var i: usize = 0;
        while (i < self.count) {
            const old = self.regions[i];
            const old_right = old.x + @as(i32, @intCast(old.w));
            const old_bottom = old.y + @as(i32, @intCast(old.h));
            if (x <= old_right and old.x <= right and y <= old_bottom and old.y <= bottom) {
                x = @min(x, old.x);
                y = @min(y, old.y);
                right = @max(right, old_right);
                bottom = @max(bottom, old_bottom);
                self.count -= 1;
                self.regions[i] = self.regions[self.count];
                i = 0; // The enlarged union may now touch an earlier region.
            } else i += 1;
        }
        if (self.count == self.regions.len) return self.all();
        self.regions[self.count] = .{ .x = x, .y = y, .w = @intCast(right - x), .h = @intCast(bottom - y) };
        self.count += 1;
    }
};
