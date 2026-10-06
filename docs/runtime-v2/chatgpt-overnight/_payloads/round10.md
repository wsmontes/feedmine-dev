[[ROUND 10 — LACUNA DE TESTES DOS SETE ADRs]]

Fatos novos: a auditoria dos nomes de teste que os próprios sete ADRs citam nas suas seções de testes nomeados, resolvidos contra o código de teste real do repositório (`feedmineTests/`, `Packages/FeedRuntimeV2/Tests/`). Linha por citação: `ADR | identificador citado | ADR:linha | EXISTE em path:linha | AUSENTE | RENOMEADO para <nome>`.

### Resumo da auditoria
A (ADRs 001-004): linhas=103 existe=72 ausente=7 renomeado=24
B (ADRs 005-007 + rollout/baseline): linhas=252 existe=184 ausente=10 renomeado=58

### AUSENTES — auditoria A
ADR-001 | explicitUserPurgeRemovesPublicationAndAssets | ADR-001.md:353 | - | AUSENTE | -
ADR-001 | tombstoneDoesNotDeletePublishedHistory | ADR-001.md:354 | - | AUSENTE | -
ADR-002 | supplyGenerationIncrementKeepsDraftValid | ADR-002.md:369 | - | AUSENTE | -
ADR-002 | irrelevantCatalogRevisionKeepsEditorialRevision | ADR-002.md:371 | - | AUSENTE | -
ADR-002 | staleEditorialRevisionKeepsEditionDisplayableUntilExplicitRefresh | ADR-002.md:379 | - | AUSENTE | -
ADR-004 | walAwareBackupRestoresConsistentDatabase | ADR-004.md:307 | - | AUSENTE | -
ADR-004 | unknownFutureSchemaFailsControlled | ADR-004.md:310 | - | AUSENTE | -

### AUSENTES — auditoria B
baseline.md | GeometryTests.xctestplan | docs/runtime-v2/baseline.md:86 | AUSENTE
ADR-005 | budgetStopMidPageKeepsResumableCheckpoint | docs/runtime-v2/adrs/ADR-005.md:324 | AUSENTE
ADR-005 | acquisitionDoesNotProbeMediaInline | docs/runtime-v2/adrs/ADR-005.md:326 | AUSENTE
ADR-006 | admissionTransactionHasNoSuspensionPoints | docs/runtime-v2/adrs/ADR-006.md:423 | AUSENTE
ADR-006 | cancelledButValidWorkMayStillCommit | docs/runtime-v2/adrs/ADR-006.md:424 | AUSENTE
ADR-006 | criticalWritesBypassRuntimeWriteCoordinator | docs/runtime-v2/adrs/ADR-006.md:425 | AUSENTE
ADR-006 | retryAfterStorageFailureDoesNotDoubleApply | docs/runtime-v2/adrs/ADR-006.md:426 | AUSENTE
ADR-006 | oversizedBatchIsRejectedWithoutCheckpointAdvance | docs/runtime-v2/adrs/ADR-006.md:427 | AUSENTE
ADR-006 | durablePerItemRejectionAdvancesCheckpointOnlyWithinContract | docs/runtime-v2/adrs/ADR-006.md:428 | AUSENTE
ADR-007 | tombstonedOriginDoesNotDeleteExposureHistory | docs/runtime-v2/adrs/ADR-007.md:322 | AUSENTE

### Amostra de RENOMEADOS (8, auditoria B)
baseline.md | PublicationTests | docs/runtime-v2/baseline.md:1972 | RENOMEADO para PublicationRepositoryTests (Packages/FeedRuntimeV2/Tests/FeedStorageTests/PublicationRepositoryTests.swift)
baseline.md | RetentionTests | docs/runtime-v2/baseline.md:1972 | RENOMEADO para RetentionCoordinatorTests (Packages/FeedRuntimeV2/Tests/FeedStorageTests/RetentionCoordinatorTests.swift)
baseline.md | RuntimeV2LegacyMapperTests | docs/runtime-v2/baseline.md:1972 | RENOMEADO para LegacyIdentityMapperTests (feedmineTests/LegacyIdentityMapperTests.swift)
baseline.md | testAScopeTheStorageCannotHonourMatchesNothing | docs/runtime-v2/baseline.md:2079 | RENOMEADO para testAListNobodySavedIntoMatchesNothing (Packages/FeedRuntimeV2/Tests/FeedStorageTests/S
baseline.md | testFetchAllOfflineMirrorsEachSourceOutcomeWithoutExtraRequests | docs/runtime-v2/baseline.md:453 | RENOMEADO para testFetchAllMirrorsEachSourceOutcomeWithoutExtraRequests (feedmineTests
baseline.md | FeedRuntimeTests/Session | docs/runtime-v2/baseline.md:1972 | RENOMEADO para arquivos planos: Packages/FeedRuntimeV2/Tests/FeedRuntimeTests/ExposureTrackerTests.swift, FeedWindowTests.sw
baseline.md | FeedStorageTests/RetentionTests | docs/runtime-v2/baseline.md:1972 | RENOMEADO para RetentionCoordinatorTests (Packages/FeedRuntimeV2/Tests/FeedStorageTests/RetentionCoordinatorTests.swi
baseline.md | Retention | docs/runtime-v2/baseline.md:1972 | RENOMEADO para RetentionCoordinatorTests (Packages/FeedRuntimeV2/Tests/FeedStorageTests/RetentionCoordinatorTests.swift)


A e B juntas: 256 existem, 82 renomeados e 17 AUSENTES (listados acima com ADR e linha).

[[TAREFA]]

1. LACUNA POR ADR — tabela: ADR, testes ausentes, o comportamento que o ADR promete, e o veredito: (a) o teste é necessário e a ausência BLOQUEIA o freeze, (b) o teste é necessário mas pode entrar depois do freeze, (c) o ADR deve ser corrigido porque o comportamento mudou de lugar (se for o caso, diga qual teste real cobre isso hoje).

2. ESPECIFICAÇÃO DOS TESTES QUE FALTAM — para cada teste com veredito (a): nome exato do teste, arquivo onde entra, o arranjo mínimo (tabelas/linhas que precisam existir), a asserção que o torna falso se a implementação regredir, e o que ele NÃO deve testar. Sem código Swift — especificação em prosa curta e precisa.

3. EDIÇÕES DE TEXTO NOS ADRs — para os vereditos (c): a âncora verbatim a substituir em cada arquivo e o texto novo, uma linha por edição.

4. RENOMEADOS — regra de manutenção: os 24 nomes que mudaram devem ser atualizados no texto do ADR? Diga sim/não e por quê, em duas linhas.

Formato: markdown, máximo ~2500 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
