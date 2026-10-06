# ADR-003 — Adendo A: Runtime Identity para Sources de Catálogo

**Status:** NORMATIVO — fecha a decisão aberta de identidade de Source para superfícies de catálogo.  
**Escopo:** complementa ADR-003 D2/D18; não cria novo ADR.  
**Autoridade factual:** checkout `fix/release-1.0-final-hardening`, HEAD `70f7b06b`, mais o estado registrado em `rollout.md`.

A regra central deste adendo é:

> **Uma Source de catálogo ganha identidade de runtime por alocação transacional no runtime database e por persistência explícita em `legacy_source_map`. O ID nunca é calculado a partir da URL, do `CatalogSourceID`, do digest ou de qualquer posição.**

---

## A1. Evento de alocação de `SourceID`

### DECISÃO

O evento normativo é **`ensureRuntimeSourceIdentity(catalogSource)`**, executado pela camada de identidade do runtime quando uma Source de catálogo entra pela primeira vez no domínio V2.

Esse evento:

1. recebe `catalog_source.key`, `catalog_source.id`, a `canonicalization_version` vigente e os metadados editoriais necessários;
2. procura `legacy_source_map`;
3. se já houver mapping válido, retorna o `FeedDomain.SourceID`;
4. se não houver, chama `RuntimeSourceRegistry.sourceID(...)`, que **aloca** uma row positiva em `source`;
5. grava, na mesma operação lógica, o bridge `legacy_source_map → runtime_source_id`;
6. devolve o `SourceID` persistido.

O disparador não é a URL e não é o `CatalogSourceID`: eles são **evidência de entrada para o bridge**, não matéria-prima matemática do runtime ID. Isso preserva D2, que proíbe conversão entre `FeedEngine.SourceID(UInt32)` e `FeedDomain.SourceID(UInt64)`, e acompanha o runtime já existente, no qual `SourceRegistry` obtém o ID da row de `source`, sem derivação por digest. (`feedmine/FeedEngine/Identities.swift:32-37`; `Packages/FeedRuntimeV2/Sources/FeedDomain/RuntimeIDs.swift:5-24`; `Packages/FeedRuntimeV2/Sources/FeedStorage/Identity/SourceRegistry.swift:30-65`)

Há dois disparadores legítimos para **a mesma operação**:

- bootstrap incremental do catálogo;
- resolução on-demand de uma Source ainda não bootstrapada.

Não existem dois algoritmos de identidade.

### CONSEQUÊNCIA

`FeedSurfaceCatalog` deixa de precisar que o caller já conheça um runtime ID. A Source de catálogo chega ao boundary com sua identidade legada; o resolver garante ou cria o mapping antes de construir `HistoryScope.source(SourceID)`.

`legacy_source_map` permanece o único caminho catalog→runtime, conforme D18. (`Packages/FeedRuntimeV2/Sources/FeedStorage/Migrations/RuntimeMigrations.swift:414-423`; `Packages/FeedRuntimeV2/Sources/FeedDomain/Identity/EditorialIdentity.swift:150-165`)

A existência de `catalog_source.id` não autoriza `UInt32 → UInt64`; sua função no mapa é detectar identidade/conflito legado.

### TESTE

`CatalogRuntimeIdentityTests.testFirstResolutionAllocatesAndPersistsRuntimeSourceID`

Deve provar:

- nenhuma operação aritmética/cast produz o runtime ID;
- primeira resolução cria exatamente uma row `source`;
- cria exatamente um `legacy_source_map`;
- segunda resolução retorna o mesmo `SourceID`;
- restart do processo retorna o mesmo ID persistido.

---

## A2. Substituição de `runtimeIdentityUnavailable(.source)`

### DECISÃO

A recusa prévia é substituída por **resolução obrigatória de identidade antes da construção do Source SurfacePlan**.

Fluxo normativo:

```text
catalog source
    ↓
ensureRuntimeSourceIdentity
    ↓
SourceID
    ↓
HistoryScope.source(SourceID)
    ↓
ResolvedFeedPlan
A condição exata em que a recusa continua correta é:

o runtime identity service não conseguiu estabelecer durablemente um mapping não disputado para aquela Source.

Isso inclui somente falhas reais de identidade/storage: runtime DB indisponível ou não migrável, transação falhou, conflito/dispute detectado, ou mapping persistido inconsistente.

Mapping simplesmente ausente não é motivo de recusa. Ausência dispara alocação.

Hoje rollout.md registra a recusa porque a surface necessita HistoryScope.source(SourceID) e nenhum shipping mode garante runtime DB disponível; essa situação é precisamente o gap que este adendo fecha. (rollout.md:118,155,338-342)

CONSEQUÊNCIA
FeedSurfacePlanError.runtimeIdentityUnavailable(.source) deixa de significar “row ainda não existe” e passa a significar “não foi possível garantir identidade durável”.

A Source surface não degrada silenciosamente para semântica de identidade baseada em URL.

TESTE
SourceSurfacePlanTests.testMissingMappingIsAllocatedBeforeSourcePlanResolution

E:

SourceSurfacePlanTests.testSourcePlanRefusesOnlyWhenDurableIdentityCannotBeEstablished

O primeiro deve eliminar a antiga expectativa de refusal para simples mapping ausente.

A3. Bootstrap de instalações existentes
DECISÃO
O bootstrap é híbrido: batch incremental + lazy ensure.

Não será feita alocação síncrona de centenas de Sources antes de liberar o launch.

Em cada launch elegível:

runtime migrations são abertas/concluídas;
um batch limitado de Sources do catálogo sem mapping é processado;
cada mapping concluído é durável imediatamente;
um checkpoint permite continuar no próximo launch;
qualquer Source solicitada antes de seu batch é resolvida imediatamente pelo mesmo ensureRuntimeSourceIdentity.
Estado intermediário permitido:

runtime DB válido
+ parte do catálogo mapeada
+ parte ainda não mapeada
+ zero mapping parcialmente gravado
Esse estado é normal e funcional.

Não é permitido estado intermediário em que uma row de legacy_source_map aponte para uma source inexistente ou em que um mapping seja considerado concluído antes do commit.

O catálogo é reconstruível por build→swap e contém centenas de rows potencialmente desnecessárias para uma sessão; bloquear launch para mapear tudo acrescentaria custo sem ganho de correção. (feedmine/FeedEngine/SQLiteCatalogStore.swift:55-76,656-695)

CONSEQUÊNCIA
Custo de launch é O(batch fixo), não O(tamanho total do catálogo), depois das migrations.

O processo é idempotente porque mappings persistidos são reutilizados; é resumível porque cada row concluída é suficiente por si só. O checkpoint é otimização de varredura, não autoridade de identidade.

A lazy allocation garante que bootstrap incompleto nunca impeça uma Source efetivamente acessada.

TESTE
CatalogIdentityBootstrapTests.testBootstrapIsBoundedIdempotentAndResumable

Deve interromper o bootstrap entre batches, recriar o processo e provar:

IDs já alocados não mudam;
não há duplicação de source;
trabalho continua apenas sobre mappings faltantes;
uma Source fora do batch pode ser resolvida on-demand.
A4. Concorrência de RuntimeSourceRegistry
DECISÃO
INSERT ... ON CONFLICT DO NOTHING seguido de SELECT é semanticamente correto somente se o par for executado dentro da mesma transação de escrita no mesmo database writer.

Como duas statements separadas não constituem por si mesmas uma operação atômica de domínio, a garantia normativa passa a ser:

BEGIN write transaction
    INSERT source ... ON CONFLICT DO NOTHING
    SELECT id FROM source WHERE <editorial uniqueness>
    INSERT legacy_source_map ...
COMMIT
A correção mínima é envolver allocation + lookup + bridge write em uma única db.write/transaction no storage boundary; não criar um novo allocator nem trocar a estratégia SQLite existente.

Hoje o registry já usa INSERT/SELECT (SourceRegistry.swift:30-62) e o bridge é gravado separadamente em acquisition (feedmine/RuntimeV2/V2Acquisition.swift:165-197). O fechamento necessário é transacional, não algorítmico.

CONSEQUÊNCIA
Dois callers concorrentes para a mesma Source:

podem disputar a tentativa de insert;
devem observar a mesma row final;
devem retornar o mesmo SourceID;
não podem deixar uma Source alocada sem bridge como resultado “bem-sucedido”.
Uma row source órfã causada por transação abortada não pode sobreviver ao rollback.

TESTE
RuntimeSourceRegistryConcurrencyTests.testConcurrentEnsureReturnsOneDurableSourceIdentity

Executar múltiplas tasks simultâneas para a mesma catalog Source e provar:

um único source.id;
um único mapping para (catalog_source_key, canonicalization_version);
todos recebem o mesmo ID;
fault injection entre allocation e bridge insert resulta em rollback integral.
A5. Semântica de canonicalization_version
DECISÃO
canonicalization_version versiona exclusivamente o algoritmo que transforma a identidade legada da Source em catalog_source_key.

Não é:

versão do app;
versão do catálogo;
versão do runtime schema;
número do migration.
Muda somente quando uma alteração em OPMLParser.normalizeURL/CatalogIdentity.canonicalURLKey puder produzir uma chave diferente para o mesmo input legado. Hoje a chave deriva explicitamente dessa canonicalização. (feedmine/FeedEngine/CatalogIdentity.swift:12-31; feedmine/Services/OPMLParser.swift:677-742)

Quando a versão muda:

rows antigas de legacy_source_map são imutáveis e preservadas;
o resolver calcula a chave na versão nova;
para uma Source já conhecida, tenta transportar a identidade usando a mesma entrada de catálogo processada também sob a canonicalização anterior;
se localizar de forma inequívoca o mapping anterior, grava nova row de versão apontando para o mesmo runtime SourceID;
se não houver continuidade comprovável, executa alocação normal;
qualquer colisão/disputa impede associação automática.
Nunca se faz UPDATE das rows antigas para “convertê-las” à versão nova.

A PK existente (catalog_source_key, canonicalization_version) está alinhada a essa regra. (RuntimeMigrations.swift:414-423)

CONSEQUÊNCIA
Mudanças de canonicalização não renumeram automaticamente Sources V2 já estabelecidas e não reinterpretam histórico.

O runtime ID permanece independente da URL; a canonicalização existe somente no bridge legado.

TESTE
LegacySourceMapVersioningTests.testCanonicalizationUpgradePreservesOldMapAndCarriesForwardUnambiguousIdentity

Também deve haver caso de colisão:

LegacySourceMapVersioningTests.testCanonicalizationUpgradeRefusesAmbiguousCarryForward

A6. Regra única para mapping ausente
DECISÃO
A regra universal é:

missing mapping → ensure/allocate; allocation impossível ou disputada → refuse.

Nunca:

missing mapping → legacy fallback
e nunca:

missing mapping → derivar SourceID
Isso vale para Main Feed, Source Detail, collections, Smart Feed, background e qualquer SurfacePlan futuro.

O missingSourceMapping atual em LegacySourceMap.runtimeSource(...) continua útil como resultado de lookup puro (EditorialIdentity.swift:150-165), mas não deve escapar diretamente de um orchestration boundary capaz de garantir identidade. O caller normativo captura “missing”, chama ensureRuntimeSourceIdentity, e só recusa se o ensure falhar.

CONSEQUÊNCIA
Não existem semânticas de identidade diferentes por superfície.

Legacy pode continuar dono de aquisição/apresentação onde o rollout ainda exigir, mas isso não muda o significado da Source. O demand arbiter já assegura single ownership das requests; identidade passa a ser igualmente única. (rollout.md:287-293,451)

TESTE
RuntimeSourceIdentityPolicyTests.testEverySurfaceUsesEnsureThenRefusePolicy

O teste deve enumerar todos os FeedSurfaceCatalog cases e provar que nenhum transforma missing mapping em URL-derived ID ou fallback identitário legacy.

A7. Relação com ADR-002 e gates
DECISÃO
Este adendo fecha uma pendência interna ao ADR-003 e deve estar congelado antes de ADR-002.

A ordem permanece:

ADR-003
  └─ Adendo A — Runtime Source Identity [este documento]
        ↓
ADR-002 — Context & Revision Model
        ↓
ADR-001 — Publication & Media Identity
        ↓
demais gates já fixados
ADR-002 pode assumir, sem reabrir a decisão:

SourceID é estável, positivo e runtime-owned;
Source identity não é URL/binding;
catalog identity é somente bridge evidence;
canonicalization version pertence à coexistência/migração legacy, não ao ContextKey;
mudar endpoint, request URL ou binding não cria por si só novo SourceID;
HistoryScope.source(SourceID) é sempre nomeado por runtime identity real.
ADR-002 ainda precisa congelar quando mudanças editoriais/contextuais invalidam selection/history/session, mas não pode usar essas revisions para renumerar Source.

O card identity continua fora deste adendo: PublicationCardID real nasce na transaction de publicação (`PublicationRepository.performCommit` começa em `PublicationRepository.swift:903`; o `published_card` é inserido em `:1009-1041` e `PublicationCardID(db.lastInsertedRowID)` é criado em `:1042`) e o SHA-256 atual de MainFeedCardBridge continua sendo apenas alias até o publication slice. (rollout.md:343-349)

CONSEQUÊNCIA
A implementação permitida antes de ADR-002 é limitada a:

runtime Source allocation;
bridge persistence/versioning;
bootstrap/resolution;
remoção da refusal causada exclusivamente por mapping ausente.
Não está autorizado usar este adendo para alterar ContextKey, revision semantics, publication identity ou grouping.

TESTE
ArchitectureGateTests.testSourceIdentityIsFrozenBeforeContextRevisionSemantics

Deve provar por API boundaries que ContextKey/HistoryScope recebem FeedDomain.SourceID já resolvido e que nenhuma API de contexto aceita CatalogSourceID, URL ou digest como substituto.