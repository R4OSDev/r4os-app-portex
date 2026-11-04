//! UI observation only. The shared update owner owns durable mutation/jobs.
pub const Phase = enum { idle, downloading, verifying, ready, staging, pending_restart, installed, rolled_back, failed, cancelled };
pub const Token = struct { request: u64, process: u32, generation: u64 };
pub const Receipt = struct { backend_job: u64, phase: Phase };
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
