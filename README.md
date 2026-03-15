# wkix

**Fast codebase indexer for LLMs.** Scans your repo in milliseconds, generates structured `.workspace/` JSON files, and automatically injects navigation instructions into `CLAUDE.md` / `AGENTS.md`.

Built in Zig. No runtime dependencies. Incremental by default.

---

## Why

LLMs navigating a codebase waste context on blind file searches. `wkix` pre-computes everything an agent needs — symbol locations, import graphs, code chunks, TODOs — so it can answer "where is `useAuth`?" in one lookup instead of reading ten files.

---

## Usage

```bash
npx wkix generate
# or
bunx wkix generate
```

Run this at the root of any JavaScript / TypeScript project. It will:

1. Walk the repo and hash every file (parallel, CPU-count threads)
2. Parse changed files with tree-sitter (incremental — unchanged files are skipped)
3. Write `.workspace/*.json`
4. Upsert a `## Workspace Index` section in `CLAUDE.md` (and `AGENTS.md` if it exists)

### Options

| Flag | Description |
|------|-------------|
| `--force` | Reindex everything, ignore cache |
| `--quiet` | Suppress output |
| `--no-inject` | Skip CLAUDE.md / AGENTS.md update |

---

## Output files

All files are written to `.workspace/` in the repo root.

| File | Contents |
|------|----------|
| `repo_map.json` | Every file — path, size, line count, symbol/export/import counts |
| `symbols.json` | All functions, classes, types, enums with exact line, parameters, return type, doc comment. Includes `byName` map for O(1) lookup |
| `import_graph.json` | Per-file `imports` and `importedBy` (resolved, not raw strings) |
| `chunks.json` | Code split into logical chunks with full content |
| `todos.json` | Every TODO / FIXME / HACK / NOTE / XXX comment with file and line |
| `repo_docs.json` | README content |
| `project_metadata.json` | Package name, scripts, dependency counts |
| `test_map.json` | Source file → test file mapping |
| `metadata.json` | File hashes used for incremental indexing |

### Example: finding a symbol

```json
// .workspace/symbols.json → byName["useAuth"]
{
  "id": "src/hooks/useAuth.ts::useAuth",
  "kind": "function",
  "line": 12,
  "params": ["options?: AuthOptions"],
  "returnType": "AuthContext"
}
```

### Example: import graph

```json
// .workspace/import_graph.json → nodes["src/pages/Login.tsx"]
{
  "imports": ["src/hooks/useAuth.ts", "src/components/Button.tsx"],
  "importedBy": ["src/App.tsx"]
}
```

---

## CLAUDE.md injection

After indexing, wkix upserts this section into `CLAUDE.md`:

```markdown
## Workspace Index

This repo has a pre-generated codebase index in `.workspace/`.
Before exploring code, consult these files — avoids blind searches and speeds up navigation significantly.

| File | Contents | When to use |
| ...  | ...      | ...         |

Recommended workflow:
1. repo_map.json → identify relevant files by size and symbol count
2. symbols.json → locate a function/class by name (use byName)
3. Read the actual file only if you need full context
```

The section is idempotent — re-running `wkix generate` updates it in place without duplicating content.

---

## Performance

wkix uses a compiled Zig binary with parallel file hashing across all CPU cores. Incremental mode skips unchanged files using SHA-256 content hashes stored in `metadata.json`.

Typical indexing times:

| Repo size | Cold | Incremental |
|-----------|------|-------------|
| ~50 files | ~0.3s | ~0.05s |
| ~500 files | ~1.2s | ~0.1s |

---

## Requirements

- **Node.js ≥ 18** (to run the CLI wrapper)
- **Zig ≥ 0.14** — only needed if building from source; the npm package ships a pre-compiled binary

### Build from source

```bash
git clone https://github.com/JohnnyBoySou/wkix
cd wkix
zig build -Doptimize=ReleaseFast
# binary at zig-out/bin/wkix
```

---

## License

MIT
