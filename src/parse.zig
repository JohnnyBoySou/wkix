const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;
const types = @import("types");

fn nowMs() i64 {
    const spec = std.posix.clock_gettime(.REALTIME) catch return 0;
    return @as(i64, spec.sec) * 1000 + @as(i64, @divTrunc(spec.nsec, 1_000_000));
}
const walk = @import("walk");
const ts = @import("ts_parser");
const extractors = @import("extractors");

/// Indexa ficheiro: lê conteúdo, parse com tree-sitter, extrai símbolos/imports/exports.
/// Caller owns returned FileNode; call types.fileNodeDeinit then free path/absolute_path/sha256.
pub fn indexFile(
    allocator: std.mem.Allocator,
    io: Io,
    absolute_path: []const u8,
    relative_path: []const u8,
    sha256_hash: []const u8,
) !types.FileNode {
    const f = Dir.openFileAbsolute(io, absolute_path, .{}) catch return error.OpenError;
    defer f.close(io);

    var buf: [2 * 1024 * 1024]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return error.ReadError;
    const content = buf[0..n];

    var lines: u32 = 1;
    for (content) |c| {
        if (c == '\n') lines += 1;
    }

    const lang = walk.detectLanguage(relative_path) orelse .typescript;
    const lang_zig = switch (lang) {
        .typescript => types.Language.typescript,
        .tsx => types.Language.tsx,
        .javascript => types.Language.javascript,
        .jsx => types.Language.jsx,
    };

    var symbols: std.ArrayList(types.CodeSymbol) = .empty;
    var imports: std.ArrayList(types.ImportRecord) = .empty;
    var exports: std.ArrayList([]const u8) = .empty;
    var has_default_export = false;

    if (ts.parse(allocator, content, lang_zig)) |parse_result| {
        var result = parse_result;
        defer result.free();
        if (extractors.extractImports(allocator, result.root, result.source)) |import_list| {
            imports = import_list;
        } else |_| {}
        if (extractors.extractExports(allocator, result.root, result.source)) |export_info| {
            exports = export_info.names;
            has_default_export = export_info.has_default_export;
        } else |_| {}
        if (extractors.extractSymbols(allocator, result.root, result.source, relative_path)) |sym_list| {
            symbols = sym_list;
        } else |_| {}
    }

    return .{
        .path = try allocator.dupe(u8, relative_path),
        .absolute_path = try allocator.dupe(u8, absolute_path),
        .language = lang_zig,
        .size = content.len,
        .lines = lines,
        .sha256 = try allocator.dupe(u8, sha256_hash),
        .symbols = symbols,
        .imports = imports,
        .exports = exports,
        .has_default_export = has_default_export,
        .indexed_at = nowMs(),
    };
}
