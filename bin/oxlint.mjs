#!/usr/bin/env node
/**
 * oxlint.mjs — runs oxlint on a project and writes .workspace/lint.json
 *
 * Usage:
 *   node bin/oxlint.mjs [target-dir] [--quiet]
 *   npx wkix lint [target-dir] [--quiet]
 *
 * Output: .workspace/lint.json
 *
 * Requires oxlint to be installed:
 *   npm install --save-dev oxlint
 *   # or
 *   npx oxlint@latest
 */

import { spawnSync } from "node:child_process";
import { writeFileSync, mkdirSync, existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function resolveOxlint(targetDir) {
  // 1. local node_modules/.bin/oxlint
  const local = path.join(targetDir, "node_modules", ".bin", "oxlint");
  if (existsSync(local)) return local;

  // 2. npx fallback
  return null;
}

/**
 * Oxlint outputs one JSON object per line (NDJSON) when using --format json.
 * Each line is: { severity, filename, message, rule, start: { line, column } }
 */
function parseOxlintOutput(stdout) {
  const lines = stdout.split("\n").filter((l) => l.trim().startsWith("{"));
  const diagnostics = [];

  for (const line of lines) {
    try {
      diagnostics.push(JSON.parse(line));
    } catch {
      // skip malformed lines
    }
  }

  return diagnostics;
}

function groupByFile(diagnostics) {
  const byFile = {};
  for (const d of diagnostics) {
    const file = d.filename ?? d.file ?? "unknown";
    if (!byFile[file]) byFile[file] = [];
    byFile[file].push({
      rule: d.rule ?? d.code ?? null,
      severity: d.severity ?? "error",
      message: d.message,
      line: d.start?.line ?? d.line ?? null,
      column: d.start?.column ?? d.column ?? null,
    });
  }
  return byFile;
}

function runOxlint(targetDir, quiet) {
  const bin = resolveOxlint(targetDir);
  const cmd = bin ?? "npx";
  const args = bin
    ? ["--format", "json", targetDir]
    : ["oxlint", "--format", "json", targetDir];

  if (!quiet) console.log(`wkix lint: running oxlint on ${targetDir} …`);

  const result = spawnSync(cmd, args, {
    cwd: targetDir,
    encoding: "utf8",
    shell: false,
    // oxlint exits with 1 when there are lint errors — that's expected
    maxBuffer: 32 * 1024 * 1024,
  });

  if (result.error) {
    throw new Error(
      `Failed to launch oxlint: ${result.error.message}\n` +
        `Make sure oxlint is installed: npm install --save-dev oxlint`
    );
  }

  return {
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    exitCode: result.status ?? 0,
  };
}

function writeLintJson(targetDir, diagnostics, { quiet, exitCode, stderr }) {
  const wsDir = path.join(targetDir, ".workspace");
  mkdirSync(wsDir, { recursive: true });

  const byFile = groupByFile(diagnostics);
  const errorCount = diagnostics.filter((d) => (d.severity ?? "error") === "error").length;
  const warnCount = diagnostics.filter((d) => d.severity === "warning").length;

  const output = {
    generatedAt: new Date().toISOString(),
    summary: {
      total: diagnostics.length,
      errors: errorCount,
      warnings: warnCount,
      filesAffected: Object.keys(byFile).length,
    },
    byFile,
    // raw list for quick grep / filtering
    diagnostics,
  };

  const outPath = path.join(wsDir, "lint.json");
  writeFileSync(outPath, JSON.stringify(output, null, 2), "utf8");

  if (!quiet) {
    const { total, errors, warnings, filesAffected } = output.summary;
    if (total === 0) {
      console.log("wkix lint: no issues found ✓");
    } else {
      console.log(
        `wkix lint: ${total} issue(s) — ${errors} error(s), ${warnings} warning(s) across ${filesAffected} file(s)`
      );
    }
    console.log(`  written  .workspace/lint.json`);
  }

  if (stderr && !quiet) {
    process.stderr.write(stderr);
  }

  return exitCode;
}

export function runLint(targetDir, { quiet = false } = {}) {
  const { stdout, stderr, exitCode } = runOxlint(targetDir, quiet);
  const diagnostics = parseOxlintOutput(stdout);
  return writeLintJson(targetDir, diagnostics, { quiet, exitCode, stderr });
}

// CLI entry point
function main() {
  const argv = process.argv.slice(2);
  let quiet = false;
  let repoRoot = null;

  for (const arg of argv) {
    if (arg === "--quiet") quiet = true;
    else if (arg === "lint") continue;
    else if (!arg.startsWith("--")) repoRoot = arg;
  }

  const targetDir = repoRoot ? path.resolve(process.cwd(), repoRoot) : process.cwd();

  try {
    const exitCode = runLint(targetDir, { quiet });
    // propagate oxlint exit code only when there are real errors (not lint errors)
    process.exitCode = exitCode > 1 ? exitCode : 0;
  } catch (err) {
    console.error(`wkix lint: ${err.message}`);
    process.exitCode = 1;
  }
}

main();
