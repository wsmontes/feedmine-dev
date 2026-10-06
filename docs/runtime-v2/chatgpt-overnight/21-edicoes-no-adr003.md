ARQUIVO: docs/runtime-v2/adrs/ADR-003.md
ANCORA: The only translation is a persisted lookup in `legacy_source_map` (D18), which fails when no mapping exists.
NOVO: The only translation is through a persisted row in `legacy_source_map` (D18). An existing row is authoritative and is returned by lookup. When no row exists, D20–D21 may establish one only from a valid durable `EditorialSourceKey` and only when the mapping can be established without ambiguity. Resolution fails when no valid durable key is available, when continuity or distinctness required by D23 has not been declared, or when a non-conflicting durable mapping cannot be established; no caller may derive, cast or synthesize a runtime `SourceID` as a fallback.
MOTIVO: remove o conflito D2×D20 sem enfraquecer a proibição de conversão/derivação; lookup continua sendo o caminho para mappings existentes e D20–D21 passam a governar exclusivamente o caso ausente.

ARQUIVO: docs/runtime-v2/adrs/ADR-003.md
ANCORA: - Canonicalization version bump: the same URL can yield a different `editorial_key` under a new version. Continuity must be declared in `legacy_source_map`; without a declaration, a new `source` row is created and the divergence is recorded, never merged by URL similarity.
NOVO: - Canonicalization version bump: the same URL can yield a different `editorial_key` under a new version. A version bump alone creates neither a mapping nor a `source`. Before a mapping for the new version is established, the catalog/bridge policy must explicitly declare either continuity with exactly one existing runtime source or intentional distinctness. Declared continuity creates a new-version `legacy_source_map` row pointing to that existing source; declared distinctness may allocate a new source through D20–D21. Without either declaration, resolution is refused and the divergence is recorded; URL similarity never establishes continuity or distinctness.
MOTIVO: elimina o conflito com D23 e impede que um bump de canonicalization seja, sozinho, autorização implícita para criar uma Source.

ARQUIVO: docs/runtime-v2/adrs/ADR-003.md
ANCORA: | Blueprint §112 (ADR-003 scope list) | D1–D19 | 1–20 | PR-02, PR-03 | proposed |
NOVO: | Blueprint §112 (ADR-003 scope list) | D1–D23 | 1–30 | PR-01, PR-02, PR-03 | proposed |
MOTIVO: a linha de escopo precisa incluir D20–D23, os novos invariantes 21–30 e o PR-01, responsável pela evidência de implementação da emenda.

NOTA — REESCREVER D23 ANTES DE INSERI-LA

A correção do edge case acima deve ser refletida na própria decisão D23; editar somente o bullet deixaria espaço para duas leituras normativas.

NOVA REDAÇÃO INTEGRAL:

**D23 — Canonicalization-version history is immutable and continuity or distinctness is explicit.** A row in `legacy_source_map` for an older `(catalog_source_key, canonicalization_version)` is retained and never rewritten to represent a newer canonicalization version. Exact resolution uses the requested version, and older-version rows may be consulted only as evidence. A canonicalization-version change by itself authorizes neither reuse of an existing runtime Source nor allocation of a new one. Before establishing the mapping for the new version, the catalog/bridge policy must explicitly declare either continuity with exactly one existing runtime Source or intentional distinctness. Declared continuity creates a new-version mapping to that Source without rewriting prior rows; declared distinctness permits D20–D21 to allocate and map a new Source. If the declaration is absent, ambiguous, or would require URL similarity or other inferred equivalence, resolution is refused, the conflict/divergence is recorded, and no automatic mapping or Source is created.

MOTIVO: torna explícita a mesma regra aplicada ao edge case e impede que D20 seja interpretado como autorização genérica para alocar após qualquer version bump.

NOTA — D21 PRECISA ESPECIFICAR A SOBREVIVÊNCIA DA EVIDÊNCIA DE CONFLITO

ARQUIVO: docs/runtime-v2/adrs/ADR-003.md
ANCORA: [NAO FORNECIDA]
NOVO: **D21 — `RuntimeSourceRegistry` is the only allocator, and Source allocation plus mapping is one write transaction.** `LegacySourceIdentityResolver` decides whether D20 permits creation; `RuntimeSourceRegistry` performs the SQLite-owned allocation of the runtime `SourceID`. Creation or lookup of the `source` row, validation of the proposed mapping, insertion of `legacy_source_map`, and read-back of the authoritative mapping occur inside one logical database write transaction. Concurrent resolves of the same durable key must converge on one `source.id` and one mapping. If validation discovers a divergent or ambiguous existing mapping, the allocation/mapping transaction rolls back completely; durable conflict evidence is then recorded in a separate successful write so that recording the conflict is not itself lost with the rollback. The conflicting mapping is never installed or re-pointed.
MOTIVO: resolve o ponto INDETERMINADO D21×D12: rollback da tentativa e persistência da evidência deixam de competir na mesma transação. Para transformar isto em substituição mecânica, envie o texto integral exato de D21 que seria inserido na emenda.

NOTA — nenhuma alteração em D12 é necessária. D12 continua governando aliases de identidade externa; D21 apenas precisa garantir a mesma propriedade normativa relevante aqui: conflito detectado não pode ser silenciosamente absorvido nem ter sua evidência perdida pelo rollback.

NOTA — o parecer também menciona nomes de testes ainda inexistentes no repositório. Isso não exige substituição adicional no ADR enquanto esses nomes estiverem declarados como acceptance tests futuros de decisões com status `proposed`; seria defeito apenas se o ADR afirmasse que tais testes já existem ou já produzem evidência. Nenhuma âncora com essa afirmação foi fornecida.