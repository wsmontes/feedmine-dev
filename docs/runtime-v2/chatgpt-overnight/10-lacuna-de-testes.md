# Round 10 — Lacuna de testes dos sete ADRs

## 1. Lacuna por ADR

Critério usado: ausência de implementação não bloqueia por si só um freeze normativo. Porém ADR-001, ADR-002, ADR-004 e ADR-007 afirmam explicitamente, nas próprias seções de testes nomeados, que os critérios “are implemented and pinned by real tests”. Para esses ADRs, um nome auditado como **AUSENTE** torna a evidência declarada falsa; enquanto o texto permanecer assim, o teste ausente bloqueia o freeze. ADR-005 e ADR-006, ao contrário, qualificam explicitamente seus testes como **future tests**, então a ausência não bloqueia o freeze.

| ADR | Teste ausente | Comportamento prometido | Veredito |
|---|---|---|---|
| **ADR-001** | `explicitUserPurgeRemovesPublicationAndAssets` | Purge explícito remove apenas o aggregate autorizado e assets não pinned, como operação distinta. | **(a) BLOQUEIA** — o ADR declara que os critérios listados já estão implementados/pinned. |
| **ADR-001** | `tombstoneDoesNotDeletePublishedHistory` | Tombstone muda future eligibility sem apagar segments/assets publicados. | **(a) BLOQUEIA** — mesma razão. |
| **ADR-002** | `supplyGenerationIncrementKeepsDraftValid` | Nova supply durante draft não invalida draft nem troca a Edition ativa. | **(a) BLOQUEIA** — o ADR declara cobertura real existente. |
| **ADR-002** | `irrelevantCatalogRevisionKeepsEditorialRevision` | Catalog generation irrelevante ao contexto não muda `EditorialRevision`. | **(a) BLOQUEIA** — evidência declarada inexiste. |
| **ADR-002** | `staleEditorialRevisionKeepsEditionDisplayableUntilExplicitRefresh` | Edition restaurada continua visível apesar de revision mais nova; successor só em boundary explícita. | **(a) BLOQUEIA** — evidência declarada inexiste. |
| **ADR-003** | — | Nenhum teste AUSENTE reportado pela auditoria. | **Sem lacuna ausente nesta auditoria.** |
| **ADR-004** | `walAwareBackupRestoresConsistentDatabase` | Backup de DB vivo/WAL restaura estado consistente e committed. | **(a) BLOQUEIA** — seção afirma que os critérios estão implementados e pinned. |
| **ADR-004** | `unknownFutureSchemaFailsControlled` | DB de schema futuro é recusado/controlado sem apagar ou reinterpretar dados. | **(a) BLOQUEIA** — mesma razão; é também invariável crítica de upgrade. |
| **ADR-005** | `budgetStopMidPageKeepsResumableCheckpoint` | Interrupção por budget mantém checkpoint somente no último boundary duravelmente committed. | **(b) DEPOIS DO FREEZE** — ADR-005 chama a seção explicitamente de “Future tests”. |
| **ADR-005** | `acquisitionDoesNotProbeMediaInline` | Acquisition não faz media probing inline; probing pertence à MediaPreparation. | **(b) DEPOIS DO FREEZE** — contrato pode congelar antes da implementação. |
| **ADR-006** | `admissionTransactionHasNoSuspensionPoints` | Transaction de admission contém zero suspension/network/foreign callback. | **(b) DEPOIS DO FREEZE** — o próprio ADR diz que todos são future tests. |
| **ADR-006** | `cancelledButValidWorkMayStillCommit` | Cancellation economiza trabalho, mas segurança depende da validation transacional. | **(b) DEPOIS DO FREEZE**. |
| **ADR-006** | `criticalWritesBypassRuntimeWriteCoordinator` | Admission/publication/checkpoint/user durable writes não passam pelo coordinator de non-critical writes. | **(b) DEPOIS DO FREEZE**. |
| **ADR-006** | `retryAfterStorageFailureDoesNotDoubleApply` | Retry após storage failure reaplica no máximo uma vez após nova validation. | **(b) DEPOIS DO FREEZE**. |
| **ADR-006** | `oversizedBatchIsRejectedWithoutCheckpointAdvance` | Batch acima do limite falha sem avançar checkpoint nem deixar canonical residue. | **(b) DEPOIS DO FREEZE**. |
| **ADR-006** | `durablePerItemRejectionAdvancesCheckpointOnlyWithinContract` | Caminho opcional per-item só avança checkpoint atomicamente e para connector explicitamente autorizado. | **(b) DEPOIS DO FREEZE**. |
| **ADR-007** | `tombstonedOriginDoesNotDeleteExposureHistory` | Tombstone/overlay não reescreve nem apaga exposure/history já registrada. | **(a) BLOQUEIA** — ADR-007 afirma que todos os critérios listados já estão implementados/pinned. |

### Resultado

- **8 testes (a): bloqueiam o freeze enquanto os ADRs mantiverem a afirmação de que já existem.**
- **8 testes (b): necessários para implementação/conformance, mas não para congelar o contrato.**
- **0 testes (c):** a auditoria fornecida não mostra nenhum dos 16 AUSENTES como coberto sob outro nome. Os casos comprovadamente movidos estão classificados separadamente como RENOMEADOS.

O 17º ausente, `GeometryTests.xctestplan`, pertence a `baseline.md`, não a um ADR. É defeito documental/verificatório do baseline, mas não demonstra por si só falha de nenhuma decisão D-n.

---

## 2. Especificação dos testes que bloqueiam

### `explicitUserPurgeRemovesPublicationAndAssets`

**Arquivo:** `Packages/FeedRuntimeV2/Tests/FeedStorageTests/RetentionCoordinatorTests.swift`

**Arranjo mínimo:** criar uma Edition com segment/card publicado, referência para asset A usada apenas pelo aggregate alvo e asset B pinned por outro root; registrar a operação de purge explícito para o aggregate alvo.

**Asserção falsificadora:** após purge, cards/segments/refs do aggregate alvo não existem, A é removido se ficou unpinned, B permanece, e existe evidência distinta da operação de purge. Falha se qualquer publicação não alvo ou asset ainda pinned desaparecer.

**Não deve testar:** UX de confirmação, autorização de conta, media download ou política geral de GC.

### `tombstoneDoesNotDeletePublishedHistory`

**Arquivo:** `Packages/FeedRuntimeV2/Tests/FeedStorageTests/PublicationRepositoryTests.swift`

**Arranjo mínimo:** persistir `OriginRecord`/revision, publicar card numa Edition e depois aplicar tombstone/future-facing unavailable state ao origin.

**Asserção falsificadora:** as mesmas rows de Edition/segment/published card continuam presentes e recuperáveis byte-for-byte; somente future eligibility muda. Qualquer delete/cascade da publication faz o teste falhar.

**Não deve testar:** purge explícito, retention expiry ou overlay legal obrigatório.

### `supplyGenerationIncrementKeepsDraftValid`

**Arquivo:** `Packages/FeedRuntimeV2/Tests/FeedRuntimeTests/FeedSessionTests.swift`

**Arranjo mínimo:** iniciar draft sob `EditorialRevision R` e `SupplyGeneration N`; antes do commit, admitir supply relevante suficiente para incrementar generation para `N+1`, sem mudar os qualifiers que compõem `R`.

**Asserção falsificadora:** o draft original ainda pode completar/commit segundo seu token/revision e a Edition visível não é substituída passivamente só pelo incremento de supply generation.

**Não deve testar:** mudança real de `EditorialRevision`, stale `TargetStamp` ou refresh explícito.

### `irrelevantCatalogRevisionKeepsEditorialRevision`

**Arquivo:** `Packages/FeedRuntimeV2/Tests/FeedStorageTests/CatalogRevisionRelevanceTests.swift` *(criar)*

**Arranjo mínimo:** construir dois snapshots de catálogo com `CatalogGeneration` diferente, alterando apenas Source/node fora da projeção relevante do `ContextKey`; manter políticas e user-state qualifiers iguais.

**Asserção falsificadora:** o digest/version de `EditorialRevision` calculado para o contexto deve ser idêntico nos dois snapshots. Se a generation global, por si só, mudar a revision, o teste falha.

**Não deve testar:** alteração de Source relevante, policy version, filtro ou canonical serialization.

### `staleEditorialRevisionKeepsEditionDisplayableUntilExplicitRefresh`

**Arquivo:** `Packages/FeedRuntimeV2/Tests/FeedRuntimeTests/FeedSessionTests.swift`

**Arranjo mínimo:** persistir Edition E sob revision R1; disponibilizar R2 como revisão editorial mais recente; iniciar restore sem evento explícito de refresh/context change.

**Asserção falsificadora:** E/R1 é imediatamente restaurada e permanece a Edition visível; R2 pode tornar trabalho successor elegível, mas não troca E antes de boundary explícita. Falha se startup descartar E ou trocar automaticamente para successor.

**Não deve testar:** schema incompatível, payload corrompido ou refresh explicitamente solicitado.

### `walAwareBackupRestoresConsistentDatabase`

**Arquivo:** `Packages/FeedRuntimeV2/Tests/FeedStorageTests/MigrationTests.swift`

**Arranjo mínimo:** abrir `runtime-v2.sqlite` em WAL, persistir rows relacionadas em transaction committed enquanto WAL contém estado relevante; gerar backup pela política oficial e restaurá-lo em caminho independente.

**Asserção falsificadora:** DB restaurado passa `PRAGMA integrity_check = 'ok'` e contém todas as rows committed com FKs válidas. O harness também deve demonstrar que a implementação oficial não é simples cópia insegura do `.sqlite` isolado.

**Não deve testar:** performance do backup, cloud backup, tamanho de arquivo ou retention.

### `unknownFutureSchemaFailsControlled`

**Arquivo:** `Packages/FeedRuntimeV2/Tests/FeedStorageTests/MigrationTests.swift`

**Arranjo mínimo:** criar DB válido com durable rows e metadata/schema version superior ao maior version suportado pelo binário atual; tentar abrir pelo migrator oficial.

**Asserção falsificadora:** abertura termina em erro/estado de compatibilidade explicitamente tipado e nenhuma tabela/row é removida, zerada ou reinterpretada. Qualquer erase/recreate ou downgrade automático falha o teste.

**Não deve testar:** migration normal N→N+1 nem corrupção física de SQLite.

### `tombstonedOriginDoesNotDeleteExposureHistory`

**Arquivo:** `Packages/FeedRuntimeV2/Tests/FeedStorageTests/RetentionCoordinatorTests.swift`

**Arranjo mínimo:** publicar um card real, gravar exposure facts + projection associadas ao `PublicationCardID`, então tombstonar/revogar o Origin por meio do caminho canônico.

**Asserção falsificadora:** exposure facts, idempotency rows e history projection permanecem com os mesmos valores; nenhuma FK/cascade ou cleanup provocado pelo tombstone os remove. Future presentation pode ficar inelegível separadamente.

**Não deve testar:** novo exposure após tombstone, UI suppression, explicit history purge ou bounded-history GC.

---

## 3. Edições de texto nos ADRs para veredictos (c)

**Nenhuma.**

A auditoria classifica os 16 nomes acima como **AUSENTES**, não como RENOMEADOS, e não forneceu evidência de que qualquer um desses comportamentos esteja coberto hoje por outro teste real. Portanto seria incorreto inventar uma âncora/substituição dizendo que o comportamento “mudou de lugar”.

Se um teste equivalente real for localizado posteriormente, ele deve ser reclassificado de AUSENTE para RENOMEADO antes de editar o ADR.

---

## 4. Renomeados — regra de manutenção

**Sim.** Todo identificador de teste citado por um ADR como evidência executável deve ser atualizado para o nome/path real; deixar aliases históricos reduz a auditabilidade e faz uma busca literal produzir falso negativo.

A mudança é exclusivamente de **traceability**, não de decisão normativa: preservar o nome antigo apenas quando explicitamente rotulado como “nome do plano → nome atual”. Para os 24 renomeados dentro do conjunto A, atualizar os ADRs; os demais renomeados de baseline/rollout devem ser corrigidos nos respectivos documentos, não copiados para os ADRs.