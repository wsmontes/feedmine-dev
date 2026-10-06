### 1. Bloco `Compatibility with existing decisions`

ARQUIVO: docs/runtime-v2/adrs/ADR-003.md
ANCORA: ### Compatibility with existing decisions
NOVO: substituir integralmente essa subseção, até imediatamente antes da próxima heading de mesmo nível, por:

### Compatibility with existing decisions

- **D2 — remains valid as amended by D20–D21.** Catalog identity and runtime identity remain distinct types and no cast, widening, URL digest or other derivation can translate between them. An existing `legacy_source_map` row remains authoritative; D20 adds only the controlled policy for establishing a missing persisted mapping from a valid durable `EditorialSourceKey`, and D21 defines the allocator, transaction and conflict behavior for that establishment.

- **D4 — remains valid without further change.** `EditorialSourceKey(catalogIdentity, canonicalizationVersion)` remains the durable key separate from the local row ID; D22–D23 define ownership of the canonicalization version and the rules for continuity across versions.

- **D18 — remains valid without further change.** Catalog Sources still cross the legacy/runtime boundary exclusively through `legacy_source_map`; D20–D21 define how an absent row may be established and do not introduce a parallel identity path.

- **D1 — remains valid without further change.** A Source established through D20–D21 remains FeedMine-owned and receives an opaque runtime ID allocated by `RuntimeSourceRegistry`.

- **D3 — remains valid without further change.** Runtime Source IDs remain positive checked local row IDs; neither the resolver nor catalog identity chooses the integer value.

- **D12 — remains valid without further change.** D12 continues to govern ambiguous external-identity aliases. D21 independently requires a divergent `legacy_source_map` proposal to be refused and its durable conflict evidence to survive rollback; it does not change alias semantics.

MOTIVO: o ADR aplicado não deve conter instruções para substituir uma versão antiga do próprio D2; esta subseção passa a documentar somente a compatibilidade do estado normativo já composto.

---

### 2. Heading duplicada dos acceptance tests

ARQUIVO: docs/runtime-v2/adrs/ADR-003.md
ANCORA: ### Named acceptance tests
NOVO: ### D20–D23 acceptance tests
MOTIVO: a emenda é inserida dentro da seção `## Named acceptance tests`; qualificar a subseção evita uma heading duplicada semanticamente.

NOTA: esta substituição deve ser aplicada somente à heading introduzida pela emenda D20–D23, não a qualquer heading homônima preexistente fora desse bloco.

---

### 3. Traceability D20–D23

As invariantes novas **não devem ser renumeradas 21–30** se o texto inserido continua nomeando-as `INV-M1`…`INV-M10`. As células devem usar os identificadores que realmente existem no ADR.

Substituir as quatro linhas da emenda por:

| Blueprint/plan row | ADR decision id | Invariant ids | PR that must produce the evidence | Status |
|---|---|---|---|---|
| amendment D20–D23 | D20 | 8, 11, INV-M1, INV-M2, INV-M5, INV-M10 | PR-01 | proposed |
| amendment D20–D23 | D21 | 7, 8, 11, INV-M2, INV-M3, INV-M4, INV-M5 | PR-01 | proposed |
| Plan §5.1 (`SourceID` runtime is allocated/persisted; persist catalog identity + canonicalization version → runtime source) + amendment D20–D23 | D22 | 7, 11, INV-M6, INV-M7 | PR-01 | proposed |
| Plan §5.1 (catalog rebuild reapplies mappings; no reallocation by row order) + amendment D20–D23 | D23 | 5, 11, INV-M5, INV-M7, INV-M8, INV-M9, INV-M10 | PR-01 | proposed |

MOTIVO: o ADR possui invariantes numeradas `1`–`20` e a emenda possui identificadores distintos `INV-M1`–`INV-M10`; apresentar `21`–`30` inventa ids que não existem. Segundo o backlog definido para a migração, **PR-01 — Source bridge** é o slice que deve implementar e produzir evidência para D20–D23 após o freeze; o status permanece `proposed` enquanto essa evidência não existe.

ARQUIVO: docs/runtime-v2/adrs/ADR-003.md
ANCORA: | Blueprint §112 (ADR-003 scope list) | D1–D23 | 1–30 | PR-01, PR-02, PR-03 | proposed |
NOVO: | Blueprint §112 (ADR-003 scope list) | D1–D23 | 1–20, INV-M1–INV-M10 | PR-01, PR-02, PR-03 | proposed |
MOTIVO: corrige a mesma inconsistência na linha agregada de escopo sem renumerar nenhum invariante já existente.

---

### 4. Anexo §1.9 — teste deixou de ser indeterminado

ARQUIVO: docs/runtime-v2/adrs/ADR-003.md
ANCORA: Nome exato: [INDETERMINADO — requer leitura de Packages/FeedRuntimeV2/Tests/FeedStorageTests/]
NOVO: Nome exato normativo: `missingLegacySourceMappingAllocatesAndPersistsExactlyOnce`, em `Packages/FeedRuntimeV2/Tests/FeedStorageTests/LegacySourceIdentityResolutionTests.swift` (`criar`).
MOTIVO: o corpo da emenda já nomeia o acceptance test de D20–D21; o anexo não pode continuar declarando seu nome como indeterminado.

NOTA: esse nome é **especificação de acceptance test futuro**, não alegação de que o arquivo/teste já existe no checkout.

---

### 5. Anexo §1.9 — `ensureRuntimeSourceIdentity`

ARQUIVO: docs/runtime-v2/adrs/ADR-003.md
ANCORA: [NAO FORNECIDA]
NOVO: substituir `ensureRuntimeSourceIdentity` pela expressão normativa `D20–D21 legacy Source resolution`, ou, se a linha exigir um callable concreto, por `LegacySourceIdentityResolver` conforme D20–D21.
MOTIVO: `ensureRuntimeSourceIdentity` não é termo definido pelo corpo normativo; o anexo deve referenciar a decisão/resolver que o ADR efetivamente define.

NOTA: para produzir uma substituição mecânica segura, envie a **linha integral do §1.9 que contém `ensureRuntimeSourceIdentity`**. Sem essa transcrição não é possível fornecer uma âncora literal única sem inventá-la.