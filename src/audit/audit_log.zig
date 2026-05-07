//! Append-only JSONL log of LLM-triage requests for transparency.
//!
//! Every triage call writes one line: `{"timestamp":..., "envelope":{...}, "verdict":{...}, "cache_hit":bool}`.
//! Users can review this file to verify exactly what metadata left their machine.

const std = @import("std");
const std_compat = @import("compat");
const Allocator = std.mem.Allocator;
const fs_compat = @import("../fs_compat.zig");
const llm_client = @import("llm_client.zig");
const Verdict = llm_client.Verdict;

pub const AuditLog = struct {
    allocator: Allocator,
    path: []u8,

    pub fn init(allocator: Allocator, path: []const u8) !AuditLog {
        const path_dup = try allocator.dupe(u8, path);
        return .{ .allocator = allocator, .path = path_dup };
    }

    pub fn deinit(self: *AuditLog) void {
        self.allocator.free(self.path);
    }

    pub fn record(
        self: *AuditLog,
        envelope_json: []const u8,
        verdict: Verdict,
    ) !void {
        if (std.fs.path.dirname(self.path)) |dir| {
            fs_compat.makePath(dir) catch {};
        }
        const file = try fs_compat.createPath(self.path, .{ .truncate = false });
        defer file.close();
        try file.seekFromEnd(0);

        const ts: i64 = std_compat.time.timestamp();
        const reasoning_escaped = try jsonEscape(self.allocator, verdict.reasoning);
        defer self.allocator.free(reasoning_escaped);

        const line = try std.fmt.allocPrint(
            self.allocator,
            "{{\"timestamp\":{d},\"envelope\":{s},\"verdict\":{{\"decision\":\"{s}\",\"severity_adjusted\":\"{s}\",\"reasoning\":\"{s}\",\"confidence_score\":{d:.4}}}}}\n",
            .{
                ts,
                envelope_json,
                verdict.decision.name(),
                verdict.severity_adjusted,
                reasoning_escaped,
                verdict.confidence_score,
            },
        );
        defer self.allocator.free(line);
        try file.writeAll(line);
    }
};

fn jsonEscape(allocator: Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    for (s) |ch| {
        if (ch == '"') {
            try buf.appendSlice(allocator, "\\\"");
        } else if (ch == '\\') {
            try buf.appendSlice(allocator, "\\\\");
        } else if (ch == '\n') {
            try buf.appendSlice(allocator, "\\n");
        } else if (ch == '\r') {
            try buf.appendSlice(allocator, "\\r");
        } else if (ch == '\t') {
            try buf.appendSlice(allocator, "\\t");
        } else if (ch < 0x20) {
            const rendered = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{ch});
            defer allocator.free(rendered);
            try buf.appendSlice(allocator, rendered);
        } else {
            try buf.append(allocator, ch);
        }
    }
    return buf.toOwnedSlice(allocator);
}
