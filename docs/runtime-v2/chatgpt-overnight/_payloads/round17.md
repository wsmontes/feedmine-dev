[[ROUND 17 — QUANTO DO SEU PLANO JÁ ESTÁ DECIDIDO PELO ADR-003]]

O ADR-003 já é normativo no repositório e contém decisões D1..D19. Você produziu um plano de migração com decisões M1..M8. Antes de qualquer trabalho de implementação, preciso saber o que é novo.

### Decisões já normativas no ADR-003 (D1..D19, do arquivo real)
D1 — Source is the editorial unit, and its ID is FeedMine-owned.
D2 — The catalog ID is a different type, aliased, never converted.
D3 — Local row IDs are positive `Int64` with a checked encoding.
D4 — Durable editorial key is separate from the local row ID.
D5 — Source, Provider, Binding, Target are four distinct things.
D6 — Endpoint is an attribute of a binding, not of a Source.
D7 — Target identity never becomes editorial identity.
D8 — External keys are opaque, scoped, and compared in full.
D9 — `ExternalVersionKey` is not globally ordered.
D10 — An RSS/Atom GUID is not a URL.
D11 — Version collisions are auditable conflicts, never overwrites.
D12 — Aliases add evidence; ambiguous aliases never merge.
D13 — Equivalence is a relation, not a merge.
D14 — Only promoted relations are canonical.
D15 — Membership and target observation are different relations.
D16 — Missing external identity falls back to a versioned, low-confidence key.
D17 — Timestamp epistemology is preserved.
D18 — Legacy bridges are the only legacy identity path.
D19 — No array index and no batch ordinal is an identity.

### Decisões M1..M8 do plano do worker
28:## M1 — FeedSource / SourceID
60:M2 — FeedItem / OriginRecord / OriginRevision
74:M3 — CatalogIdentity
83:M4 — Persistence e migrations
110:M5 — Referências duráveis do usuário
126:M6 — Identidade de apresentação
139:M7 — Fronteira RSS
151:M8 — Compatibilidade de release


[[TAREFA]]

1. MAPA M → D — para cada M1..M8: a decisão correspondente que já existe no ADR-003 (número exato da decisão), ou NOVO se o ADR não decide aquilo, ou CONFLITO se o ADR decide o contrário. Uma linha por M, com o motivo apoiado no título da decisão.
2. O QUE SOBRA DE NOVO — a lista apenas dos itens NOVO e CONFLITO, cada um com o que ele exige que o ADR ainda não autoriza.
3. CONFLITOS — para cada CONFLITO: qual leitura do ADR sustenta a decisão existente, e o que a sua proposta mudaria. Se houver conflito real, ele é BLOQUEADOR de Gate 0.
4. VEREDITO — em uma linha: a migração proposta é (a) implementação de decisões já tomadas, (b) decisão nova que precisa de ADR novo, ou (c) híbrido — e no caso (b)/(c) qual seria o objeto mínimo do ADR que falta.

Não invente títulos de decisão: os que você tem estão nos fatos. Se não tiver certeza de um mapeamento, escreva INDETERMINADO e diga qual texto do ADR eu preciso te mandar.

Formato: markdown, máximo ~1500 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
