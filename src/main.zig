const r = @import("r4os");
const load = @import("load_job.zig");
const ui = @import("ui.zig");
const download = @import("download.zig");

pub fn r4_app_main(app: *r.App) i32 {
    var timers: [0]r.Timer = .{};
    var window = r.Window.init(app.system(), app.desktop() orelse return -1, app.drawing() orelse return -1, &timers) orelse return -2;
    _ = window.setTitle("Portex");
    _ = window.setMinimumSize(680, 560);
    var snapshot: load.Snapshot = .{};
    defer snapshot.deinit();
    var view = ui.Ui{ .window = &window, .allocator = app.system().allocator(), .snapshot = &snapshot, .style = r.gui.Style.light().withSystemFonts(&window.draw), .reload_requested = true };
    defer view.deinit();
    const focus_client = r.desktop_actions.Client{ .sys = window.sys };
    switch (focus_client.focusSnapshot(.{ .window_id = @intCast(window.id) })) {
        .reply => |reply| if (reply.result == 0) {
            view.active = reply.snapshot.focus_state == r.abi.desktop_focus_state_focused;
        },
        .failure => {},
    }
    var job = load.Job{ .app = app, .allocator = app.system().allocator() };
    var download_job: download.Job = undefined;
    var downloading = false;
    var thread: ?r.app_resources.JoinHandle = null;
    const resources = app.resources();
    var closing = false;
    var exit_code: i32 = 0;
    const period = r.time_contract.timeoutFinite(r.time_contract.durationFromNanoseconds(100_000_000));
    while (true) {
        closing = closing or app.shouldClose();
        if (closing or view.cancel_requested) {
            if (downloading) download_job.stop.request() else job.stop.request();
            view.cancel_requested = false;
        }
        if (!closing and view.download_requested != null and thread == null) {
            const index = view.download_requested.?;
            view.download_requested = null;
            if (snapshot.result.snapshot) |*cached| if (cached.fresh and index < cached.catalog.packages.len) {
                const plan = download.Plan.init(cached.catalog.packages[index], cached.origin, cached.profile);
                if (plan) |value| {
                    // Snapshot and all plan slices remain alive through join.
                    download_job = .{ .app = app, .allocator = app.system().allocator(), .plan = value, .progress = .{ .total = value.size } };
                    view.download_progress = &download_job.progress;
                    switch (resources.createThread(download.Job.entry, @intFromPtr(&download_job), 256 * 1024)) {
                        .handle => |handle| {
                            thread = handle;
                            downloading = true;
                            view.busy = true;
                        },
                        .failure => {
                            download_job.progress.failure(error.WorkerUnavailable);
                            download_job.progress.set(.failed);
                        },
                    }
                } else |err| {
                    snapshot.failure = err;
                }
            };
            view.dirty = true;
        }
        if (!closing and view.reload_requested and thread == null) {
            view.reload_requested = false;
            view.download_progress = null;
            job = .{ .app = app, .allocator = app.system().allocator() };
            switch (resources.createThread(load.Job.entry, @intFromPtr(&job), 256 * 1024)) {
                .handle => |handle| {
                    thread = handle;
                    view.busy = true;
                },
                .failure => {
                    snapshot.failure = error.WorkerUnavailable;
                    view.busy = false;
                },
            }
            view.dirty = true;
        }
        if (thread) |*worker| switch (worker.join(if (closing) period else r.time_contract.timeoutPoll())) {
            .exited => {
                if (!downloading) {
                    view.replaced();
                    snapshot.deinit();
                    snapshot = job.output;
                    job.output = .{};
                }
                downloading = false;
                thread = null;
                view.busy = false;
                view.dirty = true;
            },
            .timed_out => {},
            .failure => {
                closing = true;
                exit_code = -8;
                app.system().sleepTicks(@max(1, app.system().monotonicHz() / 10));
            },
        };
        if (downloading) view.dirty = true;
        if (closing) {
            if (thread == null) break;
            continue;
        }
        if (view.dirty) {
            view.dirty = false;
            if (!view.paint()) {
                closing = true;
                exit_code = -3;
                continue;
            }
        }
        switch (window.waitMessage(period)) {
            .message => |message| switch (message) {
                .close => closing = true,
                .resize => {
                    view.release();
                    view.dirty = true;
                },
                .font_changed => {
                    view.style = view.style.withSystemFonts(&window.draw);
                    view.dirty = true;
                },
                .key => |key| view.key(key),
                .mouse => |mouse| view.mouse(mouse),
                .wheel => |wheel| view.wheel(wheel.delta),
                .focus_gained => {
                    view.active = true;
                    view.dirty = true;
                },
                .focus_lost => {
                    view.active = false;
                    view.release();
                    view.dirty = true;
                },
                .input_reset => {
                    view.release();
                    view.dirty = true;
                },
                .pointer_capture => |capture| {
                    if (capture.state == r.abi.gui_pointer_state_cancelled) view.release();
                    view.dirty = true;
                },
                else => {},
            },
            .failure => |code| {
                closing = true;
                exit_code = code;
            },
            else => {},
        }
    }
    return exit_code;
}
