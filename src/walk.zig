const std = @import("std");
const Io = std.Io;
const fs = std.fs;
const mem = std.mem;
const path = std.fs.path;
const Dir = std.Io.Dir;
const File = std.Io.File;

pub const WalkedFile = struct {
    absolute_path: []const u8,
    relative_path: []const u8, // POSIX, relative to root
};

pub const Language = enum {
    typescript,
    tsx,
    javascript,
    jsx,
};

const default_ignores = [_][]const u8{
    "node_modules",
    ".git",
    "dist",
    "build",
    "out",
    ".next",
    ".nuxt",
    ".turbo",
    ".workspace",
    "coverage",
    "__pycache__",
    "vendor",
};

const ext_to_lang = std.StaticStringMap(Language).initComptime(.{
    .{ ".ts", .typescript },
    .{ ".tsx", .tsx },
    .{ ".mts", .typescript },
    .{ ".cts", .typescript },
    .{ ".js", .javascript },
    .{ ".jsx", .jsx },
    .{ ".mjs", .javascript },
    .{ ".cjs", .javascript },
});

pub fn detectLanguage(filename: []const u8) ?Language {
    const ext = path.extension(filename);
    return ext_to_lang.get(ext);
}

fn isIgnoredByPattern(relative_path: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    if (mem.eql(u8, relative_path, pattern)) return true;
    if (mem.startsWith(u8, relative_path, pattern) and relative_path.len > pattern.len and relative_path[pattern.len] == path.sep)
        return true;
    if (mem.endsWith(u8, relative_path, pattern)) return true;
    var start: usize = 0;
    while (start < relative_path.len) {
        if (mem.indexOf(u8, relative_path[start..], pattern)) |idx| {
            const pos = start + idx;
            if (pos == 0 or relative_path[pos - 1] == path.sep) return true;
            start = pos + 1;
        } else break;
    }
    return false;
}

fn isIgnoredByDefaults(relative_path: []const u8) bool {
    for (default_ignores) |pat| {
        if (isIgnoredByPattern(relative_path, pat)) return true;
    }
    if (mem.endsWith(u8, relative_path, ".min.js")) return true;
    if (mem.endsWith(u8, relative_path, ".min.ts")) return true;
    if (mem.endsWith(u8, relative_path, ".d.ts")) return true;
    return false;
}

fn loadGitignore(allocator: mem.Allocator, dir: Dir, io: Io) std.ArrayList([]const u8) {
    var patterns = std.ArrayList([]const u8).empty;
    var buf: [64 * 1024]u8 = undefined;
    const f = dir.openFile(io, ".gitignore", .{}) catch return patterns;
    defer f.close(io);
    const n = f.readPositionalAll(io, &buf, 0) catch return patterns;
    var line_iter = mem.splitScalar(u8, buf[0..n], '\n');
    while (line_iter.next()) |line| {
        const trimmed = mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const p = allocator.dupe(u8, trimmed) catch continue;
        patterns.append(allocator, p) catch {
            allocator.free(p);
            break;
        };
    }
    return patterns;
}

/// When path.sep is already '/', returns p as-is (no allocation). Otherwise returns owned slice (caller must free when different from p).
fn pathToPosix(allocator: mem.Allocator, p: []const u8) ![]const u8 {
    if (path.sep == '/') return p;
    var list = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < p.len) {
        if (p[i] == path.sep) {
            try list.append(allocator, '/');
            i += 1;
        } else {
            try list.append(allocator, p[i]);
            i += 1;
        }
    }
    return list.toOwnedSlice(allocator);
}

fn matchesGitignore(relative_path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pat| {
        if (isIgnoredByPattern(relative_path, pat)) return true;
    }
    return false;
}

pub const WalkOptions = struct {
    root_absolute_path: []const u8,
    allocator: mem.Allocator,
    io: Io,
    extra_ignore: []const []const u8 = &.{},
};

pub fn walkRepo(options: WalkOptions) !std.ArrayList(WalkedFile) {
    const allocator = options.allocator;
    var result = std.ArrayList(WalkedFile).empty;
    errdefer result.deinit(allocator);

    const root_dir = Dir.openDirAbsolute(options.io, options.root_absolute_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return result;
    defer root_dir.close(options.io);

    var gitignore_patterns = loadGitignore(allocator, root_dir, options.io);
    defer gitignore_patterns.deinit(allocator);
    defer for (gitignore_patterns.items) |p| allocator.free(p);

    var walker = try Dir.walk(root_dir, allocator);
    defer walker.deinit();

    while (try walker.next(options.io)) |entry| {
        if (entry.kind != .file) continue;
        const rel_path = try allocator.dupe(u8, entry.path);
        defer allocator.free(rel_path);
        if (detectLanguage(rel_path) == null) continue;
        if (isIgnoredByDefaults(rel_path)) continue;
        if (matchesGitignore(rel_path, gitignore_patterns.items)) continue;
        for (options.extra_ignore) |pat| {
            if (isIgnoredByPattern(rel_path, pat)) continue;
        }

        const posix_rel = try pathToPosix(allocator, rel_path);
        const to_free_posix: ?[]const u8 = if (path.sep != '/') posix_rel else null;
        defer if (to_free_posix) |s| allocator.free(s);
        const abs_path = try path.join(allocator, &.{ options.root_absolute_path, rel_path });
        try result.append(allocator, .{
            .absolute_path = abs_path,
            .relative_path = try allocator.dupe(u8, posix_rel),
        });
    }

    mem.sort(WalkedFile, result.items, {}, struct {
        fn lessThan(_: void, a: WalkedFile, b: WalkedFile) bool {
            return mem.order(u8, a.relative_path, b.relative_path) == .lt;
        }
    }.lessThan);

    return result;
}

pub fn deinitWalked(allocator: mem.Allocator, list: *std.ArrayList(WalkedFile)) void {
    for (list.items) |w| {
        allocator.free(w.absolute_path);
        allocator.free(w.relative_path);
    }
    list.deinit(allocator);
}

test "detectLanguage" {
    try std.testing.expect(detectLanguage("foo.ts") == .typescript);
    try std.testing.expect(detectLanguage("foo.tsx") == .tsx);
    try std.testing.expect(detectLanguage("bar.js") == .javascript);
    try std.testing.expect(detectLanguage("bar.mjs") == .javascript);
    try std.testing.expect(detectLanguage("x.d.ts") == null);
}
