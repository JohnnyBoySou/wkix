// Bindings para tree-sitter C API + gramáticas TypeScript/TSX/JavaScript.
// O caller deve chamar ts_parse_result_free após usar o resultado.

const std = @import("std");
const types = @import("types");

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub const TSNode = c.TSNode;
pub const TSTree = c.TSTree;
pub const TSLanguage = c.TSLanguage;
pub const TSPoint = c.TSPoint;

extern fn tree_sitter_typescript() ?*const TSLanguage;
extern fn tree_sitter_tsx() ?*const TSLanguage;
extern fn tree_sitter_javascript() ?*const TSLanguage;

pub const ParseResult = struct {
    tree: *c.TSTree,
    root: TSNode,
    source: []const u8,

    pub fn free(self: *ParseResult) void {
        c.ts_tree_delete(self.tree);
    }
};

fn getLanguage(lang: types.Language) ?*const TSLanguage {
    return switch (lang) {
        .typescript => tree_sitter_typescript(),
        .tsx => tree_sitter_tsx(),
        .javascript => tree_sitter_javascript(),
        .jsx => tree_sitter_javascript(), // JSX usa gramática JS
    };
}

/// Parseia source com a linguagem indicada. Retorna null em caso de erro ou se language não for suportada.
pub fn parse(allocator: std.mem.Allocator, source: []const u8, lang: types.Language) ?ParseResult {
    const language = getLanguage(lang) orelse return null;

    const parser = c.ts_parser_new() orelse return null;
    defer c.ts_parser_delete(parser);

    if (!c.ts_parser_set_language(parser, language)) return null;

    // ts_parser_parse_string espera string null-terminated; nossa source pode não ser.
    const with_null = blk: {
        const buf = allocator.alloc(u8, source.len + 1) catch return null;
        @memcpy(buf[0..source.len], source);
        buf[source.len] = 0;
        break :blk buf;
    };
    defer allocator.free(with_null);

    const tree = c.ts_parser_parse_string(parser, null, with_null.ptr, @intCast(source.len));
    const tree_ptr = tree orelse return null;

    const root = c.ts_tree_root_node(tree_ptr);
    if (c.ts_node_is_null(root)) {
        c.ts_tree_delete(tree_ptr);
        return null;
    }

    return .{
        .tree = tree_ptr,
        .root = root,
        .source = source,
    };
}

pub fn parseResultFree(result: *ParseResult) void {
    result.free();
}

// ─── Acesso a nós (wrapper em volta da API C) ───────────────────────────────

pub fn nodeType(node: TSNode) [*:0]const u8 {
    const p = c.ts_node_type(node);
    return if (p != null) p else "";
}

pub fn nodeStartByte(node: TSNode) u32 {
    return c.ts_node_start_byte(node);
}

pub fn nodeEndByte(node: TSNode) u32 {
    return c.ts_node_end_byte(node);
}

pub fn nodeStartPoint(node: TSNode) TSPoint {
    return c.ts_node_start_point(node);
}

pub fn nodeEndPoint(node: TSNode) TSPoint {
    return c.ts_node_end_point(node);
}

pub fn nodeIsNull(node: TSNode) bool {
    return c.ts_node_is_null(node);
}

pub fn nodeIsNamed(node: TSNode) bool {
    return c.ts_node_is_named(node);
}

pub fn nodeParent(node: TSNode) TSNode {
    return c.ts_node_parent(node);
}

pub fn nodeChildCount(node: TSNode) u32 {
    return c.ts_node_child_count(node);
}

pub fn nodeChild(node: TSNode, index: u32) TSNode {
    return c.ts_node_child(node, index);
}

pub fn nodeNamedChildCount(node: TSNode) u32 {
    return c.ts_node_named_child_count(node);
}

pub fn nodeNamedChild(node: TSNode, index: u32) TSNode {
    return c.ts_node_named_child(node, index);
}

/// Retorna o filho com o campo `name`. Retorna nó nulo se não existir.
pub fn nodeChildByFieldName(node: TSNode, name: []const u8) TSNode {
    return c.ts_node_child_by_field_name(node, name.ptr, @intCast(name.len));
}

pub fn nodeNextSibling(node: TSNode) TSNode {
    return c.ts_node_next_sibling(node);
}

pub fn nodePrevSibling(node: TSNode) TSNode {
    return c.ts_node_prev_sibling(node);
}

/// Slice do source correspondente ao nó. source deve ser o mesmo []const u8 passado a parse().
pub fn nodeText(node: TSNode, source: []const u8) []const u8 {
    const start = c.ts_node_start_byte(node);
    const end = c.ts_node_end_byte(node);
    if (end <= source.len and start < end) {
        return source[start..end];
    }
    return "";
}
