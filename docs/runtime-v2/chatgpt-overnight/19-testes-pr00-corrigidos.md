## 5. TESTES QUE PROVAM

### T1 — schema dos bridges já existe

**Decisão:** **ELIMINAR como teste novo.**

A proposta anterior `testLegacyIdentityBridgeIsAlreadyPartOfRuntimeSchema` é redundante.

Cobertura existente:

- `MigrationTests.testEmptyDatabaseMigratesWithCleanIntegrityAndForeignKeys` — `Packages/FeedRuntimeV2/Tests/FeedStorageTests/MigrationTests.swift`; já exige a presença de `source`, `legacy_source_map` e `legacy_item_map` após migration.
- `RuntimeSchemaTests.testClosedVocabulariesAndRangesAreRefused` — `Packages/FeedRuntimeV2/Tests/FeedStorageTests/RuntimeSchemaTests.swift`; já exercita os `CHECK` do bridge, inclusive `catalog_source_id > 0` e os valores permitidos de `legacy_item_map.confidence`.

**Motivo:** adicionar outro teste de existência/constraints não aumentaria a capacidade de detectar regressão do schema.

---

### T2 — reabertura/idempotência da migration

**Decisão:** **FUNDIR com teste existente; não criar novo teste.**

A proposta anterior `testLegacyIdentitySchemaReopenIsIdempotent` deve ser absorvida por:

**Teste existente:** `testReopeningAppliesNoMigrationAndChangesNoData`  
**Arquivo:** `Packages/FeedRuntimeV2/Tests/FeedStorageTests/MigrationTests.swift`

Esse teste já:

1. cria e migra o banco;
2. persiste estado;
3. captura a lista de migrations e o conteúdo anterior;
4. reabre com `RuntimeDatabase`;
5. prova que nenhuma migration é reaplicada;
6. compara o estado antes/depois;
7. verifica integridade do banco.

Se for necessário tornar a cobertura do bridge explícita, acrescentar **ao teste existente** uma `legacy_source_map` row antes do fechamento e verificar a mesma row após a reabertura. Não criar um segundo caso com a mesma propriedade.

**Motivo:** a propriedade relevante é idempotência/reopen do `DatabaseMigrator`, que esse teste já possui como responsabilidade nominal.

---

### T3 — conflito divergente precisa ser detectado

**Decisão:** **MANTER como teste novo**, porque a cobertura existente prova apenas “não re-point”, não prova “conflito não pode ser silencioso”.

**Nome:** `testLegacySourceMappingConflictIsReportedAndDoesNotRepoint`

**Arquivo de destino:** `Packages/FeedRuntimeV2/Tests/FeedStorageTests/RuntimeSchemaTests.swift` — **existente**.

Ele deve ficar próximo de `testLegacyMappingStorePersistsBothBridges`, que já cobre persistência normal e `ON CONFLICT DO NOTHING`.

#### Arranjo exato

1. Criar duas Sources runtime distintas:
   - `sourceA`, com `SourceID A`;
   - `sourceB`, com `SourceID B`;
   - garantir `A != B`.
2. Construir uma única `EditorialSourceKey`:
   - mesmo `catalog_source_key`;
   - mesma `canonicalization_version`.
3. Persistir primeiro mapping:
   - `(key, version) → sourceA`.
4. Construir segundo `LegacySourceMapping` para **a mesma `(key, version)`**, mas com:
   - `runtimeSourceID = sourceB`;
   - opcionalmente outro `catalogSourceID`/`legacyURL` para deixar a divergência inequívoca.
5. Chamar `recordSourceMapping` com o segundo mapping.

#### Asserção que precisa falhar hoje

A chamada divergente deve produzir erro:

```swift
XCTAssertThrowsError(
    try store.recordSourceMapping(conflictingMapping, in: database)
)
Depois da chamada, independentemente do erro, confirmar também:

sourceMapping(for: editorialKey).runtimeSourceID == sourceA
e:

COUNT(*) para (catalog_source_key, canonicalization_version) == 1
Por que este é um teste real
Com LegacyMappingStore.swift:17-28 como está hoje:

INSERT ... ON CONFLICT DO NOTHING
absorve o segundo insert.

Resultado atual esperado:

recordSourceMapping(conflictingMapping) retorna normalmente
stored mapping continua apontando para sourceA
Logo, XCTAssertThrowsError falha hoje.

Depois da correção, o writer deve reler/validar o mapping já existente e:

mesma key/version + mesmo runtime SourceID → idempotent success
mesma key/version + runtime SourceID diferente → erro de conflito
Assim o teste passa somente quando o comportamento silencioso defeituoso deixar de existir.

O teste já existente testLegacyMappingStorePersistsBothBridges continua útil para provar que um segundo write não re-pointa a row; ele não deve ser removido. O novo teste acrescenta a obrigação ausente: divergência precisa ser observável pelo caller.

O que esta seção NÃO deve testar
Não testar novamente criação das tabelas, FKs, ranges ou closed vocabularies já cobertos por MigrationTests e RuntimeSchemaTests.
Não testar missing mapping → allocate SourceID, concorrência do futuro resolver ou atomic allocation+mapping; isso pertence à implementação D20/D21, não à correção deste writer isolado.
Não testar feed_item.id, bookmarks, user-state migration, canonicalization-version lifecycle, UI/card identity, rollout ou qualquer rekey/delete de dados legacy.