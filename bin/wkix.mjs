#!/usr/bin/env node

/**
 * CLI do workspace indexer.
 * Uso: workspace generate [--force] [--quiet] [<repo_root>]
 *
 * Após indexar, injeta/atualiza a seção ## Workspace Index em CLAUDE.md e AGENTS.md
 * do repositório alvo, com instruções para o agente consultar .workspace/ primeiro.
 */

import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const pkgRoot = path.resolve(__dirname, "..");
const zigWorkspaceDir = pkgRoot;
const zigBin = path.join(zigWorkspaceDir, "zig-out", "bin", "wkix");

// ─── Indexer ──────────────────────────────────────────────────────────────────

function runIndexer(targetDir, { force, quiet }) {
  // Tenta usar o binário pré-compilado primeiro, fallback para zig build run
  const hasBin = existsSync(zigBin);
  const cmd = hasBin ? zigBin : "zig";
  const args = hasBin
    ? [targetDir, ...(force ? ["--force"] : []), ...(quiet ? ["--quiet"] : [])]
    : ["build", "run", "--", targetDir, ...(force ? ["--force"] : []), ...(quiet ? ["--quiet"] : [])];
  const cwd = hasBin ? undefined : zigWorkspaceDir;

  const result = spawnSync(cmd, args, { cwd, stdio: "inherit", shell: false });

  if (result.signal) return 128 + ({ SIGINT: 2, SIGTERM: 15 }[result.signal] ?? 1);
  return result.status ?? 0;
}

// ─── Lê stats do .workspace gerado ────────────────────────────────────────────

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

// ─── Gera a seção Markdown ────────────────────────────────────────────────────

function buildWorkspaceSection(stats) {
  return `## Workspace Index

Este repositório tem um índice de codebase pré-gerado em \`.workspace/\`.
**Antes de explorar o código, consulte estes arquivos** — evita buscas cegas e acelera muito a navegação:

| Arquivo | Conteúdo | Quando usar |
|---------|----------|-------------|
| \`.workspace/repo_map.json\` | Todos os arquivos com tamanho, linhas, nº de símbolos/exports/imports | Primeiro passo — descubra quais arquivos ler |
| \`.workspace/symbols.json\` | Todas as funções, classes, tipos, enums — com linha exata, parâmetros e tipo de retorno. \`byName\` para busca rápida | Localize um símbolo pelo nome instantaneamente |
| \`.workspace/import_graph.json\` | Grafo de imports com \`imports\` e \`importedBy\` por arquivo | Rastreie dependências nas duas direções |
| \`.workspace/chunks.json\` | Código dividido em chunks lógicos com conteúdo real | Leia trechos sem abrir o arquivo inteiro |
| \`.workspace/todos.json\` | Comentários TODO/FIXME/HACK com arquivo e linha | Encontre problemas conhecidos |
| \`.workspace/repo_docs.json\` | Conteúdo do README e documentação | Visão geral do projeto |
| \`.workspace/project_metadata.json\` | Nome do pacote, scripts, contagem de dependências | Configuração do projeto |
| \`.workspace/test_map.json\` | Mapeamento arquivo-fonte → arquivo de teste | Encontre os testes de um módulo |

**Estatísticas atuais:** ${stats.fileCount} arquivos · ${stats.symbolCount} símbolos · ${stats.todoCount} TODOs

**Workflow recomendado:**
1. \`repo_map.json\` → identifique arquivos relevantes pelo tamanho e contagem de símbolos
2. \`symbols.json\` → localize a função/classe pelo nome (use \`byName\`)
3. Leia o arquivo real só se precisar de contexto completo

> Gerado por \`workspace generate\`. Atualize com \`npx workspace generate --force\` ou \`bunx workspace generate --force\`.
`;
}

// ─── Injeta/atualiza seção em CLAUDE.md / AGENTS.md ──────────────────────────

const SECTION_MARKER_START = "## Workspace Index";
const SECTION_MARKER_END_RE = /^## /m; // próximo h2 indica fim da seção

function upsertSection(filePath, section) {
  let existing = "";
  if (existsSync(filePath)) {
    existing = readFileSync(filePath, "utf8");
  }

  const startIdx = existing.indexOf(SECTION_MARKER_START);
  if (startIdx === -1) {
    // Seção não existe — adiciona no final
    const separator = existing.length > 0 && !existing.endsWith("\n\n") ? "\n\n" : "";
    writeFileSync(filePath, existing + separator + section, "utf8");
  } else {
    // Seção existe — substitui do início até o próximo h2 (ou fim do arquivo)
    const afterStart = existing.slice(startIdx + SECTION_MARKER_START.length);
    const nextH2 = afterStart.search(SECTION_MARKER_END_RE);
    const endIdx = nextH2 === -1 ? existing.length : startIdx + SECTION_MARKER_START.length + nextH2;
    const updated = existing.slice(0, startIdx) + section + existing.slice(endIdx);
    writeFileSync(filePath, updated, "utf8");
  }
}

function writeAgentInstructions(targetDir, quiet) {
  const stats = readWorkspaceStats(targetDir);
  const section = buildWorkspaceSection(stats);

  const targets = ["CLAUDE.md", "AGENTS.md"];
  for (const name of targets) {
    const filePath = path.join(targetDir, name);
    // Só cria AGENTS.md se já existir; CLAUDE.md sempre cria/atualiza
    if (name === "AGENTS.md" && !existsSync(filePath)) continue;
    upsertSection(filePath, section);
    if (!quiet) console.log(`  updated  ${name}`);
  }

  // Cria CLAUDE.md se não existia nenhum dos dois
  const claudePath = path.join(targetDir, "CLAUDE.md");
  if (!existsSync(claudePath)) {
    upsertSection(claudePath, section);
    if (!quiet) console.log(`  created  CLAUDE.md`);
  }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

function main() {
  const argv = process.argv.slice(2);
  let force   = false;
  let quiet   = false;
  let noInject = false;
  let repoRoot = null;

  for (const arg of argv) {
    if (arg === "--force")     force = true;
    else if (arg === "--quiet")    quiet = true;
    else if (arg === "--no-inject") noInject = true;
    else if (arg === "generate")   continue; // subcomando
    else if (!arg.startsWith("--")) repoRoot = arg;
  }

  const targetDir = repoRoot ? path.resolve(process.cwd(), repoRoot) : process.cwd();

  const exitCode = runIndexer(targetDir, { force, quiet });

  if (exitCode === 0 && !noInject) {
    writeAgentInstructions(targetDir, quiet);
  }

  process.exitCode = exitCode;
}

main();
