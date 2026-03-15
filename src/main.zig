const std = @import("std");
const Thread = std.Thread;
const process = std.process;
const time = std.time;
const walk = @import("walk");
const hash = @import("hash");
const metadata = @import("metadata");
const parse = @import("parse");
const types = @import("types");
const chunk = @import("chunk");
const indices = @import("indices");
const writer = @import("writer");

fn hashWorker(io: std.Io, batch: []const walk.WalkedFile, results: [][16]u8) void {
    for (batch, results) |w, *r| {
        hash.hashFileToBuffer(io, w.absolute_path, r) catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();

    _ = args_iter.next(); // skip executable name

    var root_arg: ?[]const u8 = null;
    var force: bool = false;
    var quiet: bool = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            root_arg = arg;
        }
    }

    const root_path = root_arg orelse blk: {
        break :blk try std.process.getCwdAlloc(allocator);
    };
    defer if (root_arg == null) allocator.free(root_path);

    // Resolve to absolute for Dir.openDirAbsolute
    const root_absolute = blk: {
        if (std.fs.path.isAbsolute(root_path)) break :blk try allocator.dupe(u8, root_path);
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.join(allocator, &.{ cwd, root_path });
    };
    defer allocator.free(root_absolute);

    const t_start = if (!quiet) time.Instant.now() catch null else null;

    if (!quiet) std.log.info("workspace  {s}", .{root_absolute});

    // 1. Walk
    var walked = try walk.walkRepo(.{
        .root_absolute_path = root_absolute,
        .allocator = allocator,
        .io = io,
    });
    defer walk.deinitWalked(allocator, &walked);

    // 2. Hash all files (parallel when multi-threaded)
    var current_hashes = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = current_hashes.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        current_hashes.deinit();
    }

    const num_workers = blk: {
        if (@import("builtin").single_threaded or walked.items.len == 0) break :blk 0;
        const n = Thread.getCpuCount() catch 4;
        break :blk @min(n, walked.items.len);
    };

    if (num_workers <= 1) {
        var hash_done: usize = 0;
        for (walked.items) |w| {
            const h = hash.hashFile(allocator, io, w.absolute_path) catch continue;
            const k = allocator.dupe(u8, w.relative_path) catch {
                allocator.free(h);
                continue;
            };
            current_hashes.put(k, h) catch {
                allocator.free(k);
                allocator.free(h);
                continue;
            };
            hash_done += 1;
        }
    } else {
        const results = allocator.alloc([16]u8, walked.items.len) catch return error.OutOfMemory;
        defer allocator.free(results);

        const step = (walked.items.len + num_workers - 1) / num_workers;
        var threads: std.ArrayList(Thread) = std.ArrayList(Thread).empty;
        defer threads.deinit(allocator);

        var i: usize = 0;
        while (i < num_workers) : (i += 1) {
            const start = i * step;
            const end = @min(start + step, walked.items.len);
            if (start >= end) break;
            const thread = try Thread.spawn(.{}, hashWorker, .{ io, walked.items[start..end], results[start..end] });
            try threads.append(allocator, thread);
        }
        for (threads.items) |t| t.join();

        var hash_done: usize = 0;
        for (walked.items, results) |w, r| {
            const h = try allocator.dupe(u8, &r);
            current_hashes.put(try allocator.dupe(u8, w.relative_path), h) catch {
                allocator.free(h);
                continue;
            };
            hash_done += 1;
        }
    }

    // 3. Incremental: diff hashes, list files to reindex
    const workspace_dir = try metadata.getWorkspaceDir(allocator, root_absolute);
    defer allocator.free(workspace_dir);

    var prev_meta: ?metadata.WorkspaceMetadata = null;
    if (!force) {
        prev_meta = metadata.readMetadata(allocator, io, workspace_dir) catch null;
    }
    defer if (prev_meta) |*m| m.deinit(allocator);

    var changed_files = std.ArrayList(walk.WalkedFile).empty;
    defer {
        for (changed_files.items) |c| {
            allocator.free(c.absolute_path);
            allocator.free(c.relative_path);
        }
        changed_files.deinit(allocator);
    }
    var removed_count: usize = 0;

    if (prev_meta) |*prev| {
        for (walked.items) |w| {
            const cur_hash = current_hashes.get(w.relative_path) orelse continue;
            const prev_hash = prev.file_hashes.get(w.relative_path);
            if (!std.mem.eql(u8, cur_hash, prev_hash orelse "")) {
                try changed_files.append(allocator, .{
                    .absolute_path = try allocator.dupe(u8, w.absolute_path),
                    .relative_path = try allocator.dupe(u8, w.relative_path),
                });
            }
        }
        var it = prev.file_hashes.keyIterator();
        while (it.next()) |k| {
            if (!current_hashes.contains(k.*)) removed_count += 1;
        }
    } else {
        for (walked.items) |w| {
            try changed_files.append(allocator, .{
                .absolute_path = try allocator.dupe(u8, w.absolute_path),
                .relative_path = try allocator.dupe(u8, w.relative_path),
            });
        }
    }

    const incremental = prev_meta != null and changed_files.items.len < walked.items.len;
    _ = incremental;

    // 4. Parse changed files com tree-sitter (símbolos, imports, exports)
    var all_nodes = std.ArrayList(types.FileNode).empty;
    defer {
        for (all_nodes.items) |*node| {
            types.fileNodeDeinit(node, allocator);
            allocator.free(node.path);
            allocator.free(node.absolute_path);
            allocator.free(node.sha256);
        }
        all_nodes.deinit(allocator);
    }

    for (changed_files.items) |w| {
        const h = current_hashes.get(w.relative_path) orelse continue;
        var node = parse.indexFile(allocator, io, w.absolute_path, w.relative_path, h) catch continue;
        all_nodes.append(allocator, node) catch {
            types.fileNodeDeinit(&node, allocator);
            allocator.free(node.path);
            allocator.free(node.absolute_path);
            allocator.free(node.sha256);
            continue;
        };
    }

    // 5. Chunk
    var chunk_index = chunk.buildChunks(allocator, io, all_nodes.items) catch blk: {
        const empty = types.ChunkIndex{ .indexed_at = 0, .chunks = std.ArrayList(types.Chunk).empty };
        break :blk empty;
    };
    defer {
        for (chunk_index.chunks.items) |*c| {
            allocator.free(c.id);
            allocator.free(c.content);
            allocator.free(c.language);
            c.symbol_names.deinit(allocator);
        }
        chunk_index.chunks.deinit(allocator);
    }
    // 5. Indices
    var repo_map = indices.buildRepoMap(allocator, root_absolute, all_nodes.items) catch return error.OutOfMemory;
    defer {
        allocator.free(repo_map.root);
        repo_map.files.deinit(allocator);
    }
    var symbol_index = indices.buildSymbolIndex(allocator, all_nodes.items) catch return error.OutOfMemory;
    defer indices.symbolIndexDeinit(allocator, &symbol_index);
    var import_graph = indices.buildImportGraph(allocator, all_nodes.items) catch return error.OutOfMemory;
    defer indices.importGraphDeinit(allocator, &import_graph);
    var repo_docs = indices.buildRepoDocs(allocator, io, root_absolute) catch return error.OutOfMemory;
    defer allocator.free(repo_docs.content);
    var project_meta = indices.buildProjectMetadata(allocator, io, root_absolute) catch return error.OutOfMemory;
    defer indices.projectMetadataDeinit(allocator, &project_meta);
    var todo_index = indices.buildTodoIndex(allocator, io, walked.items) catch return error.OutOfMemory;
    defer indices.todoDeinit(allocator, &todo_index);
    var test_map = indices.buildTestMap(allocator, all_nodes.items) catch return error.OutOfMemory;
    defer indices.testMapDeinit(allocator, &test_map);

    // 6. Write .workspace
    std.Io.Dir.createDirAbsolute(io, workspace_dir, .default_dir) catch {};
    const meta_json = try writer.buildMetadataJson(allocator, root_absolute, &current_hashes);
    defer allocator.free(meta_json);
    try writer.writeJsonFile(allocator, io, workspace_dir, "metadata.json", meta_json);
    const repo_json = try writer.buildRepoMapJson(allocator, &repo_map);
    defer allocator.free(repo_json);
    try writer.writeJsonFile(allocator, io, workspace_dir, "repo_map.json", repo_json);
    const symbols_json = try writer.buildSymbolIndexJson(allocator, &symbol_index);
    defer allocator.free(symbols_json);
    try writer.writeJsonFile(allocator, io, workspace_dir, "symbols.json", symbols_json);
    const chunks_json = try writer.buildChunksJson(allocator, &chunk_index);
    defer allocator.free(chunks_json);
    try writer.writeJsonFile(allocator, io, workspace_dir, "chunks.json", chunks_json);
    const import_graph_json = try writer.buildImportGraphJson(allocator, &import_graph);
    defer allocator.free(import_graph_json);
    try writer.writeJsonFile(allocator, io, workspace_dir, "import_graph.json", import_graph_json);
    const repo_docs_json = try writer.buildRepoDocsJson(allocator, &repo_docs);
    defer allocator.free(repo_docs_json);
    try writer.writeJsonFile(allocator, io, workspace_dir, "repo_docs.json", repo_docs_json);
    const project_meta_json = try writer.buildProjectMetadataJson(allocator, &project_meta);
    defer allocator.free(project_meta_json);
    try writer.writeJsonFile(allocator, io, workspace_dir, "project_metadata.json", project_meta_json);
    const todos_json = try writer.buildTodosJson(allocator, &todo_index);
    defer allocator.free(todos_json);
    try writer.writeJsonFile(allocator, io, workspace_dir, "todos.json", todos_json);
    const test_map_json = try writer.buildTestMapJson(allocator, &test_map);
    defer allocator.free(test_map_json);
    try writer.writeJsonFile(allocator, io, workspace_dir, "test_map.json", test_map_json);
    if (t_start) |ts| {
        const now = time.Instant.now() catch ts;
        const elapsed_s = @as(f64, @floatFromInt(now.since(ts))) / 1_000_000_000.0;
        std.log.info("✓  {d} files · {d} changed · {d} symbols · {d} chunks  [{d:.2}s]", .{
            walked.items.len,
            changed_files.items.len,
            repo_map.total_symbols,
            chunk_index.chunks.items.len,
            elapsed_s,
        });
    } else {
        std.log.info("✓  {d} files · {d} changed · {d} symbols · {d} chunks", .{
            walked.items.len,
            changed_files.items.len,
            repo_map.total_symbols,
            chunk_index.chunks.items.len,
        });
    }
}
