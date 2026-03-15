#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runLint } from "./oxlint.mjs";
import { runGraph } from "./graph.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const pkgRoot = path.resolve(__dirname, "..");


const PLATFORM_PACKAGES = {
  "linux-x64":    "@myselfcoding/wkix-linux-x64",
  "darwin-arm64": "@myselfcoding/wkix-darwin-arm64",
  "darwin-x64":   "@myselfcoding/wkix-darwin-x64",
  "win32-x64":    "@myselfcoding/wkix-win32-x64",
};

function resolveBinary() {
  const key = `${process.platform}-${process.arch}`;
  const pkgName = PLATFORM_PACKAGES[key];
  const binName = process.platform === "win32" ? "wkix.exe" : "wkix";

  if (pkgName) {
    try {
      const require = createRequire(import.meta.url);
      const pkgDir = path.dirname(require.resolve(`${pkgName}/package.json`));
      const bin = path.join(pkgDir, "bin", binName);
      if (existsSync(bin)) return { bin, fallback: false };
    } catch {}
  }

  const localBin = path.join(pkgRoot, "zig-out", "bin", binName);
  if (existsSync(localBin)) return { bin: localBin, fallback: false };

  return { bin: null, fallback: true };
}


function runIndexer(targetDir, { force, quiet }) {
  const { bin, fallback } = resolveBinary();
  const extraArgs = [...(force ? ["--force"] : []), ...(quiet ? ["--quiet"] : [])];

  let cmd, args, cwd;
  if (!fallback) {
    cmd = bin;
    args = [targetDir, ...extraArgs];
    cwd = undefined;
  } else {
    if (!quiet) console.error("wkix: pre-compiled binary not found, falling back to `zig build run` (requires Zig ≥ 0.14)");
    cmd = "zig";
    args = ["build", "run", "--", targetDir, ...extraArgs];
    cwd = pkgRoot;
  }

  const result = spawnSync(cmd, args, { cwd, stdio: "inherit", shell: false });

  if (result.signal) return 128 + ({ SIGINT: 2, SIGTERM: 15 }[result.signal] ?? 1);
  return result.status ?? 0;
}


function readWorkspaceStats(targetDir) {
  const wsDir = path.join(targetDir, ".workspace");
  try {
    const repoMap = JSON.parse(readFileSync(path.join(wsDir, "repo_map.json"), "utf8"));
    const symbols = JSON.parse(readFileSync(path.join(wsDir, "symbols.json"), "utf8"));
    const todos   = JSON.parse(readFileSync(path.join(wsDir, "todos.json"), "utf8"));
    return {
      fileCount:    repoMap.fileCount   ?? 0,
      symbolCount:  symbols.count       ?? 0,
      todoCount:    todos.entries?.length ?? 0,
    };
  } catch {
    return { fileCount: 0, symbolCount: 0, todoCount: 0 };
  }
}


function buildWorkspaceSection(stats) {
  return `## Workspace Index

This repository has a pre-generated codebase index in \`.workspace/\`.
**Before exploring the code, check these files** — avoids blind search and speeds up navigation:

| File | Contents | When to use |
|------|----------|-------------|
| \`.workspace/repo_map.json\` | All files with size, lines, symbol/export/import counts | First step — discover which files to read |
| \`.workspace/symbols.json\` | All functions, classes, types, enums — with exact line, parameters and return type. \`byName\` for fast lookup | Locate a symbol by name instantly |
| \`.workspace/import_graph.json\` | Import graph with \`imports\` and \`importedBy\` per file | Trace dependencies in both directions |
| \`.workspace/chunks.json\` | Code split into logical chunks with actual content | Read snippets without opening the whole file |
| \`.workspace/todos.json\` | TODO/FIXME/HACK comments with file and line | Find known issues |
| \`.workspace/repo_docs.json\` | README and documentation content | Project overview |
| \`.workspace/project_metadata.json\` | Package name, scripts, dependency counts | Project configuration |
| \`.workspace/test_map.json\` | Source file → test file mapping | Find tests for a module |
| \`.workspace/call_graph.json\` | Per-symbol list of called function names — extracted from AST | Trace execution flow without reading code |
| \`.workspace/type_hierarchy.json\` | Classes/interfaces with their extends and implements — full inheritance tree | Understand type relationships instantly |
| \`.workspace/env_vars.json\` | All \`process.env.X\` usages with file and line — unique var list + full usage list | Know all config variables at a glance |
| \`.workspace/complexity.json\` | Per-function McCabe complexity, branch count, line count | Find complex/risky functions before editing |
| \`.workspace/dead_code.json\` | Exported symbols never imported + files with no importers | Identify unused code safely |
| \`.workspace/api_surface.json\` | All exported symbols with signatures and doc — the public API | Understand module interfaces without reading implementation |
| \`.workspace/lint.json\` | Oxlint diagnostics grouped by file — errors, warnings, rule names and line numbers | Find lint errors without running the linter |
| \`.workspace/graph.md\` | Mermaid import graph + exported symbol tables — visual map of file dependencies | Understand module structure at a glance |

**Current stats:** ${stats.fileCount} files · ${stats.symbolCount} symbols · ${stats.todoCount} TODOs

**Recommended workflow:**
1. \`repo_map.json\` → identify relevant files by size and symbol count
2. \`symbols.json\` → locate the function/class by name (use \`byName\`)
3. Read the actual file only if you need full context

> Generated by \`workspace generate\`. Update with \`npx workspace generate --force\` or \`bunx workspace generate --force\`.
`;
}


const SECTION_MARKER_START = "## Workspace Index";
const SECTION_MARKER_END_RE = /^## /m;

function upsertSection(filePath, section) {
  let existing = "";
  if (existsSync(filePath)) {
    existing = readFileSync(filePath, "utf8");
  }

  const startIdx = existing.indexOf(SECTION_MARKER_START);
  if (startIdx === -1) {
    const separator = existing.length > 0 && !existing.endsWith("\n\n") ? "\n\n" : "";
    writeFileSync(filePath, existing + separator + section, "utf8");
  } else {
    const afterStart = existing.slice(startIdx + SECTION_MARKER_START.length);
    const nextH2 = afterStart.search(SECTION_MARKER_END_RE);
    const endIdx = nextH2 === -1 ? existing.length : startIdx + SECTION_MARKER_START.length + nextH2;
    const updated = existing.slice(0, startIdx) + section + existing.slice(endIdx);
    writeFileSync(filePath, updated, "utf8");
  }
}

function ensureGitignore(targetDir, quiet) {
  const gitignorePath = path.join(targetDir, ".gitignore");
  const entry = ".workspace/";
  let content = existsSync(gitignorePath) ? readFileSync(gitignorePath, "utf8") : "";
  const lines = content.split("\n");
  if (lines.some((l) => l.trim() === entry)) return;
  const separator = content.length > 0 && !content.endsWith("\n") ? "\n" : "";
  writeFileSync(gitignorePath, content + separator + entry + "\n", "utf8");
  if (!quiet) console.log(`  updated  .gitignore (+${entry})`);
}

function writeAgentInstructions(targetDir, quiet) {
  const stats = readWorkspaceStats(targetDir);
  const section = buildWorkspaceSection(stats);

  const targets = ["CLAUDE.md", "AGENTS.md"];
  for (const name of targets) {
    const filePath = path.join(targetDir, name);
    if (name === "AGENTS.md" && !existsSync(filePath)) continue;
    upsertSection(filePath, section);
    if (!quiet) console.log(`  updated  ${name}`);
  }

  const claudePath = path.join(targetDir, "CLAUDE.md");
  if (!existsSync(claudePath)) {
    upsertSection(claudePath, section);
    if (!quiet) console.log(`  created  CLAUDE.md`);
  }
}


function main() {
  const argv = process.argv.slice(2);
  let force    = false;
  let quiet    = false;
  let noInject = false;
  let repoRoot = null;
  let subcommand = null;

  for (const arg of argv) {
    if (arg === "--force")      force = true;
    else if (arg === "--quiet")     quiet = true;
    else if (arg === "--no-inject") noInject = true;
    else if (arg === "generate")    subcommand = "generate";
    else if (arg === "lint")        subcommand = "lint";
    else if (arg === "graph")       subcommand = "graph";
    else if (!arg.startsWith("--")) repoRoot = arg;
  }

  const targetDir = repoRoot ? path.resolve(process.cwd(), repoRoot) : process.cwd();

  if (subcommand === "lint") {
    try {
      process.exitCode = runLint(targetDir, { quiet });
    } catch (err) {
      console.error(`wkix lint: ${err.message}`);
      process.exitCode = 1;
    }
    return;
  }

  if (subcommand === "graph") {
    // pass remaining args through to runGraph
    const graphArgs = argv.filter((a) => !["graph", repoRoot].includes(a));
    let focusFile = null, depth = 1, noSymbols = false;
    for (let i = 0; i < graphArgs.length; i++) {
      if (graphArgs[i] === "--focus")      focusFile = graphArgs[++i];
      else if (graphArgs[i] === "--depth") depth = parseInt(graphArgs[++i], 10) || 1;
      else if (graphArgs[i] === "--no-symbols") noSymbols = true;
    }
    try {
      runGraph(targetDir, { focusFile, depth, noSymbols, quiet });
    } catch (err) {
      console.error(`wkix graph: ${err.message}`);
      process.exitCode = 1;
    }
    return;
  }

  // default: generate (index)
  const exitCode = runIndexer(targetDir, { force, quiet });

  if (exitCode === 0 && !noInject) {
    ensureGitignore(targetDir, quiet);
    writeAgentInstructions(targetDir, quiet);
  }

  process.exitCode = exitCode;
}

main();
