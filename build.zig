const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ts_include = b.path("vendor/tree-sitter/lib/include");
    const ts_src = b.path("vendor/tree-sitter/lib/src");

    const types_module = b.createModule(.{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Módulo que compila tree-sitter C + gramáticas e expõe a API Zig (ts_parser.zig)
    const ts_parser_module = b.createModule(.{
        .root_source_file = b.path("src/ts_parser.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "types", .module = types_module } },
    });
    ts_parser_module.addIncludePath(ts_include);
    ts_parser_module.addIncludePath(ts_src);
    // Gramáticas precisam encontrar tree_sitter/parser.h no seu src
    ts_parser_module.addIncludePath(b.path("vendor/tree-sitter-typescript/typescript/src"));
    ts_parser_module.addIncludePath(b.path("vendor/tree-sitter-typescript/tsx/src"));
    ts_parser_module.addIncludePath(b.path("vendor/tree-sitter-javascript/src"));
    // tree-sitter core (inclui wasm_store.c para símbolos ts_wasm_* referenciados por parser/language)
    const ts_cflags = [_][]const u8{ "-std=c11", "-D_DEFAULT_SOURCE", "-D_POSIX_C_SOURCE=200809L" };
    const ts_c_sources = [_][]const u8{
        "alloc.c",
        "get_changed_ranges.c",
        "language.c",
        "lexer.c",
        "node.c",
        "parser.c",
        "point.c",
        "stack.c",
        "subtree.c",
        "tree.c",
        "tree_cursor.c",
        "wasm_store.c",
    };
    ts_parser_module.addCSourceFiles(.{
        .root = ts_src,
        .files = &ts_c_sources,
        .flags = &ts_cflags,
    });
    ts_parser_module.addCSourceFiles(.{
        .root = b.path("vendor/tree-sitter-typescript/typescript/src"),
        .files = &.{ "parser.c", "scanner.c" },
        .flags = &.{ "-std=c11" },
    });
    ts_parser_module.addCSourceFiles(.{
        .root = b.path("vendor/tree-sitter-typescript/tsx/src"),
        .files = &.{ "parser.c", "scanner.c" },
        .flags = &.{ "-std=c11" },
    });
    ts_parser_module.addCSourceFiles(.{
        .root = b.path("vendor/tree-sitter-javascript/src"),
        .files = &.{ "parser.c", "scanner.c" },
        .flags = &.{ "-std=c11" },
    });

    const walk_module = b.createModule(.{
        .root_source_file = b.path("src/walk.zig"),
        .target = target,
        .optimize = optimize,
    });
    const hash_module = b.createModule(.{
        .root_source_file = b.path("src/hash.zig"),
        .target = target,
        .optimize = optimize,
    });
    const metadata_module = b.createModule(.{
        .root_source_file = b.path("src/metadata.zig"),
        .target = target,
        .optimize = optimize,
    });
    const extractors_module = b.createModule(.{
        .root_source_file = b.path("src/extractors.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_module },
            .{ .name = "ts_parser", .module = ts_parser_module },
        },
    });
    const parse_module = b.createModule(.{
        .root_source_file = b.path("src/parse.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_module },
            .{ .name = "walk", .module = walk_module },
            .{ .name = "ts_parser", .module = ts_parser_module },
            .{ .name = "extractors", .module = extractors_module },
        },
    });
    const chunk_module = b.createModule(.{
        .root_source_file = b.path("src/chunk.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "types", .module = types_module } },
    });
    const indices_module = b.createModule(.{
        .root_source_file = b.path("src/indices.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types_module },
            .{ .name = "walk", .module = walk_module },
        },
    });
    const writer_module = b.createModule(.{
        .root_source_file = b.path("src/writer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "types", .module = types_module } },
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "walk", .module = walk_module },
            .{ .name = "hash", .module = hash_module },
            .{ .name = "metadata", .module = metadata_module },
            .{ .name = "parse", .module = parse_module },
            .{ .name = "types", .module = types_module },
            .{ .name = "chunk", .module = chunk_module },
            .{ .name = "indices", .module = indices_module },
            .{ .name = "writer", .module = writer_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "wkix",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zig-workspace indexer");
    run_step.dependOn(&run_cmd.step);

    const perf_cmd = b.addRunArtifact(exe);
    perf_cmd.step.dependOn(b.getInstallStep());
    perf_cmd.addArg("..");
    perf_cmd.addArg("--force");
    const perf_step = b.step("perf", "Run indexer with logs (like type/workspace test:perf)");
    perf_step.dependOn(&perf_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const test_run = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);
}
