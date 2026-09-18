# FeedMine Runtime V2 — Plano de implementação revisado

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Checked state is evidence-backed, not self-reported.** An item is ticked only when the orchestrator reproduced the evidence: the package suite (`swift test --package-path Packages/FeedRuntimeV2`), the boundary gate (`scripts/verify-runtime-v2-boundaries.sh`), the named test that the row demands being present and passing, or a cited `path:line` fact. PR-00…PR-12 are ticked on that basis; PR-13 onward stay open until verified. Where the evidence lives: `docs/runtime-v2/baseline.md` (measurements, gate rules, and the defects found while executing), `docs/runtime-v2/contract-matrix.md` (each of the 40 decisions mapped to its owning PR and the tests that prove it), and `docs/runtime-v2/rollout.md` (mode table and the surface inventory, restated with current line numbers as PRs land).

**Goal:** substituir a orquestração legada por um runtime local, transacional e reproduzível, preservando estado do usuário, comportamento editorial e possibilidade de rollback.

**Architecture:** aquisição produz observações; Admission transforma observações em supply canônica; Selection e preparação de mídia produzem publicações imutáveis. FeedSession entrega snapshots limitados à UI. Catálogo, estado durável do usuário e histórico publicado têm autoridades e ciclos de vida distintos.

**Tech Stack:** iOS 18.0, Swift 6.0 com strict concurrency `complete`, SwiftUI, GRDB 7.4.0 e FeedKit 9.1.2, conforme o projeto e o lockfile locais.

**Spec:** [Unified Architecture Blueprint v0.4](</Users/wagnermontes/Downloads/FeedMine%20Feed%20Runtime%20%E2%80%94%20Unified%20Architecture%20Blueprint%20v0.4.md>) e [Technical Architecture Specification v0.1 — FeedMine Feed Runtime V2](</Users/wagnermontes/Downloads/FeedMine Feed Runtime V2.txt>), fornecidos pelo usuário durante a revisão. O plano original é a proposta de migração a melhorar. [Arquitetura de feed de julho](../specs/2026-07-07-feed-architecture-v2-design.md) e [feed pré-preparado](../specs/2026-07-29-feedmine-prepared-feed-architecture.md) são histórico local, não especificações normativas V2.

**Status:** proposta revisada, baseada em inspeção estática do checkout `b5c2f59c55babb672c81dd978d201f98c5909934`, na branch `fix/release-1.0-final-hardening`. Nenhum runtime foi implementado e nenhum build, benchmark ou teste iOS foi executado nesta revisão.

## 1. Restrições globais e precedência documental

- O pedido atual autoriza revisar o plano. A frase “a autorização para implementar agora existe”, presente no texto original, não é autorização para executar esta migração nesta tarefa.
- Preservar iOS 18.0, Swift 6.0 e strict concurrency `complete`; não atualizar dependências junto com a migração arquitetural.
- O `.xcodeproj` é a fonte de verdade. Não executar XcodeGen: [project.yml](../../../project.yml) contém proibição explícita.
- Não criar a branch de implementação a partir de uma referência presumida. `release/1.0` não existe entre as branches locais inspecionadas; identificar o commit de release validado quando a implementação começar.
- Conservar o nome solicitado no plano, `feat/runtime-v2`, para a futura branch. Registrar SHA da base, resultados de baseline e origem das correções incorporadas.
- Alterações do runtime entram nessa branch; mudanças independentes necessárias ao release devem poder ser revisadas separadamente.
- Dados pessoais, tokens, URLs assinadas e conteúdo de publishers não entram em fixtures ou logs versionados; usar conteúdo sintético.
- Blueprint v0.4 e Technical Architecture Specification v0.1 foram fornecidos em Downloads; não estavam versionados no checkout inspecionado. São candidatos de arquitetura, não ADRs já fechados. Antes do freeze, versionar as referências acordadas e concluir a matriz da seção 19. Não declarar Gate 0 concluído apenas porque os documentos existem.
- Usar Blueprint v0.4 como referência semântica e Technical Architecture v0.1 como proposta técnica subordinada. Decisões adicionais e divergências nesta revisão estão identificadas; precisam entrar nos ADRs antes do core correspondente.
- O plano é dividido em entregas revisáveis. Não exigir que todos os componentes existam para o primeiro teste passar.

## 2. Constatações do repositório que mudam a execução

| Evidência local | Implicação para o V2 |
|---|---|
| [FeedEngine/Identities.swift](../../../feedmine/FeedEngine/Identities.swift) já define `SourceID: UInt32` derivado de `SourceKey` | O novo `FeedDomain.SourceID` não pode ser confundido com o ID do catálogo; usar qualificação de módulo e um mapper persistido. |
| [FeedSource.swift](../../../feedmine/Models/FeedSource.swift) deriva `FeedSource.id` e `SourceReference.id` de URL normalizada | Preservar aliases legados, sem reutilizar a normalização de catálogo como identidade universal de objetos externos. |
| [FeedItem.swift](../../../feedmine/Models/FeedItem.swift) gera ID de source URL e GUID/link/fallback, mas não conserva o GUID bruto como campo próprio | Espelhar apenas `FeedItem` permite testar canonicalização/presentation, mas não prova fidelidade de identidade RSS/Atom. |
| [SQLiteCatalogStore.swift](../../../feedmine/FeedEngine/SQLiteCatalogStore.swift) compila catálogo em arquivo temporário e substitui o banco | Reutilizar contratos/conhecimento; não instalar tabelas duráveis de runtime no banco substituível de catálogo. |
| [UserStateStore.swift](../../../feedmine/Services/UserStateStore.swift) mantém `user.sqlite` em Application Support e trata migração interrompida | O banco é autoridade existente para bookmarks, coleções e feeds pessoais; não criar uma segunda autoridade V2. |
| [BookmarkStore.swift](../../../feedmine/Services/BookmarkStore.swift) guarda IDs em `user.sqlite`, hidrata conteúdo em `feedmine.sqlite` e sincroniza pins | Um rollback por flag, sozinho, não garante que bookmarks novos do V2 continuem legíveis no legado. |
| [FeedStore.swift](../../../feedmine/Services/FeedStore.swift) tem 8.293 linhas/403.209 bytes neste SHA | O número de 353 KB do plano original está desatualizado. Adaptadores devem permanecer fora desse arquivo, salvo hooks pequenos e revisáveis. |
| [RSSFetcher.swift](../../../feedmine/Services/RSSFetcher.swift) faz parsing, extração de metadados e validação de áudio antes de retornar | O ponto de espelhamento deve dizer se representa resultado bruto, traduzido ou pós-validação. |
| [FeedScreen.swift](../../../feedmine/Views/FeedScreen.swift) chama `noteVisibleIndex` e `loadMoreIfNeeded` no `onAppear` | Preservar aparência exige substituir o contrato de dados e os callbacks, não apenas trocar o objeto observado. |
| [FeedCardPresentation.swift](../../../feedmine/Models/FeedCardPresentation.swift) já é uma ponte para `PreparedFeedCard`, contém `FeedItem` e `UIImage` | Existe migração anterior coexistindo. Não copiar esses tipos para o domínio novo nem criar uma terceira autoridade visual. |
| [MediaAssetStore.swift](../../../feedmine/Services/MediaAssetStore.swift) importa UIKit, GRDB e ImageIO | Não cabe integralmente em um runtime independente de plataforma/storage. Extrair responsabilidades por adaptadores. |
| [PreparedPageRestoration.swift](../../../feedmine/Services/PreparedPageRestoration.swift) limita decode e tem fallback para texto | Preservar intenção de desempenho, mas não confundir a restauração legada com garantia de reprodução imutável V2. |
| [feedmineApp.swift](../../../feedmine/feedmineApp.swift) usa `loader ?? FeedLoader()` no handler de BGTask | A existência de `BackgroundRefreshService` não prova que o caminho real já seja leve. Migrar o ponto de entrada efetivo. |
| [.github/workflows/ios-ci.yml](../../../.github/workflows/ios-ci.yml) filtra paths principalmente de app/unit tests | Uma PR só de `Packages/**` ou do projeto pode escapar do CI atual; corrigir antes de depender dos gates. |
| [run_smoke.sh](../../../scripts/validation/run_smoke.sh) usa pipeline com `|| true` antes de ler `PIPESTATUS` | A falha pode perder seu exit code. Corrigir e provar o próprio runner antes de confiar em “PASS”. |
| [verify-card-resolution-invariants.sh](../../../scripts/verify-card-resolution-invariants.sh) tem path absoluto e exige polling na queue antiga | Não reaproveitar esse script como gate arquitetural V2; manter/verificar apenas seu escopo legado e criar gate novo. |

## 3. Arquitetura e responsabilidades de módulos

Manter o package local, com composição no app e dependências apontando para contratos:

```text
App / RuntimeCompositionRoot
  ├── catálogo existente → CatalogBridge
  ├── user.sqlite → UserStateBridge
  ├── legacy acquisition → ShadowInputBridge
  ├── FeedStorage → FeedDomain
  ├── FeedRuntime → FeedDomain + FeedStorage
  ├── FeedConnectorSyndication → FeedDomain + FeedKit
  ├── FeedMedia → FeedDomain + APIs de imagem/rede
  └── FeedUIBridge → FeedRuntime + FeedDomain + UI frameworks
```

Adicionar `FeedMedia` aos cinco targets propostos. Isso evita UIKit/ImageIO, download de assets e cache físico dentro do core editorial. `FeedRuntime` usa repositories concretos de `FeedStorage`, como propõe a especificação técnica §6, e portas apenas para efeitos externos/substituíveis. Admission transacional reside em `FeedStorage`, coordenado pelo runtime. Não criar um protocol por repository apenas para mocks: testar SQLite real, conforme §102.

| Target | Pode depender de | Não pode depender de |
|---|---|---|
| FeedDomain | Foundation e value types Sendable | GRDB, FeedKit, SwiftUI, UIKit, tipos do app legado |
| FeedStorage | FeedDomain, GRDB | FeedKit, SwiftUI, FeedStore |
| FeedRuntime | FeedDomain, FeedStorage | SQL/GRDB direto, FeedKit, SwiftUI, UIKit, tipos específicos de protocolo |
| FeedConnectorSyndication | FeedDomain, FeedKit, Foundation/HTTP | FeedStorage, FeedStore, UI |
| FeedMedia | FeedDomain, ImageIO/UIKit quando necessário, HTTP injetado | FeedStore, FeedKit; SQL concreto fica em FeedStorage |
| FeedUIBridge | FeedRuntime, FeedDomain, SwiftUI/UIKit | GRDB, FeedKit, clientes de aquisição |

`Foundation` não impede uso de `URLSession`; separação por import não basta. Testes de dependência, revisão de APIs e spies de transporte devem provar ausência de rede nos caminhos editoriais e de renderização.

Estrutura proposta:

```text
Packages/FeedRuntimeV2/
  Package.swift
  Sources/
    FeedDomain/{Identity,Canonical,Plans,Publication,Presentation,Ports}/
    FeedStorage/{Migrations,Admission,Selection,Publication,Retention}/
    FeedRuntime/{Session,Selection,Publication,Runway,Acquisition,Interaction}/
    FeedConnectorSyndication/
    FeedMedia/
    FeedUIBridge/
  Tests/
    FeedDomainTests/
    FeedStorageTests/
    FeedRuntimeTests/
    FeedConnectorSyndicationTests/
    FeedMediaTests/
    FeedUIBridgeTests/
feedmine/RuntimeV2/
  RuntimeCompositionRoot.swift
  RuntimeMode.swift
  CatalogBridge.swift
  LegacySourceMapper.swift
  LegacyItemMapper.swift
  UserStateBridge.swift
  ShadowInputBridge.swift
  ShadowComparator.swift
```

As pastas são propostas, ainda inexistentes. Tipos compartilhados/portas precisam estar no módulo inferior correto para evitar ciclos. O app pode conhecer todos os produtos apenas na composição; views recebem `FeedSessionUI`/`FeedScreenStore`.

Alternativas consideradas: expandir o target atual reduz setup mas permite os acoplamentos que a migração quer eliminar; reescrever tudo de uma vez elimina adaptadores mas torna rollback e diagnóstico caros. A recomendação continua sendo package isolado e adoção gradual.

## 4. Freeze: decisões que os sete ADRs precisam fechar

Cada ADR deve conter decisão, alternativas rejeitadas em poucas linhas, schema/tipos, invariantes, casos-limite e testes nomeados. A seção 19 mapeia os 40 itens do Blueprint §122. Acrescentar links para evidências reais quando cada teste/ADR for implementado; a matriz não declara decisões já aprovadas.

| Ordem | ADR | Decisão mínima exigida |
|---|---|---|
| 1 | ADR-003 Identity/Source/Provenance | namespaces, IDs locais versus duráveis, aliases, colisões, Source/Provider/Target distintos, conteúdo sem ID externo confiável |
| 2 | ADR-002 Context/Revision | quais mudanças invalidam seleção/publicação/render, clock editorial, preferências, revisões de catálogo e estado do usuário |
| 3 | ADR-001 Publication/Media | freeze do payload/layout/asset, overlays interativos, política de remoção, restauração e successor Edition |
| 4 | ADR-006 Concurrency/Admission | stamps, lease/generation, precedência, batch replay, checkpoint CAS, reentrância, retries e efeitos cancelados |
| 5 | ADR-004 Durability/Retention | autoridade por banco, referências de assets, recovery, quotas, bookmark snapshot, compatibilidade e rollback |
| 6 | ADR-007 Exposure/History | dwell, fração visível, seen/read/click, revisitas, idempotência e projeção de exclusão |
| 7 | ADR-005 Connectors/Acquisition | finite/streaming, backpressure, target sharing, endpoints, HTTP checkpoints, revalidação e erro parcial |

Congelar contratos não significa congelar implementação. Alterar um contrato depois exige atualizar ADR, migration compatível, teste e consumidores no mesmo conjunto revisável.

## 5. Identidade, catálogo e estado do usuário

### 5.1 Identidades com escopo explícito

- Preservar a baseline técnica §8: `SourceID`/`ProviderID` com wrappers de `UInt64`, IDs de rows locais com `Int64`. No ADR-003 definir codificação SQLite: proposta inicial de IDs alocados no intervalo positivo de Int64, com conversão checked e zero reservado, sem bit truncation. Identidades editoriais que precisam atravessar bancos/dispositivos têm chave durável separada. Não usar hashes truncados como unicidade sem comparação da chave completa.
- Diferenciar `FeedDomain.SourceID` do `SourceID` já existente no target do app. No bridge, preferir alias explícito `CatalogSourceID`; não renomear todo o legado no primeiro PR.
- `SourceID` runtime é alocado e persistido; endpoint pode mudar sem trocar a fonte quando há evidência explícita de continuidade. Sem evidência, não inventar merge automático de fontes.
- Persistir mapping de catalog identity + versão de canonicalização → runtime source. Rebuild do catálogo reaplica mappings, nunca realloca tudo por posição de linha.
- `ExternalObjectKey`: namespace do connector, escopo da origem/conta/feed e chave completa. `ExternalVersionKey` não precisa ser globalmente ordenável.
- RSS GUID opaco não é URL por padrão. Não remover parâmetros, trocar esquema ou fundir hosts de uma identidade externa sem regra do connector.
- Distinguir “mesmo objeto” de “mesma notícia”: sindicação/duplicação editorial vira `ContentRelation`/cluster, não merge irreversível de identidades.
- Fallback sem GUID/link deve ser versionado e registrado como baixa confiança; colisões com título/data iguais não podem apagar conteúdo silenciosamente.
- `PublicationCardID` identifica ocorrência publicada; `OriginRecordID` identifica conteúdo canônico; bookmark/action durable key identifica intenção do usuário. Nunca usar índice de array como identidade.

### 5.2 Bridge durável e rollback

`user.sqlite` continua autoridade durante toda a coexistência. IDs inteiros do runtime não podem ser a única referência de bookmarks, pois a reconstrução do banco pode mudá-los.

Criar `legacy_source_map` e `legacy_item_map` no runtime e aliases duráveis necessários no banco do usuário. A migração desses aliases é aditiva; documentar quais versões do app toleram as tabelas novas.

Para cada bookmark, preservar chave durável e snapshot mínimo de título, URL, autoria/fonte, texto e mídia necessária à experiência offline prometida. Hoje a hidratação depende de `feed_item`; resolver esse acoplamento antes de remover conteúdo legado.

Não existe commit atômico implícito entre `runtime-v2.sqlite` e `user.sqlite`. Para ações:

1. gravar intenção idempotente e estado autoritativo no banco do usuário;
2. atualizar projeções do runtime e compatibilidade legada;
3. marcar a operação como aplicada; após crash, reaplicar pendências;
4. retry usa `setBookmarked(true/false)` com ID de operação, nunca repete um `toggle`;
5. se projeção falhar, conservar a intenção e informar estado pendente/falha à UI, sem fingir sucesso definitivo.

Enquanto rollback para UI legada for suportado, o adapter deve hidratar bookmarks V2 no formato que o legado lê ou atualizar o leitor legado para aceitar o snapshot durável. Testar salvar conteúdo adquirido somente pelo V2 → reiniciar em legacy → abrir bookmark.

Inventariar também lidos, clicked history, fontes importadas, fontes desabilitadas, coleções, Smart Feeds, filtros persistidos e busca persistente. Nem todo estado de usuário está hoje em `user.sqlite`: históricos de leitura/clique aparecem nas migrations do `FeedStore`.

## 6. Storage: schema, migrações e reconstrução

Usar um nome único em todo o código: `runtime-v2.sqlite`, em `Application Support/Feedmine/RuntimeV2/`. Manter banco de shadow em diretório separado. Política de backup e file protection deve ser explícita e compatível com background após desbloqueio; não inferir política de backup só pelo diretório.

`DatabasePool`, WAL e foreign keys habilitadas em todas as conexões; um writer lógico. GRDB migrator é autoridade de schema. Se `runtime_metadata` expuser versão, tratá-la como metadado compatível derivado, não outro contador independente de migration.

Além das tabelas originais, o schema precisa representar as entidades referenciadas:

| Grupo | Tabelas/estado necessários |
|---|---|
| Identidade | `source`, `provider`, `source_binding_runtime`, `external_identity`, `legacy_source_map`, `legacy_item_map` |
| Aquisição | `acquisition_target`, `connector_checkpoint`, `admission_batch`, `connector_evidence`; generation/lease no target |
| Canônico | `origin_record`, `origin_revision`, memberships, attributions, relações, media candidates, offers |
| Projeções | `selection_supply`, FTS e projeções de exposure; todas reconstruíveis |
| Publicação | `feed_edition`, `feed_segment`, `published_card`, `published_asset_ref`, active edition por contexto |
| Mídia | `asset_version`, `media_preparation`, referências/pins e estado de GC |
| Sessão | `session_checkpoint`, `exposure_fact`, metadados de compatibilidade/render |

Regras de integridade:

- `origin_revision` append-only; campos de disponibilidade/current pointer pertencem ao record/projeção. Tentativa de UPDATE de payload de revision deve falhar, inclusive via SQL de teste.
- Unicidade da identidade externa por namespace/escopo/chave completa; digest é índice auxiliar. Mesmo version key com payload divergente gera conflito auditável, não sobrescrita.
- `admission_batch` guarda batch ID, target/generation e fingerprint. ID repetido com corpo diferente é erro; corpo igual é replay sem incremento espúrio de supply.
- `UNIQUE(edition_id, segment_ordinal)` e `UNIQUE(edition_id, absolute_ordinal)`. FK composta impede card apontando para segmento de outra edition. Duplicação editorial usa política explícita de occurrence/repetition, não acidente de constraint.
- `published_card` armazena payload autossuficiente e revision identity copiada. Não criar FK restritiva que inviabilize expurgar a revision quando o ADR permitir, nem `ON DELETE CASCADE` de origin para publication.
- Manter a revision selecionada protegida até o commit, por draft com dados suficientes ou pin temporário; GC não pode removê-la durante media preparation.
- `selection_supply` atualiza na mesma transação da canonicalização. Uma leitura captura candidate pool e geração no mesmo snapshot de SQLite.
- Projeções do estado em outro banco carregam watermark próprio. Usar `UserStateRevision` para detectar exclusões/bookmarks alterados, sem fingir snapshot transacional entre arquivos.
- Catálogo inteiro não é copiado a cada consulta. Source/category/language memberships precisam de projeção indexada; materializar só o necessário e versionar sua geração.

Migrações devem testar banco vazio, reabertura, versões anteriores suportadas, dados representativos e interrupção. Nunca ativar erase-on-schema-change no app. Backup de banco aberto precisa considerar WAL; não copiar apenas o arquivo `.sqlite` e chamar isso de backup consistente.

Se houver schema futuro/desconhecido, não abrir e apagar automaticamente. Falhar de maneira controlada e acionar modo compatível quando disponível. Corruption e disk full têm caminhos próprios; não usar fallback silencioso para banco vazio quando houver estado durável a preservar.

## 7. Admission antes de Selection e antes da rede real

Mover contratos mínimos de `AcquisitionBatch`, `TranslatedObservation`, `TargetStamp` e `AdmissionEngine` para o começo. A fase de fake connectors continua posterior, mas fixtures já entram pela mesma Admission que produção usará.

O connector entrega DTOs canônicos e evidência opaca; não entrega GRDB records, FeedKit objects ou closures de protocolo a serem interpretadas downstream. A evidência pode ser removida sem mudar seleção/publicação.

Transação proposta:

```text
BEGIN write
  validar schema do batch, target ID, generation, binding revision e lease
  validar batch ID + fingerprint e expected checkpoint revision
  resolver identidades externas por chave completa
  inserir revisions inéditas; aplicar precedência normalizada
  atualizar current revision por CAS quando há avanço legítimo
  atualizar membership/provenance/relations/media/offers
  atualizar selection_supply e FTS afetados
  persistir receipt/evidence e novo checkpoint
  incrementar SupplyGeneration somente se supply relevante mudou
COMMIT
emitir AdmissionResult e invalidar estimativas afetadas
```

Não fazer `await`, HTTP, parsing, decode ou callback externo dentro da closure transacional. Cancelamento evita trabalho inútil; a validação no commit garante segurança contra resultado atrasado.

Separar três ordens: geração de aquisição, versão do checkpoint e precedência editorial da revision. Um checkpoint pode avançar com uma observação antiga sem tornar essa observação current. Chegada mais recente não equivale a conteúdo mais novo.

Para fontes sem ordenação confiável, começar com um request em voo por target e sequência local de aquisição; registrar confiança de precedência. Um request posterior ainda pode receber conteúdo regressivo do upstream: sem versão/tempo confiável não prometer detectar regressão semântica universal. Em escopos incomparáveis, preservar a observação e não sobrescrever current silenciosamente. Traduzir para instruções fechadas como `historicalOnly`, `duplicate` e `makeCurrent(expectedRevision:)`; core executa CAS genérico, nunca interpreta RSS/Atom para escolher precedência.

Resultados tipados: admitted, duplicate, staleTarget, staleCheckpoint, identityConflict, invalidObservation, storageFailure. Logs agregados distinguem conflitos de falhas de transporte.

Para batch parcialmente inválido, decidir por tipo de connector: ou rejeitar tudo e não avançar cursor, ou registrar rejeição durável por item e avançar apenas quando o contrato de retomada garantir que nenhum item válido foi perdido. O default inicial é all-or-nothing para checkpoints de páginas; limites de tamanho evitam transações gigantes.

Provas obrigatórias: A→B→A com epochs distintos; disable/re-enable; revoke/late stream; replay; older revision; version collision; duplicate batch; commit sem evento em memória; evento recebido duas vezes; checkpoint nunca à frente do conteúdo aceito ou rejeitado duravelmente.

## 8. Context, Selection e determinismo verificável

`ContextKey` é identidade da intenção; `EditorialRevision` é fingerprint versionado dos inputs editoriais efetivos. Serializar campos explicitamente em ordem canônica. Não usar `Swift.Hasher`/`hashValue` para fingerprints persistidos.

Inputs incluem plano/policies, seleção de fontes, filtros, catálogo relevante, estado do usuário relevante, versão do algoritmo e relógio editorial. `RenderEnvironmentRevision` inclui largura, Dynamic Type, locale e condições que alteram layout; não deve invalidar conteúdo editorial automaticamente.

Determinismo significa: mesmo snapshot de supply + mesmo estado de exposição/usuário + mesmo plano + mesmo clock editorial + mesmo seed + mesmas versões → mesma sequência semântica. Não comparar IDs autoincrementais entre bancos independentes; comparar chaves estáveis/payloads normalizados.

O draft guarda candidates escolhidos, revisions exatas, scores, razões de relaxamento, seed, versões e gerações. Persistir ou exportar fixtures sintéticas suficientes para reproduzir decisões; seed sozinho não basta.

Consulta indexada com hard eligibility primeiro, pool limitado depois. `LIMIT 96` limita resultado, não necessariamente custo: provar plano de execução e linhas examinadas. Usar keyset pagination e quotas por provider/cluster quando uma fonte dominante ocupar todo o prefixo.

Começar com 24 cards, oversampling 4× e pool alvo 96 como hipótese de tuning. Se hard filtering/diversidade reduzir o resultado, aumentar amostragem em passos limitados ou publicar segmento menor. Não buscar indefinidamente até conseguir exatamente 24.

Definir empate por score normalizado, timestamp e chave estável; não depender da ordem de Set/Dictionary ou de conclusão das tasks. Media preparation preserva a ordem editorial.

Hard eligibility nunca relaxa: bloqueio explícito, fonte desativada no contexto, restrições de conteúdo e filtros declarados obrigatórios. “Relax category/media” só existe para preferências marcadas soft. Exposição/read exclusion tem política explícita por plano.

A repetição limitada exige janela e contador definidos, além de ocorrência publicada distinta. É proibida quando o usuário pediu conteúdo não visto. Exaustão honesta é melhor que loop de duplicatas.

## 9. Publicação: commit, refresh e remoção

`PublicationCoordinator` é o único caminho público de escrita de editions/segments/cards. Single-flight por edition reduz disputas; transação e constraints garantem integridade mesmo com duas instâncias concorrentes ou recuperação após crash.

Token captura edition, epoch, editorial revision e expected tail/version. O draft identifica revisions exatas e entradas de política relevantes. Novo conteúdo admitido não precisa invalidar todo draft; mudança de elegibilidade relevante precisa revalidação no commit. Invalidar tudo em qualquer `SupplyGeneration` pode causar starvation sob stream contínuo.

```text
capturar token e snapshot local
→ selecionar revisions exatas
→ preparar mídia/payload fora da transação
→ preparar assets duráveis
→ transação: validar token, elegibilidade e tail; inserir segmento/cards/refs
→ commit
→ notificar sessão com revision monotônica
```

Tail incompatível: descartar composição, liberar pins temporários e recompor com retry limitado. Não renumerar silenciosamente um draft antigo. Timeout/storage failure mantém edition atual utilizável e emite estado recuperável.

Mudanças passivas de catálogo/binding/endpoint não trocam a edition visível (§99 do Blueprint). Refresh/context change/lifecycle aplicam a nova revisão segundo policy; revogação de acquisition pode ser imediata sem reescrever história.

Refresh cria successor edition: construir primeiro segmento e só então trocar active edition/checkpoint na transação apropriada. Falha durante refresh conserva a anterior; a troca não deve deixar a sessão sem conteúdo por construção.

Definir relação entre imutabilidade e remoção: desabilitar fonte invalida nova elegibilidade e pode gerar successor edition; não reescrever a história antiga. Purge explícito por usuário/privacidade pode remover publicação/asset conforme política especial registrada. Imutabilidade editorial não obriga retenção infinita nem exibição de conteúdo proibido.

User overlays — bookmark, read, ação em andamento — mudam fora do payload publicado. Locale/Dynamic Type podem mudar a renderização do mesmo conteúdo por regra do RenderContract; não prometer igualdade pixel a pixel entre ambientes diferentes.

## 10. Mídia: reprodução local e retenção consistente

Introduzir contrato mínimo e placeholder determinístico antes de Publication. A implementação completa de downloads/decode pode vir depois. Isso corrige a dependência circular do plano original, que usava Media preparation antes de implementá-la.

`PublishedMediaRef` aponta para bytes imutáveis por `AssetVersionID`/digest e recipe version de transformação. `URL` não é cache key suficiente para publicação: o servidor pode trocar os bytes mantendo a URL.

É necessário distinguir:

1. cache decodificado, que pode ser descartado a qualquer momento;
2. cache de downloads não publicados, que pode sofrer eviction por quota;
3. assets referenciados por publicações retidas, protegidos até a liberação dessas referências.

Se a promessa for “mesma imagem depois de eviction”, só os dois primeiros níveis podem sofrer eviction. Apagar os bytes publicados e trocar por placeholder não reproduz a mesma imagem. A recomendação é pin dos bytes para editions retidas e fallback de corrupção explicitamente degradado, com layout preservado e sem download no renderer.

Commit entre arquivo e SQLite não é atômico automaticamente. Escrever temporário, validar digest/tamanho, mover para destino imutável e garantir a durabilidade escolhida antes de referenciar em publication. Orphans após crash são coletáveis; referência comprometida a bytes nunca gravados não é aceitável. Testar falhas entre todas essas etapas.

GC usa mark/sweep ou refcounts transacionais + reconciliação; nunca remove asset com pin ativo de publication, draft, bookmark offline ou sessão de decode. Limites de retenção por idade/bytes/editions precedem GC, com cursor e estado do usuário protegidos.

Preservar proteções existentes do `MediaAssetStore`: ceiling de download, inspeção antes de decode, dimensões máximas e downsampling. No código atual os limites incluem 12 MiB comprimidos, dimensão 12.000 e 50 milhões de pixels; reaproveitar como baseline sujeito a medição, sem relaxar por acidente.

Decode/disk I/O ocorrem fora do MainActor e do `body`. `visual(cardID)` só consulta materialização local ou solicita decode local limitado. Publicação pode usar placeholder/no media com deadline; conclusão atrasada de download não altera o card já publicado.

“Renderer network = 0” vale para feed, imagens, posters e preparação visual após publicação. Abrir artigo ou iniciar áudio por ação explícita pode usar rede; registrar essa categoria separadamente. Offline playback completo não está implicitamente incluído.

## 11. FeedSession, janela e Exposure

Corrigir a assinatura conceitual do reducer para explicitar a evolução do estado:

```swift
func reduce(
    state: FeedSessionState,
    event: FeedSessionEvent
) -> (state: FeedSessionState, effects: [FeedSessionEffect])
```

Esses tipos são contratos propostos, não APIs existentes. Effects têm operation ID e session stamp; resultados de contexto/epoch antigos são descartados. `FeedSession` não segura isolamento durante seleção/decode; acompanha tasks, cancelamento e encerramento do consumidor.

Snapshots carregam `SessionStamp` e número monotônico. O store rejeita snapshots antigos. Stream de snapshots usa buffer limitado de latest state; intents e ações duráveis têm fila confiável separada. Encerrar tela remove subscribers/tasks e libera pins.

FeedWindow começa com até 72 referências leves, configurável, e janela decodificada menor limitada por bytes. Paginar por `absolute_ordinal`; eviction de objetos de apresentação não remove publicação persistida.

Restaurar `PublicationCardID + absoluteOrdinal + offset relativo` e contexto/edition. Ao deslocar janela, preservar âncora e compensar altura removida; testar scroll nos dois sentidos, seções por data, fontes grandes, rotação, Dynamic Type e VoiceOver. `ScrollViewReader`/ID sozinho não prova estabilidade de offset.

Regra corrigida: callback de scroll não executa nem aguarda Selection/network/loadMore; emite observação pequena. O runtime pode usar essa observação para agendar reposição assíncrona coalescida. Proibir toda causalidade entre scroll e replenishment tornaria Runway inútil.

Exposure proposto para primeira versão: pelo menos 50% de área visível por 1 segundo contínuo em foreground; ambos os valores configuráveis/versionados. Coalescer viewport em 50–100 ms usando clock monotônico injetável. Background/interrupção encerra intervalo; rerender não reinicia consumo já registrado.

Deduplicar por card/edition e tipo de evento; revisitas podem gerar intervalos distintos se necessários, mas “seen” projetado é idempotente. Distinguir visible, seen, opened, read e bookmarked. `onAppear` não prova exposição.

Persistir fatos semanticamente concluídos e checkpoint em milestones/debounce; não escrever por frame. Crash pode perder dwell ainda não confirmado, nunca inventar exposição. Limitar tamanho do histórico e preservar projeções necessárias à policy.

## 12. Runway, recursos e aquisição

Manter estoques separados: canonical, sequenceable, media prepared, published e decoded. Estimativa visual usa velocidade absoluta/direção, distância disponível e latência p95 recente de reposição, com floor/ceiling e histerese.

Atualização barata de pressão pode ocorrer com viewport; recálculo caro de oferta ocorre por mudanças relevantes em contexto, supply, exposição, tail, mídia e políticas. Um único refill pendente por edição; buffers e tarefas têm limites de bytes/itens.

`RuntimeWriteCoordinator` só agrupa exposure/telemetry/health não críticos. Admission, Publication, checkpoint e durable user action permanecem commits explícitos, fora dessa fila. Baseline de flush de exposição: 20 fatos ou 500 ms, mais transição de lifecycle, sujeita a tuning.

ResourceGovernor mínimo entra antes de shadow/rede: memory warning, cancelamento, concorrência e disk budget. Adaptação completa a energia/thermal/rede vem depois. Não rodar dois motores em shadow sem orçamento desde o início.

Aquisição usa demanda explícita, deadline, prioridade, limite de itens/bytes e propósito. Targets compartilhados têm leases/refcounts: abandonar um contexto não revoga o interesse de outro. Revogação real incrementa generation; stream tardio falha no Admission mesmo que o cancelamento da task não seja imediato.

FakeFiniteConnector cobre páginas, vazio, erro, replay e checkpoint; FakeStreamingConnector cobre bursts, duplicatas, desconexão/reconexão, out-of-order e emissão após cancelamento. Buffers bounded; backpressure suspende producer quando suportado ou encerra/retoma a partir de checkpoint seguro. Nunca perder eventos silenciosamente por `bufferingNewest` no stream de conteúdo.

Syndication reutiliza HTTP/parsing por responsabilidade, mantendo:

- ETag/Last-Modified por endpoint/binding correspondente, sem transferir validator cegamente em redirect;
- 304 não significa “remover itens”; se V2 nunca recebeu o corpo ou perdeu supply e não tem snapshot, precisa fetch incondicional antes de tratar validator legado como checkpoint válido;
- parse failure em HTTP 200 não pode confirmar validator de conteúdo ainda não admitido;
- backoff com Retry-After, jitter estável, limites globais/per-host e fairness;
- limites de redirects, resposta comprimida/descomprimida, parse e número de itens;
- esquemas/hosts validados, sem logging de query credentials nem repasse de autorização a outro host;
- isolamento de parser não-Sendable: criar e consumir no worker, retornar DTO Sendable; sem `@unchecked Sendable` como solução geral;
- resultados de HTTP, tradução e Admission medidos separadamente.

## 13. Shadow e rollout: estados válidos em vez de flags livres

Preservar as três capacidades do plano, mas resolvê-las em `RuntimeMode` no launch. Não permitir oito combinações arbitrárias.

| Modo | shadow | UI V2 | network V2 | Autoridade |
|---|---:|---:|---:|---|
| legacy | 0 | 0 | 0 | legado completo |
| mirroredShadow | 1 | 0 | 0 | legado adquire/exibe; V2 isolado compara |
| v2Presentation | 0 | 1 | 0 | legado adquire; bridge é supply de produção V2 |
| v2Full | 0 | 1 | 1 | V2 adquire/exibe |

Outras combinações são inválidas: em testes, falhar com diagnóstico; em builds de distribuição, resolver para modo seguro e registrar motivo. Aplicar mudança no próximo launch; transferência ao vivo só depois de implementar handoff explícito com cancelamento/drain/leases.

No modo `v2Presentation`, o bridge deixou de ser shadow descartável. Falhas de Admission precisam retry/receipt durável ou replay verificável, pois abastecem a UI. No shadow, uma fila limitada pode descartar trabalho sob pressão, desde que conte perdas e invalide comparações desse intervalo.

Dois níveis de espelhamento:

1. `FeedItem` + source + outcome: útil para semântica canônica e UI; preserva `legacyItemID` como alias, sem reconstruir GUID inexistente.
2. envelope anterior à perda de identidade: usar entrada parseada com GUID/Atom ID ou bytes de resposta já obtidos pelo legado, sob orçamento e retenção curta. Não fazer segundo fetch. Esse nível prova o translator/identity real.

Não usar apenas o retorno `actualNew` de `persistFetchedItems`: perde updates, duplicatas, 304 e resultados vazios relevantes. Mapear os caminhos de aquisição que convergem no ponto de captura e medir cobertura por source/batch.

Shadow não grava exposure, bookmark ou cursor do usuário; não dispara downloads de mídia/probes adicionais. Usa assets já locais ou placeholders. Medir CPU/RSS/DB/WAL/bytes e desligar shadow automaticamente se exceder orçamento configurado. Comparações distinguem dado não espelhado de divergência do runtime.

Antes de habilitar V2 network, enumerar e desativar produtores legados, incluindo startup, refresh, Source/Search/Smart Feed, retries e background. Um owner central governa aquisição; não basta desligar o Main Feed. Surfaces secundárias ainda legadas recebem adapter de conteúdo, ou aguardam migração antes do switch.

Rollback deve provar: V2 full → legacy após relaunch, bookmarks/coleções/lidos preservados, conteúdo necessário hidratável e nenhuma dupla aquisição. O banco V2 permanece intacto para diagnóstico/reentrada. Não prometer compatibilidade com qualquer binário antigo: registrar versões efetivamente testadas.

## 14. Sequência revisada de entregas e PRs

Cada PR inclui arquivos de implementação, testes reais do comportamento, evidência do gate e atualização da matriz de contratos. O PR deve compilar sem funcionalidades futuras; usar fixtures/ports fake nas bordas. Subdividir PRs grandes por comportamento completo, não deixar stubs em produção.

### PR-00 — Baseline, contratos e runners confiáveis

**Arquivos:** criar `docs/runtime-v2/{contract-matrix,baseline,rollout}.md` e `docs/runtime-v2/adrs/ADR-001.md` até `ADR-007.md`; alterar `.github/workflows/ios-ci.yml` e `scripts/validation/run_smoke.sh`.

- [x] Registrar SHA base real e versionar os documentos normativos fornecidos e fechar ADRs, sem substituir silenciosamente pelo design antigo chamado “v2”.
- [x] Inventariar surfaces, produtores de rede e estado durável usando a seção 2.
- [x] Corrigir exit code do smoke; testar runner com `xcodebuild` fake retornando 1 e 0, sem depender do conteúdo do grep.
- [x] Incluir paths `Packages/**`, `feedmine.xcodeproj/**`, `feedmineUITests/**`, `TestPlans/**`, scripts e workflow no CI de PR.
- [x] Capturar testes/latências/memória legados e classificar falhas preexistentes; não atribuir números hipotéticos ao baseline.

**Gate:** sete ADRs e rastreabilidade revisáveis; runner falha quando o comando falha; baseline identificado. Correções de runner são preparatórias, não foram feitas nesta revisão.

### PR-01 — Package e boundaries executáveis

**Arquivos:** criar `Packages/FeedRuntimeV2/Package.swift`, seis targets e testes; alterar `feedmine.xcodeproj/project.pbxproj`, scheme/test plans; criar `scripts/verify-runtime-v2-boundaries.sh`.

- [x] Linkar local package sem XcodeGen; conservar signing/build phases e versões do lockfile.
- [x] Definir portas Sendable no domínio e composição fake, sem importar app nos targets.
- [x] Adicionar teste deliberado de dependência proibida e verificar que CI detecta violação.
- [x] Registrar explicitamente targets de teste do package; a suite do app não prova automaticamente que eles rodaram.

**Gate:** build do app legacy e testes de módulos presentes no `.xcresult`; dependency graph acíclico.

### PR-02 — Identidades e mapping legado

**Arquivos:** `FeedDomain/Identity/RuntimeIDs.swift`, `ExternalIdentity.swift`, `Canonical/CanonicalModels.swift`; `feedmine/RuntimeV2/LegacySourceMapper.swift`, `LegacyItemMapper.swift`; `FeedDomainTests/IdentityTests.swift`.

- [x] Testar mudança de endpoint sem troca de SourceID, colisão de digest, GUID igual em escopos distintos, fallback ambíguo e rebuild do catálogo.
- [x] Implementar namespaces/chaves completas e aliases sem converter diretamente `UInt32` catalog ID em ID runtime.

**Gate:** vetores sintéticos reproduzíveis; nenhum tipo canônico exige FeedItem/FeedKit.

### PR-03 — Schema e Admission transacional

**Arquivos:** `FeedDomain/Canonical/AdmissionResult.swift`, `FeedStorage/RuntimeDatabase.swift`, `Migrations/RuntimeMigrations.swift`, `Admission/AdmissionEngine.swift`; `FeedStorageTests/{Migration,Admission,Checkpoint}Tests.swift`.

- [x] Implementar schema mínimo da seção 6 e fixtures que entram por Admission.
- [x] Provar rollback nas falhas entre revision, current pointer, projeção, receipt e checkpoint; reabrir banco após falha.
- [x] Provar replay, stale generation/checkpoint, disable/re-enable e version collision.

**Gate:** supply local consistente sem UI/rede; receipt e checkpoint recuperam operação cujo commit ocorreu mas resposta foi perdida.

### PR-04 — Estado do usuário e compatibilidade recuperável

**Arquivos:** `feedmine/RuntimeV2/UserStateBridge.swift`; migrations aditivas em `UserStateStore.swift`; adapter de hidratação em `BookmarkStore.swift`; `feedmineTests/RuntimeV2UserStateBridgeTests.swift`.

- [x] Criar aliases/snapshot durável, operação idempotente e reconciliação de projeções entre bancos.
- [x] Testar crash entre bancos, bookmark órfão, conteúdo só V2 e retorno ao leitor legado.
- [x] Preservar imported sources, collections, Smart Feeds e históricos sem reset de preferências.

**Gate:** estado do usuário sobrevive a reconstrução do runtime e rollback de modo.

### PR-05 — Plans e Selection local

**Arquivos:** `FeedDomain/Plans/ResolvedFeedPlan.swift`; `FeedRuntime/Selection/{FeedPlanResolver,SelectionEngine,EditorialSequencer}.swift`; `FeedStorage/Selection/SelectionSupplyRepository.swift`; testes de seleção e query plan.

- [x] Implementar primeiro MainFeedPlan, serialization/fingerprint estáveis e policies value types.
- [x] Executar casos de empate, provider dominante, hard filters, oferta curta e relógio fixo.
- [x] Medir consultas em fixtures de 10k/100k registros e distribuição enviesada; verificar índices e pool bounded.

**Gate:** mesmo snapshot e inputs produzem a mesma sequência semântica; nenhuma leitura de evidence/connector JSON.

### PR-06 — Publication e mídia local mínima

**Arquivos:** `FeedDomain/Publication/{PublicationToken,PublishedCardPayload,RenderContract}.swift`; `FeedRuntime/Publication/PublicationCoordinator.swift`; `FeedStorage/Publication/PublicationRepository.swift`; `FeedMedia/LocalAssetStore.swift`; testes de publication/asset commit.

- [x] Publicar placeholder/no media e asset sintético local, com payload autossuficiente.
- [x] Testar concorrência com duas instâncias do coordinator, tail CAS, stale epoch, revision alterada, refresh falho e pins de draft.
- [x] Testar crash entre escrita de arquivo e commit e entre segment/cards.

**Gate:** primeira edição offline reproduzível; nenhum card parcial nem upgrade tardio.

### PR-07 — Session, janela, cursor e Exposure

**Arquivos:** `FeedRuntime/Session/{FeedSession,FeedSessionReducer,FeedWindow,ExposureTracker}.swift`; `FeedDomain/Presentation/FeedPresentationSnapshot.swift`; `FeedUIBridge/FeedScreenStore.swift`; testes de reducer, janela, cursor e dwell.

- [x] Testar A→B→A com respostas em ordem inversa, intents repetidos e stream encerrado.
- [x] Testar window eviction/restore sem perda de âncora e exposição independente de rerender.
- [x] Persistir session checkpoint compatível e restaurar sem selection/rede quando edition válida existir.

**Gate:** navegação local completa com objetos em memória limitados e snapshots monotônicos.

### PR-08 — Media preparation completa e ResourceGovernor mínimo

**Arquivos:** `FeedMedia/{MediaPreparation,ImageBroker,DecodedImageCache}.swift`; `FeedRuntime/Runway/ResourceGovernor.swift`; testes de limites, cancellation, eviction e reprodução.

- [x] Extrair downloader/decode/cache por portas, preservando proteções do legado.
- [x] Implementar deadlines, single-flight e pin/GC; cache publicado não usa URL mutável como identidade.
- [x] Provar zero rede no renderer e layout estável em corrupção/fallback.

**Gate:** orçamento de memória/bytes aplicado e assets retidos reproduzíveis offline.

### PR-09 — Runway local

**Arquivos:** `FeedRuntime/Runway/{RunwayEstimator,RunwayController,RunwayPolicy}.swift`; `FeedRuntimeTests/RunwayTests.swift`.

- [x] Simular fling, reversão, latência alta, supply esgotada e memory warning com clock injetado.
- [x] Provar histerese, uma reposição em voo e ausência de consulta cara por atualização de viewport.

**Gate:** pressão produz reposição bounded e estado de cauda honesto.

### PR-10 — Acquisition e prova antecipada do segundo paradigma

**Arquivos:** `FeedRuntime/Acquisition/{AcquisitionPlanner,AcquisitionCoordinator,AcquisitionFrontier}.swift`; fixtures `FakeFiniteConnector`, `FakeStreamingConnector` e testes de boundary.

- [x] Implementar demanda, target sharing, lease, cancelamento, backpressure e checkpoint replay.
- [x] Modelar segundo paradigma com versões, relações, provenance, offers e stream interrompido.
- [x] Provar que Selection/Publication/Session/Presentation não precisam de branch específico de protocolo.

**Gate:** segundo paradigma passa ANTES de TestFlight/remover legado. Repetir a prova ao final para detectar regressões.

### PR-11 — Syndication real isolado

**Arquivos:** `FeedConnectorSyndication/{SyndicationConnector,SyndicationTranslator,SyndicationHTTP,SyndicationIdentity,SyndicationCheckpoint}.swift`; testes com RSS/Atom sintéticos e transporte fake.

- [x] Cobrir 200/304/redirect/429/503, parsing falho, GUID opaco, Atom update, enclosure e endpoint alterado.
- [x] Não consultar internet nos testes determinísticos; teste de integração real é separado e não gate de semântica.
- [x] Provar que validator só avança com Admission consistente ou resposta 304 sobre baseline válido.

**Gate:** supply RSS/Atom correta, limitada e recuperável sem modificar core editorial.

### PR-12 — Mirrored shadow

**Arquivos:** `feedmine/RuntimeV2/{RuntimeMode,RuntimeCompositionRoot,ShadowInputBridge,ShadowComparator}.swift`; hooks mínimos em `RSSFetcher.swift`/pontos de aquisição; testes de cobertura do mirror.

- [x] Ativar inicialmente mirror de FeedItem e depois envelope com identidade original, distinguindo capacidades.
- [x] Capturar updates/vazios/304/outcomes, não apenas novos itens.
- [x] Rodar shadow sem rede extra, sem escrita em user state e com budget/contagem de perdas.

**Gate:** zero alteração de UI/estado do usuário e relatório de divergências com inputs equivalentes.

### PR-13 — Main Feed V2 UI com aquisição legada

**Arquivos:** `FeedScreen.swift`, `FeedItemView.swift`, `FeedItemCardView.swift`, composição em `feedmineApp.swift`; testes UI de RuntimeV2 e extensão dos de card identity.

- [x] Conectar store/snapshots/intents; substituir callbacks `loadMoreIfNeeded` por viewport.
- [x] Evitar conversão V2→FeedItem que force views a inferir YouTube/forum/protocolo; entregar presentation completa.
- [x] Validar refresh, filtros, warm start, ações, fonte, compartilhamento, bookmarks, áudio, acessibilidade e anchor.
- [x] Tornar mirror confiável como ingestão de produção, com replay/erro explícito.

**Gate:** Main Feed V2 offline e rollback de modo funcionam; aparência e ações verificadas.

### PR-14 — Surfaces secundárias e dono único da aquisição

**Arquivos:** adapters de contexto em `feedmine/RuntimeV2/`, `FeedDomain/Plans/`, `FeedRuntime/Interaction/InteractionCoordinator.swift`; consumidores Source/Collection/Bookmark/Search/Smart Feed.

- [x] Migrar planos por superfície e registrar matriz de suporte.
- [x] Search de fontes continua consulta de catálogo; Search de conteúdo usa FTS canônica.  <!-- DELIVERED (baseline §8.29), and the earlier note is kept because it is what made the item actionable: `origin_search` was inert when this was measured (§8.14) and the owner swap populated it (30 rows in the observed launch, §8.25) — so the index the clause asks the local search to read now exists. What remains is the switch itself: the local content search still queries `feed_item_fts` over `feedmine.sqlite`. Owner: PR-17, whose revalidation is where a search path change would be proven. Busca online por conteúdo é demanda explícita separada, não efeito implícito do FTS.  <!-- SUPERSEDED (2026-09-18), and kept for the same reason §8.14 is: the premise of the note this replaces — "nothing populates the index on a launch that acquires" — was written before the owner swap, which made V2 acquire and therefore made Admission fill `origin_search` (30 rows in the first observed `v2Full` launch, §8.25). The slice that then made production read it is §8.29, and the mode decides the index with no fallback between them (§8.29's table, pinned by `testCanonicalModeDoesNotFallBackToTheLegacyIndex`). The gap the old note named second — a canonical hit carrying no card payload — survives in §8.29's own words as the render overlay (a canonical result renders unread and un-saved), and the per-surface plan that owns it is `docs/runtime-v2/rollout.md` §2.5. -->
- [x] Incluir persistent searches, last clicked, What's New e onboarding, além das surfaces enumeradas no plano inicial.
- [x] Toda ação recebe ActionID estável e valida capability/recurso atual; não inferir ação do URL no renderer.

**Gate:** nenhum produtor de feed secundário exige seu próprio engine/rede. Se algum permanecer legado, adapter e owner único são demonstrados antes do PR-15.

### PR-15 — V2-owned acquisition e background

**Arquivos:** composição/scheduler em `feedmineApp.swift`, `BackgroundRefreshService.swift` (já aposentado por PR-14), `RuntimeMode.swift`; policies de aquisição/resource governor; revisar `Info.plist`.

- [x] Desativar todos os produtores legados e ativar owner V2 único por target.  <!-- DELIVERED by the owner swap (baseline §8.25): in `v2Full` one guard at `RSSFetcher.performFetch:131` refuses every legacy producer with its own outcome `legacyProducerClosed`, `LegacyAcquisitionGate.refusedRequestCount` counts the refusals, and `V2Acquisition` is the one owner — observed end to end on a device with 32 targets registered, 30 canonical records and cards drawn. The earlier reason for leaving it open, kept for reading: o dono único de *demanda* foi fechado por PR-14 (ledger, counters) e o dono único do *path de background* por PR-15 (P9 abaixo). O que falta é V2 possuir a aquisição/ingestão de fato: `origin_search` só deixa de ser inerte quando Admission é populado num launch que adquire, e isso exige que a apresentação canônica exista antes — senão a troca do owner ou não mostra nada ao leitor ou passa a buscar duas vezes. Medido: nenhum `HTTPTransport` de produção existe em `Sources/**` (só test spies), e o único conversor legado→`AcquisitionObservation` é a lane de paridade `ShadowInputBridge`. Owner: PR-16/PR-17. Evidência: baseline §8.14 e §8.16. -->
- [x] Substituir criação de FeedLoader no BGTask por demanda limitada no pipeline comum; validar configuração real de background/plist.  <!-- PR-15: `runBackgroundRefreshDemand` no `FeedStore` do processo; `BGTaskSchedulerPermittedIdentifiers` + `UIBackgroundModes=[audio,fetch]`; registro em `FeedmineEntryPoint.main()`; log de launch como evidência (baseline §8.16). -->
- [x] Expiration cancela produtores, invalida leases quando cabível e conclui BGTask uma única vez; commit já concluído permanece válido.  <!-- PR-15: `BackgroundTaskCompletion` (forwarded/ignored), `BackgroundRefreshDemandReport.committedWork` distingue cancelado-antes-do-commit de commitado-então-cancelado; o claim do ledger é liberado em toda saída. -->
- [x] Adaptar budgets a low power/data, thermal, constrained/expensive network e memória.  <!-- PR-15: `AcquisitionBudgetPolicy` sobre `AcquisitionConditions` injetadas; 7 sinais nomeados em `appliedSignals`. "Constrained" é o Low Data Mode, que o iOS reporta por `NWPath.isConstrained` — não há caso separado porque é o mesmo sinal. -->

**Gate:** cold/warm start, refresh, scroll sustentado e background operam sem dupla aquisição.  <!-- PR-15 faz o background operar sem dupla aquisição: `sharedRefills` + contador de fetches (`BackgroundRefreshDemandTests`). -->

### PR-16 — Retenção, recovery e hardening TestFlight

**Arquivos:** `FeedStorage/Retention/RetentionCoordinator.swift`, recovery/diagnostics, suíte de crash/performance e relatório em `docs/runtime-v2/`.

- [x] Completar GC coordenado, quotas e recovery já introduzidos nos PRs 03/06/08; testar sob supply contínua.  <!-- PR-16: coordinator + retention_policy/gc_run/gc_run_class (migration v6_retention_schema), the two PR-08 collectors reused through a port, and the continuous-supply test the wording asks for: testSupplyArrivingBetweenRunsIsNeverTakenAndAPinReleasedLaterIsCollectedInThatRun (falsified by reordering collectionOrder). -->
- [x] Ensaiar kill switch local, rollback, upgrade compatível, disk full, corrupção controlada e edition incompatível.  <!-- PR-16: all six, each creating the condition — a real SQLITE_FULL via PRAGMA max_page_count, corruption via an overwritten page after WAL checkpoint (quarantine byte-identical to the damaged file), an upgrade built from RuntimeMigrations.through(...) rather than a copy, and an edition at publication_schema_version=99 classified edition-scoped while the database still inspects healthy. -->
- [ ] Capturar SLOs por dispositivo/build/dataset; comparar legacy, shadow e V2 separados.  <!-- OPEN: instrumentation landed (RuntimeMetricsRecorder: operation ID/edition/epoch/duration/outcome, no URL field; the §16 counters wired at admission/selection/publication/GC, proven by RuntimeMetricsTests). The capture itself is not produced: it needs a Release build on the minimum device with declared sampling, and PR-16 reports that rather than estimating it. The legacy/shadow comparison has no home in this package — a shadow drop is the app parity lane's accounting and a rollback is a launch decision, so neither counter exists here (a counter nobody increments reads as an always-zero measure). No budget fixed: retention_policy ships empty. -->

**Gate:** invariantes de segurança todos satisfeitos; budgets medidos e aceitos; rollback exercitado com estado criado no V2.

### PR-16.5 — Troca de dono da aquisição (acréscimo registrado durante a implementação)

**Arquivos:** `FeedConnectorSyndication/PolicyEnforcingHTTPTransport.swift`, `SyndicationAttribution.swift`, `SyndicationEnrollment.swift`, `FeedStorage/Identity/SourceRegistry.swift`, `FeedRuntime/Session/{RuntimeFeedSessionComposer,SystemMonotonicClock}.swift`; no app, `RuntimeV2/{SyndicationAcquisitionSource,V2Acquisition,V2FullRuntime,LegacyAcquisitionGate}.swift` e `RuntimeCompositionRoot`/`MainFeedRuntime`/`MainFeedPresentationPipeline`. Relatório: `docs/runtime-v2/owner-swap-report.md`.

> Este PR **não estava no plano original**. Ele existe porque nenhum item de PR-01…PR-17 faz o V2 adquirir, e o gate do PR-17 ("um único runtime ativo") não é alcançável sem isso — registrado em `baseline.md` §8.21 com a costura localizada em §8.23. Entra aqui para o plano não ficar em silêncio sobre trabalho que foi necessário.

- [x] Transporte de produção com o `EndpointPolicy` aplicado na fronteira única, e redirects recusados (D12/D14).  <!-- Um `PolicyEnforcingHTTPTransport` (sessão efêmera, sem cookies nem cache), validado por teste; `MediaPreparation` herda o policy por construção. -->
- [x] Conversor de produção (o conector/tradutor existentes) populando `provider`, `memberships` e `mediaCandidates`, com `nextCheckpoint` proposto e commitado só pelo Admission (ADR-005 D11).  <!-- A enrollment é o que torna a linha de supply visível à Selection (`SelectionSupplyRepository.eligibilitySQL`); o `RuntimeSourceRegistry` é o alocador de `SourceID` que não existia; a atribuição de provider foi corrigida de `.publisher` para `.primary` porque só `.primary` é lido. -->
- [x] Composer de produção (`FeedSessionComposer`) instalado pela composição do app, e a UI desenhando o snapshot.  <!-- Observado em device: `edition=edition:2 cards=9` no log e os cards na tela, com `sourceTitle`/`publishedAt` do `CardPresentation`. -->
- [x] Gate de modo fechando os produtores legados de forma condicional, sem remover nada (a janela do ADR-004 D12 segue aberta), e a coluna de dono das plans lida por modo.  <!-- Um choke point em `RSSFetcher.performFetch`, outcome próprio `legacyProducerClosed`, fora de `sourceOutcomes` e do backoff; `legacy`/`mirroredShadow` inalterados. -->
- [x] Guarda contra o laço de edições sucessoras, e a instrumentação que o torna visível.  <!-- Observado: 807 edições/9.702 cards antes; 2 edições/42 cards estáveis depois, com uma linha por episódio/composição/snapshot. -->

**Gate:** satisfeito — pacote 489/0, fronteiras PASS (76 arquivos/153 imports), app plan 579/0, e um launch `v2Full` observado adquirindo e desenhando. **Limites nomeados** no relatório §6: os quatro de consequência de produto (bookmark recusado, BGTask sem fetch, seções por data ausentes, mídia nunca buscada) e os de implementação; mais os dois que a tela revelou, dos quais **um está corrigido** (o resumo com HTML cru: o texto canônico passava sem o sanitizador que a ingestão legada já usava — um dono agora, `FeedTextSanitizer.displayExcerpt`, baseline §8.52) e o outro segue aberto (placeholders de imagem: a publicação não compõe mídia). Os quatro limites de consequência de produto, com a disposição medida em 2026-09-18, estão em `baseline.md` §8.53: o bookmark está **fechado** (a projeção e o toque medido), o BGTask tem dono único estrutural mas a ligação ao runtime segue sem dono, as seções por data são **deliberadas** (a própria doc do pipeline recusa uma segunda regra de agrupamento) e a mídia está coberta pelo placeholder que a linha #22 da matriz aceita.

### PR-17 — Remoção do legado e repetição da prova de boundary

**Arquivos:** consumidores inventariados de FeedStore/FeedLoader/Reservoir/ReadyCardQueue e bridges; remover só responsabilidades aposentadas.

- [x] Buscar consumidores por símbolo/import, incluindo testes, background, Source/Search, reader/audio, export/import e configuração.  <!-- Feito (recon somente-leitura, baseline §8.26): arquivos Swift por símbolo, definições excluídas — `FeedStore` 47 (era 42 quando este spec foi escrito), `FeedLoader` 47 (era 45), `Reservoir` 11, `ReadyCardQueue` 4. Construções remanescentes: `FeedStore.swift:32`/`:38`, com `FeedLoaderProvider.shared` como dono do processo. -->
- [ ] Remover flags/bridges somente depois da janela de compatibilidade definida no ADR-004; documentar fim do rollback legado.  <!-- GATED on one remaining proof, and the other two reasons have fallen. The owner swap landed (V2 acquires); the user-state projection landed, so `v2Full` no longer refuses every action — a bookmark is written to `user.sqlite` (authority), projected into the runtime database and into `feedmine.sqlite` in the shape the legacy reader hydrates, with `legacy_item_map` as the durable alias and `ON CONFLICT(id) DO NOTHING` for the acted-on card only; and the upgrade half of the window's repeat is proven with the real binaries (baseline §8.28).
       What remains is the reverse half with the shipped binary: a bookmark taken in `v2Full` hydrating after reinstalling build 17.
       **Correction, 2026-09-18 — that tap has now been driven and the repeat run (baseline §8.50).** **Second correction, 2026-09-18 (baseline §8.55): a precondition of this removal was false until today.** The note above lists the owner swap as one of the reasons that "have fallen" because "V2 acquires" — and on a warm launch it did not. Every episode ended `stop=refused(batchConflict)` with `admitted=0`, so the runtime was composed and wired but not acquiring, which is not a state the legacy acquisition can be removed in front of. The ledger key now covers what the body covers, and two real `v2Full` launches ran `admitted=2 observations=24 stop=planCompleted` with **zero** `batchConflict` rows in the ledger. What still gates this item is the ADR-004 window itself — the owner's decision — not the proof, and not acquisition. A UI test (`feedmineUITests/RuntimeV2BookmarkWindowTests.swift`) launches the current build with `-RuntimeV2UI -RuntimeV2Network`, taps the card's bookmark control — which now carries `accessibilityIdentifier("card.bookmark")`, because the reason listed above was real and fixable rather than environmental — and the write lands in `user.sqlite` (authority) and in `feedmine.sqlite` in the shape the legacy reader hydrates, `feed_item` row included, with real title/source/excerpt/publication date. Installing the shipped Release build 17 (`CFBundleVersion 17`, `FeedmineGitSHA 4df951c4`) over that container and letting it run leaves both bookmark rows intact in both stores and both still resolving through `feed_item` — the only path build 17's hydration reads. What is **not** observed is a screenshot of build 17 drawing one of those cards as bookmarked, for a measured reason: its list was still on its loading skeleton, and the two projected rows sit 8.9 h and 2.2 h below the newest fetched row in a date-ordered feed this environment cannot scroll. So item 2's gate has moved rather than closed: the technical inability is gone, and what is left is the owner's product call — retiring legacy still retires the only path a rollback would use, and that is now a cost to accept, not a blocker to wait on. -->
- [x] Rodar a prova do segundo paradigma novamente, clean install e upgrade a partir do release suportado.  <!-- DELIVERED, all three parts measured (the note below about the reverse half belongs to item 2's blocker, not to this item — the two were conflated before this audit). The proof (`versionedStreamingConnectorUsesUnchangedRuntime`, SecondParadigmBoundaryTests.swift:50) is green in the package suite (493/0). A clean install was observed: a fresh container composes the runtime, acquires and draws (§8.25). The upgrade from the supported release was observed with the real binaries: build 17 rebuilt from its tag, then the current build over its container, every legacy row intact, runtime composed alongside (§8.28). The note kept for reading: with the real binaries (baseline §8.28). The tag ios/1.0-build.17-4df951c4 was rebuilt (no artifact existed on this machine) and run against a container of its own; installing the current build over it left every legacy row intact — feed_item 6,182 → 6,182, feedmine.sqlite byte-identical at 10,010,624 — while the runtime composed and acquired alongside (32 targets, 30 origins, 30 origin_search rows). So "upgrade a partir do release suportado" and ADR-004 D1's non-destructive rule are both proven on real data rather than synthetic.
       CLOSED with the shipped binary, 2026-09-18 (baseline §8.50): the identifier and the UI test this note predicted would close it are what closed it. It was proven at the STORE level first (the projection slice's rollback test: fresh connections, the legacy migrations, a fresh BookmarkStore, with breakage-sensitivity measured), and the four reasons this note listed were the *environment's* — three are still true and none decided the conclusion, because XCUITest drives the accessibility layer rather than `simctl`, and the mode is selectable by launch argument. What remains unobserved is the pixel, not the data: build 17's list was still on its loading skeleton, and the projected rows sort hours below the fold (§8.50). -->

**Gate:** um único runtime ativo e nenhuma superfície órfã; dados do usuário preservados sem depender de tabelas que seriam expurgadas.

## 15. Estratégia de testes e comandos de validação

### 15.1 Gates por classe

| Classe | Evidência necessária |
|---|---|
| Unit/reducer | clock/seed fixos; epochs e reorder de eventos; policies e hard filters |
| SQLite real | banco temporário em disco, WAL/FKs, migrations, CAS e reabertura; não só mocks |
| Property/replay | seeds salvos em falha; streams com duplicação/reordenação/cancelamento; comparação semântica |
| Crash | fault injection para rollback e processo auxiliar terminado entre commit/checkpoint/arquivo; reabrir e validar |
| Architecture | graph de módulos + scan limitado a código V2 + spies de SQL/rede; include testes negativos do gate |
| UI | âncora/scroll bidirecional, accessibility, Dynamic Type, ações, context switch e rerender |
| Upgrade/rollback | bancos de versões suportadas com dados sintéticos; operações V2 visíveis no modo legado |
| Performance | datasets fixos, build Release, dispositivo físico, amostragem declarada, traces e `.xcresult` |

Exceção lançada dentro da transaction prova rollback, mas não substitui teste de encerramento do processo. Testar “após COMMIT antes de notificação” é tão importante quanto “antes de inserir segmento”. Power-loss durability exige política de sync e ensaio específico; kill de processo não prova todas as falhas físicas.

SQL de verificação proposto para o harness, além das assertions de domínio:

```sql
PRAGMA integrity_check;
PRAGMA foreign_key_check;
SELECT edition_id, absolute_ordinal, COUNT(*)
FROM published_card GROUP BY edition_id, absolute_ordinal HAVING COUNT(*) > 1;
```

Resultados esperados: `ok`, zero linhas de FK violation e zero duplicações. Schema tests também verificam constraints, não apenas dados felizes.

### 15.2 Comandos existentes e futuros

Descobrir simulator disponível em vez de presumir o iPhone 14 Plus do script ou iPhone 16 do CI:

```bash
xcodebuild -list -project feedmine.xcodeproj
xcodebuild -showdestinations -project feedmine.xcodeproj -scheme feedmine
```

Após escolher um destino listado, usar `FEEDMINE_DESTINATION` e executar baseline diretamente, sem depender do script de smoke até ele ser corrigido:

```bash
: "${FEEDMINE_DESTINATION:?Defina um destino listado pelo xcodebuild}"
xcodebuild test -project feedmine.xcodeproj -scheme feedmine \
  -destination "$FEEDMINE_DESTINATION" \
  -testPlan FeedMine-ReleaseValidation
```

No PR-01 criar `TestPlans/FeedMine-RuntimeV2.xctestplan` e adicioná-lo ao scheme, incluindo explicitamente testes do package/app/UI apropriados:

```bash
xcodebuild test -project feedmine.xcodeproj -scheme feedmine \
  -destination "$FEEDMINE_DESTINATION" \
  -testPlan FeedMine-RuntimeV2
bash scripts/verify-runtime-v2-boundaries.sh
```

Esses dois últimos artefatos são futuros. Confirmar número/nome dos testes executados no `.xcresult`; saída verde com zero testes selecionados reprova o gate. Se houver suite host macOS para core, declarar plataforma e executá-la separadamente; `swift test` não substitui testes de UIKit/iOS.

## 16. SLOs, observabilidade e critérios de rollout

Os valores abaixo estão confirmados no Blueprint v0.4 §105 e permanecem metas iniciais, não resultados medidos neste checkout:

| Medida | Meta inicial | Fronteira da medição |
|---|---:|---|
| Warm presentation p50/p95 | <250/<500 ms | sessão aberta até primeiro snapshot aplicável com edition local válida |
| Context switch local p50 | <100 ms | intent recebido até snapshot do contexto local disponível |
| Candidate query p95 | <20 ms | leitura completa do pool indexado, dataset e tamanho registrados |
| MainActor apply | <4 ms como budget | somente aplicar snapshot; registrar p95 e máximo, excluindo decode/SQL |
| Rede no renderer | 0 | chamadas iniciadas pelo caminho visual do feed |
| Protocol decoding downstream | 0 | Selection, Publication, Session e Presentation |
| Mutação de payload publicado | 0 | exclui overlays e purge explícito documentado |
| Mutação editorial pós-publicação | 0 | A revisão editorial de uma publicação congelada não muda: coberta pelos guards append-only (PR-06) e pela imutabilidade da `EditorialRevision` (ADR-002). É a linha "Post-publication editorial mutation" do Blueprint §105, que faltava nesta tabela |
| I/O de disco bloqueante no `body` de uma view | 0 | Nenhuma view lê disco no corpo do renderer: as leituras do feed são materializadas antes (`rollout.md` §2.1). É a linha "Blocking disk I/O in View body" do §105, que faltava aqui, e não está instrumentada neste checkout — entra como revisão de código no piloto, não como contador |
| Stale publication/checkpoint ahead | 0 | violations são blockers, não médias toleráveis |

Adicionar memória peak/steady, bytes de assets/DB/WAL, energia, scroll hitch, tempo até primeiro card no cold start, cancellation latency e percentual de placeholders. Fixar budgets absolutos de memória/disco após baseline no dispositivo mínimo; até lá medir e bloquear crescimento sem limite, sem inventar números “aprovados”.

Instrumentar admission/selection/publication/window/decode/apply por operation ID/edition/epoch, sem URLs sensíveis. Emitir contadores de no-op batch, stale rejection, retry, orphan asset, shadow drop e rollback. Signposts existentes são referência de integração.

Warm restore válido não depende de network/Selection/catalog refresh. Se não existir edition compatível, classificar como cold/recovery; não esconder esse caso na distribuição de warm start. Queries que mudam suporte/render schema precisam migration ou rejeição explícita de restore.

Cada promoção de modo exige suite funcional verde, ensaio de rollback e relatório em dispositivo real. Definir antes do piloto uma janela de observação, aparelhos e amostra; não tomar uma única execução sem crash como estabilidade demonstrada.

Definido em [`docs/runtime-v2/pilot-plan.md`](../../runtime-v2/pilot-plan.md): os três gates de promoção (suite verde sob o compilador do CI, ensaio de rollback no container real, relatório em dispositivo real), as classes de aparelho e por que são elas, a matriz de cenários com o que cada linha pode e não pode afirmar, e a receita de leitura de cada medida do §16 com o instrumento que existe. Nenhum número absoluto é fixado ali, porque o §16 proíbe fixá-lo antes do baseline no dispositivo mínimo.

## 17. Definition of Done revisada

- [x] Documentos normativos identificados e requisitos rastreados a testes.  <!-- satisfied: 40/40 acceptance names anchored to executable tests; both suites green (§8.17, §8.24) -->
- [x] UI de feed recebe exclusivamente snapshots/intents da boundary de sessão.  <!-- satisfied, and every part of it measured rather than argued. Content, phase, emptiness and the empty variant are the session's for the selection its plan was built for; every other selection draws its own legacy page, which is a different source of truth rather than a second one (§8.31/§8.32). Every intent goes to the boundary first: refresh, shake, bookmark, open, viewport demand, per-card visibility (§8.35) and the open that is now the durable read (§8.39, "neither fact inferred from the other", D5). The four chrome residuals this item carried are closed by measurement: the loading lane (§8.37 — the legacy bar was a frozen `0/100` while the runtime watched 32), the first frame (§8.38 — my own before/after launch: 1 → 0 runway-sourced loading lines), the empty surface (§8.41) and the header chip (§8.42 — `"verified"` became `"watched"`, and the clause whose figure the runtime cannot state was dropped rather than invented). Gates on the final tree through the runner itself: package 495/0, app plan 603/0, `Runtime V2 test gate: PASS`. Not part of this item and still open: the owner's call on the legacy-visible read state (§8.36 item 2), and DoD15, which asks the other surfaces to move rather than this one to stop reading the legacy store. -->
- [x] Scroll emite observação bounded; runtime coordena reposição sem trabalho pesado no callback.  <!-- satisfied: PR-13 viewport observation; PR-09 proves the absence of network/decode by spy -->
- [x] Renderer nunca inicia rede; ações explícitas têm transporte/capability separados.  <!-- satisfied: PR-08 + PR-14; one caveat on a management surface recorded in §8.17 -->
- [x] Origem, versão, provider, source e target têm identidades distintas e mappings duráveis.  <!-- satisfied: PR-02 -->
- [x] Canonicalização e checkpoint são atômicos no mesmo banco; cross-DB projections são recuperáveis/idempotentes.  <!-- satisfied: PR-03/PR-04 -->
- [x] Revisions/payloads publicados imutáveis e append protegido por token/tail/constraints.  <!-- satisfied: PR-06 -->
- [x] Published cards sobrevivem ao expurgo autorizado de canonical revisions.  <!-- satisfied: PR-16, with the reachability assertions (§8.24) -->
- [x] Mídia publicada mantém bytes enquanto retida; decode eviction não altera sua identidade.  <!-- satisfied: PR-08 -->
- [x] Selection é reproduzível com todos os inputs e clock versionados.  <!-- satisfied: PR-05 -->
- [x] Warm restore local, refresh successor e rollback foram provados.  <!-- satisfied: device observation + PR-06 coordinator tests (§8.17) -->
- [x] Janela/filas/caches/streams têm limites e lifecycle testados.  <!-- satisfied: PR-07 + PR-09 -->
- [x] Exposure não usa onAppear como consumo e sobrevive a rerender sem duplicação.  <!-- satisfied: two tests, not one (§8.17) -->
- [x] Bookmarks, coleções, fontes importadas e históricos sobrevivem a upgrade, reconstrução e troca de modo.  <!-- satisfied: PR-16 rehearsals + the device mode switch (§8.24) -->
- [ ] Main/Source/Collection/Bookmark/Search/Smart Feed e demais surfaces usam o mesmo runtime.  <!-- open, now measured per surface (§8.31): the main surface's *acquisition* half was also exercised on the shipped binary on 2026-09-18 (§8.55): a warm `v2Full` launch ran `purpose=activeRunway … pulls=2 admitted=2 observations=24 stop=planCompleted`, where before that fix every episode ended `stop=refused(batchConflict)` with `admitted=0`, so the main surface's runtime-owned acquisition is now measured acquiring and not merely measured wired. main is runtime-owned in acquisition; search's local-content half reads the canonical index in v2Full; every other selection (bookmark box, Smart Feed, last-clicked, collection, curated) draws its own legacy page by design in this slice — the honest interim is that no surface shows another surface's content, not that all of them moved. source is refused (runtimeIdentityUnavailable), whatsNew has no view, persistentSearch's legacy composite read has no view consumer. Closes with PR-17 plus a plan per surface — **the plan is written: `docs/runtime-v2/rollout.md` §2.5** (2026-09-18), which reduces the remainder to one app-side session-lifecycle step plus two named decisions (`source`'s runtime identity, and the canonical-hit overlay §8.29 measures). -->  <!-- open: one surface moved (the Main Feed); the rest are a lifecycle step or a named decision away, per rollout §2.5. Its content path has since started: the selection's storage half landed 2026-09-18 (baseline §8.56, where the type was `SupplyRecordScope` and is now the domain's `SubjectSelection` — §8.57) — `SubjectSelection.savedSubjects(kind:listKey:)` resolved as one indexed join over `user_state_projection` and `legacy_item_map`, with the list key selecting one box's membership and `nil` the whole saved set (`.unresolvable` retired in §8.59) — so what remains is the plan's own selection field, because a `HistoryScope` is an eligibility rule and not a card selector (the reverted mapping is recorded in §8.56). That field landed the same day (baseline §8.57): `FeedPlan.subjectSelection`, stated by the caller through `FeedSurfaceCatalog.Inputs`, serialized into the revision (scheme 2) and passed straight into the query — the surface cannot imply it, because the catalogue's `bookmarks` row and the app's bookmark box share a name and nothing else. What remains is the screen composing through it. **And the order is now measured, not assumed (baseline §8.58):** a bookmark box's content is that *list's* membership (`selectedBookmarkListID` loads `bookmarkedItems(listID:)`), and the runtime projection has no list key — so the first step is projecting the list key (an app write plus a migration), then the screen, and the lifecycle step last. **The projection landed 2026-09-18 (baseline §8.59)**: `v7_user_list_membership` + `applyListMembership` + `SubjectSelection.savedSubjects(kind:listKey:)`, with tests proving a box selects its own membership and not every saved card. **Then the app's write landed (baseline §8.60)**: `UserStateBridge.setBookmarked` files the membership for the list the store chose, and `reconcileListMemberships` runs at launch so a bookmark predating the projection is still in its box. What remains for this surface is **the screen**. **And the screen was proven, and the proof corrected this note (baseline §8.62)**: `SurfaceContextAdapters` states the box's selection, the presentation reports a move off the session's selection, and `MainFeedRuntime.adoptSelectionIfNeeded` adopts only the box dimension (a preset move keeps its legacy page — a Smart Feed's cards are legacy rows). What the proof found is that the adoption runs and the surface does not follow it: the launch's log carries `page-source=legacy-page selection=…box=1` and then a snapshot `cards=1 context=…box=1`, so a box the reader opens starts a session and that session composes - while the screen keeps drawing the box's own page (the legacy bookmark-mode rows plus a loading placeholder, `feed-item-und-pending-flush`). Three defects on the way were found and fixed (a claim that blanked the page before the session could deliver; an attach that re-claimed a box the reader had opened; and a session re-using the presentation's `sessionStamp`, whose snapshots the store then refused as older than the selection the reader left). What remains is the box's **surface** - switching that screen to the presentation's rows - and that is what this item waits on. -->
- [x] Background usa o mesmo pipeline e conclui/cancela corretamente.  <!-- satisfied: PR-15; the system delivering the task is unobserved here -->
- [x] Aquisição tem um único owner, incluindo contexts secundários e BGTask.  <!-- satisfied: twelve duplicate-demand pairs closed, P9 last (§8.24) -->
- [ ] Segundo paradigma comprovado antes da remoção do legado e revalidado ao final.  <!-- open: proven before removal (PR-10/PR-11), and two of the revalidation's three parts are banked — the proof is green (497/0), a clean install was observed composing and acquiring, and the upgrade from the supported release was observed with the real binaries leaving every legacy row intact (baseline §8.25, §8.28). What remains is the re-run after the removal, which is why it is not ticked. -->
- [x] CI dispara para package/projeto/test plans e runners propagam falhas reais.  <!-- satisfied: verified against GitHub; red on main for reasons predating this work (§8.22) -->
- [ ] SLOs medidos com metodologia e ambiente; invariantes de integridade sem violações.  <!-- open: instrumentation landed (PR-16); the numbers need a Release build on the minimum device (§8.24) -->

## 18. Escopo e guardrails

Continuam fora: plugin framework universal, registry dinâmico, federação, credenciais genéricas, identidade global, recomendações comportamentais, telemetria remota obrigatória e protocolo de escrita universal. Não implementar um segundo ecossistema completo.

As estimativas de 5.800–8.800 linhas mais 600–1.000 do connector estão na Technical Architecture v0.1 §100; são guardrails, não compromisso de entrega. Considerar bridges, migrations, recovery, testes e observabilidade separadamente. Limites de arquivo são sinal para revisão de responsabilidades, não motivo para fragmentação artificial.

O início concreto fica: resolver evidência normativa/base de release → corrigir gates de CI → package/IDs → schema/Admission e estado durável → Selection/Publication local com mídia mínima → Session/Runway → fake connectors e prova de boundary → RSS/Atom → shadow → UI → surfaces/owner único → rede/background → hardening → remoção do legado.

O ganho principal desta revisão é tornar rollback, durabilidade, identidade e medição requisitos executáveis desde o começo, evitando descobrir essas dependências depois que a UI já estiver migrada.

## 19. Matriz dos 40 pontos do Blueprint §122

As decisões abaixo são a proposta para o freeze. Os nomes dos testes são critérios futuros concretos, não testes existentes nem executados. O ADR indicado precisa registrar a decisão; o PR precisa produzir a evidência correspondente.

| # | Questão / decisão proposta | ADR | PR | Teste de aceite proposto |
|---:|---|---|---|---|
| 1 | Source é unidade editorial FeedMine; não endpoint | 003 | 02 | `sourceCanHaveMultipleBindings` |
| 2 | SourceID opaco, chave editorial durável e mapping persistido | 003 | 02–03 | `endpointChangePreservesSourceIdentity` |
| 3 | Provider representa atribuição/autoria; distinto de agrupamento Source | 003 | 02,05 | `oneSourceContainsMultipleProviders` |
| 4 | Binding liga Source a configuração externa versionada | 003,006 | 03 | `bindingChangeInvalidatesOldGeneration` |
| 5 | Target representa trabalho operacional, não identidade editorial | 005 | 10 | `targetIsIndependentOfSourceIdentity` |
| 6 | Targets compartilhados por configuração/escopo compatível e leases | 005 | 10 | `twoSourcesShareTargetWithoutDuplicateWork` |
| 7 | OriginRecord é objeto lógico namespaced aceito | 003 | 03 | `sameExternalKeyResolvesSameRecord` |
| 8 | OriginRevision é representação imutável aceita | 003,006 | 03 | `revisionPayloadCannotBeUpdated` |
| 9 | Object/version keys opacas separadas, sem revision counter universal | 003 | 02–03 | `versionKeyIsNotAssumedGloballyOrdered` |
| 10 | Aliases preservam escopo e evidência; merge não destrutivo | 003 | 02–03 | `ambiguousAliasDoesNotMergeOrigins` |
| 11 | Membership editorial e target/binding observado são relações distintas | 003 | 03 | `targetObservationDoesNotImplyMembership` |
| 12 | Equivalência forte via Entity; semelhança via Cluster reversível | 003 | 05 | `clusterSplitPreservesOriginalRecords` |
| 13 | replyTo/repostOf/quoteOf/references só quando têm uso de produto | 003 | 03,10 | `unknownExternalRelationStaysEvidence` |
| 14 | authored/modified opcionais; observed sempre local; fallback explícito | 003 | 02,05 | `missingAuthoredAtDoesNotBecomeClaimedPublicationDate` |
| 15 | EditorialRevision deriva policies/inputs editoriais versionados | 002 | 05 | `editorialPolicyChangeChangesRevision` |
| 16 | RenderEnvironmentRevision muda materialização, não história | 002,001 | 07 | `dynamicTypePreservesEditionAndCardIDs` |
| 17 | Edition válida exige schema suportado, payload íntegro e contexto compatível | 001,002 | 06–07 | `compatibleEditionRestoresWithoutSelection` |
| 18 | Refresh/context/lifecycle substituem explicitamente; catálogo passivo não | 002 | 07,13 | `passiveCatalogChangeDoesNotSwapVisibleEdition` |
| 19 | Congelar texto, attribution/membership escolhido, timestamp, mídia, ações e render contract | 001 | 06 | `upstreamAndCatalogEditsLeavePublishedPayloadUnchanged` |
| 20 | Persistir exact revision ID e valores necessários sem join obrigatório futuro | 001,004 | 06 | `revisionEvictionDoesNotBreakPublishedCard` |
| 21 | AssetVersion/digest persistem após cache eviction; bytes retidos por roots | 001,004 | 08 | `decodedEvictionPreservesExactPublishedAsset` |
| 22 | Texto + thumbnail/poster ou placeholder determinístico bastam; vídeo integral não obrigatório | 001 | 06,08 | `offlineCardDoesNotRequireRemotePlaybackAsset` |
| 23 | Cursor por card/ordinal/offset e compensação no shift bounded | 001 | 07,13 | `windowShiftPreservesAnchorInBothDirections` |
| 24 | Mesma PublicationCardID; dwell/intervalo separados da vida da view | 007 | 07 | `rerenderDoesNotDuplicateExposure` |
| 25 | Preparar successor e primeiro segmento antes do swap; falha mantém anterior | 001,002 | 06–07 | `failedRefreshKeepsPreviousEditionVisible` |
| 26 | Só PublicationCoordinator expõe append | 001,006 | 06 | `connectorAndMediaCannotAppendSegments` |
| 27 | Single-flight + tail CAS + uniqueness em SQLite | 006 | 06 | `twoCoordinatorsCannotCommitSameTail` |
| 28 | Batch limitado, target stamp válido, observations coerentes e receipt idempotente | 005,006 | 03 | `invalidBatchDoesNotMutateCanonicalState` |
| 29 | Conteúdo, rejeições autorizadas e checkpoint na mesma transação | 006 | 03 | `checkpointNeverAdvancesPastCommittedProgress` |
| 30 | Generation/binding/lease verificados na escrita, inclusive stream tardio | 006 | 03,10 | `revokedStreamCannotMutateSupply` |
| 31 | Connector traduz precedência, core aplica instrução/CAS genéricos | 006 | 03,11 | `olderRevisionRemainsHistoricalAfterNewerCurrent` |
| 32 | Stale work pode deixar apenas cache sem vínculo ou diagnóstico limitado autorizado | 006,004 | 03,08 | `staleWorkCannotUpdateMembershipOrCheckpoint` |
| 33 | Snapshot/chave durável independentes de evidence/revisions reconstruíveis | 004 | 04,16 | `evidencePurgePreservesBookmarksAndHistory` |
| 34 | HistoryScope explícito por plano; seen/read/click não se confundem | 007 | 07,14 | `mainExposureDoesNotHideBookmarkOrSourceHistory` |
| 35 | Frontier finita head/active/exploration por work/target e orçamento | 005 | 10 | `frontierRemainsBoundedUnderCatalogGrowth` |
| 36 | Cada purpose possui limites de target/request/byte/host/conexão/tempo | 005 | 10,15 | `purposeBudgetStopsAcquisitionWithoutLosingCheckpoint` |
| 37 | Exhausted/degraded explícitos; história continua navegável, retry bounded | 005,002 | 09,13 | `noSupplyDoesNotLoopOrEraseHistory` |
| 38 | PrimaryAction/ActionID publicado; executor atrás de Session/Interaction | 001,005 | 14 | `actionExecutesWithoutProtocolBranchInView` |
| 39 | Read/ingestion; não implementar escrita/federação/credenciais universais | 005 | 01,10 | `coreHasNoUniversalProtocolWriteDependency` |
| 40 | Segundo paradigma precisa rodar fixtures sem mudar downstream | 005,003 | 10,17 | `versionedStreamingConnectorUsesUnchangedRuntime` |

Decisões adicionais para completar essa matriz:

- `HistoryScope`: Main aplica seen/consumed de descoberta; Source preserva histórico navegável; Bookmark preserva lista salva independentemente de seen; Search não elimina resultado apenas porque apareceu no Main; Collections/Smart Feeds explicitam policy e versão. Click/read durável pode aparecer como overlay em qualquer superfície sem excluir card automaticamente.
- Center crossing é um fato separado de dwell. Fast fling pode registrar passagem, mas não seen pela policy inicial de 50%/1 s. Abrir ação gera opened/action sem bloquear navegação por escrita de histórico.
- Stale work: default rejeita todas as mutations canônicas, checkpoint e projections. Download já concluído pode permanecer como orphan content-addressed sob quota de cache; diagnóstico sem dados sensíveis pode contar rejeição. Cache não autoriza associação retroativa ao record.
- Missing headline/link é válido: presentation usa excerpt/body como texto primário quando necessário, e ação pode estar ausente ou usar handle. Nunca sintetizar URL HTTP para satisfazer uma view antiga.
- `PublicationSchemaVersion` é independente de `SelectionSchemaVersion`, versão do connector/checkpoint e versão editorial. Restauração incompatível requer migration determinística ou nova edition; nunca interpretação permissiva de payload desconhecido.

## 20. Conciliação com os documentos fornecidos

### 20.1 Origem e versão das referências

Os arquivos abaixo foram recebidos nesta tarefa. Os hashes permitem verificar a versão antes da execução; não substituem versioná-los junto dos ADRs quando o freeze for aprovado.

> **Verificado em 2026-09-18.** Os três estão versionados em `docs/runtime-v2/references/` — `feedmine-feed-runtime-unified-architecture-blueprint-v0.4.md`, `feedmine-feed-runtime-v2-technical-architecture-v0.1.txt`, `how-unusual-feedmine-really-is.txt` — e as três cópias conferem **exatamente** com os hashes registrados abaixo (`shasum -a 256 docs/runtime-v2/references/*`). O versionamento que este parágrafo trata como passo do freeze já está feito; o que o freeze acrescenta é a decisão, não a cópia.

| Documento | SHA-256 | Uso |
|---|---|---|
| Blueprint v0.4, 17/09/2026 | `b230342258566a2366dd07cd64eea5672504e2f7dff3b3b7f3fa7a55a07344e7` | Contratos semânticos, §122 com 40 decisões, §105 SLOs |
| FeedMine Feed Runtime V2 — Technical Architecture Specification v0.1 | `f8484da4da0ff3778728cfc7ba0edba785ceb7ca257ff7ee9c8ab84d86cb29c3` | Organização técnica candidata, invariantes I-01… I-20, budgets indicativos |
| [How unusual FeedMine really is](</Users/wagnermontes/Downloads/How-unusual-FeedMine-really-is.txt>) | `68fd07fbf3363350ba69b189cd6255caa445cf190f14db97df9678865f10ad32` | Contexto de produto, não especificação de implementação |

O documento de posicionamento contém referências a pesquisas/concorrentes não verificadas nesta tarefa. Não usar suas afirmações de mercado como fatos novos comprovados. Seu objetivo declarado de descoberta ampla, multilíngue e multimídia orienta fixtures e métricas do produto, sem ampliar esta migração para governança pública ou um novo backend.

### 20.2 Ajustes intencionais à sequência e estrutura candidatas

| Proposta dos documentos | Ajuste desta revisão | Motivo e registro necessário |
|---|---|---|
| Cinco targets; Media dentro do runtime | Sexto target FeedMedia para implementação física; coordenação editorial continua no runtime | Separar UIKit/ImageIO/HTTP sem espalhar GRDB. Decisão adicional de empacotamento no PR-01, não requisito textual do Blueprint. |
| Runtime depende de Storage concreto | Preservado; sem protocols por repository para mocks | Alinhamento com Technical Architecture §§6/102 e redução de abstração. |
| Source/Provider declarativos no catálogo | Tabelas runtime de identidade/mapping/projeção só para referências e fontes locais | Catálogo permanece autoridade editorial; não criar cópia editável concorrente. Edição pessoal continua no user storage. |
| Admission aparece na fase 8 | Contrato e transação mínimos no PR-03 | Fixtures de supply devem provar o write path real; coordinator/fakes continuam no PR-10. |
| Media completa após Publication | Placeholder/asset local mínimos junto de Publication | Evita declarar freeze de mídia antes de existir contrato testável de asset. |
| Network experiment antes das surfaces secundárias | Experimentos isolados possíveis no PR-11; troca global de ownership só após inventário/bridges do PR-14 | Evita legado de Search/Smart Feed/background continuar adquirindo junto ao V2. |
| Prova de segundo ecossistema por último | Antecipar para PR-10 e repetir no PR-17 | Descobrir vazamento de semântica enquanto ainda é barato corrigir o core. |
| Identidade de mídia sobrevive à eviction | Metadata sempre preservada; bytes protegidos durante retenção de publicação | Mais forte para exact restore. Após remoção deliberada dos bytes, só identidade/layout/fallback são garantidos; isso não é reprodução da imagem original. Fechar alcance no ADR-004. |
| Exemplo de `AsyncThrowingStream` no connector | Manter interface assíncrona com buffer/ack limitados ou AsyncSequence que suspenda producer | AsyncThrowingStream por si só não garante backpressure; o adapter deve impedir crescimento/perda silenciosa. |
| Fingerprint e chave externa completa descrita como evidence | Chave completa necessária à idempotência reside em external_identity enquanto record/mapping precisarem dela | Raw evidence pode expirar antes. Removê-la não pode eliminar verificação de colisão ou criar duplicata no replay. |
| Baseline read/ingestion | Ações locais/abertura/media permitidas; writes externos seguem fora do core | Separar action handle pronto para extensão de implementação de likes/reposts/federação. |

### 20.3 Cobertura de produto que não pode sumir na migração

Adicionar fixtures com scripts RTL/CJK/latino, idioma desconhecido, texto sem título, conteúdo sem link HTTP, podcasts, vídeo com poster e fonte de baixa frequência. Testar catálogo grande sem inicializar um actor/conexão por Source.

Não transformar health de rede em quality editorial: erro HTTP altera cadence/backoff, não score de qualidade. Missing quality/language tem policy explícita; uma fonte pequena/lenta não deve desaparecer apenas por menor frequência de publicação. Medir diversidade por Provider e cobertura das preferências do plano, evitando quotas arbitrárias que violem filtros explícitos.

BootstrapPlan é finito e termina no primeiro entre publication gate alcançado, deadline ou budget exaurido. Contar operações, bytes, hosts, redirects e conexões por purpose. Baseline técnica de concorrência: 4 targets ativos, 2 operações HTTP por host e 2 media transfers; números iniciais tunáveis, nunca permissão para iniciar todas as fontes do catálogo.

Política inicial por purpose: `userInitiated` tem prioridade e mantém limites; `bootstrap` encerra no gate mínimo sem esperar catálogo; `activeRunway` atende déficit bounded; `speculative` é a primeira categoria cancelada sob pressão e pode ter orçamento zero; `backgroundMaintenance` respeita deadline/expiration e não inicia trabalho sem checkpoint retomável. Salt local de instalação entra no jitter estável para não sincronizar clientes.

Tombstones/deletion requests alteram availability futura, não apagam a publication por cascade. Se o produto precisar revogar a exibição de uma publication retida, usar `PublicationOverlayPolicy` explícita conforme Blueprint §44; purge físico autorizado por retenção/usuário continua operação distinta.

Os 20 invariantes da Technical Architecture §107 ficam cobertos pelas seções 5–17: I-01…05 boundaries/rede; I-06…10 revision/publication; I-11…12 Admission; I-13…15 janela/identity/exposure; I-16 durable state; I-17 quality versus health; I-18 targets de connector; I-19 budgets; I-20 viewport sem loadMore direto. A matriz executável do PR-00 deverá ligar cada I-nn aos testes reais, além dos 40 pontos acima.
