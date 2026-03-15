// Extractors de import/export/símbolos a partir da AST tree-sitter (port do type/workspace).

const std = @import("std");
const types = @import("types");
const ts = @import("ts_parser");

fn nodeTypeEq(node: ts.TSNode, typ: []const u8) bool {
    const p = ts.nodeType(node);
    return std.mem.eql(u8, std.mem.span(p), typ);
}

fn findChildByType(node: ts.TSNode, typ: []const u8) ?ts.TSNode {
    var i: u32 = 0;
    const n = ts.nodeChildCount(node);
    while (i < n) : (i += 1) {
        const c = ts.nodeChild(node, i);
        if (nodeTypeEq(c, typ)) return c;
    }
    return null;
}

fn hasChildType(node: ts.TSNode, typ: []const u8) bool {
    return findChildByType(node, typ) != null;
}

fn stripQuotes(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'' or s[0] == '`')) {
        const end: u8 = s[0];
        var last = s.len - 1;
        if (s[last] == end) last -= 1 else return try allocator.dupe(u8, s);
        return allocator.dupe(u8, s[1 .. last + 1]);
    }
    return try allocator.dupe(u8, s);
}

// ─── Call-name extractor ─────────────────────────────────────────────────────

fn collectCallNamesRec(
    allocator: std.mem.Allocator,
    node: ts.TSNode,
    source: []const u8,
    calls: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
    depth: u8,
) !void {
    if (depth > 64) return; // guard against deep recursion
    const typ = std.mem.span(ts.nodeType(node));
    if (std.mem.eql(u8, typ, "call_expression")) {
        const func = ts.nodeChildByFieldName(node, "function");
        if (!ts.nodeIsNull(func)) {
            const fname_typ = std.mem.span(ts.nodeType(func));
            const name: ?[]const u8 = if (std.mem.eql(u8, fname_typ, "identifier"))
                ts.nodeText(func, source)
            else if (std.mem.eql(u8, fname_typ, "member_expression")) blk: {
                const prop = ts.nodeChildByFieldName(func, "property");
                break :blk if (ts.nodeIsNull(prop)) null else ts.nodeText(prop, source);
            } else null;
            if (name) |nm| {
                if (nm.len > 0 and !seen.contains(nm)) {
                    const dup = try allocator.dupe(u8, nm);
                    try seen.put(dup, {});
                    try calls.append(allocator, dup);
                }
            }
        }
    }
    var i: u32 = 0;
    const n = ts.nodeChildCount(node);
    while (i < n) : (i += 1) {
        try collectCallNamesRec(allocator, ts.nodeChild(node, i), source, calls, seen, depth + 1);
    }
}

/// Walk `body` and return deduplicated list of called function/method names.
pub fn extractCallNames(allocator: std.mem.Allocator, body: ts.TSNode, source: []const u8) !std.ArrayList([]const u8) {
    var calls: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    try collectCallNamesRec(allocator, body, source, &calls, &seen, 0);
    return calls;
}

// ─── Branch counter (for cyclomatic complexity) ───────────────────────────────

const BRANCH_NODE_TYPES = [_][]const u8{
    "if_statement",     "for_statement",     "for_in_statement",
    "for_of_statement", "while_statement",   "do_statement",
    "switch_case",      "catch_clause",      "ternary_expression",
};

fn countBranchNodesRec(node: ts.TSNode, depth: u8) u32 {
    if (depth > 64) return 0;
    const typ = std.mem.span(ts.nodeType(node));
    var count: u32 = 0;
    for (BRANCH_NODE_TYPES) |bt| {
        if (std.mem.eql(u8, typ, bt)) { count += 1; break; }
    }
    var i: u32 = 0;
    const n = ts.nodeChildCount(node);
    while (i < n) : (i += 1) {
        count += countBranchNodesRec(ts.nodeChild(node, i), depth + 1);
    }
    return count;
}

pub fn countBranchNodes(node: ts.TSNode) u32 {
    return countBranchNodesRec(node, 0);
}

// ─── Extends / implements extractor ──────────────────────────────────────────

/// Extract the first extended type name from a class_declaration node.
fn extractClassExtends(allocator: std.mem.Allocator, node: ts.TSNode, source: []const u8) ?[]const u8 {
    const heritage = findChildByType(node, "class_heritage") orelse return null;
    const ext_clause = findChildByType(heritage, "extends_clause") orelse return null;
    // The type is either a direct type_identifier, or a generic_type whose first child is one
    var i: u32 = 0;
    const n = ts.nodeChildCount(ext_clause);
    while (i < n) : (i += 1) {
        const c = ts.nodeChild(ext_clause, i);
        const ctyp = std.mem.span(ts.nodeType(c));
        if (std.mem.eql(u8, ctyp, "type_identifier") or std.mem.eql(u8, ctyp, "identifier")) {
            const name = ts.nodeText(c, source);
            if (name.len > 0) return allocator.dupe(u8, name) catch null;
        }
        if (std.mem.eql(u8, ctyp, "generic_type")) {
            const inner = findChildByType(c, "type_identifier") orelse findChildByType(c, "identifier");
            if (inner) |inn| {
                const name = ts.nodeText(inn, source);
                if (name.len > 0) return allocator.dupe(u8, name) catch null;
            }
        }
    }
    return null;
}

/// Extract implemented interface names from a class_declaration node.
fn extractClassImplements(allocator: std.mem.Allocator, node: ts.TSNode, source: []const u8) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    const heritage = findChildByType(node, "class_heritage") orelse return list;
    const impl_clause = findChildByType(heritage, "implements_clause") orelse return list;
    var i: u32 = 0;
    const n = ts.nodeChildCount(impl_clause);
    while (i < n) : (i += 1) {
        const c = ts.nodeChild(impl_clause, i);
        const ctyp = std.mem.span(ts.nodeType(c));
        if (std.mem.eql(u8, ctyp, "type_identifier") or std.mem.eql(u8, ctyp, "identifier")) {
            const name = ts.nodeText(c, source);
            if (name.len > 0) try list.append(allocator, try allocator.dupe(u8, name));
        } else if (std.mem.eql(u8, ctyp, "generic_type")) {
            const inner = findChildByType(c, "type_identifier") orelse findChildByType(c, "identifier");
            if (inner) |inn| {
                const name = ts.nodeText(inn, source);
                if (name.len > 0) try list.append(allocator, try allocator.dupe(u8, name));
            }
        }
    }
    return list;
}

/// Extract the first extended type name from an interface_declaration node.
fn extractInterfaceExtends(allocator: std.mem.Allocator, node: ts.TSNode, source: []const u8) ?[]const u8 {
    // tree-sitter-typescript uses "extends_type_list" as a named child of interface_declaration
    const etl = findChildByType(node, "extends_type_list") orelse return null;
    var i: u32 = 0;
    const n = ts.nodeChildCount(etl);
    while (i < n) : (i += 1) {
        const c = ts.nodeChild(etl, i);
        const ctyp = std.mem.span(ts.nodeType(c));
        if (std.mem.eql(u8, ctyp, "type_identifier") or std.mem.eql(u8, ctyp, "identifier")) {
            const name = ts.nodeText(c, source);
            if (name.len > 0) return allocator.dupe(u8, name) catch null;
        }
        if (std.mem.eql(u8, ctyp, "generic_type")) {
            const inner = findChildByType(c, "type_identifier") orelse findChildByType(c, "identifier");
            if (inner) |inn| {
                const name = ts.nodeText(inn, source);
                if (name.len > 0) return allocator.dupe(u8, name) catch null;
            }
        }
    }
    return null;
}

// ─── Import extractor ───────────────────────────────────────────────────────

pub fn extractImports(
    allocator: std.mem.Allocator,
    root: ts.TSNode,
    source: []const u8,
) !std.ArrayList(types.ImportRecord) {
    var list: std.ArrayList(types.ImportRecord) = .empty;
    var i: u32 = 0;
    const n = ts.nodeChildCount(root);
    while (i < n) : (i += 1) {
        const node = ts.nodeChild(root, i);
        if (nodeTypeEq(node, "import_statement")) {
            try parseImportStatement(allocator, node, source, &list);
            continue;
        }
        if (nodeTypeEq(node, "export_statement")) {
            if (parseReexport(allocator, node, source)) |rec| {
                try list.append(allocator, rec);
            }
        }
    }
    return list;
}

fn parseReexport(allocator: std.mem.Allocator, node: ts.TSNode, source: []const u8) ?types.ImportRecord {
    const source_node = findChildByType(node, "string") orelse return null;
    const raw = ts.nodeText(source_node, source);
    const src = stripQuotes(allocator, raw) catch return null;
    defer allocator.free(src);
    const is_type_only = hasChildType(node, "type");

    if (findChildByType(node, "*")) |_| {
        // export * from '...' ou export * as ns from '...'
        const ns_node = findChildByType(node, "namespace_export");
        const alias = if (ns_node) |ns|
            textOfFirstChild(ns, "identifier", source) orelse ""
        else
            "";
        return .{
            .source = allocator.dupe(u8, src) catch return null,
            .kind = "namespace",
            .names = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
            .alias = if (alias.len > 0) allocator.dupe(u8, alias) catch null else null,
            .is_type_only = is_type_only,
        };
    }

    if (findChildByType(node, "export_clause")) |clause| {
        var names: std.ArrayList([]const u8) = .empty;
        var ci: u32 = 0;
        const cn = ts.nodeChildCount(clause);
        while (ci < cn) : (ci += 1) {
            const spec = ts.nodeChild(clause, ci);
            if (!nodeTypeEq(spec, "export_specifier")) continue;
            const name = textOfField(spec, "name", source) orelse textOfFirstChild(spec, "identifier", source);
            if (name) |nm| {
                names.append(allocator, allocator.dupe(u8, nm) catch continue) catch {};
            }
        }
        return .{
            .source = allocator.dupe(u8, src) catch return null,
            .kind = "named",
            .names = names,
            .is_type_only = is_type_only,
        };
    }
    return null;
}

fn textOfField(node: ts.TSNode, field_name: []const u8, source: []const u8) ?[]const u8 {
    const child = ts.nodeChildByFieldName(node, field_name);
    if (ts.nodeIsNull(child)) return null;
    const t = ts.nodeText(child, source);
    return if (t.len > 0) t else null;
}

fn textOfFirstChild(node: ts.TSNode, typ: []const u8, source: []const u8) ?[]const u8 {
    const c = findChildByType(node, typ) orelse return null;
    const t = ts.nodeText(c, source);
    return if (t.len > 0) t else null;
}

fn parseImportStatement(
    allocator: std.mem.Allocator,
    node: ts.TSNode,
    source: []const u8,
    list: *std.ArrayList(types.ImportRecord),
) !void {
    const source_node = findChildByType(node, "string") orelse return;
    const raw = ts.nodeText(source_node, source);
    const src = try stripQuotes(allocator, raw);
    defer allocator.free(src);
    const is_type_only = hasChildType(node, "type");
    const clause = findChildByType(node, "import_clause");

    if (clause == null) {
        try list.append(allocator, .{
            .source = try allocator.dupe(u8, src),
            .kind = "side-effect",
            .names = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
            .is_type_only = false,
        });
        return;
    }

    const clause_node = clause.?;
    var ci: u32 = 0;
    const cn = ts.nodeChildCount(clause_node);
    while (ci < cn) : (ci += 1) {
        const child = ts.nodeChild(clause_node, ci);
        if (nodeTypeEq(child, "identifier")) {
            const name = ts.nodeText(child, source);
            var names: std.ArrayList([]const u8) = .empty;
            try names.append(allocator, try allocator.dupe(u8, name));
            try list.append(allocator, .{
                .source = try allocator.dupe(u8, src),
                .kind = "default",
                .names = names,
                .is_type_only = is_type_only,
            });
            continue;
        }
        if (nodeTypeEq(child, "namespace_import")) {
            const alias = textOfFirstChild(child, "identifier", source);
            try list.append(allocator, .{
                .source = try allocator.dupe(u8, src),
                .kind = "namespace",
                .names = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
                .alias = if (alias) |a| try allocator.dupe(u8, a) else null,
                .is_type_only = is_type_only,
            });
            continue;
        }
        if (nodeTypeEq(child, "named_imports")) {
            var names: std.ArrayList([]const u8) = .empty;
            var ni: u32 = 0;
            const nn = ts.nodeChildCount(child);
            while (ni < nn) : (ni += 1) {
                const spec = ts.nodeChild(child, ni);
                if (!nodeTypeEq(spec, "import_specifier")) continue;
                const name = textOfField(spec, "name", source) orelse textOfFirstChild(spec, "identifier", source);
                if (name) |nm| try names.append(allocator, try allocator.dupe(u8, nm));
            }
            try list.append(allocator, .{
                .source = try allocator.dupe(u8, src),
                .kind = "named",
                .names = names,
                .is_type_only = is_type_only,
            });
        }
    }
}

// ─── Export extractor ───────────────────────────────────────────────────────

const ExportInfo = struct {
    names: std.ArrayList([]const u8),
    has_default_export: bool,
};

const DECLARATION_TYPES = [_][]const u8{
    "function_declaration",
    "generator_function_declaration",
    "class_declaration",
    "abstract_class_declaration",
    "interface_declaration",
    "type_alias_declaration",
    "enum_declaration",
    "lexical_declaration",
    "variable_declaration",
};

fn isDeclarationType(typ: []const u8) bool {
    for (DECLARATION_TYPES) |d| {
        if (std.mem.eql(u8, typ, d)) return true;
    }
    return false;
}

pub fn extractExports(
    allocator: std.mem.Allocator,
    root: ts.TSNode,
    source: []const u8,
) !ExportInfo {
            var names: std.ArrayList([]const u8) = .empty;
    var has_default_export = false;
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var i: u32 = 0;
    const n = ts.nodeChildCount(root);
    while (i < n) : (i += 1) {
        const node = ts.nodeChild(root, i);
        if (!nodeTypeEq(node, "export_statement")) continue;

        if (hasChildType(node, "default")) {
            has_default_export = true;
            const inner = findChildByType(node, "function_declaration") orelse
                findChildByType(node, "class_declaration");
            if (inner) |inn| {
                const name = textOfField(inn, "name", source);
                if (name) |nm| {
                    const dup = try allocator.dupe(u8, nm);
                    if (!seen.contains(dup)) {
                        try seen.put(dup, {});
                        try names.append(allocator, dup);
                    } else allocator.free(dup);
                }
            }
            continue;
        }

        if (findChildByType(node, "export_clause")) |clause| {
            var ci: u32 = 0;
            const cn = ts.nodeChildCount(clause);
            while (ci < cn) : (ci += 1) {
                const spec = ts.nodeChild(clause, ci);
                if (!nodeTypeEq(spec, "export_specifier")) continue;
                const exported = textOfField(spec, "alias", source) orelse
                    textOfField(spec, "name", source) orelse
                    textOfFirstChild(spec, "identifier", source);
                if (exported) |nm| {
                    const dup = try allocator.dupe(u8, nm);
                    if (!seen.contains(dup)) {
                        try seen.put(dup, {});
                        try names.append(allocator, dup);
                    } else allocator.free(dup);
                }
            }
            continue;
        }

        var ci: u32 = 0;
        const cn = ts.nodeChildCount(node);
        while (ci < cn) : (ci += 1) {
            const inner = ts.nodeChild(node, ci);
            const typ = std.mem.span(ts.nodeType(inner));
            if (!isDeclarationType(typ)) continue;

            if (std.mem.eql(u8, typ, "lexical_declaration") or std.mem.eql(u8, typ, "variable_declaration")) {
                var vi: u32 = 0;
                const vn = ts.nodeChildCount(inner);
                while (vi < vn) : (vi += 1) {
                    const decl = ts.nodeChild(inner, vi);
                    if (!nodeTypeEq(decl, "variable_declarator")) continue;
                    const name = textOfField(decl, "name", source);
                    if (name) |nm| {
                        const dup = try allocator.dupe(u8, nm);
                        if (!seen.contains(dup)) {
                            try seen.put(dup, {});
                            try names.append(allocator, dup);
                        } else allocator.free(dup);
                    }
                }
            } else {
                const name = textOfField(inner, "name", source);
                if (name) |nm| {
                    const dup = try allocator.dupe(u8, nm);
                    if (!seen.contains(dup)) {
                        try seen.put(dup, {});
                        try names.append(allocator, dup);
                    } else allocator.free(dup);
                }
            }
            break;
        }
    }
    return .{ .names = names, .has_default_export = has_default_export };
}

// ─── Helpers para symbol extractor ───────────────────────────────────────────

fn symbolId(allocator: std.mem.Allocator, file_path: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}#{s}", .{ file_path, name });
}

fn extractDocComment(allocator: std.mem.Allocator, source: []const u8, start_line_0: u32) ?[]const u8 {
    var line_start: usize = 0;
    var line: u32 = 0;
    while (line_start < source.len and line < start_line_0) {
        if (source[line_start] == '\n') line += 1;
        line_start += 1;
    }
    if (line != start_line_0) return null;
    var i: i64 = @intCast(line_start);
    while (i > 0) {
        i -= 1;
        if (source[@intCast(i)] == '\n') break;
    }
    const line_begin = @as(usize, @intCast(i + 1));
    var end: usize = line_begin;
    while (end < source.len and source[end] != '\n') end += 1;
    const trimmed = std.mem.trim(u8, source[line_begin..end], " \t");
    if (trimmed.len >= 2 and trimmed[0] == '/' and trimmed[1] == '/') {
        var collected: std.ArrayList(u8) = .empty;
        defer collected.deinit(allocator);
        var row: i64 = @intCast(start_line_0);
        while (row >= 0) {
            var lb: usize = 0;
            var ln: u32 = 0;
            var idx: usize = 0;
            while (idx < source.len and ln <= @as(u32, @intCast(row))) {
                if (source[idx] == '\n') ln += 1;
                if (ln == row) lb = idx + 1;
                idx += 1;
            }
            if (lb >= source.len) break;
            var rb = lb;
            while (rb < source.len and source[rb] != '\n') rb += 1;
            const tr = std.mem.trim(u8, source[lb..rb], " \t");
            if (tr.len < 2 or tr[0] != '/' or tr[1] != '/') break;
            const content = if (tr.len > 2 and tr[2] == ' ') tr[3..] else tr[2..];
            if (collected.items.len > 0) collected.append(allocator, ' ') catch break;
            collected.appendSlice(allocator, content) catch break;
            row -= 1;
        }
        return allocator.dupe(u8, collected.items) catch null;
    }
    if (trimmed.len >= 2 and trimmed[trimmed.len - 1] == '*' and trimmed[trimmed.len - 2] == '*') {
        var line_start_i: usize = 0;
        var l: u32 = 0;
        while (line_start_i < source.len and l <= start_line_0) {
            if (source[line_start_i] == '\n') l += 1;
            if (l == start_line_0) break;
            line_start_i += 1;
        }
        var start_i: i64 = @intCast(line_start_i);
        while (start_i >= 0) {
            var idx: usize = 0;
            var ln: u32 = 0;
            while (idx < source.len and ln < @as(u32, @intCast(start_line_0))) {
                if (source[idx] == '\n') ln += 1;
                idx += 1;
            }
            const lb = idx;
            while (idx < source.len and source[idx] != '\n') idx += 1;
            const tr = std.mem.trim(u8, source[lb..idx], " \t");
            if (tr.len >= 2 and tr[0] == '/' and tr[1] == '*') break;
            start_i -= 1;
        }
        if (start_i < 0) return null;
        var idx: usize = 0;
        var ln: u32 = 0;
        while (idx < source.len and ln < @as(u32, @intCast(start_i)) + 1) {
            if (source[idx] == '\n') ln += 1;
            idx += 1;
        }
        const slice_start = idx;
        idx = 0;
        ln = 0;
        while (idx < source.len and ln <= start_line_0) {
            if (source[idx] == '\n') ln += 1;
            idx += 1;
        }
        const slice_end = idx;
        var parts: std.ArrayList(u8) = .empty;
        defer parts.deinit(allocator);
        var pos = slice_start;
        while (pos < slice_end) {
            var line_end = pos;
            while (line_end < slice_end and source[line_end] != '\n') line_end += 1;
            var tr = std.mem.trim(u8, source[pos..line_end], " \t");
            if (tr.len > 0) {
                if (tr[0] == '*') tr = tr[1..];
                if (tr.len > 0 and tr[tr.len - 1] == '*') tr = tr[0 .. tr.len - 1];
                tr = std.mem.trim(u8, tr, " \t*");
                if (tr.len > 0) {
                    if (parts.items.len > 0) parts.append(allocator, ' ') catch break;
                    parts.appendSlice(allocator, tr) catch break;
                }
            }
            pos = if (line_end < slice_end) line_end + 1 else slice_end;
        }
        return allocator.dupe(u8, parts.items) catch null;
    }
    return null;
}

fn extractTypeText(node: ts.TSNode, source: []const u8) ?[]const u8 {
    if (ts.nodeIsNull(node)) return null;
    const t = ts.nodeText(node, source);
    var start: usize = 0;
    while (start < t.len and (t[start] == ':' or t[start] == ' ' or t[start] == '\t')) start += 1;
    const trimmed = t[start..];
    return if (trimmed.len > 0) trimmed else null;
}

fn extractParameters(allocator: std.mem.Allocator, formal_params: ts.TSNode, source: []const u8) !std.ArrayList(types.Parameter) {
    var params: std.ArrayList(types.Parameter) = .empty;
    if (ts.nodeIsNull(formal_params)) return params;
    var i: u32 = 0;
    const n = ts.nodeChildCount(formal_params);
    while (i < n) : (i += 1) {
        const child = ts.nodeChild(formal_params, i);
        const typ = std.mem.span(ts.nodeType(child));
        if (!std.mem.eql(u8, typ, "required_parameter") and
            !std.mem.eql(u8, typ, "optional_parameter") and
            !std.mem.eql(u8, typ, "rest_pattern") and
            !std.mem.eql(u8, typ, "assignment_pattern"))
            continue;
        var pat = ts.nodeChildByFieldName(child, "pattern");
        if (ts.nodeIsNull(pat)) pat = ts.nodeChildByFieldName(child, "name");
        if (ts.nodeIsNull(pat)) {
            if (findChildByType(child, "identifier")) |p| pat = p
            else if (findChildByType(child, "object_pattern")) |p| pat = p
            else if (findChildByType(child, "array_pattern")) |p| pat = p
            else continue;
        }
        const name = ts.nodeText(pat, source);
        const type_node = ts.nodeChildByFieldName(child, "type");
        const type_annot = if (ts.nodeIsNull(type_node)) null else extractTypeText(type_node, source);
        const default_node = ts.nodeChildByFieldName(child, "value");
        const default_val = if (ts.nodeIsNull(default_node)) null else ts.nodeText(default_node, source);
        try params.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .type_annot = if (type_annot) |tann| try allocator.dupe(u8, tann) else null,
            .optional = std.mem.eql(u8, typ, "optional_parameter") or (std.mem.indexOf(u8, ts.nodeText(child, source), "?") != null),
            .default_value = if (default_val) |dv| try allocator.dupe(u8, dv) else null,
        });
    }
    return params;
}

fn extractTypeParameters(allocator: std.mem.Allocator, node: ts.TSNode, source: []const u8) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    const type_params = ts.nodeChildByFieldName(node, "type_parameters");
    if (ts.nodeIsNull(type_params)) return list;
    var i: u32 = 0;
    const n = ts.nodeChildCount(type_params);
    while (i < n) : (i += 1) {
        const c = ts.nodeChild(type_params, i);
        if (!nodeTypeEq(c, "type_parameter")) continue;
        const name = textOfField(c, "name", source) orelse ts.nodeText(c, source);
        if (name.len > 0) try list.append(allocator, try allocator.dupe(u8, name));
    }
    return list;
}

fn collectModifiers(allocator: std.mem.Allocator, node: ts.TSNode, source: []const u8, is_exported: bool, is_default: bool) !std.ArrayList([]const u8) {
    var mods: std.ArrayList([]const u8) = .empty;
    if (is_exported) try mods.append(allocator, "export");
    if (is_default) try mods.append(allocator, "default");
    var i: u32 = 0;
    const n = ts.nodeChildCount(node);
    while (i < n) : (i += 1) {
        const c = ts.nodeChild(node, i);
        const typ = std.mem.span(ts.nodeType(c));
        if (std.mem.eql(u8, typ, "async")) try mods.append(allocator, "async")
        else if (std.mem.eql(u8, typ, "static")) try mods.append(allocator, "static")
        else if (std.mem.eql(u8, typ, "abstract")) try mods.append(allocator, "abstract")
        else if (std.mem.eql(u8, typ, "readonly")) try mods.append(allocator, "readonly")
        else if (std.mem.eql(u8, typ, "accessibility_modifier")) {
            const t = ts.nodeText(c, source);
            if (std.mem.eql(u8, t, "private")) try mods.append(allocator, "private")
            else if (std.mem.eql(u8, t, "protected")) try mods.append(allocator, "protected")
            else if (std.mem.eql(u8, t, "public")) try mods.append(allocator, "public");
        }
    }
    return mods;
}

fn nodeRange(node: ts.TSNode) types.Range {
    const start_pt = ts.nodeStartPoint(node);
    const end_pt = ts.nodeEndPoint(node);
    return .{
        .start = .{ .line = start_pt.row, .column = start_pt.column },
        .end = .{ .line = end_pt.row, .column = end_pt.column },
    };
}

fn visitClassMember(
    allocator: std.mem.Allocator,
    node: ts.TSNode,
    class_name: []const u8,
    file_path: []const u8,
    source: []const u8,
    symbols: *std.ArrayList(types.CodeSymbol),
) !void {
    const typ = std.mem.span(ts.nodeType(node));
    if (std.mem.eql(u8, typ, "method_definition")) {
        const name_node = ts.nodeChildByFieldName(node, "name");
        if (ts.nodeIsNull(name_node)) return;
        const name = ts.nodeText(name_node, source);
        var mods = try collectModifiers(allocator, node, source, false, false);
        if (hasChildType(node, "async")) try mods.append(allocator, "async");
        if (hasChildType(node, "static")) try mods.append(allocator, "static");
        const kind_str: []const u8 = if (std.mem.eql(u8, name, "constructor")) "constructor" else "method";
        const method_return = ts.nodeChildByFieldName(node, "return_type");
        const return_type = if (ts.nodeIsNull(method_return)) null else extractTypeText(method_return, source);
        const start_pt = ts.nodeStartPoint(node);
        const doc = extractDocComment(allocator, source, start_pt.row);
        const qualified_name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ class_name, name });
        defer allocator.free(qualified_name);
        const sym_id = try symbolId(allocator, file_path, qualified_name);
        const body = ts.nodeChildByFieldName(node, "body");
        const calls = if (ts.nodeIsNull(body)) std.ArrayList([]const u8).empty
            else extractCallNames(allocator, body, source) catch std.ArrayList([]const u8).empty;
        const branch_count: u32 = if (ts.nodeIsNull(body)) 0 else countBranchNodes(body);
        try symbols.append(allocator, .{
            .id = sym_id,
            .name = try allocator.dupe(u8, name),
            .kind = try allocator.dupe(u8, kind_str),
            .range = nodeRange(node),
            .modifiers = mods,
            .return_type = if (return_type) |r| try allocator.dupe(u8, r) else null,
            .parameters = try extractParameters(allocator, ts.nodeChildByFieldName(node, "parameters"), source),
            .type_parameters = try extractTypeParameters(allocator, node, source),
            .parent_name = try allocator.dupe(u8, class_name),
            .doc_comment = if (doc) |d| try allocator.dupe(u8, d) else null,
            .is_exported = false,
            .calls = calls,
            .branches = branch_count,
        });
        return;
    }
    if (std.mem.eql(u8, typ, "public_field_definition")) {
        const name_node = ts.nodeChildByFieldName(node, "name");
        if (ts.nodeIsNull(name_node)) return;
        const name = ts.nodeText(name_node, source);
        const mods = try collectModifiers(allocator, node, source, false, false);
        const type_node = ts.nodeChildByFieldName(node, "type");
        const prop_return = if (ts.nodeIsNull(type_node)) null else extractTypeText(type_node, source);
        const start_pt = ts.nodeStartPoint(node);
        const doc = extractDocComment(allocator, source, start_pt.row);
        const qualified_name2 = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ class_name, name });
        defer allocator.free(qualified_name2);
        const sym_id = try symbolId(allocator, file_path, qualified_name2);
        try symbols.append(allocator, .{
            .id = sym_id,
            .name = try allocator.dupe(u8, name),
            .kind = try allocator.dupe(u8, "property"),
            .range = nodeRange(node),
            .modifiers = mods,
            .return_type = if (prop_return) |r| try allocator.dupe(u8, r) else null,
            .parameters = std.ArrayList(types.Parameter){ .items = &.{}, .capacity = 0 },
            .type_parameters = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
            .parent_name = try allocator.dupe(u8, class_name),
            .doc_comment = if (doc) |d| try allocator.dupe(u8, d) else null,
            .is_exported = false,
        });
    }
}

// ─── Symbol extractor ───────────────────────────────────────────────────────

pub fn extractSymbols(
    allocator: std.mem.Allocator,
    root: ts.TSNode,
    source: []const u8,
    file_path: []const u8,
) !std.ArrayList(types.CodeSymbol) {
    var symbols: std.ArrayList(types.CodeSymbol) = .empty;
    const visit = struct {
        fn f(
            alloc: std.mem.Allocator,
            node: ts.TSNode,
            src: []const u8,
            fp: []const u8,
            syms: *std.ArrayList(types.CodeSymbol),
            exported: bool,
            default: bool,
            parent_name: ?[]const u8,
        ) anyerror!void {
            const typ = std.mem.span(ts.nodeType(node));
            if (std.mem.eql(u8, typ, "export_statement")) {
                const default_kw = hasChildType(node, "default");
                var ci: u32 = 0;
                const cn = ts.nodeChildCount(node);
                while (ci < cn) : (ci += 1) {
                    const inner = ts.nodeChild(node, ci);
                    if (ts.nodeIsNull(inner)) continue;
                    const it = std.mem.span(ts.nodeType(inner));
                    if (!std.mem.eql(u8, it, "export") and !std.mem.eql(u8, it, "default") and ts.nodeIsNamed(inner)) {
                        try f(alloc, inner, src, fp, syms, true, default_kw, parent_name);
                        break;
                    }
                }
                return;
            }
            if (std.mem.eql(u8, typ, "function_declaration") or std.mem.eql(u8, typ, "generator_function_declaration")) {
                const name_node = ts.nodeChildByFieldName(node, "name");
                if (ts.nodeIsNull(name_node)) return;
                const name = ts.nodeText(name_node, src);
                var mods = try collectModifiers(alloc, node, src, exported, default);
                if (hasChildType(node, "async")) try mods.append(alloc, "async");
                const doc = extractDocComment(alloc, src, ts.nodeStartPoint(node).row);
                const body = ts.nodeChildByFieldName(node, "body");
                const fn_calls = if (ts.nodeIsNull(body)) std.ArrayList([]const u8).empty
                    else extractCallNames(alloc, body, src) catch std.ArrayList([]const u8).empty;
                const branch_count: u32 = if (ts.nodeIsNull(body)) 0 else countBranchNodes(body);
                try syms.append(alloc, .{
                    .id = try symbolId(alloc, fp, name),
                    .name = try alloc.dupe(u8, name),
                    .kind = try alloc.dupe(u8, "function"),
                    .range = nodeRange(node),
                    .modifiers = mods,
                    .return_type = blk: {
                        const rt = ts.nodeChildByFieldName(node, "return_type");
                        const t = if (ts.nodeIsNull(rt)) null else extractTypeText(rt, src);
                        break :blk if (t) |v| try alloc.dupe(u8, v) else null;
                    },
                    .parameters = try extractParameters(alloc, ts.nodeChildByFieldName(node, "parameters"), src),
                    .type_parameters = try extractTypeParameters(alloc, node, src),
                    .parent_name = if (parent_name) |p| try alloc.dupe(u8, p) else null,
                    .doc_comment = if (doc) |d| try alloc.dupe(u8, d) else null,
                    .is_exported = exported,
                    .calls = fn_calls,
                    .branches = branch_count,
                });
                return;
            }
            if (std.mem.eql(u8, typ, "lexical_declaration") or std.mem.eql(u8, typ, "variable_declaration")) {
                var vi: u32 = 0;
                const vn = ts.nodeChildCount(node);
                while (vi < vn) : (vi += 1) {
                    const decl = ts.nodeChild(node, vi);
                    if (!nodeTypeEq(decl, "variable_declarator")) continue;
                    const name_node = ts.nodeChildByFieldName(decl, "name");
                    if (ts.nodeIsNull(name_node) or !nodeTypeEq(name_node, "identifier")) continue;
                    const name = ts.nodeText(name_node, src);
                    const value = ts.nodeChildByFieldName(decl, "value");
                    const val_typ = if (ts.nodeIsNull(value)) "" else std.mem.span(ts.nodeType(value));
                    if (std.mem.eql(u8, val_typ, "arrow_function") or std.mem.eql(u8, val_typ, "function")) {
                        var mods = try collectModifiers(alloc, node, src, exported, default);
                        if (hasChildType(value, "async")) try mods.append(alloc, "async");
                        const arrow_rt = ts.nodeChildByFieldName(value, "return_type");
                        const decl_type = ts.nodeChildByFieldName(decl, "type");
                        const return_type = if (!ts.nodeIsNull(arrow_rt)) extractTypeText(arrow_rt, src)
                            else if (!ts.nodeIsNull(decl_type)) extractTypeText(decl_type, src)
                            else null;
                        const doc = extractDocComment(alloc, src, ts.nodeStartPoint(node).row);
                        const parent = ts.nodeParent(decl);
                        const range = if (ts.nodeIsNull(parent)) nodeRange(node) else nodeRange(parent);
                        const arrow_body = ts.nodeChildByFieldName(value, "body");
                        const arrow_calls = if (ts.nodeIsNull(arrow_body)) std.ArrayList([]const u8).empty
                            else extractCallNames(alloc, arrow_body, src) catch std.ArrayList([]const u8).empty;
                        const arrow_branches: u32 = if (ts.nodeIsNull(arrow_body)) 0 else countBranchNodes(arrow_body);
                        try syms.append(alloc, .{
                            .id = try symbolId(alloc, fp, name),
                            .name = try alloc.dupe(u8, name),
                            .kind = try alloc.dupe(u8, "arrow_function"),
                            .range = range,
                            .modifiers = mods,
                            .return_type = if (return_type) |r| try alloc.dupe(u8, r) else null,
                            .parameters = try extractParameters(alloc, ts.nodeChildByFieldName(value, "parameters"), src),
                            .type_parameters = try extractTypeParameters(alloc, value, src),
                            .parent_name = if (parent_name) |p| try alloc.dupe(u8, p) else null,
                            .doc_comment = if (doc) |d| try alloc.dupe(u8, d) else null,
                            .is_exported = exported,
                            .calls = arrow_calls,
                            .branches = arrow_branches,
                        });
                    } else {
                        const doc = extractDocComment(alloc, src, ts.nodeStartPoint(node).row);
                        const type_annot = ts.nodeChildByFieldName(decl, "type");
                        try syms.append(alloc, .{
                            .id = try symbolId(alloc, fp, name),
                            .name = try alloc.dupe(u8, name),
                            .kind = try alloc.dupe(u8, "variable"),
                            .range = nodeRange(node),
                            .modifiers = try collectModifiers(alloc, node, src, exported, default),
                            .return_type = if (!ts.nodeIsNull(type_annot)) if (extractTypeText(type_annot, src)) |t| try alloc.dupe(u8, t) else null else null,
                            .parameters = std.ArrayList(types.Parameter){ .items = &.{}, .capacity = 0 },
                            .type_parameters = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
                            .parent_name = if (parent_name) |p| try alloc.dupe(u8, p) else null,
                            .doc_comment = if (doc) |d| try alloc.dupe(u8, d) else null,
                            .is_exported = exported,
                        });
                    }
                }
                return;
            }
            if (std.mem.eql(u8, typ, "class_declaration") or std.mem.eql(u8, typ, "abstract_class_declaration")) {
                const name_node = ts.nodeChildByFieldName(node, "name");
                if (ts.nodeIsNull(name_node)) return;
                const name = ts.nodeText(name_node, src);
                var mods = try collectModifiers(alloc, node, src, exported, default);
                if (std.mem.eql(u8, typ, "abstract_class_declaration")) try mods.append(alloc, "abstract");
                const doc = extractDocComment(alloc, src, ts.nodeStartPoint(node).row);
                const class_extends = extractClassExtends(alloc, node, src);
                const class_implements = try extractClassImplements(alloc, node, src);
                try syms.append(alloc, .{
                    .id = try symbolId(alloc, fp, name),
                    .name = try alloc.dupe(u8, name),
                    .kind = try alloc.dupe(u8, "class"),
                    .range = nodeRange(node),
                    .modifiers = mods,
                    .return_type = null,
                    .parameters = std.ArrayList(types.Parameter){ .items = &.{}, .capacity = 0 },
                    .type_parameters = try extractTypeParameters(alloc, node, src),
                    .parent_name = if (parent_name) |p| try alloc.dupe(u8, p) else null,
                    .doc_comment = if (doc) |d| try alloc.dupe(u8, d) else null,
                    .is_exported = exported,
                    .extends = class_extends,
                    .implements = class_implements,
                });
                const body = ts.nodeChildByFieldName(node, "body");
                if (!ts.nodeIsNull(body)) {
                    var bi: u32 = 0;
                    const bn = ts.nodeChildCount(body);
                    while (bi < bn) : (bi += 1) {
                        try visitClassMember(alloc, ts.nodeChild(body, bi), name, fp, src, syms);
                    }
                }
                return;
            }
            if (std.mem.eql(u8, typ, "interface_declaration")) {
                const name_node = ts.nodeChildByFieldName(node, "name");
                if (ts.nodeIsNull(name_node)) return;
                const name = ts.nodeText(name_node, src);
                const doc = extractDocComment(alloc, src, ts.nodeStartPoint(node).row);
                const iface_extends = extractInterfaceExtends(alloc, node, src);
                try syms.append(alloc, .{
                    .id = try symbolId(alloc, fp, name),
                    .name = try alloc.dupe(u8, name),
                    .kind = try alloc.dupe(u8, "interface"),
                    .range = nodeRange(node),
                    .modifiers = try collectModifiers(alloc, node, src, exported, default),
                    .return_type = null,
                    .parameters = std.ArrayList(types.Parameter){ .items = &.{}, .capacity = 0 },
                    .type_parameters = try extractTypeParameters(alloc, node, src),
                    .parent_name = if (parent_name) |p| try alloc.dupe(u8, p) else null,
                    .doc_comment = if (doc) |d| try alloc.dupe(u8, d) else null,
                    .is_exported = exported,
                    .extends = iface_extends,
                });
                return;
            }
            if (std.mem.eql(u8, typ, "type_alias_declaration")) {
                const name_node = ts.nodeChildByFieldName(node, "name");
                if (ts.nodeIsNull(name_node)) return;
                const name = ts.nodeText(name_node, src);
                const doc = extractDocComment(alloc, src, ts.nodeStartPoint(node).row);
                try syms.append(alloc, .{
                    .id = try symbolId(alloc, fp, name),
                    .name = try alloc.dupe(u8, name),
                    .kind = try alloc.dupe(u8, "type_alias"),
                    .range = nodeRange(node),
                    .modifiers = try collectModifiers(alloc, node, src, exported, default),
                    .return_type = null,
                    .parameters = std.ArrayList(types.Parameter){ .items = &.{}, .capacity = 0 },
                    .type_parameters = try extractTypeParameters(alloc, node, src),
                    .parent_name = if (parent_name) |p| try alloc.dupe(u8, p) else null,
                    .doc_comment = if (doc) |d| try alloc.dupe(u8, d) else null,
                    .is_exported = exported,
                });
                return;
            }
            if (std.mem.eql(u8, typ, "enum_declaration")) {
                const name_node = ts.nodeChildByFieldName(node, "name");
                if (ts.nodeIsNull(name_node)) return;
                const name = ts.nodeText(name_node, src);
                const doc = extractDocComment(alloc, src, ts.nodeStartPoint(node).row);
                try syms.append(alloc, .{
                    .id = try symbolId(alloc, fp, name),
                    .name = try alloc.dupe(u8, name),
                    .kind = try alloc.dupe(u8, "enum"),
                    .range = nodeRange(node),
                    .modifiers = try collectModifiers(alloc, node, src, exported, default),
                    .return_type = null,
                    .parameters = std.ArrayList(types.Parameter){ .items = &.{}, .capacity = 0 },
                    .type_parameters = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 },
                    .parent_name = if (parent_name) |p| try alloc.dupe(u8, p) else null,
                    .doc_comment = if (doc) |d| try alloc.dupe(u8, d) else null,
                    .is_exported = exported,
                });
                return;
            }
            if (std.mem.eql(u8, typ, "internal_module") or std.mem.eql(u8, typ, "module")) {
                const body = ts.nodeChildByFieldName(node, "body");
                if (!ts.nodeIsNull(body)) {
                    var bi: u32 = 0;
                    const bn = ts.nodeChildCount(body);
                    while (bi < bn) : (bi += 1) {
                        try f(alloc, ts.nodeChild(body, bi), src, fp, syms, exported, false, parent_name);
                    }
                }
                return;
            }
            var ci: u32 = 0;
            const cn = ts.nodeChildCount(node);
            while (ci < cn) : (ci += 1) {
                try f(alloc, ts.nodeChild(node, ci), src, fp, syms, false, false, parent_name);
            }
        }
    }.f;
    var i: u32 = 0;
    const n = ts.nodeChildCount(root);
    while (i < n) : (i += 1) {
        try visit(allocator, ts.nodeChild(root, i), source, file_path, &symbols, false, false, null);
    }
    return symbols;
}

