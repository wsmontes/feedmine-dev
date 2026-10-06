[[ROUND 4 — REVISÃO ADVERSARIAL DOS SETE ADRs CONTRA O CHECKOUT REAL]]

Você recebeu D1–D4 (working tree, 2026-10-05, HEAD 70f7b06b) e produziu o plano de migração e a decisão de identidade do Source.
O repositório JÁ CONTÉM os sete ADRs, escritos e com status "Proposed — freeze pending sign-off (Gate 0 not complete)": docs/runtime-v2/adrs/ADR-001..007.md (31–45 KB cada). Eles já estão referenciados como autoridade por docs/runtime-v2/baseline.md e rollout.md.

Fatos novos:

=== ADR-001.md ===
D1 — The published log is append-only and single-writer.
D2 — Occurrence identity is `PublicationCardID`.
D3 — Append requires a token, single-flight, and a tail CAS.
D4 — Publication freezes the payload.
D5 — The payload is self-sufficient.
D6 — Precedence of validity.
D7 — A successor Edition replaces history explicitly.
D8 — Removal is three distinct operations, never a cascade.
D9 — `PublicationSchemaVersion` is independent.
D10 — Media preparation happens before the commit, never inside it.
D11 — Minimal local asset commit.
D12 — Asset identity is digest + recipe, not URL.
D13 — Byte retention is pinned by publication references.
D14 — After deliberate byte removal, only identity, layout and fallback are guaranteed.
D15 — `RenderContract` and render environment.
D16 — Actions are frozen handles, not protocol branches.
D17 — Anchors are ordinal-based.

=== ADR-002.md ===
D1 — `ContextKey` is the identity of an intent, not a fingerprint of inputs.
D3 — Canonical serialization rules (normative).
D4 — Canonical field order and the exclusion list.
D5 — Fingerprint versioning rule.
D6 — Relevance qualifiers: catalog generations and user-state revisions are separate authorities.
D7 — `RenderEnvironmentRevision` changes materialisation, never editorial history.
D8 — Warm restore validity: supported schema + intact payload + compatible context; no network.
D9 — Edition replacement is explicit; passive changes never swap the visible edition.
D10 — Clock rules.
D11 — Draft starvation rule.
D12 — `ContextKey` and `EditorialRevision` are session-visible, not UI-visible.

=== ADR-003.md ===
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

=== ADR-004.md ===
D1 — Authority per database.
D2 — One canonical database name.
D3 — Explicit backup and file-protection policy.
D4 — Pool, WAL, foreign keys, single logical writer, migrator authority.
D5 — `origin_revision` is append-only.
D6 — Cross-database user actions follow intents → projection → applied marker.
D7 — Durable aliases and a minimal bookmark snapshot.
D8 — Retention classes, quotas, GC.
D9 — Recovery paths, never a silent empty database.
D10 — Asset reference consistency.
D11 — Migration testing matrix, and the ban on erase-on-schema-change.
D12 — Compatibility window and rollback proof.

=== ADR-005.md ===
D1 — Connector boundary is DTO-only and evidence-opaque.
D2 — One connector surface for finite, streaming and backfill+live.
D3 — Backpressure is real, not a buffer policy.
D4 — Bounded batch and stream shape.
D5 — Targets are operational work, not editorial identity (row #5).
D6 — Sharing is by leases and refcounts (row #6).
D7 — Frontier is finite and classified by work, not by URL (row #35).
D8 — Bootstrap is finite and terminates (row #37, §20.3).
D9 — Purpose budgets are explicit and per purpose (row #36, §20.3).
D10 — Endpoints, bindings and generations.
D11 — Checkpoints are opaque, versioned and connector-owned (row #28).
D12 — HTTP validator semantics.
D13 — Backoff, jitter, host fairness and Retry-After.
D14 — Hard request limits and credential hygiene.
D15 — Result taxonomy: connector failure vs Admission outcome.
D16 — Partial errors and all-or-nothing pages.
D17 — Media speculation is not acquisition.
D18 — Measurement is separated and network health is not editorial quality.
D19 — Read-only/ingestion stance (row #39).
D20 — Parser isolation without general escape hatches.

=== ADR-006.md ===
D1 — Every canonical write is guarded by a `TargetStamp` validated inside the write transaction.
D2 — Admission batch identity is `batchID` + fingerprint, with defined replay semantics.
D3 — Precedence reaches the core only as closed instructions.
D4 — Three orders stay separate.
D5 — Checkpoint advances by CAS and never outside the admitting transaction.
D6 — `SupplyGeneration` increments at most once per transaction and only when relevant supply changed.
D7 — All-or-nothing is the default for page checkpoints, with a bounded alternative.
D8 — No suspension, network, parse, decode or foreign callback inside the write transaction.
D9 — Cancellation saves work; commit validation provides safety.
D10 — Reentrancy and retries.
D11 — `RuntimeWriteCoordinator` admits only non-critical writes.
D12 — Failures are typed and each type has a fixed effect on canonical state and checkpoint.
D13 — Stale work leaves no canonical residue.
D14 — Append serialization belongs to `PublicationCoordinator`.

=== ADR-007.md ===
D1 — An exposure interval is a continuous foreground dwell of at least 50% of the card's area for at least 1000 ms.
D2 — Viewport observations are coalesced UI telemetry, not a queue.
D3 — Exposure continuity is anchored to `PublicationCardID`, not to the SwiftUI view, and a rerender is not part of the interval's life.
D4 — Window eviction and restoration have one defined rule.
D5 — Every fact type is recorded separately and none is inferred from another.
D6 — Opening or actioning a card never blocks navigation on a history write.
D7 — Every fact type has one explicit idempotency key, and one row is authoritative.
D8 — Revisits are bounded, ordered and do not make `seen` non-idempotent.
D9 — Facts are persisted at milestones and by debounce, never per frame.
D10 — History is bounded, and the bound never touches the projection that policy reads.
D11 — Stale work cannot attach to history.
D12 — `HistoryScope` is explicit per surface, owned and versioned, and Main's discovery exclusion is not global.
D13 — Exhaustion and degradation are states, not history mutations.
D14 — Deletion and tombstones project into history, and never rewrite it.
D15 — Monotonic time is scoped to a boot session.



### Status dos sete arquivos (todos iguais)
**Status:** Proposed — freeze pending sign-off (Gate 0 not complete).


[[TAREFA]]

Faça a revisão adversarial dos sete ADRs contra os fatos do checkout. Não reescreva os ADRs. Produza uma lista de defeitos acionável.

Para cada defeito: ID (R1..Rn), ADR e decisão (D-n) afetada, a AFIRMAÇÃO do ADR (citada), o FATO do checkout que a contradiz ou confirma (path:line), a severidade (BLOQUEADOR / CORREÇÃO / NOTA) e a correção mínima.

Regras:
- Só defeito com evidência nos fatos fornecidos. Sem opinião estética.
- Separe explicitamente: (a) contradições verificáveis, (b) afirmações não verificáveis com os fatos disponíveis, (c) nomes de teste/arquivo citados pelos ADRs que podem estar desatualizados.
- Termine com um veredito por ADR: PODE CONGELAR / NÃO PODE (com o motivo em uma linha).

Formato: markdown, máximo ~3000 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document; sem resumo.
