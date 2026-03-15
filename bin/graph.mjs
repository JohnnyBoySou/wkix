#!/usr/bin/env node
/**
 * graph.mjs — generates .workspace/graph.md with a Mermaid import graph
 *             and a per-file exported symbol index.
 *
 * Usage:
 *   node bin/graph.mjs [target-dir] [options]
 *   npx wkix graph [target-dir] [options]
 *
 * Options:
 *   --focus <file>   Show only that file and its neighbours (relative path)
 *   --depth <n>      BFS depth from focused file (default: 1)
 *   --no-symbols     Skip the exported-symbols section
 *   --quiet          Suppress output
 *
 * Output: .workspace/graph.md
 *
 * Requires .workspace/ to exist (run `wkix generate` first).
 */

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// ─── helpers ─────────────────────────────────────────────────────────────────

/** Make a valid Mermaid node ID from a file path. */
function nodeId(filePath) {
  return filePath.replace(/[^a-zA-Z0-9]/g, "_");
}

/** Short display label: last two path segments, no extension. */
function nodeLabel(filePath) {
  const parts = filePath.split("/");
  const tail = parts.slice(-2).join("/");
  return tail.replace(/\.[^.]+$/, "");
}

/** Extract file path from a symbol id (format: "src/foo.ts::symbolName"). */
function fileFromSymbolId(id) {
  const sep = id.indexOf("::");
  return sep === -1 ? null : id.slice(0, sep);
}

// ─── BFS neighbourhood ───────────────────────────────────────────────────────

function bfsNeighbours(graph, startFile, depth) {
  const visited = new Set([startFile]);
  let frontier = [startFile];
  for (let d = 0; d < depth; d++) {
    const next = [];
    for (const f of frontier) {
      const node = graph[f];
      if (!node) continue;
      for (const imp of node.imports ?? []) {
        if (!visited.has(imp)) { visited.add(imp); next.push(imp); }
      }
      for (const ib of node.importedBy ?? []) {
        if (!visited.has(ib)) { visited.add(ib); next.push(ib); }
      }
    }
    frontier = next;
    if (frontier.length === 0) break;
  }
  return visited;
}

// ─── Mermaid builder ─────────────────────────────────────────────────────────

function buildMermaid(graph, visibleFiles, focusFile) {
  const lines = ["graph LR"];

  // node declarations
  for (const f of visibleFiles) {
    const id = nodeId(f);
    const label = nodeLabel(f);
    if (f === focusFile) {
      lines.push(`  ${id}["**${label}**"]:::focus`);
    } else {
      lines.push(`  ${id}["${label}"]`);
    }
  }

  lines.push("");

  // edges (only between visible files)
  const seen = new Set();
  for (const f of visibleFiles) {
    const node = graph[f];
    if (!node) continue;
    for (const imp of node.imports ?? []) {
      if (!visibleFiles.has(imp)) continue;
      const key = `${f}→${imp}`;
      if (seen.has(key)) continue;
      seen.add(key);
      lines.push(`  ${nodeId(f)} --> ${nodeId(imp)}`);
    }
  }

  lines.push("");
  lines.push("  classDef focus fill:#f5a623,stroke:#c47d0e,color:#000");

  return lines.join("\n");
}

// ─── symbol table builder ────────────────────────────────────────────────────

function buildSymbolTables(symbols, visibleFiles) {
  /** group exported symbols by file */
  const byFile = {};
  for (const sym of symbols.all ?? []) {
    if (!sym.isExported) continue;
    const file = fileFromSymbolId(sym.id);
    if (!file) continue;
    if (!visibleFiles.has(file)) continue;
    if (!byFile[file]) byFile[file] = [];
    byFile[file].push(sym);
  }

  const sections = [];
  for (const file of [...visibleFiles].sort()) {
    const syms = byFile[file];
    if (!syms || syms.length === 0) continue;
    sections.push(`### \`${file}\``);
    sections.push("");
    sections.push("| Symbol | Kind | Line |");
    sections.push("|--------|------|------|");
    for (const s of syms.sort((a, b) => a.range.start.line - b.range.start.line)) {
      const params = s.parameters?.length
        ? `(${s.parameters.map((p) => p.name + (p.optional ? "?" : "")).join(", ")})`
        : s.kind === "function" || s.kind === "arrow_function" ? "()" : "";
      const ret = s.returnType ? `: ${s.returnType}` : "";
      sections.push(`| \`${s.name}${params}${ret}\` | ${s.kind} | ${s.range.start.line} |`);
    }
    sections.push("");
  }

  return sections.join("\n");
}

// ─── main builder ─────────────────────────────────────────────────────────────

export function runGraph(targetDir, { focusFile, depth = 1, noSymbols = false, quiet = false } = {}) {
  const wsDir = path.join(targetDir, ".workspace");

  const graphPath   = path.join(wsDir, "import_graph.json");
  const symbolsPath = path.join(wsDir, "symbols.json");

  if (!existsSync(graphPath)) {
    throw new Error(`.workspace/import_graph.json not found — run \`wkix generate\` first`);
  }

  const graphData   = JSON.parse(readFileSync(graphPath, "utf8"));
  const symbolsData = existsSync(symbolsPath)
    ? JSON.parse(readFileSync(symbolsPath, "utf8"))
    : { all: [] };

  const graph = graphData.nodes ?? {};
  const allFiles = Object.keys(graph);

  // resolve focus path (support partial match like "foo.ts")
  let resolvedFocus = null;
  if (focusFile) {
    resolvedFocus = allFiles.find((f) => f === focusFile || f.endsWith(`/${focusFile}`) || f.endsWith(focusFile))
      ?? focusFile;
  }

  const visibleFiles = resolvedFocus
    ? bfsNeighbours(graph, resolvedFocus, depth)
    : new Set(allFiles);

  // ── build markdown ──────────────────────────────────────────────────────────
  const now = new Date().toISOString();
  const focusNote = resolvedFocus
    ? ` · focused on \`${resolvedFocus}\` (depth ${depth})`
    : "";

  const mermaid = buildMermaid(graph, visibleFiles, resolvedFocus);
  const symbolSection = noSymbols ? "" : buildSymbolTables(symbolsData, visibleFiles);

  const lines = [
    `# Import Graph`,
    ``,
    `> Generated by \`wkix graph\` — ${now}${focusNote}  `,
    `> ${visibleFiles.size} file(s) · ${allFiles.length} total in repo`,
    ``,
    `## File Dependencies`,
    ``,
    "```mermaid",
    mermaid,
    "```",
  ];

  if (!noSymbols && symbolSection.trim()) {
    lines.push(
      ``,
      `## Exported Symbols`,
      ``,
      `> Only exported symbols are listed. Each row links symbol name, kind, and source line.`,
      ``,
      symbolSection,
    );
  }

  lines.push(`---`, ``, `*Update with \`npx wkix graph\` or \`npx wkix graph --focus <file>\`*`, ``);

  const output = lines.join("\n");
  const outPath = path.join(wsDir, "graph.md");
  writeFileSync(outPath, output, "utf8");

  if (!quiet) {
    const edgeCount = [...visibleFiles].reduce((n, f) => {
      const node = graph[f];
      return n + (node?.imports?.filter((imp) => visibleFiles.has(imp)).length ?? 0);
    }, 0);
    console.log(
      `wkix graph: ${visibleFiles.size} node(s), ${edgeCount} edge(s)${focusNote}`
    );
    console.log(`  written  .workspace/graph.md`);
  }
}

// ─── CLI entry point ──────────────────────────────────────────────────────────

function main() {
  const argv = process.argv.slice(2);
  let quiet      = false;
  let noSymbols  = false;
  let focusFile  = null;
  let depth      = 1;
  let repoRoot   = null;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--quiet")        quiet = true;
    else if (arg === "--no-symbols") noSymbols = true;
    else if (arg === "graph")        continue;
    else if (arg === "--focus")      focusFile = argv[++i];
    else if (arg === "--depth")      depth = parseInt(argv[++i], 10) || 1;
    else if (!arg.startsWith("--"))  repoRoot = arg;
  }

  const targetDir = repoRoot ? path.resolve(process.cwd(), repoRoot) : process.cwd();

  try {
    runGraph(targetDir, { focusFile, depth, noSymbols, quiet });
  } catch (err) {
    console.error(`wkix graph: ${err.message}`);
    process.exitCode = 1;
  }
}

main();
