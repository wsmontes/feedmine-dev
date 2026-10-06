# `_apply/` — aplicação da emenda e do anexo ao ADR-003

**Nada aqui foi aplicado ao repositório.** Este diretório existe para que a sua decisão vire um comando, com verificação e rollback.

## O que o script faz

`apply-adr003.sh` opera em três estágios, nesta ordem, sobre `docs/runtime-v2/adrs/ADR-003.md`:

**1. Substituições pontuais** (de `21-edicoes-no-adr003.md`, materializadas em `substitutions.tsv` — 3 linhas):

|Âncora (texto que existe hoje)|Por quê|
|---|---|
|frase do D2 "…which fails when no mapping exists…"|o lookup deixa de ser o único caminho quando existe `EditorialSourceKey` durável válida (D20)|
|bullet de edge case "Canonicalization version bump: … a new `source` row is created"|consistência com D23 (sem declaração, nenhum mapping automático)|
|linha da tabela de escopo `| D1–D19 | 1–20 |`|passa a `D1–D23`|

**2. Inserções da emenda** (`18-emenda-adr003.md`):

|Bloco|Destino|
|---|---|
|D20–D23|antes de `## Rejected alternatives`|
|`### Compatibility with existing decisions`|antes de `## Rejected alternatives`|
|`### What this amendment does not authorize`|antes de `## Rejected alternatives`|
|`### Invariants added or preserved by D20–D23`|antes de `## Edge cases` (fim de `## Invariants`)|
|`### Named acceptance tests` → renomeado para `### D20–D23 acceptance tests`|antes de `## Traceability` (fim de `## Named acceptance tests`)|
|4 linhas de rastreabilidade de D20–D23 (`traceability-rows.md`)|logo após a linha de escopo `| D1–D23 |`|

**3. Anexo** (`07b-anexo-corrigido.md` inteiro): fim do arquivo, como seção nomeada.

`--simple` insere a emenda inteira num único ponto, se você preferir revisar tudo de uma vez.

## Garantias

- **Dry-run por padrão.** Sem `--apply`, o script só valida e imprime o plano — não escreve.
- **Âncoras verificadas antes de escrever:** `## Rejected alternatives`, `## Edge cases`, `## Traceability` têm de aparecer exatamente uma vez; `D19` tem de existir; `D20` **não** pode existir (evita aplicar duas vezes).
- **Backup automático** em `_apply/backup/ADR-003.md.<timestamp>` antes de qualquer escrita.
- **Pós-condições:** se `D20`, `D19` ou o anexo não estiverem no resultado, o script falha e **não** substitui o arquivo.
- **Testado ponta a ponta (após as correções de composição):** `ADR_PATH=/tmp/ADR-copy3.md ./apply-adr003.sh --apply` → 45 001 → **74 185 bytes**, 454 → 822 linhas; D19–D23 presentes; `##` originais presentes exatamente uma vez cada (inclusive `## Named acceptance tests`, agora com a subseção qualificada `### D20–D23 acceptance tests`); 4 linhas de rastreabilidade inseridas; `D1–D23` aplicado; o bulleto de edge case conflitante ausente; `ensureRuntimeSourceIdentity` ausente (substituído por `LegacySourceIdentityResolver`); `Replace the existing sentence` ausente; ADR real intocado (45 001 bytes, sem D20).

## Como usar

```bash
cd docs/runtime-v2/chatgpt-overnight/_apply
./apply-adr003.sh                                   # confere o plano
ADR_PATH=/tmp/ADR-copy.md ./apply-adr003.sh --apply  # ensaia numa cópia, se quiser ver o resultado
./apply-adr003.sh --apply                            # aplica no ADR de verdade
git -C ../../../.. diff -- docs/runtime-v2/adrs/ADR-003.md
```

Rollback: `cp _apply/backup/ADR-003.md.<timestamp> docs/runtime-v2/adrs/ADR-003.md`.

## O que o script NÃO faz

- Não muda a linha de `**Status:**` do ADR (o freeze é decisão sua).
- Não cria as linhas de rastreabilidade (`## Traceability`) para D20–D23 — a tabela associa cada D a uma linha do plano e a um PR; isso exige a decisão do Gate 0.
- Não cria os arquivos de teste nomeados na emenda.
- Não commita nada.
