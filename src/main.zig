const r = @import("r4os");
const load = @import("load_job.zig");
const ui = @import("ui.zig");
const download = @import("download.zig");
const installation = @import("installation.zig");
const r4std = @import("r4std");

pub fn r4_app_main(app: *r.App) i32 {
    if (!r4std.init(app.startContext())) return r.abi.err_no_group;
    var timers: [0]r.Timer = .{};
    var window = r.Window.init(app.system(), app.desktop() orelse return -1, app.drawing() orelse return -1, &timers) orelse return -2;
    _ = window.setTitle("Portex");
    _ = window.setMinimumSize(680, 560);
    var snapshot: load.Snapshot = .{};
    defer snapshot.deinit();
    var view = ui.Ui{ .window = &window, .allocator = app.system().allocator(), .snapshot = &snapshot, .style = r.gui.Style.light().withSystemFonts(&window.draw), .reload_requested = true, .capabilities = .{ .install = true, .update = true } };
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
    var install_job: installation.Job = undefined;
    var mode: enum { load, download, install } = .load;
    var thread: ?r.app_resources.JoinHandle = null;
    const resources = app.resources();
    var closing = false;
    var exit_code: i32 = 0;
    var next_progress_paint: u64 = 0;
    const period = r.time_contract.timeoutFinite(r.time_contract.durationFromNanoseconds(100_000_000));
    while (true) {
        closing = closing or app.shouldClose();
        if (closing or view.cancel_requested) {
            switch (mode) {
                .download => download_job.stop.request(),
                .load => job.stop.request(),
                .install => {
                    install_job.stop.request();
                    if (install_job.download_job) |*dl| dl.stop.request();
                },
            }
            view.cancel_requested = false;
        }
        if (!closing and (view.install_requested != null or view.resume_requested or view.restart_requested) and thread == null) {
            const request = view.install_requested;
            const resuming = view.resume_requested or view.restart_requested;
            const restarting = view.restart_requested;
            view.install_requested = null;
            view.resume_requested = false;
            view.restart_requested = false;
            var created = false;
            if (resuming) {
                install_job = .{ .app = app, .allocator = app.system().allocator(), .resuming = true, .commit_restart = restarting };
                created = true;
            } else if (request) |value| if (snapshot.result.snapshot) |*cached| if (cached.fresh and value.package_index < cached.catalog.packages.len) {
                const package = cached.catalog.packages[value.package_index];
                if (download.Plan.init(package, cached.origin, cached.profile)) |plan| {
                    install_job = .{ .app = app, .allocator = app.system().allocator(), .destination = value.destination, .title = package.display_name, .adopt = value.adopt, .replace = value.replace, .download_job = .{ .app = app, .allocator = app.system().allocator(), .plan = plan, .progress = .{ .total = plan.size } } };
                    created = true;
                } else |err| snapshot.failure = err;
            };
            if (created) {
                view.installation_progress = &install_job.progress;
                view.download_progress = if (install_job.download_job) |*dl| &dl.progress else null;
                switch (resources.createThread(installation.Job.entry, @intFromPtr(&install_job), 512 * 1024)) {
                    .handle => |handle| {
                        thread = handle;
                        mode = .install;
                        view.busy = true;
                    },
                    .failure => {
                        snapshot.failure = error.WorkerUnavailable;
                        view.installation_progress = null;
                    },
                }
            }
            view.dirty = true;
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
                    view.installation_progress = null;
                    switch (resources.createThread(download.Job.entry, @intFromPtr(&download_job), 256 * 1024)) {
                        .handle => |handle| {
                            thread = handle;
                            mode = .download;
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
            if (view.installation_progress == null) view.download_progress = null;
            job = .{ .app = app, .allocator = app.system().allocator() };
            switch (resources.createThread(load.Job.entry, @intFromPtr(&job), 256 * 1024)) {
                .handle => |handle| {
                    thread = handle;
                    mode = .load;
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
                if (mode == .load) {
                    view.replaced();
                    snapshot.deinit();
                    snapshot = job.output;
                    job.output = .{};
                }
                if (mode == .install) view.reload_requested = true;
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
        const now = app.system().ticks();
        if (thread != null and mode != .load and now >= next_progress_paint) {
            view.dirty = true;
            next_progress_paint = now +| @max(1, app.system().monotonicHz() / 4);
        }
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
