# FeedMine Feed Runtime — Unified Architecture Blueprint v0.4

**Status:** macroarquitetura candidata a freeze  
**Data:** 17 de setembro de 2026  
**Implementação estrutural de produção:** ainda não autorizada  
**Próximo estágio:** sete ADRs arquiteturais, com quatro revisados pela nova boundary de aquisição  
**Escopo:** novo runtime do feed + contrato formal Runtime ↔ UI + fronteira formal External Systems ↔ Canonical FeedMine Supply

---

## 1. Objetivo

Construir um novo motor de feed para o FeedMine capaz de entregar navegação extremamente fluida, local-first e offline-first, sem servidor próprio obrigatório e sob as limitações reais de rede, energia, memória, thermal state e background execution do iOS.

A arquitetura deve eliminar os problemas acumulados no runtime atual:

- orchestration concentrada em `FeedStore`;
- múltiplos caminhos de seleção;
- estado difícil de invalidar;
- trabalho assíncrono alterando conteúdo já publicado;
- dependência de aquisição para sustentar o scroll;
- media resolution acoplada à apresentação;
- regras editoriais espalhadas;
- UI sabendo demais sobre como o feed é produzido;
- identidade editorial derivada de URL;
- modelo de conteúdo crescendo como union de protocolos;
- aquisição tratada implicitamente como HTTP fetch;
- provenance de aquisição confundida com membership editorial.

O objetivo não é reescrever o produto FeedMine.

O objetivo é substituir o caminho legado por uma arquitetura única, capaz de receber sistemas externos heterogêneos sem permitir que suas representações contaminem Selection, Publication ou Presentation.

---

## 2. Tese central

FeedMine mantém antecipadamente uma oferta editorial local limitada. Uma sessão publica segmentos imutáveis dessa oferta, e a UI navega uma projeção local dessa história.

Aquisição e preparação aumentam apenas a oferta futura; nunca reconstruem silenciosamente aquilo que o usuário já está navegando.

A v0.4 acrescenta uma segunda tese, anterior à primeira:

> External systems are heterogeneous until admission. FeedMine is homogeneous after admission.

Em forma operacional:

```text
External world
    │
    │ protocol semantics
    ▼
Connector
    │
    │ translated, versioned observations
    ▼
Acquisition Admission
    │
    ▼
Canonical FeedMine Supply
    │
    ├── identity + provenance
    ├── content projection
    ├── relations
    ├── media candidates
    └── interaction offers
    │
    ▼
Selection
    ▼
Media Preparation
    ▼
Publication
    ▼
Immutable FeedEdition
    ▼
FeedSession
    ▼
local Presentation
    ▼
SwiftUI
```

A regra mais importante continua sendo:

> quando o dedo do usuário se move, ele está navegando história local já publicada — não pilotando a internet.

---

## 3. A boundary arquitetural principal da v0.4

A linha entre `Connector` e `Canonical FeedMine Supply` é a fronteira arquitetural mais importante da v0.4.

Antes dela:

- sistemas externos são heterogêneos;
- identidade pode ser URI, DID, pubkey, GUID, CID, event ID ou outra forma;
- transporte pode ser HTTP, WebSocket, stream, sync, polling ou paginação;
- update/delete/replacement seguem regras do protocolo;
- payload pode conter semântica que FeedMine não conhece.

Depois dela:

- Selection consulta estruturas FeedMine;
- Publication congela fatos FeedMine;
- Media trabalha com candidatos e assets FeedMine;
- Presentation trabalha com payload publicado;
- SwiftUI não conhece protocol, connector, endpoint ou checkpoint.

---

## 4. Três zonas semânticas

A v0.4 divide os dados traduzidos em três zonas.

### Canonical Projection

Fatos que FeedMine efetivamente consulta, ordena, busca, seleciona ou apresenta.

Exemplos:

- headline opcional;
- summary/body projection;
- authored/modified/observed timestamps;
- language;
- primary external link quando existir;
- availability;
- search projection.

### Structured Semantics

Semânticas genéricas que FeedMine entende como conceitos próprios.

Exemplos:

- provenance;
- external identities;
- provider attribution;
- Source memberships;
- content relations;
- media candidates;
- interaction offers.

### Connector Evidence

Representações e metadata protocol-specific necessárias para replay, debug, checkpoint, precedência ou futuras traduções.

Exemplos:

- raw representation;
- connector metadata;
- connector checkpoint;
- protocol-specific identity evidence.

Regra normativa:

> Um conceito só entra no schema canônico quando FeedMine precisa compreendê-lo como conceito do FeedMine — não porque um protocolo o possui.

---

## 5. O que permanece assentado da v0.3

A v0.4 não reabre conceitualmente:

- `FeedPlan`;
- bounded bootstrap;
- `FeedEdition`;
- immutable `FeedSegment`;
- `FeedWindow`;
- `PublicationCoordinator`;
- `RunwayController`;
- `MediaPreparation`;
- `RenderContract`;
- UI consumindo `FeedSession`, não o Engine;
- network completamente fora do renderer;
- SQLite como autoridade de fatos persistentes;
- actors como autoridade de coordenação efêmera;
- publication append-only;
- exposure por `PublicationCardID`.

Mudam principalmente:

- significado de `Source`;
- identidade de `Source`;
- `OriginEntry` → `OriginRecord` + `OriginRevision`;
- Source membership versus acquisition provenance;
- `AcquisitionFrontier`;
- `FetchPurpose` → `AcquisitionPurpose` no runtime;
- boundary e unidade de commit da aquisição;
- mídia de origem como conjunto de candidatos;
- actions/capabilities como offers;
- quatro ADRs.

---

## 6. UI não consome o Engine

Regra normativa preservada:

> A UI não consome o Feed Runtime diretamente. A UI consome uma `FeedSession`.

E:

> The UI asks what the user wants and reports what the user is seeing. It never tells the Runtime how to obtain content.

É explicitamente proibido:

```text
SwiftUI ─X→ Connector
SwiftUI ─X→ Acquisition
SwiftUI ─X→ Selection
SwiftUI ─X→ PublicationCoordinator
SwiftUI ─X→ GRDB
SwiftUI ─X→ AssetStore
SwiftUI ─X→ protocol metadata
SwiftUI ─X→ acquisition target
SwiftUI ─X→ remote media
SwiftUI ─X→ identity resolution
```

---

## 7. A UI consome apresentação, não entidades internas

SwiftUI nunca recebe:

- `OriginRecord`;
- `OriginRevision`;
- connector evidence;
- external object key;
- external version key;
- `AcquisitionTarget`;
- GRDB row;
- Candidate;
- `ContentEntity`;
- `ContentCluster`;
- `FeedSegment`;
- `PublicationToken`;
- `EditorialRevision`;
- source runtime health.

Ela recebe somente valores de apresentação imutáveis e `Sendable`.

---

## 8. FeedPresentationSnapshot

A unidade entregue à UI permanece semanticamente coerente:

```swift
struct FeedPresentationSnapshot: Sendable {
    let contextKey: ContextKey
    let editionID: EditionID?
    let generation: UInt64
    let supersedesGeneration: UInt64?
    let phase: FeedPresentationPhase
    let window: FeedWindowSnapshot?
    let tailState: FeedTailPresentationState
    let refreshState: RefreshState
    let transition: FeedTransition
}
```

A UI não observa mudanças soltas de banco.

---

## 9. FeedWindowSnapshot

```swift
struct FeedWindowSnapshot: Sendable {
    let items: [FeedCardPresentation]
    let anchor: FeedWindowAnchor?
}
```

A Edition pode conter milhares de cards.

A UI mantém apenas uma janela finita.

Window shift nunca modifica a história publicada.

---

## 10. FeedCardPresentation

A v0.4 remove o pressuposto de que todo conteúdo possui uma URL web.

```swift
struct FeedCardPresentation: Identifiable, Sendable {
    let id: PublicationCardID
    let title: String?
    let primaryText: String?
    let publishedAt: Date?
    let sourceDisplayName: String?
    let providerDisplayName: String?
    let primaryAction: FeedPrimaryAction?
    let media: FeedMediaPresentation?
    let interactionSummary: PublishedInteractionSummary?
    let renderContract: RenderContract
}
```

A identidade SwiftUI permanece:

```text
PublicationCardID
```

Nunca:

- `OriginRecordID`;
- `OriginRevisionID`;
- URL;
- `ContentEntityID`;
- array position.

---

## 11. FeedPrimaryAction

`targetURL` deixa de ser obrigatório.

Conceitualmente:

```swift
enum FeedPrimaryAction: Sendable {
    case externalURL(URL)
    case localContentDetail(PublicationCardID)
    case mediaPlayback(PublishedMediaID)
    case thread(InteractionHandle)
    case connectorAction(ActionID)
}
```

Ausência de `primaryAction` é válida.

Presentation decide o gesto e a affordance.

Protocol-specific execution permanece fora da UI.

---

## 12. FeedScreenStore

Permanece deliberadamente pequeno.

Ele encaminha intenção e apresenta estado.

Ele não decide:

- qual connector usar;
- qual target ativar;
- quantos registros adquirir;
- qual stream abrir;
- qual imagem baixar;
- qual Segment carregar;
- qual protocolo executará uma ação.

---

## 13. FeedUIIntent

Métodos operacionais como `loadMore`, `fetchMore`, `subscribeRelay`, `downloadImages` ou `publishCards` não fazem parte da API UI → Runtime.

A Session recebe intenção do usuário.

Viewport continua em canal próprio por frequência.

---

## 14. FeedSessionUI

A interface pública pode continuar estreita:

```swift
protocol FeedSessionUI: Sendable {
    func updates() -> AsyncStream<FeedPresentationSnapshot>
    func send(_ intent: FeedUIIntent) async
    func submitViewport(_ observation: ViewportObservation) async
    func visual(for cardID: PublicationCardID) async -> FeedVisual
    func perform(_ actionID: ActionID) async -> InteractionResult
}
```

`perform` representa intenção explícita.

Renderização nunca depende dela.

---

## 15. Scroll não significa acquisition

Scroll produz `ViewportObservation`.

Não produz:

- `GET`;
- `REQ`;
- API pagination;
- relay subscription;
- firehose cursor advance;
- `loadMore`.

`RunwayController` traduz pressão de consumo em demanda de supply.

---

## 16. Viewport, backpressure e transition semantics

As regras da v0.3 permanecem:

- viewport telemetry é throttled/coalesced;
- intents importantes não são descartados por buffering acidental;
- snapshots explicam sua transição;
- render rematerialization preserva `PublicationCardID`;
- Edition replacement é troca explícita de história.

---

## 17. ContextKey, EditorialRevision e RenderEnvironmentRevision

A separação permanece.

`EditorialRevision` descreve regras concretas que produziram a história.

`RenderEnvironmentRevision` descreve apenas as condições de materialização visual.

Mudanças de connector implementation ou target checkpoint, por si só, não criam nova `EditorialRevision`.

Mudanças em catálogo, user selection, eligibility, scoring, sequencing ou exposure policy podem fazê-lo.

---

## 18. FeedEdition pertence à EditorialRevision

`FeedEdition` responde:

> quais publications, e em qual ordem, foram produzidas sob determinada revisão editorial?

Ela não pertence:

- ao Dynamic Type;
- ao connector;
- ao protocolo;
- ao endpoint atual;
- ao checkpoint de aquisição.

---

## 19. Rerender não é exposure

Exposure continua identificado por `PublicationCardID` e continuidade visual real.

Mudança de SwiftUI tree, local image materialization ou render environment não gera exposição falsa.

---

# Parte II — Source, identity e provenance

## 20. Source muda de significado

Na v0.4:

> `Source` é uma entidade editorial estável do FeedMine: uma unidade que pode ser catalogada, selecionada, habilitada, seguida, apresentada ou usada por um `FeedPlan`.

`Source` não diz como o conteúdo é obtido.

Portanto:

```text
SourceID != URL
SourceID != endpoint
SourceID != account ID
SourceID != protocol object ID
SourceID != acquisition target
```

Uma Source pode representar, conforme o produto:

- uma publicação;
- um feed específico;
- uma conta;
- uma comunidade;
- uma lista;
- um custom feed;
- uma hashtag curada;
- uma recipe editorial.

Não é necessário congelar hoje um `SourceKind` exaustivo.

---

## 21. Source não é Provider

`SourceID ≠ ProviderID` permanece e se torna ainda mais importante.

`Source` responde:

> por qual unidade editorial este conteúdo participa do universo FeedMine?

`Provider` responde:

> quem é atribuído como produtor/editor/autor institucional relevante para diversidade e display?

Uma Source pode produzir conteúdo de muitos Providers.

Um Provider pode participar de muitas Sources.

Provider diversity continua sendo a dimensão editorial principal do Main Feed quando aplicável.

---

## 22. SourceID é FeedMine-owned

`SourceID` deixa de ser derivado de URL canônica.

Requisitos:

- estável através de redirects;
- estável através de mudanças de endpoint;
- estável quando um binding muda sem mudança editorial;
- grande o suficiente para catálogo amplo;
- não dependente de representation externa.

Baseline candidata:

- 64-bit opaque ID, UUID/ULID equivalente, ou outra identidade interna durável;
- chave editorial explícita no catálogo quando necessária;
- nunca primeiros 32 bits de hash de URL como identidade semântica.

---

## 23. SourceBinding

`SourceBinding` é a relação declarativa entre uma Source FeedMine e um sistema externo.

Exemplos conceituais:

```text
Source "CBC News"
    ↳ syndication binding

Source "@alice"
    ↳ ActivityPub actor binding

Source "Astronomy"
    ↳ ATProto custom-feed binding

Source "Photography"
    ↳ Nostr filter binding
```

O binding pode possuir:

- connector kind;
- external principal/source identity;
- aliases;
- connector-owned configuration;
- generation/revision;
- enabled/revoked state.

---

## 24. AcquisitionTarget

`AcquisitionTarget` é a unidade operacional de trabalho capaz de produzir observações.

Pode representar:

- uma URL de syndication;
- uma API timeline;
- uma query paginada;
- um custom feed URI;
- um repo sync;
- um filtered stream;
- um conjunto de relays + filters;
- uma WebSocket subscription.

`Endpoint` é localização de rede usada pelo Target.

Endpoint não precisa ser entidade de domínio independente na baseline.

---

## 25. SourceBinding e AcquisitionTarget não são 1:1 obrigatórios

Um binding pode depender de múltiplos targets.

Múltiplos bindings podem compartilhar um target.

Exemplo conceitual:

```text
200 Sources
    ↓
25 logical filters
    ↓
3 relay connections
```

A arquitetura não cria uma conexão de rede por Source apenas porque há uma Source.

---

## 26. Binding generation

Toda configuração cuja mudança torna trabalho antigo semanticamente inválido possui uma generation/revision observável pelo admission path.

Exemplo:

```text
target T revision 6 starts
        ↓
binding changes
        ↓
target revision 7 is current
        ↓
old batch from revision 6 returns
        ↓
WriteAdmission rejects semantic mutation
```

Cancellation é otimização.

Validity é decidida no write admission.

---

## 27. External identities pertencem à fronteira

FeedMine não tenta criar uma identidade global universal.

O core admite external identities como valores opacos e namespaced pelo connector.

Conceitualmente:

```text
ExternalIdentity {
    connectorKind
    namespace
    value
    role
}
```

Roles podem distinguir, quando útil:

- principal identity;
- external object identity;
- external version identity;
- alias;
- lookup identity.

O core não interpreta o conteúdo do valor.

---

## 28. OriginRecord

`OriginRecord` representa a identidade FeedMine de um objeto lógico externo aceito pelo runtime.

Conceitualmente:

```swift
struct OriginRecord {
    let originRecordID: OriginRecordID
    let connectorScope: ConnectorScopeID
    let externalObjectKey: ExternalObjectKey
    let currentRevisionID: OriginRevisionID?
    let availability: OriginAvailability
    let firstObservedAt: Date
    let lastObservedAt: Date
}
```

Uniqueness/idempotency existe sobre a identidade externa dentro do scope apropriado do connector.

---

## 29. OriginRevision

`OriginRevision` representa uma representação imutável aceita de um `OriginRecord` em determinado estado.

```text
OriginRecord R42
    ├── Revision V1
    ├── Revision V2
    └── Revision V3 ← current for future selection
```

Conceitualmente:

```swift
struct OriginRevision {
    let originRevisionID: OriginRevisionID
    let originRecordID: OriginRecordID
    let externalVersionKey: ExternalVersionKey?
    let headline: String?
    let summary: String?
    let bodyText: String?
    let authoredAt: Date?
    let modifiedAt: Date?
    let observedAt: Date
    let language: String?
    let primaryLink: URL?
    let searchProjection: String?
}
```

`OriginRevision` é imutável.

---

## 30. Record identity ≠ revision identity

A v0.4 assume explicitamente:

```text
external logical object
            ≠
a particular version of that object
```

O connector traduz a semântica do sistema externo em:

- `externalObjectKey`;
- `externalVersionKey?`;
- precedence instruction.

O core não possui um `universalRevisionNumber`.

---

## 31. Current revision é future-facing

`OriginRecord.currentRevisionID` indica qual revision é corrente para future Selection.

Mudá-la:

- pode alterar supply futura;
- pode alterar uma futura Edition;
- não altera `PublishedCardPayload` existente;
- não reescreve Segment existente;
- não altera exposure passado.

---

## 32. Canonical projection é deliberadamente pequena

`OriginRevision` não é um union model de protocolos.

Não entram no core apenas por existirem externamente:

- protocol kind numbers;
- relay URL;
- CID como coluna específica de ATProto;
- ActivityPub-specific activity types;
- Mastodon local database IDs;
- RSS-only GUID semantics.

Entram conceitos que FeedMine usa como FeedMine.

---

## 33. Headline é opcional

Conteúdo social ou multimídia pode não ter título.

A ingestão não rejeita um record apenas por ausência de headline.

Presentation decide, por exemplo:

```text
headline exists
    → headline + excerpt/body

headline absent
    → body excerpt as primary text
```

Isso é Presentation policy.

Não protocol policy.

---

## 34. Primary link é opcional

Nem todo objeto possui representação HTTP pública.

`primaryLink` pode ser `nil`.

Ações de abertura são publicadas separadamente como `primaryAction`/interaction handle.

---

## 35. Timestamps preservam epistemologia

A v0.4 nunca transforma ausência de publication date em `Date()` como se fosse fato editorial.

Preservamos:

```text
authoredAt?   // declarado/inferido segundo contrato do connector
modifiedAt?   // idem
observedAt    // sempre FeedMine-controlled
```

Selection pode usar uma política explícita:

```text
sortDate = authoredAt ?? observedAt
```

mas sabe quando usa fallback.

---

## 36. SourceMembership

`OriginRecord` não possui obrigatoriamente um único `sourceID`.

Membership é relação.

```text
OriginRecord
    ├── member of Source A
    ├── member of Source B
    └── attributed to Provider P
```

`SourceMembership` deve preservar como a associação foi conhecida.

Conceitualmente:

```swift
struct SourceMembership {
    let originRecordID: OriginRecordID
    let sourceID: SourceID
    let membershipKind: SourceMembershipKind
    let evidenceTargetID: AcquisitionTargetID?
    let firstObservedAt: Date
    let lastObservedAt: Date
}
```

Isso evita confundir membership editorial com provenance operacional.

---

## 37. Acquisition provenance é separada de membership

O fato primário da ingestão v0.4 é:

> FeedMine observed an external record through an acquisition target, translated it into canonical content and provenance, and associated it with zero or more editorial sources.

Portanto preservamos separadamente:

- target que produziu a observação;
- binding/generation que autorizou o trabalho;
- external object/version identity;
- Source memberships resultantes;
- Provider attribution.

---

## 38. Provider attribution

Provider é relação estruturada do conteúdo.

Uma revision pode ter:

- provider principal;
- autoria individual;
- múltiplos contributors quando o produto precisar;
- attribution evidence.

Selection usa apenas os conceitos promovidos ao domínio.

Não decodifica connector metadata.

---

## 39. ContentEntity e ContentCluster permanecem relações

Canonicalization destrutiva continua proibida.

`ContentEntity` pode reconhecer equivalência em um domínio de confiança.

`ContentCluster` representa relação editorial soft com:

- confidence;
- method;
- version.

Erro de dedupe continua reversível.

`OriginRecord` e suas revisions não são destruídos para formar a entidade.

---

## 40. Cross-protocol syndication

O mesmo conteúdo pode aparecer:

- em RSS;
- numa conta ActivityPub;
- num custom feed;
- num agregador;
- em outro mecanismo futuro.

A arquitetura preserva cada origin/provenance.

`ContentEntity`/`ContentCluster` expressam a relação sem apagar a evidência.

---

## 41. ContentRelation

A v0.4 promove um conjunto pequeno de relações editoriais genéricas.

Baseline candidata:

```text
replyTo
repostOf
quoteOf
references
```

A origem externa pode ter mecanismos totalmente diferentes.

O connector traduz apenas quando a relação possui significado FeedMine.

---

## 42. Relações não são ActivityStreams reimplementado

O domínio não tenta transportar todos os verbos, NIPs, collections ou activity types existentes.

Regra:

> Se a relação altera como FeedMine entende, seleciona ou apresenta o conteúdo, ela pode ser promovida. Caso contrário permanece em Connector Evidence.

---

## 43. Availability e tombstones

`OriginRecord` possui estado future-facing de disponibilidade.

Baseline conceitual:

```text
available
updated
removed
revoked
unknown
```

O nome físico final será fechado em ADR.

Delete upstream não implica delete de publication.

---

## 44. Upstream mutation não reescreve história

Regra normativa:

```text
upstream mutation
        ↓
future-facing OriginRecord state

published history
        unchanged
```

Se um dia existir revogação obrigatória por segurança/direitos, ela deve ser uma `PublicationOverlayPolicy` explícita.

Nunca mutation silenciosa de Segment histórico.

---

# Parte III — Media e interaction capabilities

## 45. MediaCandidate

A origem não é reduzida a `imageURL?` e `audioURL?`.

`OriginRevision` pode possuir `MediaCandidate[]`.

Fatos genéricos candidatos:

```text
role
media class
mime type?
dimensions?
duration?
locator
alternate representations
integrity/hash evidence?
```

O locator pode ser remoto antes da preparação.

Nunca chega ao renderer.

---

## 46. MediaPreparation continua separada

Fluxo:

```text
MediaCandidate[]
        ↓
MediaPreparation
        ↓
publication chooses representation
        ↓
PublishedMediaSet
        ↓
local materialization
```

`MediaPreparation` decide disponibilidade, dimensões, suitability e asset versions.

`RenderContract` decide apresentação.

---

## 47. PublishedMediaSet

A v0.4 generaliza `PublishedMediaRef` para zero ou mais representações publicadas quando necessário.

Conceitualmente:

```swift
struct PublishedMediaSet {
    let primary: PublishedMediaRef?
    let alternates: [PublishedMediaRef]
}
```

Baseline de card pode usar apenas `primary`.

A estrutura não obriga download integral de áudio/vídeo antes de publicar um card.

---

## 48. Card offline determinístico ≠ baixar a internet inteira

Publication precisa garantir representação local suficiente para renderizar o card de forma determinística.

Isso pode ser:

- thumbnail local;
- waveform/metadata local;
- placeholder determinístico;
- poster frame local;
- texto e geometry contract.

Playback iniciado explicitamente pelo usuário pode acessar network segundo policy.

Scroll não pode.

---

## 49. InteractionOffer

Capabilities não entram na UI como `isMastodon`, `isNostr` ou `isBluesky`.

O conteúdo publicado pode oferecer ações sem expor o protocolo.

Exemplos de semântica FeedMine:

```text
open
play
openDiscussion
showReplies
follow
reply
repost
quote
```

Nem todas precisam existir na baseline.

---

## 50. ActionID

Uma interaction offer publicada referencia um handle interno:

```text
repost
    actionID = A792
```

Ao executar:

```text
SwiftUI
    ↓ explicit intent
FeedSessionUI
    ↓
InteractionCoordinator
    ↓
connector/action executor owning A792
    ↓
network/signing/etc.
```

SwiftUI nunca executa client protocol code diretamente.

---

## 51. Feed Runtime baseline é read/ingestion

Escopo normativo:

> The Feed Runtime v0.4 is a read/ingestion runtime. It is interaction-ready, but it does not make protocol write semantics part of the feed core.

Isso permite leitura de múltiplos ecossistemas sem exigir account/credential/federation framework universal agora.

---

## 52. Connector family ≠ participation model

Consumir uma API de aplicação e participar diretamente do protocolo distribuído são responsabilidades diferentes.

Exemplos conceituais:

```text
Mastodon API Connector
≠
ActivityPub Federation Connector

Bluesky AppView Connector
≠
direct repository synchronization
```

Ambos podem produzir `AcquisitionBatch`.

A escolha não contamina downstream.

---

# Parte IV — Publication e imutabilidade

## 53. PublishedOrigin

A publication congela attribution e membership escolhidos para aquela publicação.

Conceitualmente:

```swift
struct PublishedOrigin {
    let originRecordID: OriginRecordID
    let originRevisionID: OriginRevisionID
    let sourceID: SourceID?
    let providerID: ProviderID?
    let sourceDisplayName: String?
    let providerDisplayName: String?
}
```

Atualização futura de catálogo não altera attribution histórica.

---

## 54. PublishedCardPayload

Conceitualmente:

```text
PublicationCardID
OriginRecordID
OriginRevisionID
ContentEntityID?
ContentClusterID?
PublishedOrigin
PublishedText
PublishedTimestamp
PublishedMediaSet
RenderContract
PublishedPrimaryAction?
PublishedInteractionSummary?
PublicationMetadata
```

A publication não precisa de:

- protocol;
- RSS GUID;
- AT CID como campo próprio;
- Nostr kind;
- Mastodon local ID;
- relay URL;
- feed URL.

---

## 55. Publication congela a Revision

Exemplo:

```text
external object updated
R42 V1 → V2

Edition E10 contains:
    P100 → R42/V1

future Edition E11 may contain:
    P555 → R42/V2
```

E10 continua reproduzível.

---

## 56. PublicationSchemaVersion

Continua independente de Selection e Editorial policy versions.

Quando o schema publicado passa de `OriginEntryID` para `OriginRecordID + OriginRevisionID`, isso é evolução explícita de `PublicationSchemaVersion`.

---

## 57. FeedEdition e FeedSegment permanecem imutáveis

A Edition cresce apenas por append de Segments imutáveis.

Nenhuma upstream update altera um Segment já commitado.

Nenhum connector publica.

Nenhum media resolver publica.

Nenhuma Selection publica.

`PublicationCoordinator` continua sendo o único produtor de história publicada.

---

## 58. Determinismo permanece obrigatório

Selection possui tie-breaking explícito.

Publication preserva:

- edition seed;
- segment seed;
- policy/revision identity;
- exact `OriginRevisionID`;
- exact media version.

Uma publication deve ser reproduzível e explicável.

---

# Parte V — Concurrency, admission e storage

## 59. AcquisitionBatch

A unidade uniforme produzida por connectors é um batch já traduzido para admission.

Conceitualmente:

```swift
struct AcquisitionBatch: Sendable {
    let targetID: AcquisitionTargetID
    let targetRevision: UInt64
    let observations: [TranslatedObservation]
    let memberships: [TranslatedMembership]
    let relations: [TranslatedRelation]
    let mediaCandidates: [TranslatedMediaCandidate]
    let interactionOffers: [TranslatedInteractionOffer]
    let nextCheckpoint: ConnectorCheckpoint?
}
```

O shape físico final pode ser diferente.

A semântica é obrigatória.

---

## 60. Transactional admission

Commit conceitual:

```text
receive batch
    ↓
validate target/binding generation
    ↓
dedupe external object/version identity
    ↓
apply OriginRecord changes
    ↓
insert immutable OriginRevision(s)
    ↓
apply current-revision CAS
    ↓
apply memberships/relations/media/offers
    ↓
advance checkpoint
    ↓
COMMIT
```

Checkpoint e mutations aceitas pertencem à mesma unidade transacional quando o checkpoint representa exatamente aquele progresso.

---

## 61. Checkpoint atomicity

É proibido persistir:

```text
checkpoint = 850
```

quando o conteúdo confirmado até 850 não foi persistido na mesma unidade de consistência.

Crash recovery nunca deve retomar depois de conteúdo que o runtime não commitou.

---

## 62. ConnectorCheckpoint é opaque para o core

O runtime persiste e devolve checkpoint ao connector.

Não interpreta:

- sequence numbers específicos;
- relay cursors;
- HTTP validators;
- repo revisions;
- page tokens.

Checkpoint possui:

- connector/version ownership;
- target association;
- serialization schema version.

---

## 63. Out-of-order usa connector precedence

Não existe ordering universal.

O connector traduz a observação em uma instruction de precedência adequada.

Exemplos conceituais:

```text
makeCurrent if current == V7
historicalOnly
duplicate
replaceCurrent if connectorRuleAllows
```

A transação aplica compare-and-swap quando necessário.

---

## 64. Cancellation continua sendo otimização

Stale tasks podem completar.

Antes de efeito persistente semanticamente relevante, admission verifica:

- target ainda existe;
- target revision/generation ainda é corrente;
- binding não foi revogado;
- source state permite persistência;
- connector result é admissível.

---

## 65. Revocation

Source, Binding e Target podem possuir estados diferentes.

Exemplo:

```text
Source remains cataloged
Binding disabled
Target revoked
```

Isso não exige deletar Source.

WriteAdmission decide quais efeitos de trabalho antigo ainda são permitidos.

---

## 66. SQLite authority

Regra preservada:

> SQLite é autoritativo para fatos persistentes. Actors são autoritativos para coordenação efêmera.

Persistente inclui:

- Source/Binding catalog facts;
- AcquisitionTarget runtime configuration quando durável;
- OriginRecord;
- OriginRevision;
- memberships;
- relations;
- media candidates/preparation;
- interaction offers/action handles quando necessários;
- publication;
- exposure facts;
- checkpoints;
- connector evidence conforme retention.

---

## 67. Armazenamento físico

Conceitualmente:

```text
catalog.sqlite
runtime.sqlite
existing durable user storage
asset filesystem
```

Não criamos bancos extras apenas por simetria.

---

## 68. catalog.sqlite

Read-mostly.

Contém conceitualmente:

- `Source`;
- `Provider`;
- `SourceBinding` declarativo;
- aliases editoriais;
- taxonomy;
- language;
- region;
- media/category descriptors;
- catalog quality;
- source metadata;
- taxonomy edges;
- catalog placements;
- FTS;
- `CatalogGeneration`.

O catálogo é uma camada de produto, não uma coleção de URLs.

---

## 69. runtime.sqlite

Contém conceitualmente:

### Acquisition runtime

- `AcquisitionTarget`;
- target revision/generation;
- connector checkpoints;
- bounded health/telemetry.

### Canonical supply

- `OriginRecord`;
- `OriginRevision`;
- external identities/aliases necessários;
- `SourceMembership`;
- `ContentRelation`;
- entity/cluster relations;
- `MediaCandidate`;
- `InteractionOffer`;
- connector evidence/raw representation sob retention policy.

### Media

- preparation state;
- asset versions;
- local materialization metadata.

### Publication

- Edition;
- Segment;
- PublishedCardPayload;
- Session/checkpoint state.

### History

- exposure facts;
- bounded consumed projections quando materializadas.

---

## 70. Connector-specific JSON permitido

São aceitáveis payloads connector-owned, versionados, para:

```text
connector_metadata
raw_representation
connector_checkpoint
```

Três proibições são normativas:

```text
Selection must not decode it.
Publication must not decode it.
Presentation must not decode it.
```

Se Selection precisa de uma propriedade que existe apenas ali, devemos decidir se ela é um novo conceito FeedMine.

---

## 71. Durability classes

As classes da v0.3 permanecem:

- durable user state;
- bounded runtime history;
- reconstructible;
- ephemeral.

`OriginRevision` pode ser reconstructible quando não protegido.

Connector raw evidence pode ter retention ainda mais agressiva que canonical supply.

---

## 72. Durable nunca depende de reconstructible

Remover raw representation ou revisions não protegidas não pode destruir semanticamente:

- bookmark;
- PublishedCardPayload;
- active Edition checkpoint;
- user collection;
- user-visible read state.

Publication contém os valores congelados necessários à sobrevivência.

---

## 73. Retention roots

Podem proteger:

- active Edition;
- checkpointed Edition;
- durable user object;
- pinned content;
- action state ainda necessário;
- diagnostics explicitamente pinados.

Não haverá cascade destrutivo de connector evidence para publication/user state.

---

## 74. Runtime writes e WAL

`runtime.sqlite` usa `GRDB DatabasePool` + WAL.

SQLite continua serializando writes.

Telemetry frequente usa batching/coalescing.

Admission e Publication commits permanecem transações explícitas de domínio.

---

# Parte VI — Planning, Selection e Runway

## 75. FeedPlan permanece policy-based

Um Context resolve um `ResolvedFeedPlan` composto por:

- CandidateProvider;
- EligibilityPolicy;
- ScoringPolicy;
- SequencingPolicy;
- ExposurePolicy;
- AcquisitionPolicy.

Um engine, várias policies.

---

## 76. CandidateProvider opera sobre canonical supply

Selection trabalha com estruturas FeedMine:

- current `OriginRevision`;
- `OriginRecord` availability;
- Source memberships;
- Provider;
- ContentEntity/Cluster;
- ContentRelation;
- media preparation facts;
- canonical timestamps;
- indexed search projection.

Selection nunca precisa saber qual connector produziu o item.

---

## 77. Source View Plan

CandidateProvider pode consultar:

```text
SourceMembership(sourceID)
```

Não assume `OriginRecord.sourceID` 1:1.

AcquisitionPolicy pode demandar supply daquela Source, mas o planner resolve isso em Binding/Targets.

---

## 78. Quality não recebe network health

Editorial quality continua separada de acquisition health.

Latency, reconnect rate, HTTP failure streak ou relay availability influenciam quando/como adquirir.

Não definem o valor editorial intrínseco da Source.

---

## 79. Sequenceable supply

A cadeia permanece distinguindo:

```text
Raw/Canonical Supply
MediaPreparedSupply
SequenceableSupply
PublishedSupply
DecodedVisualWindow
```

Na v0.4, `RawSupply` não significa raw protocol blob.

Significa canonical local supply admitida ainda não necessariamente preparada/publicável.

---

## 80. RunwayEstimator

Continua barato e conservador.

Pode usar:

- eligible counts;
- Provider histogram;
- cluster histogram;
- media-prepared counts;
- visual distance;
- deficits.

Não decodifica connector metadata.

---

## 81. Runway pede supply, não transport

`RunwayController` pode produzir semanticamente:

```text
replenish this supply deficit
```

Nunca:

```text
GET this URL
open this relay
fetch page 4
```

`AcquisitionPlanner` traduz demanda em targets.

---

# Parte VII — Acquisition e Connectors

## 82. AcquisitionFrontier muda de domínio

Na v0.4:

> `AcquisitionFrontier` é um conjunto finito de acquisition work/targets ativos ou elegíveis, derivado de demanda editorial e budgets.

Não é uma lista de Source URLs.

---

## 83. Frontier pode compartilhar work

A Frontier pode deduplicar ou agrupar trabalho quando múltiplas Sources dependem do mesmo recurso operacional.

Exemplos:

- uma conexão para múltiplos filters;
- uma stream para múltiplas identities;
- uma API page contendo muitos Providers;
- um endpoint agregador.

---

## 84. Frontier classes permanecem úteis

Baseline:

```text
head
active
exploration
```

Mas a unidade classificada é acquisition work/target, não URL editorial.

---

## 85. BootstrapPlan continua bounded

Budgets podem incluir:

- target budget;
- operation/request budget;
- byte budget;
- unique-host budget;
- wall-clock budget;
- per-host request budget;
- redirect budget;
- connection budget;
- minimum publication gate;
- target publication gate.

Protocol-specific budgets podem existir dentro do connector sem aparecer no Feed Runtime core.

---

## 86. AcquisitionPurpose

`FetchPurpose` é estreito demais no runtime multiprotocolo.

Baseline candidata:

```text
userInitiated
bootstrap
activeRunway
speculative
backgroundMaintenance
```

Media pode manter sub-purpose próprio quando necessário.

Dentro do `SyndicationConnector`, `FetchPurpose` pode continuar existindo como detalhe HTTP.

---

## 87. Privacy budget

Budget pode medir:

- bytes;
- unique hosts;
- operations per host;
- redirects;
- open connection count;
- acquisition purpose;
- connector-specific cost metric promovida apenas se tiver significado global de privacy/resource budget.

Não transformamos relay/protocol metadata em scoring editorial.

---

## 88. FeedConnector boundary

A abstração universal deve ser estreita.

Conceitualmente:

```swift
protocol FeedConnector: Sendable {
    func acquire(
        target: AcquisitionTarget,
        checkpoint: ConnectorCheckpoint?,
        purpose: AcquisitionPurpose
    ) -> AsyncThrowingStream<AcquisitionBatch>
}
```

A assinatura final pode variar.

A semântica é:

- runtime inicia/cancela work;
- connector produz batches traduzidos;
- connector owns external semantics;
- admission owns persistence validity.

---

## 89. Finite e continuous acquisition usam a mesma boundary

Exemplos:

```text
Syndication:
    emits one batch
    finishes

Streaming connector:
    emits batch
    batch
    batch
    continues until cancellation

Backfill + live:
    backfill batches
    live batches
```

Coordinator não precisa conhecer o mecanismo externo.

---

## 90. Concrete by default

A v0.4 não cria um `UniversalProtocolAdapterFramework`.

Primeiro connector pode ser:

```text
Connectors/
    Syndication/
        SyndicationConnector.swift
        SyndicationTranslator.swift
        SyndicationHTTP.swift
```

Parser, HTTP validators, FeedKit models e transport details ficam ali.

---

## 91. Protocol-specific imports são confinados

Regra de dependency testing:

> FeedKit, ATProto SDKs, Nostr libraries, Mastodon API models e outros protocol-specific imports são proibidos fora de `Connectors/`.

Exceções precisam ser deliberadas e documentadas.

Isso é boundary enforcement, não preferência de estilo.

---

## 92. Syndication Connector

O legado RSS/Atom é o primeiro connector, não a definição universal de acquisition.

Ele pode continuar contendo:

- HTTP conditional requests;
- redirect handling;
- FeedKit;
- parser normalization;
- syndication identity rules;
- syndication-specific revision/fingerprint logic.

Media probing que não é parsing pertence a `MediaPreparation`.

---

## 93. Connector Evidence é cold

Protocol payloads e metadata específica podem ser preservados para:

- debugging;
- replay;
- migration;
- improving translation;
- evidence.

Mas não entram no hot path.

---

## 94. Hot path depois de admission

Depois de admission, o caminho esperado é:

```text
indexed SQLite columns
normalized relations
small IDs
prepared local media
immutable publication payloads
```

Selection não executa:

```text
decode JSON blob
interpret Nostr tags
resolve ActivityPub actor
inspect ATProto record schema
parse RSS enclosure
```

Essas operações terminam antes da boundary.

---

# Parte VIII — Session, refresh e exposure

## 95. FeedSession continua sem saber protocolos

`FeedSession` possui conceitualmente:

- current ContextKey;
- current EditorialRevision;
- current PublicationToken;
- current EditionID;
- SessionCursor;
- current FeedWindow;
- current RenderEnvironmentRevision;
- Runway state.

Ela não contém:

- SQL inline;
- parsing;
- connector switch;
- transport details;
- protocol-specific identities.

---

## 96. Initial presentation flow permanece local-first

Ao aparecer:

```text
restore compatible Edition
    → display
```

Sem rede.

Ou:

```text
local SequenceableSupply
    → Selection
    → Publication
    → display
```

Sem rede.

Só sem publication e sem supply suficiente:

```text
initialSupply demand
    → bounded BootstrapPlan
```

---

## 97. Refresh cria successor Edition

Refresh explícito não modifica a Edition atual.

Pode demandar acquisition, mas a Edition anterior permanece utilizável durante o trabalho.

Nova history só aparece por swap explícito para successor Edition.

---

## 98. Refresh não espera todo acquisition work

Refresh termina por publication gate e bounded attempt.

Não espera:

- todo catálogo;
- todo target;
- todo stream;
- toda mídia especulativa;
- background maintenance.

---

## 99. Passive catalog/binding changes

Mudança passiva de catálogo, SourceBinding ou endpoint não substitui a Edition visível imediatamente.

A Edition mantém sua `EditorialRevision` durante a navegação corrente.

Nova revisão pode valer em refresh/context change/lifecycle conforme policy.

---

## 100. Exposure facts

Exposure registra publication identity e origin frozen identity quando útil.

Conceitualmente:

```text
PublicationCardID
OriginRecordID
OriginRevisionID
ContentEntityID?
ContentClusterID?
HistoryScope
enteredViewportAt
centerCrossedAt
leftViewportAt
direction
maxVisibleFraction
dwellMs
```

Exposure não depende de protocol identity.

---

## 101. Card action

Ao tocar um card, UI executa uma `FeedPrimaryAction` ou `ActionID` publicado.

O history write não bloqueia a navegação/ação.

A resolução protocol-specific do ActionID ocorre atrás da Session/Interaction boundary.

---

# Parte IX — Shadow, observability e SLOs

## 102. Shadow V2/V0.4

Primeiro shadow não executa dois universos de aquisição completos simultaneamente.

Durante migração de RSS:

```text
Legacy acquisition
      ↓
shared local translated input
   ↙               ↘
Legacy             V0.4 shadow
UI                 local-only
```

A boundary de tradução pode ser usada para espelhar input sem duplicar network.

---

## 103. Observabilidade de supply

Distinguir:

- admitted canonical supply;
- current revisions;
- media prepared supply;
- sequenceable supply;
- published supply;
- decoded visual window.

Também medir:

- acquisition operation latency;
- admission transaction latency;
- duplicate/rejected stale batch rate;
- candidate query latency;
- selection latency;
- segment commit latency;
- FeedWindow materialization;
- asset decode;
- MainActor apply;
- runway estimator cost;
- scroll hitches.

---

## 104. Privacy observability

Local diagnostics pode medir:

- operations by `AcquisitionPurpose`;
- bytes by purpose;
- unique hosts;
- requests per host;
- redirects;
- connection count/time quando útil;
- media speculation waste;
- connector-specific operation counts.

Sem necessidade de tracking remoto do usuário.

---

## 105. SLOs iniciais

Metas da v0.3 continuam, com novos invariants:

```text
Warm presentation available             <250 ms p50
Warm presentation available             <500 ms p95
Local prepared Context switch           <100 ms p50
Candidate query                         <20 ms p95
MainActor presentation apply            <4 ms
Network initiated by renderer           0
Protocol decoding in Selection          0
Protocol decoding in Publication        0
Protocol decoding in Presentation       0
Blocking disk I/O in View body          0
Post-publication ordering mutation      0
Post-publication editorial mutation     0
Publication from stale epoch            0
Checkpoint ahead of admitted content    0
```

---

# Parte X — Dependency rules e code structure

## 106. Architectural dependency rules

Permitido:

```text
SwiftUI
    ↓
FeedScreenStore
    ↓
FeedSession
    ↓
Publication / Runway / Exposure / Interaction

Runway
    ↓
Selection / Acquisition demand

Selection
    ↓
FeedPlan / Canonical repositories

Acquisition Planner
    ↓
Catalog / SourceBinding / AcquisitionTarget

Acquisition Coordinator
    ↓
Connectors
    ↓
AcquisitionBatch
    ↓
Admission / Canonical repositories

Media
    ↓
Canonical repositories / Asset filesystem
```

---

## 107. Dependências proibidas

```text
SwiftUI → Connector
SwiftUI → GRDB
SwiftUI → Acquisition
SwiftUI → Selection
SwiftUI → AssetStore
Selection → connector metadata
Selection → protocol SDK
Publication → connector metadata
Presentation → connector metadata
Acquisition → Publication
Media → Publication
OriginRecord eviction → PublishedCard deletion
OriginRevision eviction → Bookmark deletion
Source endpoint change → SourceID change
```

---

## 108. Estrutura de arquivos candidata

```text
FeedRuntime/
│
├── Core/
│   ├── FeedContext.swift
│   ├── FeedPlan.swift
│   ├── FeedIntent.swift
│   ├── FeedIdentifiers.swift
│   ├── PublicationToken.swift
│   └── FeedRuntimeConfiguration.swift
│
├── Content/
│   ├── OriginRecord.swift
│   ├── OriginRevision.swift
│   ├── ExternalIdentity.swift
│   ├── SourceMembership.swift
│   ├── ContentRelation.swift
│   ├── MediaCandidate.swift
│   └── InteractionOffer.swift
│
├── Acquisition/
│   ├── AcquisitionTarget.swift
│   ├── AcquisitionBatch.swift
│   ├── AcquisitionFrontier.swift
│   ├── AcquisitionFrontierBuilder.swift
│   ├── BootstrapPlan.swift
│   ├── AcquisitionDemand.swift
│   ├── AcquisitionPlanner.swift
│   ├── AcquisitionCoordinator.swift
│   ├── AcquisitionPurpose.swift
│   └── WriteAdmissionPolicy.swift
│
├── Connectors/
│   └── Syndication/
│       ├── SyndicationConnector.swift
│       ├── SyndicationTranslator.swift
│       └── SyndicationHTTP.swift
│
├── Planning/
│   ├── FeedPlanResolver.swift
│   ├── CandidateProvider.swift
│   ├── EligibilityPolicy.swift
│   ├── ScoringPolicy.swift
│   ├── SequencingPolicy.swift
│   ├── ExposurePolicy.swift
│   └── AcquisitionPolicy.swift
│
├── Selection/
│   ├── Candidate.swift
│   ├── CandidateQuery.swift
│   ├── QualityScorer.swift
│   ├── EditorialSequencer.swift
│   ├── SequenceValidator.swift
│   └── SelectionEngine.swift
│
├── Media/
│   ├── MediaPreparation.swift
│   ├── MediaResolver.swift
│   ├── MediaPolicy.swift
│   ├── PublishedMediaRef.swift
│   ├── PublishedMediaSet.swift
│   ├── AssetStore.swift
│   ├── ImageMaterializer.swift
│   └── DecodedImageCache.swift
│
├── Publication/
│   ├── PublishedCardPayload.swift
│   ├── PublishedOrigin.swift
│   ├── PublishedInteractionSummary.swift
│   ├── RenderContract.swift
│   ├── FeedEdition.swift
│   ├── FeedSegment.swift
│   ├── FeedWindow.swift
│   ├── SessionCursor.swift
│   └── PublicationCoordinator.swift
│
├── Interaction/
│   ├── ActionID.swift
│   ├── FeedPrimaryAction.swift
│   └── InteractionCoordinator.swift
│
├── Runway/
│   ├── RunwayDemand.swift
│   ├── RunwayEstimator.swift
│   ├── RunwayMetrics.swift
│   ├── RunwayPolicy.swift
│   └── RunwayController.swift
│
├── Session/
│   ├── FeedSession.swift
│   ├── FeedSessionUI.swift
│   ├── FeedSessionState.swift
│   ├── SessionCheckpoint.swift
│   ├── FeedPresentationSnapshot.swift
│   ├── FeedWindowSnapshot.swift
│   └── ViewportObservation.swift
│
├── Storage/
│   ├── RuntimeDatabase.swift
│   ├── RuntimeMigrations.swift
│   ├── RuntimeWriteCoordinator.swift
│   ├── OriginRepository.swift
│   ├── MembershipRepository.swift
│   ├── ContentRelationRepository.swift
│   ├── ExposureRepository.swift
│   ├── AcquisitionRepository.swift
│   ├── MediaRepository.swift
│   └── EditionRepository.swift
│
├── Background/
│   └── BackgroundFeedRefresh.swift
│
└── Diagnostics/
    ├── FeedSignposts.swift
    ├── FeedRuntimeMetrics.swift
    └── ShadowComparator.swift
```

No app/UI:

```text
ViewModels/
└── FeedScreenStore.swift

Views/
├── FeedScreen.swift
└── FeedCardView.swift
```

---

## 109. O que não criaremos agora

Não criar na baseline:

- universal ProtocolRegistry;
- dynamic connector plugins;
- DI container global;
- schema registry universal;
- universal actor graph;
- cross-protocol account resolver;
- universal canonical URL service;
- federation engine;
- credentials framework genérico;
- scripting language de connectors;
- automatic global identity reconciliation.

Concrete by default.

Promote abstractions only after repeated evidence.

---

# Parte XI — Os sete ADRs

## 110. ADR-001 — Publication, Edition & Media Identity

Deve fechar:

- FeedEdition;
- FeedSegment;
- `PublishedCardPayload`;
- `PublishedOrigin`;
- freeze de `OriginRecordID + OriginRevisionID`;
- `PublishedMediaRef` / `PublishedMediaSet`;
- `FeedPrimaryAction`;
- FeedWindow/FeedWindowSnapshot;
- SessionCursor;
- anchoring;
- FeedTransition;
- PublicationSchemaVersion;
- asset version identity;
- exact restore;
- refresh → successor Edition;
- local-only card media materialization;
- relação entre publication e RenderEnvironment;
- semântica de interaction summary congelada.

---

## 111. ADR-002 — Context & Revision Model

Permanece essencialmente como v0.3.

Deve fechar:

- ContextKey;
- EditorialRevision;
- RenderEnvironmentRevision;
- CatalogGeneration;
- policy versions;
- SelectionSchemaVersion;
- PublicationEpoch;
- PublicationToken;
- Context switching;
- Edition replacement boundaries;
- passive revision changes;
- refresh com mesma EditorialRevision;
- lifecycle behavior.

Deve deixar explícito que connector/target checkpoint não é `EditorialRevision` por si só.

---

## 112. ADR-003 — Content Identity, Source & Provenance

Passa a fechar:

- significado normativo de `Source`;
- `SourceID` FeedMine-owned;
- Source vs Provider;
- `SourceBinding`;
- `AcquisitionTarget` enquanto distinção conceitual;
- `OriginRecord`;
- immutable `OriginRevision`;
- external object identity;
- external version identity;
- aliases;
- authorship/provider attribution;
- Source memberships;
- acquisition provenance;
- ContentEntity;
- ContentCluster;
- canonical `ContentRelation`;
- optional headline/link;
- authored/modified/observed timestamp semantics;
- cross-protocol syndication;
- migration de legacy FeedItem/FeedSource identity.

Princípio obrigatório:

> original external evidence is preserved; FeedMine canonicalization is additive and reversible where equivalence is uncertain.

---

## 113. ADR-004 — Durability, Retention & Dependency Graph

Permanece em essência.

Deve incorporar:

- `OriginRecord`/Revision retention;
- connector evidence retention;
- SourceBinding/Target durability;
- checkpoint retention;
- ActionID/interaction state retention;
- publication survival após raw evidence eviction.

Princípio obrigatório:

> durable never depends on reconstructible for semantic survival.

---

## 114. ADR-005 — Connectors, Acquisition Frontier, Bootstrap & Privacy

Passa a fechar:

- Connector boundary;
- `AcquisitionTarget`;
- finite versus continuous acquisition;
- `AcquisitionFrontier` sobre acquisition work;
- target sharing/coalescing;
- bootstrap completion;
- target/request/byte/host/connection budgets;
- redirects;
- per-host concurrency;
- `AcquisitionPurpose`;
- media speculation;
- background acquisition;
- checkpoint ownership/schema;
- baseline read/ingestion;
- separation between connector family and network participation model.

Números finais continuam tunáveis.

---

## 115. ADR-006 — Concurrency, Idempotency & Write Admission

Passa a fechar:

- transactional `AcquisitionBatch` admission;
- target/binding generation checks;
- external object/version uniqueness;
- revision CAS;
- connector precedence instruction;
- checkpoint atomicity;
- stale streaming work;
- revocation;
- tombstones/deletion requests;
- cancellation semantics;
- single-flight por Edition;
- append serialization;
- Publication tail validation;
- PublicationToken validation.

Precisa provar pelo menos:

```text
A → B → A late
A → A concurrent append
disable → old finite acquisition returns
delete/revoke → old stream emits
checkpoint N → crash before mutation commit
backfill older revision arrives after newer current revision
```

---

## 116. ADR-007 — Exposure & History Semantics

Permanece essencialmente como v0.3.

Atualiza apenas origin references para:

- `OriginRecordID`;
- `OriginRevisionID`.

Deve fechar:

- ViewportObservation;
- throttle/coalescing;
- PublicationCardID continuity;
- rerender sem fake exposure;
- center crossing;
- dwell;
- fast fling;
- HistoryScope;
- consumed projections;
- cross-surface effects;
- cardOpened/action semantics;
- exposure retention.

---

## 117. Ordem dos ADRs

A ordem recomendada permanece:

```text
ADR-003 — Content Identity, Source & Provenance
        ↓
ADR-002 — Context & Revision
        ↓
ADR-001 — Publication & Media Identity
        ↓
ADR-006 — Concurrency & Write Admission
        ↓
ADR-004 — Durability & Retention
        ↓
ADR-007 — Exposure & History
        ↓
ADR-005 — Connectors / Acquisition / Bootstrap / Privacy
```

Primeiro definimos o que as coisas são.

Depois o que congelamos.

Depois quem pode escrever e como sobrevive.

Por fim, como o estoque é adquirido.

---

# Parte XII — Migration e implementação

## 118. Interpretação do release/1.0

O legacy é evidência de produção, não foundation semântica a copiar.

| Implementação atual | Aprendizado | Decisão v0.4 |
|---|---|---|
| `FeedSource.id = normalized URL` | excelente simplificação RSS | `SourceID` FeedMine-owned; URL vira binding/target |
| `CatalogIdentity.sourceKey(URL)` | catálogo já possui camada própria, mas root identity ainda é feed | preservar catálogo; separar identidade editorial de aquisição |
| `FeedItem.generateID(sourceURL + guid/link)` | origin identity depende de localização | external object key + `OriginRecordID` |
| `FeedItem` acumulando YouTube/Reddit/podcast metadata | union model cresce naturalmente | translation no Connector; canonical model pequeno |
| `MediaKind = text/video/audio/forum` | mistura medium com natureza editorial | separar media characteristics de taxonomy |
| RSS fetcher faz HTTP + parse + translation + probing | fronteira existe mas concentra funções | `SyndicationConnector`; probing não-parser vai a MediaPreparation |
| FeedEngine possui abstrações FeedFetcher/FeedParsing | nomes genéricos, semântica RSS | mantê-las internas ao connector se úteis |
| `PreparedFeedCard` | preparar antes de renderizar funciona | preservar princípio; publication possui identidade própria |
| presentation ID == feed item ID | publication e origin colapsados | `PublicationCardID` separado |
| multiple legacy/fallback display paths | migration parcial cria comportamento divergente | todas surfaces V2 usam mesma Presentation boundary |
| missing publication date → `Date()` | authored e observed colapsados | separar `authoredAt?` e `observedAt` |

---

## 119. Ordem posterior de implementação

Depois dos ADRs:

### Fase 1 — Identity + Storage foundation

- SourceID migration model;
- SourceBinding model;
- OriginRecord/OriginRevision;
- Provider;
- memberships/relations;
- runtime DB.

### Fase 2 — Context + FeedPlan

- ContextKey;
- revisions;
- policy bundles.

### Fase 3 — Local Selection

Sem internet e sem connector dependency.

### Fase 4 — Publication primitive

- Edition;
- Segments;
- PublicationCoordinator;
- freeze de exact revision.

### Fase 5 — Session/UI contract + Exposure

- FeedSession;
- Cursor;
- FeedPresentationSnapshot;
- Viewport.

### Fase 6 — Media

- MediaCandidate;
- MediaPreparation;
- PublishedMediaSet;
- local materializer.

### Fase 7 — Local Runway

- estimator;
- controller;
- starvation states.

### Fase 8 — Acquisition contracts with fake connector

- AcquisitionTarget;
- AcquisitionBatch;
- Admission;
- checkpoints;
- target generation;
- fake finite + continuous connector.

### Fase 9 — Syndication Connector

- URLSession;
- FeedKit;
- validators;
- syndication identity/revision translation.

### Fase 10 — Input-mirrored Shadow

Legacy acquisition alimenta V0.4 local-only.

### Fase 11 — Main Feed V0.4 UI

FeedScreenStore passa a consumir FeedSession.

### Fase 12 — V0.4-owned Syndication Network Experiment

Sessões/builds separados.

### Fase 13 — Secondary FeedPlans

Source, Collection, Bookmark, Search, Smart Feed etc.

### Fase 14 — Background/resource adaptation

Low Power, Low Data, thermal, memory, BGAppRefresh.

### Fase 15 — TestFlight candidate

V0.4 runtime candidata a default.

### Fase 16 — Legacy removal

FeedStore/Reservoir/compatibility paths removidos.

### Fase 17 — Second-ecosystem architecture proof

Antes de implementação ampla de outro protocolo, escrever um connector executable-design/fixture demonstrando:

- external object/version translation;
- SourceBinding/Target mapping;
- streaming ou pagination semantics;
- relations/media/offers;
- zero downstream protocol branches.

Não é necessário implementar todo o protocolo para validar a boundary.

---

## 120. Critérios para não deixar V0.4 virar FeedStore 2

Não aceitaremos:

- `FeedRuntime.swift` com milhares de linhas;
- `FeedSession` fazendo SQL;
- `FeedContext` cheio de `if mode == ...`;
- Selection chamando connectors;
- Selection decodificando connector JSON;
- Media publicando cards;
- SwiftUI chamando `loadMore()`;
- renderer usando URL remota;
- `OriginRecord` com dezenas de campos optional protocol-specific;
- `SourceID` derivado de endpoint;
- protocol SDK importado fora de `Connectors/`.

Esses são bugs arquiteturais.

Não diferenças de estilo.

---

## 121. Teste conceitual da boundary

Se alguém trabalhando downstream da admission sentir necessidade de escrever:

```text
if protocol == ...
parse protocol payload
resolve actor remotely
open relay
fetch page
lookup endpoint
interpret CID/event kind
```

então a boundary foi violada ou um conceito FeedMine legítimo ainda não foi promovido.

Pergunta obrigatória:

> FeedMine aprendeu uma nova coisa sobre seu próprio domínio, ou estamos vazando uma representação externa?

---

## 122. Gate para começar o runtime estrutural

Antes do código estrutural de produção precisamos responder sem improviso:

1. O que é uma Source?
2. Como `SourceID` é criado e permanece estável?
3. O que é Provider e como difere de Source?
4. O que é `SourceBinding`?
5. O que é `AcquisitionTarget`?
6. Quando múltiplas Sources compartilham um Target?
7. O que é `OriginRecord`?
8. O que é `OriginRevision`?
9. Como external object identity e external version identity são representadas?
10. Como aliases são preservados sem virarem identidade canônica global?
11. Como SourceMembership difere de acquisition provenance?
12. Quando duas origins representam a mesma história?
13. Que relações entram no domínio FeedMine?
14. Quais timestamps são fatos externos e qual é observation time?
15. O que constitui EditorialRevision?
16. O que constitui apenas RenderEnvironmentRevision?
17. Quando uma Edition permanece válida?
18. Quando uma Edition deve ser substituída?
19. O que exatamente fica congelado numa publication?
20. Como a publication congela uma revision específica?
21. Como a identidade de mídia sobrevive à eviction?
22. O que é suficiente para card offline determinístico sem baixar media integral?
23. Como FeedWindow preserva posição?
24. Como rerender preserva exposure continuity?
25. Como refresh cria successor Edition?
26. Quem pode acrescentar Segment?
27. Como impedimos dois appends concorrentes?
28. O que é um `AcquisitionBatch` válido?
29. Como checkpoint e admission são commitados atomicamente?
30. Como stale finite work e stale streams são rejeitados?
31. Como out-of-order revisions são tratadas sem ordering universal?
32. Que stale work ainda pode persistir como cache/diagnostic evidence?
33. Como durable state sobrevive à remoção de raw/connector evidence?
34. O que visto/consumido significa em cada HistoryScope?
35. Qual é a Frontier finita de acquisition targets/work?
36. Que budgets cada `AcquisitionPurpose` possui?
37. O que acontece quando realmente não há mais supply?
38. Como uma interaction offer chega à UI sem protocol branching?
39. O que a baseline read/ingestion explicitamente não tenta resolver?
40. Como um novo connector prova que não exige mudança em Selection/Publication/Presentation?

Quando essas respostas estiverem formalizadas nos ADRs, o projeto deixa de inventar sua arquitetura enquanto programa.

Passa a executar uma arquitetura conhecida.

---

## 123. Stress-test contract para novos ecossistemas

Para qualquer protocolo/ecossistema futuro, devemos conseguir preencher sem alterar downstream:

```text
Source meaning
SourceBinding representation
AcquisitionTarget representation
external object key
external version key or absence
precedence semantics
checkpoint semantics
canonical projection
Provider attribution
Source memberships
ContentRelations
MediaCandidates
InteractionOffers
Connector Evidence
```

Falha do teste ocorre se o connector exigir:

```text
if protocol == X
```

em Selection, Publication, FeedSession ou Presentation.

---

## 124. RSS/Atom stress test

Espera-se:

```text
Source
    editorial source/feed according to catalog intent

Binding
    syndication identity/configuration

Target
    feed endpoint/request work

Object identity
    connector-scoped GUID/link/fallback identity

Version identity
    connector-defined update/fingerprint semantics when available

Acquisition
    conditional polling; optional push mechanisms later

Structured semantics
    authorship, links, enclosures, updates, media
```

Nenhum conceito RSS específico precisa entrar em Selection.

---

## 125. Mastodon / ActivityPub stress test

Possíveis Sources incluem actor, list, hashtag ou outra unidade editorial.

API Mastodon e participação ActivityPub direta são connectors/participation models distintos.

O connector traduz:

- federated object identity;
- accepted revision/update semantics;
- reply/repost/quote relations;
- actor/provider attribution;
- visibility/eligibility apenas quando relevante ao produto;
- delete/update state;
- media candidates;
- actions quando habilitadas.

Downstream continua protocol-agnostic.

---

## 126. ATProto / Bluesky stress test

Possíveis Sources incluem account, list, custom feed ou outra unidade editorial.

O connector traduz:

- durable principal identity;
- logical record identity;
- strong version identity quando disponível;
- aliases/handles;
- record mutation;
- relations;
- media;
- actions.

AppView consumption e repo synchronization permanecem participation/acquisition models distintos.

---

## 127. Nostr stress test

Possíveis Sources incluem pubkey, list, community/filter recipe ou outra unidade editorial.

Relay não é identity.

O connector traduz:

- normal event identity;
- replaceable/addressable logical object identity;
- concrete event version identity;
- relay provenance;
- reply/reference relations;
- deletion requests;
- media/embedded metadata;
- action handles quando habilitados.

Múltiplas Sources podem compartilhar poucas relay connections/filters.

---

## 128. Regra de promoção de schema

Quando um novo protocolo chega, o schema canônico só muda se descobrimos um conceito de produto genuinamente novo.

Exemplo de gate:

```text
Protocol X contains field fooBar.
        ↓
Does FeedMine need to understand fooBar
as an editorial/presentation/product concept?
        ↓ yes                      ↓ no
promote a generic concept      connector evidence
```

A mudança de schema é justificada pelo domínio FeedMine.

Não pela existência do campo externo.

---

## 129. O que normalmente muda quando chega um novo protocolo

Normalmente mudam:

1. um novo diretório em `Connectors/`;
2. SourceBinding para aquele ecossistema;
3. target creation/planning;
4. external identity/version translation;
5. fixtures e tests;
6. import/catalog discovery específico quando necessário;
7. interaction executor específico quando a feature for suportada.

Normalmente não mudam:

- OriginRecord schema;
- OriginRevision canonical projection;
- SelectionEngine;
- FeedPlan architecture;
- PublicationCoordinator;
- FeedEdition;
- FeedSegment;
- RunwayController;
- FeedSession;
- FeedPresentationSnapshot;
- SwiftUI.

---

## 130. Freeze candidate v0.4

A macroarquitetura candidata a freeze é:

```text
heterogeneous external systems
        ↓
protocol-specific Connectors
        ↓
versioned AcquisitionBatch
        ↓
transactional admission
        ↓
OriginRecord + immutable OriginRevision
        ↓
structured provenance / relations / media / offers
        ↓
editorial Source membership + Provider attribution
        ↓
bounded canonical local supply
        ↓
policy-based FeedPlan
        ↓
deterministic Selection
        ↓
MediaPreparation
        ↓
serialized immutable FeedSegments
        ↓
FeedEdition
        ↓
FeedSession
        ↓
finite local FeedPresentationSnapshot
        ↓
FeedScreenStore
        ↓
SwiftUI
```

Com três regras normativas finais:

> External systems are heterogeneous until admission. FeedMine is homogeneous after admission.

> Protocol-specific semantics may enrich canonical supply, but protocol-specific representations never enter Selection, Publication or Presentation.

> Upstream mutation may change current supply and future publications. It never silently rewrites published history.

E a regra de produto preservada:

> The UI asks what the user wants and reports what the user is seeing. It never tells the Runtime how to obtain it.

Esta é a arquitetura FeedMine V2/v0.4 que os sete ADRs deverão tornar executável.
