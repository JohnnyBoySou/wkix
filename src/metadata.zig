const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const path = std.fs.path;
const mem = std.mem;

pub const WorkspaceMetadata = struct {
    version: []const u8,
    root: []const u8,
    indexed_at: i64,
    engine_version: []const u8,
    file_hashes: std.StringHashMap([]const u8),

    pub fn deinit(self: *WorkspaceMetadata, allocator: mem.Allocator) void {
        var it = self.file_hashes.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        self.file_hashes.deinit();
        allocator.free(self.version);
        allocator.free(self.root);
        allocator.free(self.engine_version);
    }
};

pub fn getWorkspaceDir(allocator: mem.Allocator, repo_root: []const u8) ![]const u8 {
    return path.join(allocator, &.{ repo_root, ".workspace" });
}

/// Read metadata.json from workspace dir. Caller owns returned struct; call deinit.
pub fn readMetadata(allocator: mem.Allocator, io: Io, workspace_dir: []const u8) !?WorkspaceMetadata {
    const p = try path.join(allocator, &.{ workspace_dir, "metadata.json" });
    defer allocator.free(p);

    const f = Dir.openFileAbsolute(io, p, .{}) catch return null;
    defer f.close(io);

    var buf: [512 * 1024]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return null;
    const slice = buf[0..n];

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, slice, .{}) catch return null;
    defer parsed.deinit();

    const root_val = parsed.value;
    if (root_val != .object) return null;
    const obj = root_val.object;

    const version_v = obj.get("version") orelse return null;
    if (version_v != .string) return null;
    const version = version_v.string;

    const root_v = obj.get("root") orelse return null;
    if (root_v != .string) return null;
    const root = root_v.string;

    const indexed_at_v = obj.get("indexedAt") orelse return null;
    if (indexed_at_v != .integer) return null;
    const indexed_at = indexed_at_v.integer;

    const engine_v = obj.get("engineVersion") orelse return null;
    if (engine_v != .string) return null;
    const engine_version = engine_v.string;

    const file_hashes_val = obj.get("fileHashes") orelse return null;
    if (file_hashes_val != .object) return null;

    var file_hashes = std.StringHashMap([]const u8).init(allocator);
    errdefer file_hashes.deinit();

    var it = file_hashes_val.object.iterator();
    while (it.next()) |entry| {
        const val = entry.value_ptr.*;
        if (val != .string) continue;
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const val_dup = try allocator.dupe(u8, val.string);
        file_hashes.put(key, val_dup) catch {
            allocator.free(key);
            allocator.free(val_dup);
            return error.OutOfMemory;
        };
    }

    return .{
        .version = try allocator.dupe(u8, version),
        .root = try allocator.dupe(u8, root),
        .indexed_at = indexed_at,
        .engine_version = try allocator.dupe(u8, engine_version),
        .file_hashes = file_hashes,
    };
}
