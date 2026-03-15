#!/usr/bin/env node
/**
 * extras.mjs — post-processing generators that run after the Zig indexer.
 *
 * Generates:
 *   .workspace/env_vars.json   — all process.env.VAR usages
 *   .workspace/dead_code.json  — unused exports + orphan files
 *   .workspace/api_surface.json — public API surface
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

// ─── env_vars.json ────────────────────────────────────────────────────────────

function generateEnvVars(targetDir, wsDir) {
  const repoMap = readJson(path.join(wsDir, "repo_map.json"));
  if (!repoMap) return null;

  const usages = [];
  const uniqueVars = new Set();
  const envVarRe = /process\.env\.([A-Za-z_][A-Za-z0-9_]*)/g;

  for (const file of repoMap.files ?? []) {
    const filePath = path.join(targetDir, file.path);
    let content;
    try {
      content = readFileSync(filePath, "utf8");
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

  // Build a map: file → full content (for name-occurrence checks)
  const fileContents = {};
  for (const file of repoMap.files ?? []) {
    try {
      fileContents[file.path] = readFileSync(path.join(targetDir, file.path), "utf8");
    } catch {
      fileContents[file.path] = "";
    }
  }

  const graph = importGraph.graph ?? {};

  // Find orphan files: files that nothing imports (excluding index/test/spec)
  const orphanFiles = [];
  for (const [file, entry] of Object.entries(graph)) {
    if (ORPHAN_EXCLUDE_RE.test(file)) continue;
    if ((entry.importedBy ?? []).length === 0) {
      orphanFiles.push(file);
    }
  }

  // Find unused exports: exported symbols whose name doesn't appear in any
  // other file's source text (conservative text-search heuristic)
  const unusedExports = [];
  for (const [name, syms] of Object.entries(symbols.byName ?? {})) {
    for (const sym of syms) {
      if (!sym.exported) continue;
      // Check if any other file mentions this name
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

  // Sort symbols within each file by line
  for (const syms of Object.values(byFile)) {
    syms.sort((a, b) => a.line - b.line);
  }

  return {
    generatedAt: new Date().toISOString(),
    count,
    byFile,
  };
}

// ─── runner ───────────────────────────────────────────────────────────────────

const GENERATORS = [
  { file: "env_vars.json", fn: generateEnvVars },
  { file: "dead_code.json", fn: generateDeadCode },
  { file: "api_surface.json", fn: generateApiSurface },
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
