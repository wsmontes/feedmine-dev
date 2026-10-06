[[ROUND 20 — LINHAS DE RASTREABILIDADE PARA D20–D23]]

A emenda que você escreveu (D20–D23) vai entrar no ADR-003, mas a tabela `## Traceability` do ADR associa cada decisão a uma linha do plano, a ids de invariante e ao PR que produz a evidência. Sem essas linhas, a emenda fica órfã.

Fatos do arquivo real:

### Formato da tabela de Traceability (cabeçalho + 3 linhas reais)
## Traceability

| Blueprint/plan row | ADR decision id | Invariant ids | PR that must produce the evidence | Status |
|---|---|---|---|---|
| Plan §19 #1 (Blueprint §122) | D1, D5 | 1, 7 | PR-02 | proposed |
| Plan §19 #2 | D2, D3, D4, D6 | 7, 8, 11 | PR-02, PR-03 | proposed |
| Plan §19 #3 | D5 | 17 | PR-02, PR-05 | proposed |

### Últimas 3 linhas da tabela
| Plan §5.1 legacy mapping / rollback | D4, D18 | 11, 18 | PR-02, PR-04 | proposed |
| Blueprint §112 (ADR-003 scope list) | D1–D19 | 1–20 | PR-02, PR-03 | proposed |
| Blueprint §44 / plan §20.3 tombstones | D13, D15 | 15, 20 | PR-03, PR-16 | proposed |
| Blueprint §105 / plan §16 (renderer network = 0) | D7, D15 (identity rows carry no protocol payload) | 10, 16 | PR-03, PR-11 | proposed |

### Ids de invariante existentes no ADR-003
1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 

### Bloco de invariantes da emenda
### Invariants added or preserved by D20–D23

- **INV-M1 — No derived translation.** D2 remains absolute: no `CatalogSourceID`, URL, digest, row order or widened integer can produce a `FeedDomain.SourceID`; D20 permits only creation of a persisted mapping through D21.
- **INV-M2 — Bridge before return.** A catalog Source is returned to legacy-facing/runtime bridge code as a runtime `SourceID` only after the corresponding `legacy_source_map` row is durably established.
- **INV-M3 — Single allocator.** Only `RuntimeSourceRegistry` allocates a runtime Source row; the resolver may authorize allocation but cannot manufacture the ID.
- **INV-M4 — Atomic first mapping.** The first successful allocation/mapping operation commits the Source and its bridge atomically; failure exposes neither a new mapping nor a bridge-visible orphan.
- **INV-M5 — Existing mappings are authoritative.** If an exact `(catalog_source_key, canonicalization_version)` mapping exists, resolution returns that mapping; it is never silently re-pointed.
- **INV-M6 — Canonicalization versions are positive and explicit.** D3 and the schema requirement `canonicalization_version > 0` continue to apply to every persisted version.
- **INV-M7 — Version change does not renumber Sources.** Incrementing `canonicalization_version` alone neither creates a new semantic Source nor authorizes reuse of an old one; continuity must be established explicitly under D23.
- **INV-M8 — Historical mappings are immutable evidence.** Creating a mapping for version `N+1` never updates or deletes the mapping for version `N`.
- **INV-M9 — Ambiguity never becomes merge.** D12 remains binding: ambiguous continuity is refusal/conflict evidence, never automatic Source merging.
- **INV-M10 — `legacy_source_map` remains the only catalog legacy bridge.** D18 is preserved; D20–D23 do not introduce a parallel catalog-to-runtime identity path.

### Compatibility with existing decisions

### Limites da emenda
### What this amendment does not authorize

- It does **not** authorize conversion, widening, hashing, URL-derived identity or any fallback from `CatalogSourceID`/catalog URL to `FeedDomain.SourceID`.
- It does **not** authorize re-pointing, deleting or rewriting existing `legacy_source_map` rows, nor automatic merging of Sources across canonicalization versions.
- It does **not** authorize a second generic legacy identity table, changes to `feed_item.id`, user-data rekeying, presentation cutover or release ownership changes; those remain outside this amendment.


[[TAREFA]]

1. LINHAS DA TABELA — escreva as linhas novas da tabela `## Traceability` para D20, D21, D22 e D23, no formato exato das existentes (colunas: Blueprint/plan row | ADR decision id | Invariant ids | PR that must produce the evidence | Status). Para "Blueprint/plan row", aponte a linha do plano que originou cada decisão; se a decisão for nova (não rastreada ao plano), escreva `amendment D20–D23` e diga isso explicitamente.
2. IDS DE INVARIANTE — para cada linha, os ids que a decisão faz cumprir: os preexistentes que ela preserva **e** as invariantes novas que a emenda acrescenta (numere-as continuando a sequência existente, e dê o texto de cada invariante nova em uma linha).
3. PR — o PR que deve produzir a evidência de cada decisão, usando a numeração do backlog (`PR-00`…`PR-09`) que você já produziu; se a evidência só existir depois do freeze, diga qual PR é o responsável.
4. STATUS — o valor de Status que essas linhas devem ter hoje, coerente com o fato de que o ADR continua `Proposed` e nenhuma implementação existe ainda.
5. Se algo depender de decisão humana, escreva `PARADA: HUMANO — <a pergunta>` na célula em vez de inventar.

Formato: markdown, máximo ~900 palavras. Só as linhas e as explicações mínimas.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
