# codebase-index

Indexador de codebase que gera `.workspace/*.json` (metadados, símbolos, chunks, import graph, etc.). Inclui uma implementação em **Zig** (rápida) invocável via npm.

## Uso a partir de um projeto (ex.: React + Vite)

Requisitos: **Node.js ≥18** e **Zig** instalado (para compilar o binário).

### 1. Instalar como dependência

No teu projeto (ex.: app React + Vite):

```bash
npm install --save-dev codebase-index
# ou, se estiveres a desenvolver localmente:
npm install --save-dev file:../caminho/para/codebase-index
```

### 2. Gerar o workspace

No diretório do teu projeto (onde queres que apareça a pasta `.workspace`):

```bash
npx workspace generate
```

Isto executa o binário Zig, compila se necessário (`zig build` em `zig-workspace/`) e gera `.workspace/` **no diretório atual** (o mesmo onde corriste o comando).

Opções:

- **`workspace generate`** — gera `.workspace` no cwd
- **`workspace generate --force`** — reindexa tudo (ignora cache)
- **`workspace generate --quiet`** — menos log

### 3. Script no `package.json` do teu projeto

Para poderes correr `npm run workspace:generate` (ou `generate`) no teu projeto React/Vite:

```json
{
  "scripts": {
    "generate": "workspace generate",
    "workspace:generate": "workspace generate"
  }
}
```

Exemplo:

```bash
cd meu-projeto-react
npm run workspace:generate
# → gera .workspace/ na raiz do meu-projeto-react
```

## Estrutura do repositório

- **`zig-workspace/`** — indexador em Zig; `zig build run -- <repo_root> [--force] [--quiet]`
- **`bin/workspace.mjs`** — CLI que invoca o Zig no cwd (usado por `workspace generate`)
- **`type-workspace/`** — implementação alternativa em TypeScript/Bun

## Notas

- O comando `workspace generate` usa sempre o **diretório atual** como raiz do repositório, por isso deves invocá-lo a partir da raiz do teu projeto (ex.: `cd meu-app && npx workspace generate`).
- Na primeira execução (ou após atualizar o Zig), `zig build` pode demorar um pouco; as seguintes são mais rápidas.
