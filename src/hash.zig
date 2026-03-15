const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const mem = std.mem;
const crypto = std.crypto;
const path = std.fs.path;

/// Hash file contents with SHA256 and write first 16 hex chars into hex_out (thread-safe, no alloc).
pub fn hashFileToBuffer(io: Io, absolute_path: []const u8, hex_out: *[16]u8) !void {
    const f = Dir.openFileAbsolute(io, absolute_path, .{}) catch return error.OpenError;
    defer f.close(io);

    var hasher = crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = f.readPositionalAll(io, &buf, offset) catch return error.ReadError;
        if (n == 0) break;
        hasher.update(buf[0..n]);
        offset += n;
    }

    var digest: [crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);

    const hex_chars = "0123456789abcdef";
    for (digest[0..8], 0..) |b, i| {
        hex_out[i * 2] = hex_chars[b >> 4];
        hex_out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

/// Hash file contents with SHA256 and return first 16 hex chars (matches TS hashFile).
pub fn hashFile(allocator: std.mem.Allocator, io: Io, absolute_path: []const u8) ![]const u8 {
    var hex: [16]u8 = undefined;
    try hashFileToBuffer(io, absolute_path, &hex);
    return allocator.dupe(u8, &hex);
}

/// Hash a string with SHA256, return first 16 hex chars (matches TS hashString).
pub fn hashString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var digest: [crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(s, &digest, .{});
    const hex = try allocator.alloc(u8, 16);
    const hex_chars = "0123456789abcdef";
    for (digest[0..8], 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return hex;
}

test "hashString" {
    const a = std.testing.allocator;
    const h = try hashString(a, "hello");
    defer a.free(h);
    try std.testing.expect(h.len == 16);
}
