## O QUE VOCÊ (OMP) FAZ

### Os 3 itens de maior valor agora

1. **Fechar o Source bridge catálogo → runtime (ADR-003 D20–D23)**: hoje `SourceRegistry` já aloca IDs corretamente, mas `LegacyMappingStore.recordSourceMapping` absorve conflito com `ON CONFLICT DO NOTHING`; além disso `rollout.md` registra que **Source detail continua bloqueado porque não existe `SourceID` runtime resolvível sem violar D2/D18**.
2. **Fechar a identidade `PublicationCardID` nas superfícies secundárias**: `rollout.md` registra que bookmark/Smart Feed/last-clicked/collections ainda dependem da lane de identidade do card; o alias determinístico do bridge não substitui a occurrence persistida.
3. **Tornar o gate UI determinístico**: `baseline.md` mostra package/unit limpo, mas Smoke/ReleaseValidation continuam vermelhos por testes dependentes de conteúdo adquirido; enquanto isso não for seeded/isolado, o gate não distingue regressão V2 de ambiente/conteúdo.

### Item escolhido: Source bridge D20–D23

Faça **somente este slice**.

#### Arquivos a editar

1. `Packages/FeedRuntimeV2/Sources/FeedStorage/Identity/LegacyMappingStore.swift`
2. `Packages/FeedRuntimeV2/Sources/FeedStorage/Identity/SourceRegistry.swift`
3. `Packages/FeedRuntimeV2/Sources/FeedStorage/Identity/LegacySourceIdentityResolver.swift` — **criar**
4. `Packages/FeedRuntimeV2/Tests/FeedStorageTests/LegacySourceIdentityResolutionTests.swift` — **criar**
5. `Packages/FeedRuntimeV2/Tests/FeedStorageTests/RuntimeSchemaTests.swift` — somente se você preferir colocar ali o teste de conflito do writer; não duplique cobertura já existente.

**Não criar migration/DDL novo.** `source`, `legacy_source_map` e `legacy_item_map` já existem.  
**Não tocar** `feed_item.id`, `user.sqlite`, UI, acquisition ownership, `MainFeedCardBridge` ou cutover.

#### Mudança mínima

Refatore `RuntimeSourceRegistry` e `LegacyMappingStore` para oferecer primitivas transaction-scoped que recebem `GRDB.Database`, mantendo os wrappers públicos atuais.

Depois crie `LegacySourceIdentityResolver` com uma operação equivalente a:

```swift
resolve(
    editorialKey: EditorialSourceKey,
    catalogSourceID: CatalogSourceID,
    displayTitle: String,
    kind: String?,
    legacyURL: String,
    in runtimeDatabase: RuntimeDatabase
) throws -> SourceID
Semântica obrigatória, dentro de um único RuntimeDatabase.write:

1. Ler legacy_source_map para (catalog_source_key, canonicalization_version).

2. Se existir:
   - validar que a linha representa a identidade solicitada;
   - retornar runtime_source_id;
   - nunca UPDATE/repoint.

3. Se não existir:
   - obter/criar Source via RuntimeSourceRegistry usando EditorialSourceKey;
   - INSERT do legacy_source_map;
   - reler a linha;
   - verificar que ela aponta para o SourceID obtido.

4. Se o INSERT perdeu uma corrida e a linha relida divergir:
   - lançar conflito tipado;
   - rollback integral da transação de allocation/mapping;
   - persistir a evidência de conflito conforme o contrato final de D21, em write separado;
   - nunca tratar ON CONFLICT DO NOTHING como sucesso divergente.
Não converta CatalogSourceID(UInt32) em runtime SourceID(UInt64) em nenhum ponto.

Testes mínimos novos
Em LegacySourceIdentityResolutionTests.swift:

testMissingLegacySourceMappingAllocatesAndPersistsExactlyOnce
testExistingLegacySourceMappingReturnsSameRuntimeSourceWithoutRepoint
testDivergentLegacySourceMappingThrowsAndPreservesOriginalMapping
testRepeatedResolutionConvergesOnOneRuntimeSource
testNewCanonicalizationVersionDoesNotRewritePriorMapping
O teste crítico deve provar o defeito atual:

XCTAssertThrowsError(
    try resolver.resolve(/* mesma key/version, proposta apontando para outro Source */)
)
e depois:

XCTAssertEqual(stored.runtimeSourceID, originalSourceID)
XCTAssertEqual(mappingCountForKeyAndVersion, 1)
Hoje a versão equivalente feita diretamente pelo writer passa silenciosamente por causa de:

ON CONFLICT DO NOTHING
portanto a primeira asserção precisa ficar vermelha antes da correção.

Verificação que existe no repo
Primeiro, gate estrutural/barato:

bash scripts/verify-runtime-v2-boundaries.sh &&
bash scripts/validation/test_runtime_v2_boundaries.sh
Depois, gate real do Runtime V2:

bash scripts/validation/run_runtime_v2_tests.sh
Esse runner existe no repo, executa swift test do package e depois TestPlans/FeedMine-RuntimeV2.xctestplan, e rejeita execução vazia.

Se faltar espaço:

bash scripts/validation/clean_validation_artifacts.sh --build
e rode novamente sem outro build concorrente.

Condição de parada
PARAR e me devolver o output, sem avançar para outro slice, se ocorrer qualquer um destes casos:

o ADR-003 aplicado localmente ainda não contém a semântica final D20–D23/D21 aprovada;
para implementar você precisar alterar schema ou criar uma segunda tabela de mapping;
alguma solução exigir derivar SourceID de CatalogSourceID, URL ou digest;
o teste de conflito continuar verde antes da correção;
scripts/verify-runtime-v2-boundaries.sh ou run_runtime_v2_tests.sh falhar por uma mudança deste slice.
Se os dois gates passarem, pare também: esse slice está concluído; não faça commit/push.

O QUE EU (CHAT) ENTREGO
Diagnóstico concreto que fecha o escopo
Li os ADRs 001–007, baseline.md, rollout.md, o package Runtime V2 e os runners. O gargalo mais imediato não é falta de schema: o schema já está lá. O problema está na composição da identidade.

O estado atual relevante é:

// RuntimeSourceRegistry
INSERT INTO source (...)
ON CONFLICT (editorial_key, canonicalization_version) DO NOTHING
SELECT id ...
Isso é adequado para alocação idempotente de SourceID.

Mas o bridge atual faz:

// LegacyMappingStore
INSERT INTO legacy_source_map (...)
VALUES (...)
ON CONFLICT DO NOTHING
e retorna sem conferir se o mapping existente coincide com o mapping solicitado.

Portanto hoje existem três propriedades diferentes:

Source allocation idempotente                  ✅
mapping nunca é silenciosamente re-pointed     ✅
mapping divergente é detectado pelo caller     ❌
É exatamente a terceira que precisa ser fechada.

Contrato de implementação que eu entrego
Use esta separação de responsabilidades:

LegacySourceIdentityResolver
    ├── decide a política D20/D23
    ├── abre UMA write transaction
    │
    ├── LegacyMappingStore.lookup(db:)
    │
    ├── RuntimeSourceRegistry.ensure(db:)
    │
    ├── LegacyMappingStore.insertIfAbsent(db:)
    │
    └── LegacyMappingStore.lookup(db:) + validate
RuntimeSourceRegistry continua sendo o único allocator.

LegacyMappingStore continua sendo o único persistence boundary do bridge.

O resolver é o único componente autorizado a transformar:

EditorialSourceKey + CatalogSourceID + evidence
em:

persisted legacy_source_map → FeedDomain.SourceID
Regra de conflito fechada
Para a mesma:

(catalog_source_key, canonicalization_version)
a comparação final deve obedecer:

não existe row
    → pode estabelecer mapping conforme D20/D23

row existente == proposta
    → sucesso idempotente

row existente != proposta
    → typed conflict
    → nenhuma alteração da row existente
    → nenhuma nova Source bridge-visible
    → evidência durável do conflito sobrevive ao rollback
Em particular, isto é proibido como resultado observável:

write divergente
→ ON CONFLICT DO NOTHING
→ return success
O que eu já descartei para você
Não implemente legacy_source_identity_map agora. O repo já possui o bridge de catálogo necessário e a emenda D20–D23 foi desenhada para completar sua semântica, não para criar um segundo namespace de mapping.

Não adicione v8_* apenas para este slice. A cadeia atual de migrations já contém as estruturas necessárias; uma migration append-only nova só é justificável quando houver novo estado persistente concreto.

Não duplique os testes de existência/reopen do schema: MigrationTests e RuntimeSchemaTests já cobrem presença dos bridges, constraints e reabertura. O valor novo é conflict detection + atomic resolver semantics.

Esse é o menor trabalho que remove um bloqueio arquitetural real, produz evidência falsificável e destrava depois a resolução de Source detail sem contaminar card identity, user-state migration ou cutover.