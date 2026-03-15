const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const types = @import("types");

const MAX_CHUNK_LINES = 80;
const OVERLAP_LINES = 10;

fn chunkId(allocator: std.mem.Allocator, file_path: []const u8, start_line: u32, end_line: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}#{d}-{d}", .{ file_path, start_line, end_line });
}

fn buildSymbolChunks(
    allocator: std.mem.Allocator,
    node: *const types.FileNode,
    lines: []const []const u8,
) !std.ArrayList(types.Chunk) {
    var result = std.ArrayList(types.Chunk).empty;
    if (node.symbols.items.len == 0) return result;

    var sorted = try allocator.dupe(types.CodeSymbol, node.symbols.items);
    defer allocator.free(sorted);
    std.mem.sort(types.CodeSymbol, sorted, {}, struct {
        fn lessThan(_: void, a: types.CodeSymbol, b: types.CodeSymbol) bool {
            return a.range.start.line < b.range.start.line;
        }
    }.lessThan);

    var group_start: u32 = sorted[0].range.start.line;
    var group_end: u32 = sorted[0].range.end.line;
    var group_symbols = std.ArrayList([]const u8).empty;
    try group_symbols.append(allocator, sorted[0].name);
    defer group_symbols.deinit(allocator);

    for (sorted[1..]) |*sym| {
        const sym_start = sym.range.start.line;
        const sym_end = sym.range.end.line;
        if (sym_end - group_start < MAX_CHUNK_LINES) {
            if (sym_end > group_end) group_end = sym_end;
            try group_symbols.append(allocator, sym.name);
        } else {
            const start = @max(@as(u32, 0), group_start);
            const end = @min(@as(u32, @intCast(lines.len)) -| 1, group_end);
            const content = blk: {
                var list = std.ArrayList(u8).empty;
                defer list.deinit(allocator);
                for (lines[start..end + 1]) |line| {
                    try list.appendSlice(allocator, line);
                    try list.append(allocator, '\n');
                }
                break :blk try list.toOwnedSlice(allocator);
            };
            try result.append(allocator, .{
                .id = try chunkId(allocator, node.path, start, end),
                .file_path = node.path,
                .start_line = start,
                .end_line = end,
                .content = content,
                .symbol_names = try group_symbols.clone(allocator),
                .language = types.languageToString(node.language),
            });
            group_start = sym_start;
            group_end = sym_end;
            group_symbols.shrinkRetainingCapacity(0);
            try group_symbols.append(allocator, sym.name);
        }
    }
    const start = @max(@as(u32, 0), group_start);
    const end = @min(@as(u32, @intCast(lines.len)) -| 1, group_end);
    const content = blk: {
        var list = std.ArrayList(u8).empty;
        defer list.deinit(allocator);
        for (lines[start..end + 1]) |line| {
            try list.appendSlice(allocator, line);
            try list.append(allocator, '\n');
        }
        break :blk try list.toOwnedSlice(allocator);
    };
    try result.append(allocator, .{
        .id = try chunkId(allocator, node.path, start, end),
        .file_path = node.path,
        .start_line = start,
        .end_line = end,
        .content = content,
        .symbol_names = try group_symbols.clone(allocator),
        .language = types.languageToString(node.language),
    });
    return result;
}

fn buildFixedChunks(
    allocator: std.mem.Allocator,
    node: *const types.FileNode,
    lines: []const []const u8,
) !std.ArrayList(types.Chunk) {
    var result = std.ArrayList(types.Chunk).empty;
    if (lines.len == 0) return result;
    const step = MAX_CHUNK_LINES - OVERLAP_LINES;
    var start: u32 = 0;
    while (start < lines.len) {
        const end = @min(@as(u32, @intCast(lines.len)) -| 1, start + MAX_CHUNK_LINES - 1);
        const content = blk: {
            var list = std.ArrayList(u8).empty;
            defer list.deinit(allocator);
            for (lines[start..end + 1]) |line| {
                try list.appendSlice(allocator, line);
                try list.append(allocator, '\n');
            }
            break :blk try list.toOwnedSlice(allocator);
        };
        const sym_names = std.ArrayList([]const u8).empty;
        try result.append(allocator, .{
            .id = try chunkId(allocator, node.path, start, end),
            .file_path = node.path,
            .start_line = start,
            .end_line = end,
            .content = content,
            .symbol_names = sym_names,
            .language = types.languageToString(node.language),
        });
        if (end == lines.len - 1) break;
        start += step;
    }
    return result;
}

/// Caller owns returned ChunkIndex; must free chunks and their fields.
pub fn buildChunks(
    allocator: std.mem.Allocator,
    io: Io,
    nodes: []const types.FileNode,
) !types.ChunkIndex {
    var all_chunks = std.ArrayList(types.Chunk).empty;
    errdefer {
        for (all_chunks.items) |*c| {
            allocator.free(c.id);
            allocator.free(c.content);
            c.symbol_names.deinit(allocator);
        }
        all_chunks.deinit(allocator);
    }

    var buf: [2 * 1024 * 1024]u8 = undefined;
    var line_list = std.ArrayList([]const u8).empty;
    defer line_list.deinit(allocator);
    // lines point into buf; only valid during this node's processing

    for (nodes) |*node| {
        const f = Dir.openFileAbsolute(io, node.absolute_path, .{}) catch continue;
        defer f.close(io);
        const n = f.readPositionalAll(io, &buf, 0) catch continue;
        const content = buf[0..n];

        line_list.shrinkRetainingCapacity(0);
        var iter = std.mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| try line_list.append(allocator, line);
        const lines = line_list.items;

        if (node.symbols.items.len > 0) {
            var chunks = buildSymbolChunks(allocator, node, lines) catch continue;
            defer {
                for (chunks.items) |*c| {
                    allocator.free(c.id);
                    allocator.free(c.content);
                    c.symbol_names.deinit(allocator);
                }
                chunks.deinit(allocator);
            }
            for (chunks.items) |c| try all_chunks.append(allocator, .{
                .id = try allocator.dupe(u8, c.id),
                .file_path = c.file_path,
                .start_line = c.start_line,
                .end_line = c.end_line,
                .content = try allocator.dupe(u8, c.content),
                .symbol_names = try c.symbol_names.clone(allocator),
                .language = try allocator.dupe(u8, c.language),
            });
        } else {
            var chunks = buildFixedChunks(allocator, node, lines) catch continue;
            defer {
                for (chunks.items) |*c| {
                    allocator.free(c.id);
                    allocator.free(c.content);
                    c.symbol_names.deinit(allocator);
                }
                chunks.deinit(allocator);
            }
            for (chunks.items) |c| try all_chunks.append(allocator, .{
                .id = try allocator.dupe(u8, c.id),
                .file_path = c.file_path,
                .start_line = c.start_line,
                .end_line = c.end_line,
                .content = try allocator.dupe(u8, c.content),
                .symbol_names = try c.symbol_names.clone(allocator),
                .language = try allocator.dupe(u8, c.language),
            });
        }
    }

    return .{
        .indexed_at = 0,
        .chunks = all_chunks,
    };
}
