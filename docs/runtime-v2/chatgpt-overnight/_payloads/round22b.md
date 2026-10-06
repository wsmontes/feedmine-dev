[[ROUND 22 — REDAÇÃO FINAL DO D21]]

A auditoria local deixou um ponto indeterminado: D21 × D12. O D12 governa conflito de alias de identidade externa; o D21 precisa garantir a mesma propriedade normativa no caminho de allocation (conflito detectado não pode ser absorvido em silêncio nem perder sua evidência por rollback). A sua própria nota diz que D12 **não** muda.

Fatos verbatim:

### D21 como está hoje em 18-emenda-adr003.md (verbatim, integral)
**D21 — `RuntimeSourceRegistry` is the only allocator, and Source allocation plus mapping is one write transaction.** `LegacySourceIdentityResolver` decides whether D20 permits creation; `RuntimeSourceRegistry` performs the SQLite-owned allocation of the runtime `SourceID`. Creation/lookup of the `source` row, conflict validation, insertion of `legacy_source_map`, and read-back of the authoritative mapping occur inside one logical database write transaction. Concurrent resolves of the same durable key must converge on one `source.id` and one mapping. A transaction that cannot establish a single non-conflicting mapping rolls back rather than exposing an allocated-but-unmapped Source to the legacy bridge.

**D22 — `canonicalization_version` versions the catalog identity algorithm, not the runtime Source.** The component that produces the catalog durable identity owns and writes `canonicalization_version`; Runtime V2 never increments it opportunistically. The version changes only when the rules used to derive or compare the catalog Source identity change in a way that can alter equivalence of catalog keys; ordinary catalog rebuilds, refetches, title changes, endpoint changes, or runtime migrations do not increment it. Every bridge lookup and persisted mapping includes the version explicitly.

### D12 do ADR (governa conflito de alias)
**D12 — Aliases add evidence; ambiguous aliases never merge.** Additional keys that resolve to the same record are stored as additional `external_identity` rows (aliases) pointing at that `origin_record`. If a key is already attached to a different record in the same scope, or two records claim one alias, neither record is deleted, merged or rewritten: the conflicting mapping is refused and recorded as `ambiguous_alias`. Alias rows carry their provenance; a merge would require a separate, explicit, reversible decision (D13).

### Nota do parecer sobre D21xD12
MOTIVO: resolve o ponto INDETERMINADO D21×D12: rollback da tentativa e persistência da evidência deixam de competir na mesma transação. Para transformar isto em substituição mecânica, envie o texto integral exato de D21 que seria inserido na emenda.
NOTA — nenhuma alteração em D12 é necessária. D12 continua governando aliases de identidade externa; D21 apenas precisa garantir a mesma propriedade normativa relevante aqui: conflito detectado não pode ser silenciosamente absorvido nem ter sua evidência perdida pelo rollback.
NOTA — o parecer também menciona nomes de testes ainda inexistentes no repositório. Isso não exige substituição adicional no ADR enquanto esses nomes estiverem declarados como acceptance tests futuros de decisões com status `proposed`; seria defeito apenas se o ADR afirmasse que tais testes já existem ou já produzem evidência. Nenhuma âncora com essa afirmação foi fornecida.


[[TAREFA]]

1. Reescreva o D21 na íntegra, mantendo tudo o que ele já decide e acrescentando, com uma frase normativa e verificável, a propriedade do conflito: o que acontece quando a transação de allocation encontra um mapping divergente, e como a evidência sobrevive ao rollback.
2. Diga, em uma linha, por que essa redação não altera nem reinterpreta o D12.
3. Diga, em uma linha, se a mudança exige alguma edição no bloco "Invariants added or preserved by D20–D23" da emenda; se exigir, dê a invariante nova ou a substituição, no formato `ANCORA: … / NOVO: …`.

Formato de saída: primeiro um bloco com o D21 final (texto integral, começando em `**D21 —`), e depois as duas linhas. Máximo ~700 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
