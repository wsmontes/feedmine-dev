[[ROUND 5 — CHECKLIST DE GATE 0 (FREEZE DOS SETE ADRs)]]

Fatos novos:

### Indice de decisoes dos sete ADRs
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


### baseline.md — estado de verificacao (amostra)
5:**Status: proposed material.** The ADR decisions referenced here are proposals awaiting the Gate 0 sign-off; this document records measured facts and the defects found at the base commit, not approved architecture. Per plan §1 the ADR freeze and the implementation of the migration are approved ou
428:- **No assertion that admission is still happening.** `nextCheckpoint: nil` (`:596`) means the shadow's checkpoint never advances and every batch expects revision 0 and admits. Fine until something moves it: a durable checkpoint that advanced would make every later batch `staleCheckpoint`, count
443:1. **Counters were silently dropped.** A patch that rewrote the counters block lost the two per-interval `coverage[work.interval]?.items…` writes, so only the global totals moved while the per-interval record stayed at zero. The interval is the unit the shadow's report is read in, which is why
444:2. **A health signal fired on a healthy verdict.** The admission-stall rule counted `identityConflict` and `batchConflict` refusals as stalls. Those are the runtime doing its job — refusing to overwrite a divergent representation (ADR-003 D11) — and only `staleTarget`, `staleCheckpoint`, `in
548:With this, PR-13's gate line — *"Main Feed V2 offline e rollback de modo funcionam; aparência e ações verificadas"* — is satisfied by direct observation rather than by inference from a green suite.
628:§16 lists eight SLO measures and calls its numbers **initial targets, not results measured in this checkout**, then forbids the shortcut that usually follows: fix absolute memory/disk budgets only after a baseline on the minimum device, and until then measure and block unbounded growth **withou
1098:- the projection's `RuntimeSourceRegistry.editorialKey(for:in:)` (`SourceRegistry.swift:75-96`) is the better answer **regardless**: a projection holding a runtime `SourceID` wants the runtime's own identity row, while the bridge's `legacy_url` is the legacy *evidence* of the same mapping. Unch
1474:my own check is the regression half — the class runs **29 tests, 0 failures** after the guard. (2) **The stale-swiftmodule trap**, which
1477:targets compile with `-I` that directory — so a changed package source keeps compiling against the stale
1478:signature until the stale directory is deleted, reading as `tuple pattern has the wrong length` or
1539:   purged 0 local package module(s) that a changed source would have kept stale
1546:xcodebuild), the stale-module purge (0 this time, correctly, because the rebuild had refreshed them), both

### plano 2026-09-17 — linhas do §19 (amostra)
120:| 1 | ADR-003 Identity/Source/Provenance | namespaces, IDs locais versus duráveis, aliases, colisões, Source/Provider/Target distintos, conteúdo sem ID externo confiável |
121:| 2 | ADR-002 Context/Revision | quais mudanças invalidam seleção/publicação/render, clock editorial, preferências, revisões de catálogo e estado do usuário |
122:| 3 | ADR-001 Publication/Media | freeze do payload/layout/asset, overlays interativos, política de remoção, restauração e successor Edition |
123:| 4 | ADR-006 Concurrency/Admission | stamps, lease/generation, precedência, batch replay, checkpoint CAS, reentrância, retries e efeitos cancelados |
124:| 5 | ADR-004 Durability/Retention | autoridade por banco, referências de assets, recovery, quotas, bookmark snapshot, compatibilidade e rollback |
125:| 6 | ADR-007 Exposure/History | dwell, fração visível, seen/read/click, revisitas, idempotência e projeção de exclusão |
126:| 7 | ADR-005 Connectors/Acquisition | finite/streaming, backpressure, target sharing, endpoints, HTTP checkpoints, revalidação e erro parcial |
711:| 1 | Source é unidade editorial FeedMine; não endpoint | 003 | 02 | `sourceCanHaveMultipleBindings` |
712:| 2 | SourceID opaco, chave editorial durável e mapping persistido | 003 | 02–03 | `endpointChangePreservesSourceIdentity` |
713:| 3 | Provider representa atribuição/autoria; distinto de agrupamento Source | 003 | 02,05 | `oneSourceContainsMultipleProviders` |
714:| 4 | Binding liga Source a configuração externa versionada | 003,006 | 03 | `bindingChangeInvalidatesOldGeneration` |
715:| 5 | Target representa trabalho operacional, não identidade editorial | 005 | 10 | `targetIsIndependentOfSourceIdentity` |
716:| 6 | Targets compartilhados por configuração/escopo compatível e leases | 005 | 10 | `twoSourcesShareTargetWithoutDuplicateWork` |
717:| 7 | OriginRecord é objeto lógico namespaced aceito | 003 | 03 | `sameExternalKeyResolvesSameRecord` |
718:| 8 | OriginRevision é representação imutável aceita | 003,006 | 03 | `revisionPayloadCannotBeUpdated` |
719:| 9 | Object/version keys opacas separadas, sem revision counter universal | 003 | 02–03 | `versionKeyIsNotAssumedGloballyOrdered` |
720:| 10 | Aliases preservam escopo e evidência; merge não destrutivo | 003 | 02–03 | `ambiguousAliasDoesNotMergeOrigins` |
721:| 11 | Membership editorial e target/binding observado são relações distintas | 003 | 03 | `targetObservationDoesNotImplyMembership` |
722:| 12 | Equivalência forte via Entity; semelhança via Cluster reversível | 003 | 05 | `clusterSplitPreservesOriginalRecords` |
723:| 13 | replyTo/repostOf/quoteOf/references só quando têm uso de produto | 003 | 03,10 | `unknownExternalRelationStaysEvidence` |

### suites de teste existentes
AdaptiveSchedulerTests.swift
BackgroundRefreshDemandTests.swift
BackgroundRefreshTests.swift
CardActionBoundaryTests.swift
CardPreparationCoordinatorTests.swift
CardPresentationTests.swift
CatalogBrowserViewModelTests.swift
CatalogIdentityContractTests.swift
ContentCollectionTests.swift
ContentDistributionTests.swift
ContentVarietyDiagnostics.swift
CuratedPreferenceEngineTests.swift
DatabasePerformanceTests.swift
FeedComposerPreviewTests.swift
FeedDisplayStateTests.swift
FeedEngineBoundaryTests.swift
FeedLoaderCacheTests.swift
FeedPreviewPipelineTests.swift
FeedRecipeDefinitionTests.swift
FeedRecipeResolverTests.swift


[[TAREFA]]

Produza o checklist de Gate 0 que autoriza o freeze dos sete ADRs, no formato que um revisor humano usa numa sessão única de sign-off.

Estrutura:
1. PRÉ-CONDIÇÕES — o que precisa ser verdade no repositório antes de a sessão começar (artefatos, testes verdes, relatórios), cada uma com o comando ou arquivo que a comprova.
2. POR ADR (ADR-001 … ADR-007) — em uma tabela: o que o sign-off aprova, a evidência exigida, quem pode assinar (papel), e o que fica explicitamente FORA do escopo do freeze.
3. BLOQUEIOS ABERTOS — a lista consolidada do que impede o freeze hoje, na ordem em que precisa ser resolvido, com o slice que resolve cada um.
4. ORDEM DE EXECUÇÃO PÓS-FREEZE — a sequência dos PRs (PR-00, PR-01, …) com dependências, e o ponto de não retorno de cada um.
5. CRITÉRIO DE ABORTO — o que faz a sessão de freeze ser interrompida em vez de aprovada.

Formato: markdown, máximo ~2500 palavras, tabelas onde couber, citando path:line.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document; sem resumo.
