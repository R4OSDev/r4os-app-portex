//! UI observation only. The shared update owner owns durable mutation/jobs.
pub const Phase = enum { idle, downloading, verifying, ready, staging, pending_restart, installed, rolled_back, failed, cancelled };
pub const Token = struct { request: u64, process: u32, generation: u64 };
pub const Receipt = struct { backend_job: u64, phase: Phase };
pub const Action = enum { install, update, uninstall, update_all };
/// A control needs an implemented owner adapter and an observed, unambiguous
/// installation. Offline browsing never authorizes a new mutation.
pub const Capabilities = struct {
    install: bool = false,
    update: bool = false,
    uninstall: bool = false,
    update_all: bool = false,

    pub fn allows(self: Capabilities, action: Action, fresh: bool, busy: bool, installed: bool, application: bool, newer: bool) bool {
        if (busy) return false;
        return switch (action) {
            .install => self.install and fresh and !installed,
            .update => self.update and fresh and installed and newer,
            .uninstall => self.uninstall and installed and application,
            .update_all => self.update_all and fresh and newer,
        };
    }
};
pub const Job = struct {
    token: Token,
    phase: Phase = .idle,
    backend_job: u64 = 0,
    cancel_requested: bool = false,

    pub fn matches(self: Job, token: Token) bool {
        return self.token.request == token.request and self.token.process == token.process and self.token.generation == token.generation;
    }

    pub fn requestCancel(self: *Job) void {
        self.cancel_requested = true;
    }

    pub fn observe(self: *Job, token: Token, receipt: Receipt) bool {
        if (!self.matches(token) or (self.backend_job != 0 and self.backend_job != receipt.backend_job)) return false;
        if (self.terminal()) return receipt.phase == self.phase;
        if (receipt.phase == .installed and self.backend_job == 0) return false;
        if (receipt.backend_job != 0) self.backend_job = receipt.backend_job;
        self.phase = receipt.phase;
        return true;
    }

    pub fn terminal(self: Job) bool {
        return switch (self.phase) {
            .installed, .rolled_back, .failed, .cancelled => true,
            else => false,
        };
    }
};
