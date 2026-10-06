# ADR-003 — Adendo C: Fronteira de Identidade de Card entre Legacy e Runtime V2

**Status:** NORMATIVO  
**Escopo:** fecha a fronteira de ownership da identidade de card; não redefine Publication, Exposure ou Context.  
**Princípio:** `FeedItem.id`, alias de bridge e `PublicationCardID` são três identidades com donos e durabilidades diferentes. Nenhuma é conversão da outra.

---

## C1. Dono da identidade de card por estágio

### DECISÃO

Existem três estágios explícitos:

| Estágio | Dono | Identidade |
|---|---|---|
| Legacy | `FeedStore` / modelo legacy | `FeedItem.id` |
| Compatibilidade | `MainFeedCardBridge` | alias determinístico temporário |
| Runtime publicado | `PublicationRepository` | `PublicationCardID` persistido |

**Legacy:** enquanto uma surface é alimentada por `FeedItem`, seu dono identitário continua sendo `FeedItem.id`. Hoje `PreparedFeedCard.id` e `MainFeedRow.id` derivam diretamente dessa identidade. (`feedmine/Models/PreparedFeedCard.swift:103-119`; `feedmine/RuntimeV2/MainFeedPresentationPipeline.swift:13-18`)

**Bridge:** `MainFeedCardBridge.cardID(forLegacyItemID:)` não é allocator e não possui autoridade editorial. Seu SHA-256 truncado existe somente para transportar uma apresentação legacy através de APIs que esperavam formato de card. (`feedmine/RuntimeV2/MainFeedCardBridge.swift:234-247`; `rollout.md:120`)

**Runtime:** a primeira identidade de card V2 real nasce somente no commit da publicação, dentro da transação que insere `published_card`, usando `db.lastInsertedRowID`. (`Packages/FeedRuntimeV2/Sources/FeedStorage/Publication/PublicationRepository.swift:1042`; `rollout.md:343-349`)

A troca de dono acontece somente quando a cadeia inteira passa a ser:

```text
canonical origin
→ runtime publication
→ published_card
→ PublicationCardID
→ CardPresentation
→ FeedSession/UI
Não é permitido trocar apenas o algoritmo de hash no bridge e chamar isso de migração.

CONSEQUÊNCIA
O runtime não pode aceitar um número produzido pelo bridge como se fosse uma row de published_card.

Actions, exposure, persisted position e qualquer histórico V2 que exija identidade de publicação só passam a usar PublicationCardID quando o card veio efetivamente de uma publicação persistida.

Isso corrige a classe de erro já observada em que uma operação usa card:<PublicationCardID> mas nenhuma row legacy possui aquele ID, produzindo write silenciosamente vazio. (baseline.md:1168,1259-1264)

TESTE
CardIdentityOwnershipTests.testOnlyPublicationRepositoryMintsRuntimePublicationCardID

Deve provar que:

FeedItem.id nunca é convertido em runtime card ID;
o bridge não cria uma identidade marcada como publicada;
cards vindos de published_card preservam o ID persistido;
somente PublicationRepository cria novos PublicationCardIDs.
C2. Destino do alias SHA-256 atual
DECISÃO
O alias atual NÃO continua como identidade de card do runtime V2.

Ele pode permanecer temporariamente, sem alteração, como compatibility key da apresentação legacy já publicada, enquanto as surfaces congeladas ainda passam por MainFeedCardBridge.

Ele não possui as garantias necessárias para virar identidade durável:

é derivado de outra identidade;
usa somente oito bytes do SHA-256;
é clampado ao espaço Int64;
não corresponde necessariamente a row alguma de published_card;
confunde estabilidade determinística com allocation editorial.
(feedmine/RuntimeV2/MainFeedCardBridge.swift:234-247; rollout.md:120,343-349)

A substituição ocorre em dois slices:

Slice C-ID-1 — separar tipos.

O alias deixa de ser representado como PublicationCardID. Introduzir identidade discriminada de apresentação, conceitualmente:

enum CardPresentationIdentity: Hashable, Sendable {
    case legacy(FeedItem.ID)
    case published(PublicationCardID)
}
O nome concreto pode variar; a separação semântica é obrigatória.

Slice C-ID-2 — runtime publication handoff.

Quando uma apresentação vem do runtime, o pipeline recebe o PublicationCardID da própria row publicada e nenhuma função equivalente a cardID(forLegacyItemID:) participa do caminho.

CONSEQUÊNCIA
Não existe requisito de estabilidade do alias entre edições.

Para o período em que ele ainda existe, sua única invariante é:

mesmo FeedItem.id no caminho compatibility → mesma key de apresentação durante esse caminho.

Colisão entre aliases não pode ser resolvida assumindo identidade; por isso a forma tipada futura deve preferir a própria chave legacy (FeedItem.id) em vez do hash truncado.

Nenhuma reindexação, ordenação ou posição de viewport pode gerar identidade, conforme ADR-003 D19.

TESTE
CardIdentityBoundaryTests.testLegacyAliasCannotBeUsedAsPublicationCardID

e:

RuntimePresentationTests.testPublishedCardUsesPersistedPublicationCardIDWithoutLegacyHashing

C3. legacy_item_map e item legacy ainda não mapeado
DECISÃO
legacy_item_map permanece a única ponte permitida entre legacy_item_id e OriginRecordID/OriginRevisionID. (Packages/FeedRuntimeV2/Sources/FeedStorage/Migrations/RuntimeMigrations.swift:425-433; Packages/FeedRuntimeV2/Sources/FeedStorage/Identity/LegacyMappingStore.swift:64-95)

Quando uma UI runtime precisa publicar/renderizar como V2 um FeedItem legacy sem mapping:

mapear/admitir na hora usando somente dados locais já disponíveis; não degradar silenciosamente e não fabricar card ID.

Fluxo:

legacy FeedItem
→ lookup legacy_item_map
→ missing
→ ensureLegacyItemAdmission
→ OriginRecord / OriginRevision
→ legacy_item_map
→ publication
→ PublicationCardID
Esse ensure não inicia nova aquisição de rede.

Se a admissão/mapping falhar, o runtime publication path recusa aquele card. Uma surface que ainda é integralmente legacy pode continuar no caminho legacy por decisão de rollout; não existe fallback por-card depois que a surface declarou ownership V2.

CONSEQUÊNCIA
Ausência de mapping é estado recuperável; não é identidade alternativa.

O bridge nunca usa o alias para contornar legacy_item_map.

Como GUID bruto histórico não é persistido, o backfill usa legacy_item_id como chave opaca; não tenta reconstruir GUID nem fundir itens por link/título. (feedmine/Models/FeedItem.swift:394-402; feedmine/Services/RSSFetcher.swift:1060-1073; feedmine/Services/FeedStore.swift:8392-8425)

TESTE
LegacyItemPublicationTests.testUnmappedLegacyItemIsAdmittedBeforeRuntimePublication

Deve provar que um item sem mapping:

cria ou resolve Origin;
grava legacy_item_map;
só depois recebe publicação;
nunca usa o bridge alias como substituto de Origin ou Publication identity.
C4. Edition replacement e hot restoration
DECISÃO
PublicationCardID é estável dentro da mesma edição publicada e não é identidade estável entre edições.

Dentro da mesma edition:

rerender não muda card ID;
eviction/re-materialization não muda card ID;
hot restoration usa o mesmo PublicationCardID;
ordinal/offset podem ser usados como âncoras auxiliares, nunca como identidade.
Isso corresponde ao contrato de Exposure: rerender não encerra o intervalo, e re-materialização da mesma edição recupera cardID e ordinal anchor. (ADR-007:D3-D4)

Em edition replacement:

intervalos de exposure da edição anterior são encerrados;
a nova publication transaction pode criar novas rows published_card;
novos PublicationCardIDs podem ser mintados mesmo para o mesmo Origin;
nenhum código tenta preservar card ID apenas porque conteúdo/origin parece igual.
CONSEQUÊNCIA
A restauração persistida precisa distinguir:

edition identity
+ PublicationCardID
+ ordinal/relative offset
O estado atual baseado em lastVisibleItemID é apenas compatibilidade parcial e não define a futura identidade runtime. (rollout.md:49)

Se a edição persistida ainda é válida, restaura-se o mesmo card.

Se a edição foi substituída, o antigo PublicationCardID não é transplantado para a nova edição; o runtime resolve uma nova posição por regras de restoration/contexto, não por reutilização do ID.

TESTE
PublicationCardContinuityTests.testCardIDSurvivesRerenderAndRematerializationWithinEdition

e:

PublicationCardContinuityTests.testEditionReplacementMayRemintCardIDsAndClosesPriorExposure

C5. Conteúdo exato de PR-15
DECISÃO
PR-15 não é reaberto e não recebe o cutover de PublicationCardID.

O próprio rollout já registra que PR-15 removeu a segunda árvore de background, mas mediu que card identity continua dependente do canonical→publication→presentation path e atribui o fechamento a PR-16/PR-17. (rollout.md:343-351,451)

Para esta decisão, PR-15 fica congelado com a seguinte fronteira:

Entra em PR-15
single acquisition ownership já implantado;
BGTask usando o owner único do processo;
Source demand ledger compartilhado;
nenhuma segunda árvore FeedStore/RSSFetcher;
documentação/teste explícito de que MainFeedCardBridge.cardID continua sendo compatibility alias, não runtime publication identity.
Alvos já envolvidos:

FeedmineEntryPoint;
FeedLoader;
FeedStore;
SourceDemandLedger;
background task handler;
testes de background ownership.
A prova factual existente é BackgroundRefreshDemandTests.testBackgroundDemandIssuesNoRequestForEndpointsAnotherProducerHolds. (rollout.md:287-293,451)

Fica fora de PR-15
mudança do tipo de identidade do card;
alteração de published_card;
allocator independente de card;
canonical→publication cutover;
migration de exposure para cards publicados;
persisted-position V2;
remoção de MainFeedCardBridge.cardID;
alteração das surfaces legacy.
Esses itens começam em C-ID-1/PR-16 e terminam em C-ID-2/PR-17.

CONSEQUÊNCIA
PR-15 é considerado fechado sem fingir que resolveu card identity.

A condição para PR-16 começar é esta decisão estar congelada; a condição para PR-17 encerrar a dívida é existir uma presentation path alimentada por cards realmente persistidos.

TESTE
O teste de fechamento da fronteira é:

CardIdentityRolloutTests.testPR15DoesNotTreatBridgeAliasAsPublishedIdentity

Ele deve assegurar que o estado PR-15 continua classificando o alias como compatibility-only e que nenhuma nova persistence/exposure schema foi adicionada para legitimá-lo.

C6. Caminho legacy congelado
DECISÃO
Nenhuma alteração de identidade será feita agora nas surfaces que o release atual ainda publica através de legacy ou bridge compatibility.

Ficam congelados:

Main Feed atual — loader/actions legacy com apresentação já convertida uma vez em MainFeedCardBridge; não trocar seu FeedItem.id antes do publication cutover. (rollout.md:26)
Source detail — FeedStore.loadSourceContent + apresentação construída localmente e adaptada pelo bridge. (rollout.md:28)
Bookmark list — continua usando suas durable keys legacy durante coexistência; runtime IDs não substituem bookmark_item.item_id. (rollout.md:151; ADR-003 D18)
Smart Feed — sua página legacy permanece intacta até ownership integral do runtime.
Collections — conteúdo e durable membership legacy não são rekeyed durante esta mudança.
Feed Composer / onboarding preview — apresentações estáticas/legacy continuam passando pelo bridge. (rollout.md:33)
Welcome samples — mesma regra do onboarding; nenhum PublicationCardID sintético novo.
What's New — não possui view shipping; esta decisão não autoriza recriá-la. (rollout.md §7)
Também fica congelado o comportamento de aquisição das surfaces: nenhuma mudança de card identity autoriza uma surface a iniciar seu próprio fetch. A regra de owner único continua válida após cada PR. (rollout.md:287-293)

CONSEQUÊNCIA
A migração acontece adicionando o caminho correto do runtime, não reescrevendo o caminho publicado antes de ele poder ser desligado por inteiro.

O primeiro ponto autorizado de troca é a saída de uma runtime publication real:

published_card.id
→ CardPresentationIdentity.published
→ session
→ UI / actions / exposure
Até esse ponto, a compatibilidade legacy permanece funcional e isolada.

TESTE
LegacySurfaceFreezeTests.testCardIdentityMigrationDoesNotChangeShippingLegacySurfaceKeys

O teste deve cobrir Main Feed compatibility path, Source detail, bookmarks, Smart Feed, collections e onboarding, verificando que nenhuma dessas surfaces passa a depender de published_card antes do cutover explícito.