const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const Writer = std.Io.Writer;
const types = @import("types");
const ENGINE_VERSION = "zig-0.1.0";

fn escapeJsonString(w: *Writer, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"");
}

pub fn initWorkspace(io: Io, workspace_dir: []const u8) !void {
    _ = io;
    _ = workspace_dir;
    // Dir.makeDirAbsolute or similar - we'll create dir when writing first file
}

/// Write JSON string to dir/name. Atomic: write to name.tmp then rename to name.
pub fn writeJsonFile(allocator: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8, json_str: []const u8) !void {
    const tmp_name = try std.fmt.allocPrint(allocator, "{s}.tmp", .{name});
    defer allocator.free(tmp_name);
    const full_path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(full_path);
    const tmp_path = try std.fs.path.join(allocator, &.{ dir, tmp_name });
    defer allocator.free(tmp_path);
    const f = Dir.createFileAbsolute(io, tmp_path, .{}) catch return error.CreateFile;
    defer f.close(io);
    try f.writeStreamingAll(io, json_str);
    Dir.renameAbsolute(tmp_path, full_path, io) catch return error.RenameFailed;
}

/// Build metadata.json content (camelCase to match TS).
pub fn buildMetadataJson(allocator: std.mem.Allocator, root: []const u8, file_hashes: anytype) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    const now_ms: i64 = blk: {
        if (comptime @import("builtin").os.tag == .windows) break :blk 0;
        const spec = std.posix.clock_gettime(.REALTIME) catch break :blk @as(i64, 0);
        break :blk @as(i64, spec.sec) * 1000 + @as(i64, @divTrunc(spec.nsec, 1_000_000));
    };
    try w.print("{{\n  \"version\": \"1\",\n  \"root\": ", .{});
    try escapeJsonString(w, root);
    try w.print(",\n  \"indexedAt\": {d},\n  \"engineVersion\": ", .{now_ms});
    try escapeJsonString(w, ENGINE_VERSION);
    try w.writeAll(",\n  \"fileHashes\": {\n");
    var first = true;
    var it = file_hashes.iterator();
    while (it.next()) |e| {
        if (!first) try w.writeAll(",\n");
        first = false;
        try w.writeAll("    ");
        try escapeJsonString(w, e.key_ptr.*);
        try w.writeAll(": ");
        try escapeJsonString(w, e.value_ptr.*);
    }
    try w.writeAll("\n  }\n}\n");
    return aw.toOwnedSlice();
}

pub fn buildRepoMapJson(allocator: std.mem.Allocator, map: *const types.RepoMap) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"root\": ", .{});
    try escapeJsonString(w, map.root);
    try w.print(",\n  \"indexedAt\": {d},\n  \"fileCount\": {d},\n  \"totalLines\": {d},\n  \"totalSymbols\": {d},\n  \"files\": [\n", .{
        map.indexed_at,
        map.file_count,
        map.total_lines,
        map.total_symbols,
    });
    for (map.files.items, 0..) |entry, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    { ");
        try w.print("\"path\": ", .{});
        try escapeJsonString(w, entry.path);
        try w.print(", \"language\": \"{s}\", \"size\": {d}, \"lines\": {d}, ", .{
            types.languageToString(entry.language),
            entry.size,
            entry.lines,
        });
        try w.print("\"sha256\": ", .{});
        try escapeJsonString(w, entry.sha256);
        try w.print(", \"symbolCount\": {d}, \"exportCount\": {d}, \"importCount\": {d} }}", .{
            entry.symbol_count,
            entry.export_count,
            entry.import_count,
        });
    }
    try w.writeAll("\n  ]\n}\n");
    return aw.toOwnedSlice();
}

pub fn buildChunksJson(allocator: std.mem.Allocator, index: *const types.ChunkIndex) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"indexedAt\": {d},\n  \"chunks\": [\n", .{index.indexed_at});
    for (index.chunks.items, 0..) |c, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    { ");
        try w.print("\"id\": ", .{});
        try escapeJsonString(w, c.id);
        try w.print(", \"filePath\": ", .{});
        try escapeJsonString(w, c.file_path);
        try w.print(", \"startLine\": {d}, \"endLine\": {d}, \"content\": ", .{ c.start_line, c.end_line });
        try escapeJsonString(w, c.content);
        try w.writeAll(", \"symbolNames\": [");
        for (c.symbol_names.items, 0..) |name, j| {
            if (j > 0) try w.writeAll(", ");
            try escapeJsonString(w, name);
        }
        try w.print("], \"language\": ", .{});
        try escapeJsonString(w, c.language);
        try w.writeAll(" }");
    }
    try w.writeAll("\n  ]\n}\n");
    return aw.toOwnedSlice();
}

pub fn buildVectorsEmptyJson(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{{\n  \"indexedAt\": 0,\n  \"model\": \"\",\n  \"dimensions\": 0,\n  \"entries\": []\n}}\n", .{});
}

/// Build JSON array of chunk contents for embed bridge stdin: ["content1", "content2", ...]
pub fn buildChunkContentsArrayJson(allocator: std.mem.Allocator, chunks: []const types.Chunk) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("[");
    for (chunks, 0..) |c, i| {
        if (i > 0) try w.writeAll(",");
        try escapeJsonString(w, c.content);
    }
    try w.writeAll("]\n");
    return aw.toOwnedSlice();
}

test "buildMetadataJson empty hashes" {
    const a = std.testing.allocator;
    var hashes = std.StringHashMap([]const u8).init(a);
    defer {
        var it = hashes.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        hashes.deinit();
    }
    const out = try buildMetadataJson(a, "/repo", &hashes);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"fileHashes\"") != null);
}

test "buildChunkContentsArrayJson empty" {
    const a = std.testing.allocator;
    const out = try buildChunkContentsArrayJson(a, &.{});
    defer a.free(out);
    try std.testing.expectEqualStrings("[]\n", out);
}

fn writeSymbolJson(w: *Writer, s: *const types.CodeSymbol) !void {
    try w.writeAll("{ ");
    try w.writeAll("\"id\": ");
    try escapeJsonString(w, s.id);
    try w.writeAll(", \"name\": ");
    try escapeJsonString(w, s.name);
    try w.writeAll(", \"kind\": ");
    try escapeJsonString(w, s.kind);
    try w.print(", \"range\": {{ \"start\": {{ \"line\": {d}, \"column\": {d} }}, \"end\": {{ \"line\": {d}, \"column\": {d} }} }}", .{
        s.range.start.line,
        s.range.start.column,
        s.range.end.line,
        s.range.end.column,
    });
    try w.writeAll(", \"modifiers\": [");
    for (s.modifiers.items, 0..) |m, i| {
        if (i > 0) try w.writeAll(", ");
        try escapeJsonString(w, m);
    }
    try w.writeAll("]");
    if (s.return_type) |rt| {
        try w.writeAll(", \"returnType\": ");
        try escapeJsonString(w, rt);
    }
    try w.writeAll(", \"parameters\": [");
    for (s.parameters.items, 0..) |*p, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll("{ ");
        try w.writeAll("\"name\": ");
        try escapeJsonString(w, p.name);
        try w.print(", \"optional\": {}", .{p.optional});
        if (p.type_annot) |ta| {
            try w.writeAll(", \"type\": ");
            try escapeJsonString(w, ta);
        }
        if (p.default_value) |dv| {
            try w.writeAll(", \"defaultValue\": ");
            try escapeJsonString(w, dv);
        }
        try w.writeAll(" }");
    }
    try w.writeAll("], \"typeParameters\": [");
    for (s.type_parameters.items, 0..) |tp, i| {
        if (i > 0) try w.writeAll(", ");
        try escapeJsonString(w, tp);
    }
    try w.writeAll("]");
    if (s.parent_name) |pn| {
        try w.writeAll(", \"parentName\": ");
        try escapeJsonString(w, pn);
    }
    if (s.doc_comment) |dc| {
        try w.writeAll(", \"docComment\": ");
        try escapeJsonString(w, dc);
    }
    try w.print(", \"isExported\": {}", .{s.is_exported});
    if (s.extends) |e| {
        try w.writeAll(", \"extends\": ");
        try escapeJsonString(w, e);
    }
    if (s.implements.items.len > 0) {
        try w.writeAll(", \"implements\": [");
        for (s.implements.items, 0..) |impl, i| {
            if (i > 0) try w.writeAll(", ");
            try escapeJsonString(w, impl);
        }
        try w.writeAll("]");
    }
    if (s.calls.items.len > 0) {
        try w.writeAll(", \"calls\": [");
        for (s.calls.items, 0..) |c, i| {
            if (i > 0) try w.writeAll(", ");
            try escapeJsonString(w, c);
        }
        try w.writeAll("]");
    }
    if (s.branches > 0) try w.print(", \"branches\": {d}", .{s.branches});
    try w.writeAll(" }");
}

pub fn buildSymbolIndexJson(allocator: std.mem.Allocator, index: *const types.SymbolIndex) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"indexedAt\": {d},\n  \"count\": {d},\n  \"byName\": {{\n", .{ index.indexed_at, index.count });
    var by_name = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
    defer {
        var it = by_name.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(allocator);
        }
        by_name.deinit();
    }
    for (index.all.items) |*s| {
        var gop = try by_name.getOrPut(s.name);
        if (!gop.found_existing) gop.value_ptr.* = std.ArrayList([]const u8).empty;
        try gop.value_ptr.append(allocator, s.id);
    }
    var first_name = true;
    var it = by_name.iterator();
    while (it.next()) |e| {
        if (!first_name) try w.writeAll(",\n");
        first_name = false;
        try w.writeAll("    ");
        try escapeJsonString(w, e.key_ptr.*);
        try w.writeAll(": [");
        for (e.value_ptr.items, 0..) |id, j| {
            if (j > 0) try w.writeAll(", ");
            try escapeJsonString(w, id);
        }
        try w.writeAll("]");
    }
    try w.writeAll("\n  },\n  \"all\": [\n");
    for (index.all.items, 0..) |*s, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    ");
        try writeSymbolJson(w, s);
    }
    try w.writeAll("\n  ]\n}\n");
    return aw.toOwnedSlice();
}

pub fn buildImportGraphJson(allocator: std.mem.Allocator, graph: *const types.ImportGraph) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"indexedAt\": {d},\n  \"nodes\": {{\n", .{graph.indexed_at});
    var first = true;
    var it = graph.nodes.iterator();
    while (it.next()) |e| {
        if (!first) try w.writeAll(",\n");
        first = false;
        try w.writeAll("    ");
        try escapeJsonString(w, e.key_ptr.*);
        try w.writeAll(": { ");
        try w.print("\"path\": ", .{});
        try escapeJsonString(w, e.value_ptr.path);
        try w.writeAll(", \"imports\": [");
        for (e.value_ptr.imports.items, 0..) |imp, j| {
            if (j > 0) try w.writeAll(", ");
            try escapeJsonString(w, imp);
        }
        try w.writeAll("], \"importedBy\": [");
        for (e.value_ptr.imported_by.items, 0..) |ib, j| {
            if (j > 0) try w.writeAll(", ");
            try escapeJsonString(w, ib);
        }
        try w.writeAll("] }");
    }
    try w.writeAll("\n  }\n}\n");
    return aw.toOwnedSlice();
}

pub fn buildRepoDocsJson(allocator: std.mem.Allocator, docs: *const types.RepoDocs) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"indexedAt\": {d},\n  \"content\": ", .{docs.indexed_at});
    try escapeJsonString(w, docs.content);
    try w.writeAll("\n}\n");
    return aw.toOwnedSlice();
}

pub fn buildProjectMetadataJson(allocator: std.mem.Allocator, meta: *const types.ProjectMetadata) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"indexedAt\": {d}", .{meta.indexed_at});
    if (meta.name) |n| {
        try w.writeAll(",\n  \"name\": ");
        try escapeJsonString(w, n);
    }
    try w.writeAll(",\n  \"scripts\": {");
    var first = true;
    var it = meta.scripts.iterator();
    while (it.next()) |e| {
        if (!first) try w.writeAll(", ");
        first = false;
        try escapeJsonString(w, e.key_ptr.*);
        try w.writeAll(": ");
        try escapeJsonString(w, e.value_ptr.*);
    }
    try w.print("}},\n  \"dependencyCount\": {d},\n  \"devDependencyCount\": {d}\n}}\n", .{
        meta.dependency_count,
        meta.dev_dependency_count,
    });
    return aw.toOwnedSlice();
}

pub fn buildTodosJson(allocator: std.mem.Allocator, index: *const types.TodoIndex) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"indexedAt\": {d},\n  \"entries\": [\n", .{index.indexed_at});
    for (index.entries.items, 0..) |e, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    { \"path\": ");
        try escapeJsonString(w, e.path);
        try w.print(", \"line\": {d}, \"text\": ", .{e.line});
        try escapeJsonString(w, e.text);
        try w.writeAll(" }");
    }
    try w.writeAll("\n  ]\n}\n");
    return aw.toOwnedSlice();
}

// ─── call_graph.json ─────────────────────────────────────────────────────────

pub fn buildCallGraphJson(allocator: std.mem.Allocator, cg: *const types.CallGraph) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"indexedAt\": {d},\n  \"byCaller\": {{\n", .{cg.indexed_at});
    var first = true;
    var it = cg.entries.iterator();
    while (it.next()) |e| {
        if (!first) try w.writeAll(",\n");
        first = false;
        try w.writeAll("    ");
        try escapeJsonString(w, e.key_ptr.*);
        try w.writeAll(": [");
        for (e.value_ptr.items, 0..) |c, j| {
            if (j > 0) try w.writeAll(", ");
            try escapeJsonString(w, c);
        }
        try w.writeAll("]");
    }
    try w.writeAll("\n  }\n}\n");
    return aw.toOwnedSlice();
}

// ─── type_hierarchy.json ─────────────────────────────────────────────────────

pub fn buildTypeHierarchyJson(allocator: std.mem.Allocator, th: *const types.TypeHierarchy) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"indexedAt\": {d},\n  \"nodes\": [\n", .{th.indexed_at});
    for (th.nodes.items, 0..) |*n, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    { \"name\": ");
        try escapeJsonString(w, n.name);
        try w.writeAll(", \"kind\": ");
        try escapeJsonString(w, n.kind);
        if (n.extends) |e| {
            try w.writeAll(", \"extends\": ");
            try escapeJsonString(w, e);
        }
        try w.writeAll(", \"implements\": [");
        for (n.implements.items, 0..) |impl, j| {
            if (j > 0) try w.writeAll(", ");
            try escapeJsonString(w, impl);
        }
        try w.writeAll("], \"file\": ");
        try escapeJsonString(w, n.file);
        try w.print(", \"line\": {d} }}", .{n.line});
    }
    try w.writeAll("\n  ]\n}\n");
    return aw.toOwnedSlice();
}

// ─── env_vars.json ───────────────────────────────────────────────────────────

pub fn buildEnvVarIndexJson(allocator: std.mem.Allocator, ev: *const types.EnvVarIndex) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"indexedAt\": {d},\n  \"vars\": [", .{ev.indexed_at});
    for (ev.vars.items, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        try escapeJsonString(w, v);
    }
    try w.writeAll("],\n  \"usages\": [\n");
    for (ev.usages.items, 0..) |*u, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    { \"name\": ");
        try escapeJsonString(w, u.name);
        try w.writeAll(", \"file\": ");
        try escapeJsonString(w, u.file);
        try w.print(", \"line\": {d} }}", .{u.line});
    }
    try w.writeAll("\n  ]\n}\n");
    return aw.toOwnedSlice();
}

// ─── complexity.json ─────────────────────────────────────────────────────────

pub fn buildComplexityIndexJson(allocator: std.mem.Allocator, ci: *const types.ComplexityIndex) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"indexedAt\": {d},\n  \"totalFunctions\": {d},\n  \"avgComplexity\": {d:.2},\n  \"functions\": [\n", .{
        ci.indexed_at,
        ci.total_functions,
        ci.avg_complexity,
    });
    for (ci.functions.items, 0..) |*f, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    { \"id\": ");
        try escapeJsonString(w, f.symbol_id);
        try w.writeAll(", \"name\": ");
        try escapeJsonString(w, f.name);
        try w.writeAll(", \"file\": ");
        try escapeJsonString(w, f.file);
        try w.writeAll(", \"kind\": ");
        try escapeJsonString(w, f.kind);
        try w.print(", \"line\": {d}, \"lines\": {d}, \"branches\": {d}, \"complexity\": {d} }}", .{
            f.line, f.lines, f.branches, f.complexity,
        });
    }
    try w.writeAll("\n  ]\n}\n");
    return aw.toOwnedSlice();
}

// ─── dead_code.json ──────────────────────────────────────────────────────────

pub fn buildDeadCodeJson(allocator: std.mem.Allocator, dc: *const types.DeadCode) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"indexedAt\": {d},\n  \"unusedExports\": [\n", .{dc.indexed_at});
    for (dc.unused_exports.items, 0..) |*e, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    { \"file\": ");
        try escapeJsonString(w, e.file);
        try w.writeAll(", \"symbol\": ");
        try escapeJsonString(w, e.symbol);
        try w.writeAll(", \"kind\": ");
        try escapeJsonString(w, e.kind);
        try w.print(", \"line\": {d} }}", .{e.line});
    }
    try w.writeAll("\n  ],\n  \"unreachableFiles\": [");
    for (dc.unreachable_files.items, 0..) |f, i| {
        if (i > 0) try w.writeAll(", ");
        try escapeJsonString(w, f);
    }
    try w.writeAll("]\n}\n");
    return aw.toOwnedSlice();
}

// ─── api_surface.json ────────────────────────────────────────────────────────

pub fn buildApiSurfaceJson(allocator: std.mem.Allocator, api: *const types.ApiSurface) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"indexedAt\": {d},\n  \"count\": {d},\n  \"entries\": [\n", .{ api.indexed_at, api.count });
    for (api.entries.items, 0..) |*e, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    { \"file\": ");
        try escapeJsonString(w, e.file);
        try w.writeAll(", \"name\": ");
        try escapeJsonString(w, e.name);
        try w.writeAll(", \"kind\": ");
        try escapeJsonString(w, e.kind);
        try w.writeAll(", \"signature\": ");
        try escapeJsonString(w, e.signature);
        try w.print(", \"line\": {d}", .{e.line});
        if (e.doc) |d| {
            try w.writeAll(", \"doc\": ");
            try escapeJsonString(w, d);
        }
        try w.writeAll(" }");
    }
    try w.writeAll("\n  ]\n}\n");
    return aw.toOwnedSlice();
}

pub fn buildTestMapJson(allocator: std.mem.Allocator, m: *const types.TestMap) ![]const u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print("{{\n  \"indexedAt\": {d},\n  \"map\": {{\n", .{m.indexed_at});
    var first = true;
    var it = m.map.iterator();
    while (it.next()) |e| {
        if (!first) try w.writeAll(",\n");
        first = false;
        try w.writeAll("    ");
        try escapeJsonString(w, e.key_ptr.*);
        try w.writeAll(": [");
        for (e.value_ptr.items, 0..) |p, j| {
            if (j > 0) try w.writeAll(", ");
            try escapeJsonString(w, p);
        }
        try w.writeAll("]");
    }
    try w.writeAll("\n  }\n}\n");
    return aw.toOwnedSlice();
}
