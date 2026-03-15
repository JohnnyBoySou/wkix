![WorKspace IndeXer](repo_bg.jpg)

# WorKspace IndeXer (wkix)

**Fast codebase indexer for LLMs.** Scans your repo in milliseconds, generates structured JSON files in `.workspace/`, and injects navigation instructions into `CLAUDE.md` / `AGENTS.md`.

Built in Zig. No runtime dependencies. Incremental by default.

---

## Why

LLMs navigating a codebase waste context on blind file searches. `wkix` pre-computes everything an agent needs — symbol locations, import graph, code chunks, TODOs — so it can answer "where is `useAuth`?" in one lookup instead of reading ten files.

---

## Supported languages

**Currently wkix only indexes JavaScript and TypeScript projects.**

| Extensions       | Language   |
|------------------|------------|
| `.ts`, `.mts`, `.cts` | TypeScript |
| `.tsx`           | TSX        |
| `.js`, `.mjs`, `.cjs` | JavaScript |
| `.jsx`           | JSX        |

Files with other extensions (e.g. `.py`, `.zig`, `.go`, `.rs`) **are not indexed** — the walker ignores everything that isn’t JS/TS. Symbols, imports/exports, and the dependency graph rely on tree-sitter grammars for these languages. In mixed repos, only the JS/TS part is indexed.

### Adding more languages (e.g. Python)

Yes. The pipeline is built on [tree-sitter](https://tree-sitter.github.io/), so any language with a tree-sitter grammar can be wired in. To add support for a new language (e.g. Python), you need to:

1. **Vendor the grammar** — Add the language repo (e.g. `tree-sitter-python`) under `vendor/` and compile its `parser.c` / `scanner.c` in `build.zig`.
2. **Extend the language enum** — In `src/types.zig`, add a variant (e.g. `python`) to `Language`. In `src/walk.zig`, add the file extensions (e.g. `.py`) to `ext_to_lang`.
3. **Wire the parser** — In `src/ts_parser.zig`, add the C binding (e.g. `tree_sitter_python()`) and handle the new language in `getLanguage()`.
4. **Add language-specific extractors** — The current extractors in `src/extractors.zig` are built for JS/TS AST node names (`import_statement`, `export_statement`, `function_declaration`, etc.). For Python you’d implement extractors that use that grammar’s node types (e.g. `import_statement`, `import_from_statement`, `function_definition`, `class_definition`) and either call them from `parse.zig` when `lang == .python` or refactor into a small dispatcher per language.

So adding Python (or Zig, Go, Rust, etc.) is a matter of adding the grammar, the enum + file detection, the parser binding, and the extractors for that AST; the rest of the pipeline (walk, hash, incremental cache, writer, CLI) is language-agnostic.

---

## Usage

```bash
npx wkix generate
# or
bunx wkix generate
```

Run from the root of a JavaScript/TypeScript project. The command:

1. Walks the repo and hashes every file (parallel, one thread per core)
2. Parses changed files with tree-sitter (incremental — unchanged files are skipped)
3. Writes `.workspace/*.json`
4. Upserts the `## Workspace Index` section in `CLAUDE.md` (and in `AGENTS.md` if it exists)

### Options

| Flag         | Description                                  |
|-------------|----------------------------------------------|
| `--force`   | Reindex everything, ignore cache             |
| `--quiet`   | Suppress output                              |
| `--no-inject` | Skip CLAUDE.md / AGENTS.md update          |

---

## Output files

All files are written to `.workspace/` at the repo root.

| File                    | Contents |
|-------------------------|----------|
| `repo_map.json`         | Every file — path, size, lines, symbol/export/import counts |
| `symbols.json`          | Functions, classes, types, enums with exact line, parameters, return type. Includes `byName` map for O(1) lookup |
| `import_graph.json`     | Per-file `imports` and `importedBy` (resolved paths) |
| `chunks.json`           | Code split into logical chunks with full content |
| `todos.json`            | TODO / FIXME / HACK / NOTE / XXX comments with file and line |
| `repo_docs.json`        | README content |
| `project_metadata.json` | Package name, scripts, dependency counts |
| `test_map.json`         | Source file → test file mapping |
| `call_graph.json`       | Per-function list of project functions called within each body |
| `type_hierarchy.json`   | Classes/interfaces with extends and implements |
| `env_vars.json`         | All `process.env.VAR` usages with file and line |
| `complexity.json`       | McCabe complexity per function, sorted by hotspots |
| `dead_code.json`        | Exported symbols never imported + orphan files |
| `api_surface.json`      | All exported symbols with computed signatures |
| `lint.json`             | Oxlint diagnostics grouped by file (run `wkix lint`) |
| `graph.md`              | Mermaid import graph (run `wkix graph`) |
| `metadata.json`         | File hashes used for incremental indexing |

---

## File examples

### `symbols.json` — locate any function/class by name instantly

```json
{
  "byName": {
    "createUser": [{
      "name": "createUser",
      "kind": "function",
      "file": "src/users.ts",
      "line": 42,
      "exported": true,
      "params": ["email: string", "role: Role"],
      "returnType": "Promise<User>"
    }]
  }
}
```

### `import_graph.json` — trace who imports what in both directions

```json
{
  "graph": {
    "src/users.ts": {
      "imports": ["src/db.ts", "src/types.ts"],
      "importedBy": ["src/routes/auth.ts", "src/routes/admin.ts"]
    }
  }
}
```

### `call_graph.json` — see which project functions a function calls

```json
{
  "graph": {
    "src/users.ts::createUser": {
      "name": "createUser",
      "file": "src/users.ts",
      "line": 42,
      "calls": ["hashPassword", "sendWelcomeEmail", "validateEmail"]
    }
  }
}
```

### `type_hierarchy.json` — trace class/interface inheritance

```json
{
  "classes": [
    {
      "name": "AdminUser",
      "file": "src/models/user.ts",
      "line": 10,
      "extends": "BaseUser",
      "implements": ["ISerializable", "IAuditable"]
    }
  ],
  "interfaces": [
    {
      "name": "IAuditable",
      "file": "src/types.ts",
      "line": 3,
      "extends": ["ITimestamped"]
    }
  ]
}
```

### `complexity.json` — find the riskiest functions before editing

```json
{
  "summary": { "functionCount": 48, "maxComplexity": 14, "highComplexityCount": 3 },
  "functions": [
    { "name": "processOrder", "file": "src/orders.ts", "line": 88, "complexity": 14, "branches": 13, "lineCount": 97 },
    { "name": "parseConfig",  "file": "src/config.ts", "line": 12, "complexity": 9,  "branches": 8,  "lineCount": 61 }
  ]
}
```

### `dead_code.json` — spot unused exports and orphan files

```json
{
  "summary": { "unusedExportCount": 2, "orphanFileCount": 1 },
  "unusedExports": [
    { "name": "legacyFormat", "kind": "function", "file": "src/utils.ts", "line": 201 }
  ],
  "orphanFiles": ["src/old-helpers.ts"]
}
```

### `api_surface.json` — read the public API without opening files

```json
{
  "byFile": {
    "src/users.ts": [
      { "name": "createUser", "kind": "function", "line": 42, "signature": "(email: string, role: Role): Promise<User>" },
      { "name": "UserService", "kind": "class",    "line": 10, "signature": "extends BaseService implements IUserService" }
    ]
  }
}
```

### `env_vars.json` — know every required environment variable

```json
{
  "unique": ["DATABASE_URL", "JWT_SECRET", "PORT"],
  "usages": [
    { "variable": "DATABASE_URL", "file": "src/db.ts",     "line": 3 },
    { "variable": "JWT_SECRET",   "file": "src/auth.ts",   "line": 17 },
    { "variable": "PORT",         "file": "src/server.ts", "line": 5 }
  ]
}
```

### `todos.json` — find all known issues in one place

```json
{
  "entries": [
    { "kind": "TODO",  "text": "add rate limiting",       "file": "src/routes/auth.ts", "line": 55 },
    { "kind": "FIXME", "text": "handle empty array edge case", "file": "src/utils.ts", "line": 102 }
  ]
}
```

### `lint.json` — check lint errors without running the linter

```json
{
  "summary": { "total": 3, "errors": 1, "warnings": 2, "filesAffected": 2 },
  "byFile": {
    "src/users.ts": [
      { "rule": "no-unused-vars", "severity": "error", "message": "'tmp' is declared but never read", "line": 12 }
    ]
  }
}
```

### `chunks.json` — read code snippets without opening full files

```json
{
  "chunks": [
    {
      "id": "src/users.ts#42-78",
      "file": "src/users.ts",
      "startLine": 42,
      "endLine": 78,
      "symbolName": "createUser",
      "content": "export async function createUser(email: string) {\n  ..."
    }
  ]
}
```

### `test_map.json` — jump straight to a module's tests

```json
{
  "map": {
    "src/users.ts": "src/users.test.ts",
    "src/orders.ts": "src/__tests__/orders.spec.ts"
  }
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

| Repo size    | Cold   | Incremental |
|--------------|--------|-------------|
| ~50 files    | ~0.3s  | ~0.05s      |
| ~500 files   | ~1.2s  | ~0.1s       |

---

## Requirements

- **Node.js ≥ 18** — to run the CLI wrapper
- **Zig ≥ 0.14** — only needed when building from source; the npm package ships a pre-compiled binary

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
