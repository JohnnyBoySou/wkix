const std = @import("std");

pub const Language = enum {
    typescript,
    tsx,
    javascript,
    jsx,
};

pub const Position = struct { line: u32, column: u32 };
pub const Range = struct { start: Position, end: Position };

pub const CodeSymbol = struct {
    id: []const u8,
    name: []const u8,
    kind: []const u8,
    range: Range,
    modifiers: std.ArrayList([]const u8) = .empty,
    return_type: ?[]const u8 = null,
    parameters: std.ArrayList(Parameter) = .empty,
    type_parameters: std.ArrayList([]const u8) = .empty,
    parent_name: ?[]const u8 = null,
    doc_comment: ?[]const u8 = null,
    is_exported: bool = false,
};

pub const Parameter = struct {
    name: []const u8,
    type_annot: ?[]const u8 = null,
    optional: bool = false,
    default_value: ?[]const u8 = null,
};

pub const ImportRecord = struct {
    source: []const u8,
    kind: []const u8, // "named" | "namespace" | "default" | "side-effect" | "type"
    names: std.ArrayList([]const u8) = .empty,
    alias: ?[]const u8 = null,
    is_type_only: bool = false,
};

pub const FileNode = struct {
    path: []const u8,
    absolute_path: []const u8,
    language: Language,
    size: u64,
    lines: u32,
    sha256: []const u8,
    symbols: std.ArrayList(CodeSymbol) = .empty,
    imports: std.ArrayList(ImportRecord) = .empty,
    exports: std.ArrayList([]const u8) = .empty,
    has_default_export: bool = false,
    indexed_at: i64 = 0,
};

pub const RepoMapEntry = struct {
    path: []const u8,
    language: Language,
    size: u64,
    lines: u32,
    sha256: []const u8,
    symbol_count: usize,
    export_count: usize,
    import_count: usize,
};

pub const RepoMap = struct {
    root: []const u8,
    indexed_at: i64,
    file_count: usize,
    total_lines: u64,
    total_symbols: usize,
    files: std.ArrayList(RepoMapEntry),
};

pub const Chunk = struct {
    id: []const u8,
    file_path: []const u8,
    start_line: u32,
    end_line: u32,
    content: []const u8,
    symbol_names: std.ArrayList([]const u8),
    language: []const u8,
};

pub const ChunkIndex = struct {
    indexed_at: i64,
    chunks: std.ArrayList(Chunk),
};

pub const ImportGraphNode = struct {
    path: []const u8,
    imports: std.ArrayList([]const u8),
    imported_by: std.ArrayList([]const u8),
};

pub const TodoEntry = struct {
    path: []const u8,
    line: u32,
    text: []const u8,
};

pub const TodoIndex = struct {
    indexed_at: i64,
    entries: std.ArrayList(TodoEntry),
};

pub const VectorEntry = struct {
    chunk_id: []const u8,
    vector: std.ArrayList(f64),
};

pub const VectorIndex = struct {
    indexed_at: i64,
    model: []const u8,
    dimensions: u32,
    entries: std.ArrayList(VectorEntry),
};

// symbols.json: byName computed at write time from nodes
pub const SymbolIndex = struct {
    indexed_at: i64,
    count: usize,
    all: std.ArrayList(CodeSymbol),
};

pub const ImportGraph = struct {
    indexed_at: i64,
    nodes: std.StringHashMap(ImportGraphNode),
};

pub const RepoDocs = struct {
    indexed_at: i64,
    content: []const u8,
};

pub const ProjectMetadata = struct {
    indexed_at: i64,
    name: ?[]const u8 = null,
    main: ?[]const u8 = null,
    module: ?[]const u8 = null,
    scripts: std.StringHashMap([]const u8),
    dependency_count: usize = 0,
    dev_dependency_count: usize = 0,
};

pub const TestMap = struct {
    indexed_at: i64,
    map: std.StringHashMap(std.ArrayList([]const u8)),
};

pub fn languageToString(lang: Language) []const u8 {
    return switch (lang) {
        .typescript => "typescript",
        .tsx => "tsx",
        .javascript => "javascript",
        .jsx => "jsx",
    };
}

/// Liberta um CodeSymbol e os seus campos alocados (para uso em SymbolIndex).
pub fn codeSymbolDeinit(s: *CodeSymbol, allocator: std.mem.Allocator) void {
    allocator.free(s.id);
    allocator.free(s.name);
    allocator.free(s.kind);
    if (s.return_type) |rt| allocator.free(rt);
    if (s.parent_name) |pn| allocator.free(pn);
    if (s.doc_comment) |dc| allocator.free(dc);
    // modifiers são literais ("export", "async", etc.), não alocados
    s.modifiers.deinit(allocator);
    for (s.parameters.items) |*p| {
        allocator.free(p.name);
        if (p.type_annot) |ta| allocator.free(ta);
        if (p.default_value) |dv| allocator.free(dv);
    }
    s.parameters.deinit(allocator);
    for (s.type_parameters.items) |tp| allocator.free(tp);
    s.type_parameters.deinit(allocator);
}

pub fn fileNodeDeinit(node: *FileNode, allocator: std.mem.Allocator) void {
    for (node.symbols.items) |*s| codeSymbolDeinit(s, allocator);
    node.symbols.deinit(allocator);
    for (node.imports.items) |*imp| {
        allocator.free(imp.source);
        // imp.kind é literal ("named", "default", etc.)
        for (imp.names.items) |n| allocator.free(n);
        imp.names.deinit(allocator);
        if (imp.alias) |a| allocator.free(a);
    }
    node.imports.deinit(allocator);
    for (node.exports.items) |e| allocator.free(e);
    node.exports.deinit(allocator);
}
