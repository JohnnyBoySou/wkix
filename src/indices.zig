const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const types = @import("types");
const walk = @import("walk");

fn nowMs() i64 {
    if (comptime @import("builtin").os.tag == .windows) return 0;
    const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
    return @as(i64, ts.sec) * 1000 + @as(i64, @divTrunc(ts.nsec, 1_000_000));
}

pub fn buildRepoMap(allocator: std.mem.Allocator, root: []const u8, nodes: []const types.FileNode) !types.RepoMap {
    var entries = std.ArrayList(types.RepoMapEntry).empty;
    var total_lines: u64 = 0;
    var total_symbols: usize = 0;
    for (nodes) |*n| {
        total_lines += n.lines;
        total_symbols += n.symbols.items.len;
        try entries.append(allocator, .{
            .path = n.path,
            .language = n.language,
            .size = n.size,
            .lines = n.lines,
            .sha256 = n.sha256,
            .symbol_count = n.symbols.items.len,
            .export_count = n.exports.items.len + (if (n.has_default_export) @as(usize, 1) else 0),
            .import_count = n.imports.items.len,
        });
    }
    return .{
        .root = try allocator.dupe(u8, root),
        .indexed_at = nowMs(),
        .file_count = nodes.len,
        .total_lines = total_lines,
        .total_symbols = total_symbols,
        .files = entries,
    };
}

fn dupCodeSymbol(allocator: std.mem.Allocator, s: *const types.CodeSymbol) !types.CodeSymbol {
    var mods: std.ArrayList([]const u8) = .empty;
    for (s.modifiers.items) |m| try mods.append(allocator, m);
    var params: std.ArrayList(types.Parameter) = .empty;
    for (s.parameters.items) |*p| {
        try params.append(allocator, .{
            .name = try allocator.dupe(u8, p.name),
            .type_annot = if (p.type_annot) |ta| try allocator.dupe(u8, ta) else null,
            .optional = p.optional,
            .default_value = if (p.default_value) |dv| try allocator.dupe(u8, dv) else null,
        });
    }
    var tparams: std.ArrayList([]const u8) = .empty;
    for (s.type_parameters.items) |tp| try tparams.append(allocator, try allocator.dupe(u8, tp));
    var calls: std.ArrayList([]const u8) = .empty;
    for (s.calls.items) |c| try calls.append(allocator, try allocator.dupe(u8, c));
    var implements: std.ArrayList([]const u8) = .empty;
    for (s.implements.items) |impl| try implements.append(allocator, try allocator.dupe(u8, impl));
    return .{
        .id = try allocator.dupe(u8, s.id),
        .name = try allocator.dupe(u8, s.name),
        .kind = try allocator.dupe(u8, s.kind),
        .range = s.range,
        .modifiers = mods,
        .return_type = if (s.return_type) |r| try allocator.dupe(u8, r) else null,
        .parameters = params,
        .type_parameters = tparams,
        .parent_name = if (s.parent_name) |pn| try allocator.dupe(u8, pn) else null,
        .doc_comment = if (s.doc_comment) |dc| try allocator.dupe(u8, dc) else null,
        .is_exported = s.is_exported,
        .calls = calls,
        .extends = if (s.extends) |e| try allocator.dupe(u8, e) else null,
        .implements = implements,
        .branches = s.branches,
    };
}

/// Symbol index: all symbols flattened from nodes (deep copy). byName built at write time.
pub fn buildSymbolIndex(allocator: std.mem.Allocator, nodes: []const types.FileNode) !types.SymbolIndex {
    var all = std.ArrayList(types.CodeSymbol).empty;
    for (nodes) |*n| {
        for (n.symbols.items) |*s| try all.append(allocator, try dupCodeSymbol(allocator, s));
    }
    return .{ .indexed_at = nowMs(), .count = all.items.len, .all = all };
}

pub fn symbolIndexDeinit(allocator: std.mem.Allocator, index: *types.SymbolIndex) void {
    for (index.all.items) |*s| types.codeSymbolDeinit(s, allocator);
    index.all.deinit(allocator);
}

/// Resolve um import relativo (ex: "./types") a partir de um arquivo para um caminho de arquivo do repo.
/// Retorna slice owned ou null se não conseguir resolver.
fn resolveRelativeImport(
    allocator: std.mem.Allocator,
    from_path: []const u8,
    import_source: []const u8,
    known_paths: *const std.StringHashMap(void),
) ?[]const u8 {
    if (!std.mem.startsWith(u8, import_source, "./") and !std.mem.startsWith(u8, import_source, "../"))
        return null;

    const dir = std.fs.path.dirname(from_path) orelse "";

    const extensions = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", "/index.ts", "/index.tsx", "/index.js" };

    // Se já tem extensão conhecida, tenta direto
    const candidate_base = std.fs.path.join(allocator, &.{ dir, import_source }) catch return null;
    defer allocator.free(candidate_base);

    // Normaliza: remove ../ e ./
    const normalized = normalizePath(allocator, candidate_base) catch return null;
    defer allocator.free(normalized);

    if (known_paths.contains(normalized)) {
        return allocator.dupe(u8, normalized) catch null;
    }

    for (extensions) |ext| {
        const with_ext = std.fmt.allocPrint(allocator, "{s}{s}", .{ normalized, ext }) catch continue;
        defer allocator.free(with_ext);
        if (known_paths.contains(with_ext)) {
            return allocator.dupe(u8, with_ext) catch null;
        }
    }
    return null;
}

/// Normaliza path POSIX: resolve ../ e ./
fn normalizePath(allocator: std.mem.Allocator, p: []const u8) ![]const u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);

    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
        } else if (seg.len > 0) {
            try parts.append(allocator, seg);
        }
    }
    return std.mem.join(allocator, "/", parts.items);
}

/// Import graph from nodes: path -> { imports: sources[], importedBy: [resolved] }.
pub fn buildImportGraph(allocator: std.mem.Allocator, nodes: []const types.FileNode) !types.ImportGraph {
    // Mapa de path conhecido para detectar resolução
    var known = std.StringHashMap(void).init(allocator);
    defer known.deinit();
    for (nodes) |*n| try known.put(n.path, {});

    var nodes_map = std.StringHashMap(types.ImportGraphNode).init(allocator);
    errdefer {
        var it = nodes_map.iterator();
        while (it.next()) |e| {
            e.value_ptr.imports.deinit(allocator);
            e.value_ptr.imported_by.deinit(allocator);
        }
        nodes_map.deinit();
    }

    // Primeira passagem: construir nós com imports resolvidos
    for (nodes) |*n| {
        var imports = std.ArrayList([]const u8).empty;
        for (n.imports.items) |imp| {
            const resolved = resolveRelativeImport(allocator, n.path, imp.source, &known);
            if (resolved) |r| {
                // Usar path resolvido quando possível; senão usar source original
                imports.append(allocator, r) catch {
                    allocator.free(r);
                    imports.append(allocator, imp.source) catch {};
                };
            } else {
                // Import externo (node_modules) — copia o source
                const dup = allocator.dupe(u8, imp.source) catch continue;
                imports.append(allocator, dup) catch {
                    allocator.free(dup);
                };
            }
        }
        const key = try allocator.dupe(u8, n.path);
        try nodes_map.put(key, .{
            .path = n.path,
            .imports = imports,
            .imported_by = std.ArrayList([]const u8).empty,
        });
    }

    // Segunda passagem: preencher importedBy
    var it = nodes_map.iterator();
    while (it.next()) |e| {
        const importer_path = e.key_ptr.*;
        for (e.value_ptr.imports.items) |imported| {
            if (nodes_map.getPtr(imported)) |target| {
                const dup = allocator.dupe(u8, importer_path) catch continue;
                target.imported_by.append(allocator, dup) catch {
                    allocator.free(dup);
                };
            }
        }
    }

    return .{ .indexed_at = nowMs(), .nodes = nodes_map };
}

/// Lê o conteúdo do primeiro README encontrado no root.
pub fn buildRepoDocs(allocator: std.mem.Allocator, io: Io, root: []const u8) !types.RepoDocs {
    const candidates = [_][]const u8{ "README.md", "readme.md", "README.txt", "CONTRIBUTING.md" };
    for (candidates) |name| {
        const path = std.fs.path.join(allocator, &.{ root, name }) catch continue;
        defer allocator.free(path);
        const f = Dir.openFileAbsolute(io, path, .{}) catch continue;
        defer f.close(io);
        var buf: [256 * 1024]u8 = undefined;
        const n = f.readPositionalAll(io, &buf, 0) catch continue;
        return .{
            .indexed_at = nowMs(),
            .content = try allocator.dupe(u8, buf[0..n]),
        };
    }
    return .{ .indexed_at = nowMs(), .content = try allocator.dupe(u8, "") };
}

/// Lê package.json do root e extrai name, scripts, contagem de deps.
pub fn buildProjectMetadata(allocator: std.mem.Allocator, io: Io, root: []const u8) !types.ProjectMetadata {
    const pkg_path = try std.fs.path.join(allocator, &.{ root, "package.json" });
    defer allocator.free(pkg_path);

    var scripts = std.StringHashMap([]const u8).init(allocator);
    var name: ?[]const u8 = null;
    var dep_count: usize = 0;
    var dev_dep_count: usize = 0;

    const f = Dir.openFileAbsolute(io, pkg_path, .{}) catch {
        return .{
            .indexed_at = nowMs(),
            .scripts = scripts,
            .dependency_count = 0,
            .dev_dependency_count = 0,
        };
    };
    defer f.close(io);

    var buf: [512 * 1024]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch {
        return .{
            .indexed_at = nowMs(),
            .scripts = scripts,
            .dependency_count = 0,
            .dev_dependency_count = 0,
        };
    };
    const src = buf[0..n];

    // Parser JSON mínimo para package.json
    name = extractJsonStringField(allocator, src, "\"name\"");
    scripts = extractJsonObject(allocator, src, "\"scripts\"") catch std.StringHashMap([]const u8).init(allocator);
    dep_count = countJsonObjectKeys(src, "\"dependencies\"");
    dev_dep_count = countJsonObjectKeys(src, "\"devDependencies\"");

    return .{
        .indexed_at = nowMs(),
        .name = name,
        .scripts = scripts,
        .dependency_count = dep_count,
        .dev_dependency_count = dev_dep_count,
    };
}

/// Extrai o valor de string de um campo JSON simples: "key": "value"
fn extractJsonStringField(allocator: std.mem.Allocator, src: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, src, key) orelse return null;
    var i = pos + key.len;
    // Avança até ':'
    while (i < src.len and src[i] != ':') i += 1;
    i += 1;
    // Avança whitespace
    while (i < src.len and (src[i] == ' ' or src[i] == '\n' or src[i] == '\r' or src[i] == '\t')) i += 1;
    if (i >= src.len or src[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < src.len and src[i] != '"') {
        if (src[i] == '\\') i += 1; // skip escaped char
        i += 1;
    }
    return allocator.dupe(u8, src[start..i]) catch null;
}

/// Extrai um objeto JSON simples (apenas string: string) dado a chave.
fn extractJsonObject(allocator: std.mem.Allocator, src: []const u8, key: []const u8) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    const pos = std.mem.indexOf(u8, src, key) orelse return map;
    var i = pos + key.len;
    while (i < src.len and src[i] != '{') i += 1;
    if (i >= src.len) return map;
    i += 1; // skip '{'
    var depth: usize = 1;
    while (i < src.len and depth > 0) {
        if (src[i] == '{') { depth += 1; i += 1; continue; }
        if (src[i] == '}') { depth -= 1; i += 1; continue; }
        if (src[i] != '"' or depth != 1) { i += 1; continue; }
        // Lê chave
        i += 1;
        const k_start = i;
        while (i < src.len and src[i] != '"') { if (src[i] == '\\') i += 1; i += 1; }
        const k = src[k_start..i];
        i += 1; // skip '"'
        while (i < src.len and src[i] != ':') i += 1;
        i += 1;
        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
        if (i >= src.len or src[i] != '"') continue;
        i += 1;
        const v_start = i;
        while (i < src.len and src[i] != '"') { if (src[i] == '\\') i += 1; i += 1; }
        const v = src[v_start..i];
        i += 1;
        const k_owned = allocator.dupe(u8, k) catch continue;
        const v_owned = allocator.dupe(u8, v) catch { allocator.free(k_owned); continue; };
        map.put(k_owned, v_owned) catch { allocator.free(k_owned); allocator.free(v_owned); };
    }
    return map;
}

/// Conta quantas chaves tem um objeto JSON dado a chave pai.
fn countJsonObjectKeys(src: []const u8, key: []const u8) usize {
    const pos = std.mem.indexOf(u8, src, key) orelse return 0;
    var i = pos + key.len;
    while (i < src.len and src[i] != '{') i += 1;
    if (i >= src.len) return 0;
    i += 1;
    var count: usize = 0;
    var depth: usize = 1;
    while (i < src.len and depth > 0) {
        if (src[i] == '{') { depth += 1; i += 1; continue; }
        if (src[i] == '}') { depth -= 1; i += 1; continue; }
        if (src[i] == '"' and depth == 1) {
            i += 1;
            while (i < src.len and src[i] != '"') { if (src[i] == '\\') i += 1; i += 1; }
            i += 1;
            // Verifica se é chave (seguido de ':')
            var j = i;
            while (j < src.len and (src[j] == ' ' or src[j] == '\t' or src[j] == '\n' or src[j] == '\r')) j += 1;
            if (j < src.len and src[j] == ':') count += 1;
            continue;
        }
        i += 1;
    }
    return count;
}

const TODO_PATTERNS = [_][]const u8{ "TODO", "FIXME", "HACK", "NOTE", "XXX" };

/// Escaneia arquivos TS/JS por TODO/FIXME/HACK/NOTE/XXX nos comentários.
pub fn buildTodoIndex(allocator: std.mem.Allocator, io: Io, walked: []const walk.WalkedFile) !types.TodoIndex {
    var entries = std.ArrayList(types.TodoEntry).empty;

    for (walked) |w| {
        const f = Dir.openFileAbsolute(io, w.absolute_path, .{}) catch continue;
        defer f.close(io);
        var buf: [1 * 1024 * 1024]u8 = undefined;
        const n = f.readPositionalAll(io, &buf, 0) catch continue;
        const content = buf[0..n];

        var line_num: u32 = 1;
        var line_start: usize = 0;
        while (line_start < content.len) {
            var line_end = line_start;
            while (line_end < content.len and content[line_end] != '\n') line_end += 1;
            const line = content[line_start..line_end];

            for (TODO_PATTERNS) |pat| {
                if (std.mem.indexOf(u8, line, pat)) |idx| {
                    // Verifica que está num comentário (contém // ou * antes)
                    const before = line[0..idx];
                    const in_comment = std.mem.indexOf(u8, before, "//") != null or
                        std.mem.indexOf(u8, before, "*") != null or
                        std.mem.indexOf(u8, before, "#") != null;
                    if (!in_comment) continue;

                    const text_start = idx;
                    const trimmed = std.mem.trim(u8, line[text_start..], " \t\r");
                    if (trimmed.len == 0) continue;
                    const text = try allocator.dupe(u8, trimmed);
                    const path_dup = try allocator.dupe(u8, w.relative_path);
                    entries.append(allocator, .{
                        .path = path_dup,
                        .line = line_num,
                        .text = text,
                    }) catch {
                        allocator.free(text);
                        allocator.free(path_dup);
                    };
                    break; // um TODO por linha
                }
            }

            line_num += 1;
            line_start = if (line_end < content.len) line_end + 1 else content.len;
        }
    }

    return .{ .indexed_at = nowMs(), .entries = entries };
}

/// Mapeia arquivos fonte para seus arquivos de teste (heurística por convenção de nomes).
pub fn buildTestMap(allocator: std.mem.Allocator, nodes: []const types.FileNode) !types.TestMap {
    var map = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);

    // Separa arquivos de teste dos arquivos fonte
    var test_files = std.ArrayList([]const u8).empty;
    defer test_files.deinit(allocator);

    for (nodes) |*n| {
        if (isTestFile(n.path)) {
            test_files.append(allocator, n.path) catch {};
        }
    }

    // Para cada arquivo fonte, encontra os testes correspondentes
    for (nodes) |*n| {
        if (isTestFile(n.path)) continue;

        const base = std.fs.path.stem(n.path); // e.g. "chunker"
        const dir = std.fs.path.dirname(n.path) orelse "";

        var matches = std.ArrayList([]const u8).empty;
        for (test_files.items) |tf| {
            const tf_base = std.fs.path.stem(tf);
            // Verifica se o arquivo de teste contém o nome do arquivo fonte
            if (std.mem.indexOf(u8, tf_base, base) != null) {
                const tf_dir = std.fs.path.dirname(tf) orelse "";
                // Mesmo diretório ou subdiretório __tests__/test
                if (std.mem.eql(u8, dir, tf_dir) or
                    std.mem.endsWith(u8, tf_dir, "__tests__") or
                    std.mem.endsWith(u8, tf_dir, "test") or
                    std.mem.endsWith(u8, tf_dir, "tests"))
                {
                    matches.append(allocator, try allocator.dupe(u8, tf)) catch {};
                }
            }
        }

        if (matches.items.len > 0) {
            const key = try allocator.dupe(u8, n.path);
            map.put(key, matches) catch {
                allocator.free(key);
                for (matches.items) |m| allocator.free(m);
                matches.deinit(allocator);
            };
        } else {
            matches.deinit(allocator);
        }
    }

    return .{ .indexed_at = nowMs(), .map = map };
}

fn isTestFile(p: []const u8) bool {
    return std.mem.indexOf(u8, p, ".test.") != null or
        std.mem.indexOf(u8, p, ".spec.") != null or
        std.mem.indexOf(u8, p, "__tests__") != null or
        std.mem.endsWith(u8, p, ".test.ts") or
        std.mem.endsWith(u8, p, ".spec.ts") or
        std.mem.endsWith(u8, p, ".test.js") or
        std.mem.endsWith(u8, p, ".spec.js");
}

pub fn importGraphDeinit(allocator: std.mem.Allocator, graph: *types.ImportGraph) void {
    var it = graph.nodes.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        for (e.value_ptr.imports.items) |imp| allocator.free(imp);
        e.value_ptr.imports.deinit(allocator);
        for (e.value_ptr.imported_by.items) |ib| allocator.free(ib);
        e.value_ptr.imported_by.deinit(allocator);
    }
    graph.nodes.deinit();
}

pub fn projectMetadataDeinit(allocator: std.mem.Allocator, meta: *types.ProjectMetadata) void {
    if (meta.name) |n| allocator.free(n);
    var it = meta.scripts.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    meta.scripts.deinit();
}

pub fn testMapDeinit(allocator: std.mem.Allocator, m: *types.TestMap) void {
    var it = m.map.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        for (e.value_ptr.items) |p| allocator.free(p);
        e.value_ptr.deinit(allocator);
    }
    m.map.deinit();
}

pub fn todoDeinit(allocator: std.mem.Allocator, index: *types.TodoIndex) void {
    for (index.entries.items) |*e| {
        allocator.free(e.path);
        allocator.free(e.text);
    }
    index.entries.deinit(allocator);
}

// ─── call_graph.json ─────────────────────────────────────────────────────────

/// Build call graph: symbol_id → deduplicated list of called names.
pub fn buildCallGraph(allocator: std.mem.Allocator, nodes: []const types.FileNode) !types.CallGraph {
    var entries = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
    for (nodes) |*n| {
        for (n.symbols.items) |*s| {
            if (s.calls.items.len == 0) continue;
            var calls_copy: std.ArrayList([]const u8) = .empty;
            for (s.calls.items) |c| try calls_copy.append(allocator, try allocator.dupe(u8, c));
            const id_copy = try allocator.dupe(u8, s.id);
            try entries.put(id_copy, calls_copy);
        }
    }
    return .{ .indexed_at = nowMs(), .entries = entries };
}

pub fn callGraphDeinit(allocator: std.mem.Allocator, cg: *types.CallGraph) void {
    var it = cg.entries.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        for (e.value_ptr.items) |c| allocator.free(c);
        e.value_ptr.deinit(allocator);
    }
    cg.entries.deinit();
}

// ─── type_hierarchy.json ─────────────────────────────────────────────────────

/// Build type hierarchy from classes and interfaces that have extends/implements.
pub fn buildTypeHierarchy(allocator: std.mem.Allocator, nodes: []const types.FileNode) !types.TypeHierarchy {
    var type_nodes: std.ArrayList(types.TypeNode) = .empty;
    for (nodes) |*n| {
        for (n.symbols.items) |*s| {
            if (!std.mem.eql(u8, s.kind, "class") and
                !std.mem.eql(u8, s.kind, "abstract_class") and
                !std.mem.eql(u8, s.kind, "interface")) continue;
            if (s.extends == null and s.implements.items.len == 0) continue;

            // file path is the part of the id before '#'
            const sep = std.mem.indexOf(u8, s.id, "#");
            const sym_file = if (sep) |sp| s.id[0..sp] else n.path;

            var impls_copy: std.ArrayList([]const u8) = .empty;
            for (s.implements.items) |impl| try impls_copy.append(allocator, try allocator.dupe(u8, impl));

            try type_nodes.append(allocator, .{
                .name = try allocator.dupe(u8, s.name),
                .kind = try allocator.dupe(u8, s.kind),
                .extends = if (s.extends) |e| try allocator.dupe(u8, e) else null,
                .implements = impls_copy,
                .file = try allocator.dupe(u8, sym_file),
                .line = s.range.start.line,
            });
        }
    }
    return .{ .indexed_at = nowMs(), .nodes = type_nodes };
}

pub fn typeHierarchyDeinit(allocator: std.mem.Allocator, th: *types.TypeHierarchy) void {
    for (th.nodes.items) |*n| {
        allocator.free(n.name);
        allocator.free(n.kind);
        allocator.free(n.file);
        if (n.extends) |e| allocator.free(e);
        for (n.implements.items) |impl| allocator.free(impl);
        n.implements.deinit(allocator);
    }
    th.nodes.deinit(allocator);
}

// ─── env_vars.json ───────────────────────────────────────────────────────────

/// Scan source files for `process.env.VAR_NAME` usages.
pub fn buildEnvVarIndex(allocator: std.mem.Allocator, io: Io, walked: []const walk.WalkedFile) !types.EnvVarIndex {
    var usages: std.ArrayList(types.EnvVarUsage) = .empty;
    var seen_vars = std.StringHashMap(void).init(allocator);
    defer seen_vars.deinit();
    var vars: std.ArrayList([]const u8) = .empty;
    const needle = "process.env.";

    for (walked) |w| {
        const f = Dir.openFileAbsolute(io, w.absolute_path, .{}) catch continue;
        defer f.close(io);
        var buf: [1 * 1024 * 1024]u8 = undefined;
        const n = f.readPositionalAll(io, &buf, 0) catch continue;
        const content = buf[0..n];

        var line_num: u32 = 1;
        var line_start: usize = 0;
        while (line_start < content.len) {
            var line_end = line_start;
            while (line_end < content.len and content[line_end] != '\n') line_end += 1;
            const line = content[line_start..line_end];

            var search_pos: usize = 0;
            while (search_pos < line.len) {
                const idx = std.mem.indexOf(u8, line[search_pos..], needle) orelse break;
                const name_start = search_pos + idx + needle.len;
                var name_end = name_start;
                while (name_end < line.len and (std.ascii.isAlphanumeric(line[name_end]) or line[name_end] == '_')) {
                    name_end += 1;
                }
                if (name_end > name_start) {
                    const var_name = line[name_start..name_end];
                    const var_dup = try allocator.dupe(u8, var_name);
                    const file_dup = try allocator.dupe(u8, w.relative_path);
                    try usages.append(allocator, .{ .name = var_dup, .file = file_dup, .line = line_num });
                    if (!seen_vars.contains(var_name)) {
                        const vdup = try allocator.dupe(u8, var_name);
                        try seen_vars.put(vdup, {});
                        try vars.append(allocator, vdup);
                    }
                }
                search_pos += idx + needle.len + 1;
            }

            line_num += 1;
            line_start = if (line_end < content.len) line_end + 1 else content.len;
        }
    }
    return .{ .indexed_at = nowMs(), .vars = vars, .usages = usages };
}

pub fn envVarIndexDeinit(allocator: std.mem.Allocator, ev: *types.EnvVarIndex) void {
    for (ev.vars.items) |v| allocator.free(v);
    ev.vars.deinit(allocator);
    for (ev.usages.items) |*u| {
        allocator.free(u.name);
        allocator.free(u.file);
    }
    ev.usages.deinit(allocator);
}

// ─── complexity.json ─────────────────────────────────────────────────────────

const FUNCTION_KINDS = [_][]const u8{ "function", "arrow_function", "method", "constructor" };

/// Build complexity index from function-like symbols.
pub fn buildComplexityIndex(allocator: std.mem.Allocator, nodes: []const types.FileNode) !types.ComplexityIndex {
    var functions: std.ArrayList(types.FunctionComplexity) = .empty;
    var total_complexity: u64 = 0;

    for (nodes) |*n| {
        for (n.symbols.items) |*s| {
            var is_func = false;
            for (FUNCTION_KINDS) |fk| {
                if (std.mem.eql(u8, s.kind, fk)) { is_func = true; break; }
            }
            if (!is_func) continue;

            const lines: u32 = if (s.range.end.line > s.range.start.line)
                s.range.end.line - s.range.start.line else 0;
            const complexity: u32 = s.branches + 1;
            total_complexity += complexity;

            const sep = std.mem.indexOf(u8, s.id, "#");
            const sym_file = if (sep) |sp| s.id[0..sp] else n.path;

            try functions.append(allocator, .{
                .symbol_id = try allocator.dupe(u8, s.id),
                .name = try allocator.dupe(u8, s.name),
                .file = try allocator.dupe(u8, sym_file),
                .kind = try allocator.dupe(u8, s.kind),
                .lines = lines,
                .branches = s.branches,
                .complexity = complexity,
                .line = s.range.start.line,
            });
        }
    }

    const avg: f32 = if (functions.items.len > 0)
        @as(f32, @floatFromInt(total_complexity)) / @as(f32, @floatFromInt(functions.items.len))
    else 0.0;

    return .{
        .indexed_at = nowMs(),
        .total_functions = functions.items.len,
        .avg_complexity = avg,
        .functions = functions,
    };
}

pub fn complexityIndexDeinit(allocator: std.mem.Allocator, ci: *types.ComplexityIndex) void {
    for (ci.functions.items) |*f| {
        allocator.free(f.symbol_id);
        allocator.free(f.name);
        allocator.free(f.file);
        allocator.free(f.kind);
    }
    ci.functions.deinit(allocator);
}

// ─── dead_code.json ──────────────────────────────────────────────────────────

/// Detect exports never imported elsewhere and files no other file imports.
pub fn buildDeadCode(
    allocator: std.mem.Allocator,
    nodes: []const types.FileNode,
    graph: *const types.ImportGraph,
) !types.DeadCode {
    // Collect all names that are imported anywhere in the project
    var imported_names = std.StringHashMap(void).init(allocator);
    defer imported_names.deinit();
    for (nodes) |*n| {
        for (n.imports.items) |*imp| {
            for (imp.names.items) |name| try imported_names.put(name, {});
            if (imp.alias) |a| try imported_names.put(a, {});
        }
    }

    // Find exported symbols whose name does not appear in any import
    var unused: std.ArrayList(types.DeadExport) = .empty;
    for (nodes) |*n| {
        for (n.symbols.items) |*s| {
            if (!s.is_exported) continue;
            if (std.mem.eql(u8, s.name, "default")) continue; // skip default exports
            if (imported_names.contains(s.name)) continue;
            try unused.append(allocator, .{
                .file = try allocator.dupe(u8, n.path),
                .symbol = try allocator.dupe(u8, s.name),
                .kind = try allocator.dupe(u8, s.kind),
                .line = s.range.start.line,
            });
        }
    }

    // Find files with no importers (skip index/test/declaration files — likely entry points)
    var unreachable: std.ArrayList([]const u8) = .empty;
    var it = graph.nodes.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.imported_by.items.len > 0) continue;
        const path = e.key_ptr.*;
        if (std.mem.indexOf(u8, path, "index") != null) continue;
        if (std.mem.indexOf(u8, path, ".test.") != null) continue;
        if (std.mem.indexOf(u8, path, ".spec.") != null) continue;
        if (std.mem.endsWith(u8, path, ".d.ts")) continue;
        try unreachable.append(allocator, try allocator.dupe(u8, path));
    }

    return .{ .indexed_at = nowMs(), .unused_exports = unused, .unreachable_files = unreachable };
}

pub fn deadCodeDeinit(allocator: std.mem.Allocator, dc: *types.DeadCode) void {
    for (dc.unused_exports.items) |*e| {
        allocator.free(e.file);
        allocator.free(e.symbol);
        allocator.free(e.kind);
    }
    dc.unused_exports.deinit(allocator);
    for (dc.unreachable_files.items) |f| allocator.free(f);
    dc.unreachable_files.deinit(allocator);
}

// ─── api_surface.json ────────────────────────────────────────────────────────

fn buildSignature(allocator: std.mem.Allocator, s: *const types.CodeSymbol) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const is_callable = std.mem.eql(u8, s.kind, "function") or
        std.mem.eql(u8, s.kind, "arrow_function") or
        std.mem.eql(u8, s.kind, "method") or
        std.mem.eql(u8, s.kind, "constructor");

    if (is_callable) {
        try buf.appendSlice(allocator, "(");
        for (s.parameters.items, 0..) |*p, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, p.name);
            if (p.optional) try buf.appendSlice(allocator, "?");
            if (p.type_annot) |ta| {
                try buf.appendSlice(allocator, ": ");
                try buf.appendSlice(allocator, ta);
            }
        }
        try buf.appendSlice(allocator, ")");
        if (s.return_type) |rt| {
            try buf.appendSlice(allocator, ": ");
            try buf.appendSlice(allocator, rt);
        }
        return allocator.dupe(u8, buf.items);
    }

    if (std.mem.eql(u8, s.kind, "class") or std.mem.eql(u8, s.kind, "abstract_class")) {
        if (s.extends) |e| {
            try buf.appendSlice(allocator, "extends ");
            try buf.appendSlice(allocator, e);
        }
        for (s.implements.items, 0..) |impl, i| {
            if (i == 0) {
                if (buf.items.len > 0) try buf.appendSlice(allocator, " ");
                try buf.appendSlice(allocator, "implements ");
            } else try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, impl);
        }
        return allocator.dupe(u8, buf.items);
    }

    if (std.mem.eql(u8, s.kind, "interface")) {
        if (s.extends) |e| return std.fmt.allocPrint(allocator, "extends {s}", .{e});
        return allocator.dupe(u8, "");
    }

    if (s.return_type) |rt| return allocator.dupe(u8, rt);
    return allocator.dupe(u8, "");
}

/// Distilled public API: only exported symbols with their signatures.
pub fn buildApiSurface(allocator: std.mem.Allocator, nodes: []const types.FileNode) !types.ApiSurface {
    var entries: std.ArrayList(types.ApiEntry) = .empty;
    for (nodes) |*n| {
        for (n.symbols.items) |*s| {
            if (!s.is_exported) continue;
            const sep = std.mem.indexOf(u8, s.id, "#");
            const sym_file = if (sep) |sp| s.id[0..sp] else n.path;
            try entries.append(allocator, .{
                .file = try allocator.dupe(u8, sym_file),
                .name = try allocator.dupe(u8, s.name),
                .kind = try allocator.dupe(u8, s.kind),
                .signature = try buildSignature(allocator, s),
                .line = s.range.start.line,
                .doc = if (s.doc_comment) |dc| try allocator.dupe(u8, dc) else null,
            });
        }
    }
    return .{ .indexed_at = nowMs(), .count = entries.items.len, .entries = entries };
}

pub fn apiSurfaceDeinit(allocator: std.mem.Allocator, api: *types.ApiSurface) void {
    for (api.entries.items) |*e| {
        allocator.free(e.file);
        allocator.free(e.name);
        allocator.free(e.kind);
        allocator.free(e.signature);
        if (e.doc) |d| allocator.free(d);
    }
    api.entries.deinit(allocator);
}
