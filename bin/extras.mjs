#!/usr/bin/env node
/**
 * extras.mjs — post-processing generators that run after the Zig indexer.
 *
 * Generates:
 *   .workspace/env_vars.json     — all process.env.VAR usages
 *   .workspace/dead_code.json    — unused exports + orphan files
 *   .workspace/api_surface.json  — public API surface
 *   .workspace/call_graph.json   — per-function call graph (project symbols only)
 *   .workspace/type_hierarchy.json — class/interface inheritance
 *   .workspace/complexity.json   — McCabe complexity per function
 */

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";

function readJson(filePath) {
  try {
    return JSON.parse(readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

function writeJson(filePath, data) {
  writeFileSync(filePath, JSON.stringify(data, null, 2), "utf8");
}

// ─── shared helpers ───────────────────────────────────────────────────────────

/**
 * Load all source file contents from repo_map.json.
 * Returns Map<relativePath, lines[]>
 */
function loadSourceFiles(targetDir, repoMap) {
  const files = new Map();
  for (const file of repoMap.files ?? []) {
    try {
      const content = readFileSync(path.join(targetDir, file.path), "utf8");
      files.set(file.path, content.split("\n"));
    } catch {
      files.set(file.path, []);
    }
  }
  return files;
}

/**
 * Group function/method symbols by file, sorted by line.
 * Returns Map<filePath, symbol[]>
 */
function groupFunctionsByFile(symbols) {
  const byFile = new Map();
  for (const syms of Object.values(symbols.byName ?? {})) {
    for (const sym of syms) {
      if (sym.kind !== "function" && sym.kind !== "method") continue;
      if (!byFile.has(sym.file)) byFile.set(sym.file, []);
      byFile.get(sym.file).push(sym);
    }
  }
  for (const syms of byFile.values()) {
    syms.sort((a, b) => a.line - b.line);
  }
  return byFile;
}

/**
 * For each function symbol, extract its approximate body lines.
 * Heuristic: from symbol's start line to the line before the next symbol
 * in the same file (capped at 300 lines to avoid huge functions bloating output).
 */
function getFunctionBodies(sourceFiles, byFile) {
  const bodies = [];
  for (const [filePath, syms] of byFile.entries()) {
    const lines = sourceFiles.get(filePath) ?? [];
    for (let i = 0; i < syms.length; i++) {
      const sym = syms[i];
      const startIdx = sym.line - 1; // 0-based
      const endIdx = i + 1 < syms.length
        ? Math.min(syms[i + 1].line - 2, startIdx + 300)
        : Math.min(lines.length - 1, startIdx + 300);
      const body = lines.slice(startIdx, endIdx + 1).join("\n");
      bodies.push({ sym, body, lineCount: endIdx - startIdx + 1 });
    }
  }
  return bodies;
}

// ─── env_vars.json ────────────────────────────────────────────────────────────

function generateEnvVars(targetDir, wsDir) {
  const repoMap = readJson(path.join(wsDir, "repo_map.json"));
  if (!repoMap) return null;

  const usages = [];
  const uniqueVars = new Set();
  const envVarRe = /process\.env\.([A-Za-z_][A-Za-z0-9_]*)/g;

  for (const file of repoMap.files ?? []) {
    let content;
    try {
      content = readFileSync(path.join(targetDir, file.path), "utf8");
    } catch {
      continue;
    }
    const lines = content.split("\n");
    for (let i = 0; i < lines.length; i++) {
      envVarRe.lastIndex = 0;
      let match;
      while ((match = envVarRe.exec(lines[i])) !== null) {
        uniqueVars.add(match[1]);
        usages.push({ variable: match[1], file: file.path, line: i + 1 });
      }
    }
  }

  return {
    generatedAt: new Date().toISOString(),
    unique: [...uniqueVars].sort(),
    count: uniqueVars.size,
    usages,
  };
}

// ─── dead_code.json ───────────────────────────────────────────────────────────

const ORPHAN_EXCLUDE_RE = /(\/|^)(index|test|spec|__tests__|__mocks__)\./i;

function generateDeadCode(targetDir, wsDir) {
  const symbols = readJson(path.join(wsDir, "symbols.json"));
  const importGraph = readJson(path.join(wsDir, "import_graph.json"));
  const repoMap = readJson(path.join(wsDir, "repo_map.json"));
  if (!symbols || !importGraph || !repoMap) return null;

  const fileContents = {};
  for (const file of repoMap.files ?? []) {
    try {
      fileContents[file.path] = readFileSync(path.join(targetDir, file.path), "utf8");
    } catch {
      fileContents[file.path] = "";
    }
  }

  const graph = importGraph.graph ?? {};

  const orphanFiles = [];
  for (const [file, entry] of Object.entries(graph)) {
    if (ORPHAN_EXCLUDE_RE.test(file)) continue;
    if ((entry.importedBy ?? []).length === 0) orphanFiles.push(file);
  }

  const unusedExports = [];
  for (const [name, syms] of Object.entries(symbols.byName ?? {})) {
    for (const sym of syms) {
      if (!sym.exported) continue;
      const appearsElsewhere = Object.entries(fileContents).some(
        ([filePath, content]) => filePath !== sym.file && content.includes(name)
      );
      if (!appearsElsewhere) {
        unusedExports.push({ name, kind: sym.kind, file: sym.file, line: sym.line });
      }
    }
  }

  unusedExports.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line);

  return {
    generatedAt: new Date().toISOString(),
    summary: {
      unusedExportCount: unusedExports.length,
      orphanFileCount: orphanFiles.length,
    },
    unusedExports,
    orphanFiles: orphanFiles.sort(),
  };
}

// ─── api_surface.json ─────────────────────────────────────────────────────────

function buildSignature(sym) {
  if (sym.kind === "function" || sym.kind === "method") {
    const params = (sym.params ?? []).join(", ");
    const ret = sym.returnType ? `: ${sym.returnType}` : "";
    return `(${params})${ret}`;
  }
  if (sym.kind === "class") {
    const parts = [];
    if (sym.extends) parts.push(`extends ${sym.extends}`);
    if (sym.implements?.length) parts.push(`implements ${sym.implements.join(", ")}`);
    return parts.join(" ") || null;
  }
  if (sym.kind === "interface") {
    return sym.extends ? `extends ${sym.extends}` : null;
  }
  return null;
}

function generateApiSurface(_targetDir, wsDir) {
  const symbols = readJson(path.join(wsDir, "symbols.json"));
  if (!symbols) return null;

  const byFile = {};
  let count = 0;

  for (const syms of Object.values(symbols.byName ?? {})) {
    for (const sym of syms) {
      if (!sym.exported) continue;
      if (!byFile[sym.file]) byFile[sym.file] = [];
      byFile[sym.file].push({
        name: sym.name,
        kind: sym.kind,
        line: sym.line,
        signature: buildSignature(sym),
      });
      count++;
    }
  }

  for (const syms of Object.values(byFile)) {
    syms.sort((a, b) => a.line - b.line);
  }

  return {
    generatedAt: new Date().toISOString(),
    count,
    byFile,
  };
}

// ─── call_graph.json ──────────────────────────────────────────────────────────

// Keywords and builtins to exclude from call detection
const JS_BUILTINS = new Set([
  "if", "for", "while", "switch", "catch", "new", "return", "typeof",
  "instanceof", "void", "delete", "throw", "case", "default", "function",
  "class", "import", "export", "const", "let", "var", "async", "await",
  "yield", "super", "this", "null", "undefined", "true", "false",
  "console", "Object", "Array", "String", "Number", "Boolean", "Promise",
  "Math", "JSON", "Date", "Error", "Map", "Set", "Symbol", "RegExp",
  "parseInt", "parseFloat", "isNaN", "isFinite", "require", "module",
  "process", "global", "Buffer", "setTimeout", "setInterval", "clearTimeout",
  "clearInterval", "fetch", "URL", "URLSearchParams",
]);

const CALL_RE = /\b([a-zA-Z_$][a-zA-Z0-9_$]*)\s*\(/g;

function generateCallGraph(targetDir, wsDir) {
  const symbols = readJson(path.join(wsDir, "symbols.json"));
  const repoMap = readJson(path.join(wsDir, "repo_map.json"));
  if (!symbols || !repoMap) return null;

  // Build set of all known project function/method names
  const projectFunctions = new Set();
  for (const [name, syms] of Object.entries(symbols.byName ?? {})) {
    for (const sym of syms) {
      if (sym.kind === "function" || sym.kind === "method") {
        projectFunctions.add(name);
      }
    }
  }

  const sourceFiles = loadSourceFiles(targetDir, repoMap);
  const byFile = groupFunctionsByFile(symbols);
  const bodies = getFunctionBodies(sourceFiles, byFile);

  const graph = {};

  for (const { sym, body } of bodies) {
    const key = `${sym.file}::${sym.name}`;
    const calls = new Set();

    CALL_RE.lastIndex = 0;
    let match;
    while ((match = CALL_RE.exec(body)) !== null) {
      const name = match[1];
      if (name === sym.name) continue;           // skip self-call label
      if (JS_BUILTINS.has(name)) continue;       // skip builtins
      if (projectFunctions.has(name)) calls.add(name);
    }

    graph[key] = {
      name: sym.name,
      file: sym.file,
      line: sym.line,
      calls: [...calls].sort(),
    };
  }

  return {
    generatedAt: new Date().toISOString(),
    count: Object.keys(graph).length,
    graph,
  };
}

// ─── type_hierarchy.json ──────────────────────────────────────────────────────

// Match: class Foo extends Bar implements Baz, Qux {
const CLASS_RE = /\bclass\s+(\w+)(?:\s+extends\s+([\w.]+))?(?:\s+implements\s+([\w\s,<>[\]]+?))?(?=\s*\{)/gm;
// Match: interface Foo extends Bar, Baz {
const IFACE_RE = /\binterface\s+(\w+)(?:\s+extends\s+([\w\s,<>[\]]+?))?(?=\s*\{)/gm;

function stripGenerics(s) {
  return s.replace(/<[^>]*>/g, "").trim();
}

function splitList(s) {
  return s.split(",").map((x) => stripGenerics(x.trim())).filter(Boolean);
}

function lineOf(content, index) {
  return content.slice(0, index).split("\n").length;
}

function generateTypeHierarchy(targetDir, wsDir) {
  const repoMap = readJson(path.join(wsDir, "repo_map.json"));
  if (!repoMap) return null;

  const classes = [];
  const interfaces = [];

  for (const file of repoMap.files ?? []) {
    let content;
    try {
      content = readFileSync(path.join(targetDir, file.path), "utf8");
    } catch {
      continue;
    }

    CLASS_RE.lastIndex = 0;
    let match;
    while ((match = CLASS_RE.exec(content)) !== null) {
      const implementsList = match[3] ? splitList(match[3]) : [];
      classes.push({
        name: match[1],
        file: file.path,
        line: lineOf(content, match.index),
        extends: match[2] ? stripGenerics(match[2]) : null,
        implements: implementsList.length ? implementsList : undefined,
      });
    }

    IFACE_RE.lastIndex = 0;
    while ((match = IFACE_RE.exec(content)) !== null) {
      const extendsList = match[2] ? splitList(match[2]) : [];
      interfaces.push({
        name: match[1],
        file: file.path,
        line: lineOf(content, match.index),
        extends: extendsList.length ? extendsList : undefined,
      });
    }
  }

  classes.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line);
  interfaces.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line);

  return {
    generatedAt: new Date().toISOString(),
    summary: { classCount: classes.length, interfaceCount: interfaces.length },
    classes,
    interfaces,
  };
}

// ─── complexity.json ──────────────────────────────────────────────────────────

// Branch-inducing constructs for McCabe complexity
const BRANCH_RE = /\b(if|else\s+if|for\s*\(|for\s+\w|while\s*\(|do\s*\{|switch\s*\(|catch\s*\(|case\s+)\b|\?\s*(?!\.)/g;

function countBranches(body) {
  BRANCH_RE.lastIndex = 0;
  let count = 0;
  while (BRANCH_RE.exec(body) !== null) count++;
  return count;
}

function generateComplexity(targetDir, wsDir) {
  const symbols = readJson(path.join(wsDir, "symbols.json"));
  const repoMap = readJson(path.join(wsDir, "repo_map.json"));
  if (!symbols || !repoMap) return null;

  const sourceFiles = loadSourceFiles(targetDir, repoMap);
  const byFile = groupFunctionsByFile(symbols);
  const bodies = getFunctionBodies(sourceFiles, byFile);

  const functions = [];
  let maxComplexity = 0;

  for (const { sym, body, lineCount } of bodies) {
    const branches = countBranches(body);
    const complexity = branches + 1; // McCabe = branches + 1
    if (complexity > maxComplexity) maxComplexity = complexity;
    functions.push({
      name: sym.name,
      file: sym.file,
      line: sym.line,
      complexity,
      branches,
      lineCount,
    });
  }

  // Sort by complexity descending so hotspots are at the top
  functions.sort((a, b) => b.complexity - a.complexity || a.file.localeCompare(b.file));

  // Group by file as well for quick per-file lookup
  const byFile2 = {};
  for (const fn of functions) {
    if (!byFile2[fn.file]) byFile2[fn.file] = [];
    byFile2[fn.file].push(fn);
  }

  return {
    generatedAt: new Date().toISOString(),
    summary: {
      functionCount: functions.length,
      maxComplexity,
      highComplexityCount: functions.filter((f) => f.complexity >= 10).length,
    },
    // flat list sorted by complexity (hotspots first)
    functions,
    byFile: byFile2,
  };
}

// ─── runner ───────────────────────────────────────────────────────────────────

const GENERATORS = [
  { file: "env_vars.json",       fn: generateEnvVars },
  { file: "dead_code.json",      fn: generateDeadCode },
  { file: "api_surface.json",    fn: generateApiSurface },
  { file: "call_graph.json",     fn: generateCallGraph },
  { file: "type_hierarchy.json", fn: generateTypeHierarchy },
  { file: "complexity.json",     fn: generateComplexity },
];

export function runExtras(targetDir, { quiet = false } = {}) {
  const wsDir = path.join(targetDir, ".workspace");
  if (!existsSync(wsDir)) return;

  for (const { file, fn } of GENERATORS) {
    try {
      const result = fn(targetDir, wsDir);
      if (result) {
        writeJson(path.join(wsDir, file), result);
        if (!quiet) console.log(`  written  .workspace/${file}`);
      }
    } catch (err) {
      if (!quiet) console.error(`wkix extras: failed to generate ${file}: ${err.message}`);
    }
  }
}
