# PARTE 1 — ANEXO

## §17. Plano de migração normativo (anexo)

Esta seção é o plano normativo de migração delegado pela §16. Ela define como o estado persistido do runtime legacy entra no Runtime V2 sem transformar identidades legacy em identidades canônicas, sem rekey destrutivo e sem exigir que o cutover de UI ou acquisition aconteça junto com a migração.

As regras desta seção são parte do contrato de ADR-003. ADR-004 continua autoridade sobre durability, retention, recovery e a duração da compatibility window; ADR-001 e ADR-007 continuam autoridades sobre `PublicationCardID` e history; ADR-005/ADR-006 continuam autoridades sobre acquisition e transactional admission.

### 17.1 M1 — `SourceID` legacy nunca é convertido em `SourceID` runtime

`FeedEngine.SourceID` (`UInt32`) é identidade de catálogo legacy. `FeedDomain.SourceID` é identidade local alocada pelo Runtime V2.

A migração MUST NOT:

- widening-cast `UInt32` para `UInt64`;
- derivar runtime `SourceID` do URL normalizado;
- derivar runtime `SourceID` de `CatalogIdentity.stableUInt32Digest`;
- reutilizar catalog row order ou catalog integer id como runtime identity.

Para uma Source de catálogo, a tradução normativa é `legacy_source_map`.

Quando o mapping não existir, ausência de mapping é um estado incompleto, não uma recusa terminal:

```text
catalog Source
    ↓
lookup legacy_source_map
    ↓ missing
ensureRuntimeSourceIdentity(...)
    ↓
allocate FeedDomain.SourceID
    +
persist legacy_source_map
    ↓
return durable runtime SourceID
Allocation, lookup de confirmação e gravação do mapping MUST ocorrer como uma única operação transacional lógica no mesmo runtime database. Callers concorrentes MUST convergir para o mesmo runtime_source_id.

Um mapping existente e não disputado MUST vencer qualquer tentativa de re-derivação.

Se identidades legacy não pertencentes ao catálogo precisarem de bridge próprio, uma estrutura adicional só pode ser introduzida após provar que legacy_source_map não representa corretamente aquele namespace. Não se cria um segundo source bridge para catálogo.

17.2 M2 — legacy_item_map é a autoridade da migração de item legacy
O FeedItem.id histórico é tratado como chave opaca de namespace legacy.

A migração MUST NOT reconstruir identidade externa a partir do hash armazenado. Em particular, não pode inferir novamente:

RSS GUID;
Atom id;
link original;
a escolha guid → link → title|publishedAt usada por FeedItem.generateID;
equivalência com outro item apenas por URL, título, timestamp ou digest semelhante.
O caminho normativo é:

legacy FeedItem.id
    ↓
legacy_item_map
    ↓
OriginRecordID
OriginRevisionID?
confidence
Backfill de um item não mapeável MUST resultar em mapping unresolved ou low-confidence conforme o schema vigente. Ele MUST NOT escolher outro OriginRecord por heurística.

Uma referência durável unresolved bloqueia o cutover da superfície que depende dela; ela nunca autoriza descarte silencioso do estado do usuário.

17.3 M3 — Canonicalization version é parte da ponte legacy
Todo mapping cujo input depende da canonicalização legacy MUST carregar canonicalization_version.

A versão identifica o algoritmo que produziu a chave de catálogo. Ela muda somente quando a canonicalização muda de forma capaz de produzir uma chave diferente.

Mappings de versões anteriores são imutáveis.

Em uma mudança de versão:

o runtime procura a identidade previamente estabelecida;
continuidade pode ser carregada para a nova versão somente quando for inequívoca;
a nova versão pode apontar para o mesmo runtime SourceID;
uma ambiguidade nunca causa merge automático;
conflito ou evidência insuficiente produz recusa/auditável, não re-point silencioso.
Uma nova versão de canonicalização não autoriza renumerar SourceID.

17.4 M4 — A migração é aditiva; bancos legacy não são rekeyed
feedmine.sqlite, user.sqlite e o catálogo permanecem legíveis pelo caminho legacy durante a compatibility window.

A migração MUST NOT alterar primary keys legacy para usar IDs do Runtime V2 e MUST NOT exigir erase/recreate de banco como mecanismo de upgrade.

Estruturas de migração pertencem ao Runtime V2, incluindo os mappings necessários para voltar da representação legacy à identidade runtime.

Até o gate de retirada do legacy:

feed_item.id continua intacto;
bookmark keys continuam intactas;
source_identity legacy continua intacta;
collection membership legacy continua intacta;
filtros/preferences persistidos continuam intactos;
nenhum runtime integer ID vira retroativamente a chave de uma tabela legacy.
Rollback antes da retirada do legacy MUST significar: desligar ownership V2 e voltar a ler o estado legacy existente, não reconstruí-lo a partir do runtime.

17.5 M5 — Estado durável do usuário é copiado ou bridged antes de mudar ownership
A migração de user state segue:

legacy authority
    ↓
resolve identity
    ↓
copy / bridge / project
    ↓
verify
    ↓
only then permit V2 ownership
Ela nunca segue:

move → delete legacy → attempt reconstruction
Devem sobreviver ao menos:

bookmarks e seu snapshot;
read state;
clicked/opened/consumed state existente;
imported Sources;
Source collections/memberships;
enabled/disabled source state quando aplicável;
filtros e preferences persistidos necessários para reconstruir o contexto visível.
Uma cópia V2 não transforma a origem legacy em dispensável enquanto a compatibility window estiver aberta.

Nenhuma referência durável pode ser descartada apenas porque o conteúdo correspondente já expirou de feed_item.

17.6 M6 — Identidade de card legacy e identidade de ocorrência publicada são diferentes
FeedItem.id é identidade legacy do item.

Qualquer valor determinístico produzido a partir de FeedItem.id pelo compatibility bridge é apenas compatibility identity. Ele MUST NOT ser interpretado, persistido ou propagado como se fosse um PublicationCardID alocado por publication.

PublicationCardID nasce exclusivamente da publication transaction que cria a ocorrência persistida em published_card.

Portanto o handoff correto é:

legacy item
    ↓
legacy_item_map
    ↓
OriginRecord / OriginRevision
    ↓
runtime publication
    ↓
persisted published_card
    ↓
PublicationCardID
    ↓
CardPresentation / actions / exposure
Um card compatibility pode continuar usando identidade legacy enquanto sua superfície permanecer legacy-owned. A troca de owner acontece na boundary completa, não pela substituição do string id por outro hash.

17.7 M7 — Novos ingressos preservam a identidade externa antes de FeedItem
O legado já perdeu o GUID cru de itens históricos; isso não pode ser reparado retroativamente.

Para novos ingressos que também alimentem Runtime V2, external identity MUST ser capturada antes da redução para FeedItem.

Para syndication:

RSS GUID permanece opaco;
Atom id permanece opaco;
link é evidência distinta;
nenhuma dessas chaves é reconstruída a partir de FeedItem.id;
OPMLParser.normalizeURL não é aplicado a GUID/Atom id;
fallback de identidade é explícito, versionado e low-confidence.
O shadow/runtime pode reutilizar bytes/parsing adquiridos pelo owner legacy, mas deve receber a evidência necessária antes que o modelo legacy a descarte.

17.8 M8 — Bootstrap da migração não implica cutover
O Runtime V2 pode criar/migrar seu database e executar backfill enquanto o shipping mode continua legacy.

O primeiro bootstrap MUST NOT, por si só:

trocar Main Feed para V2;
iniciar uma segunda árvore de network acquisition;
tornar Runtime V2 autoridade de bookmarks;
tornar aliases do bridge publication identity;
apagar conteúdo ou estado legacy.
Bootstrap de Source identity usa estratégia híbrida:

um batch limitado e resumable em launch;
lazy ensureRuntimeSourceIdentity quando uma Source ainda não mapeada é realmente necessária.
Um catálogo parcialmente mapeado é válido durante o bootstrap. Uma superfície V2 que necessita de uma Source ainda não mapeada executa ensure; só recusa quando um mapping durável e não disputado não puder ser estabelecido.

17.9 Ordem normativa dos slices
Os slices são executados nesta ordem porque cada um só pode criar referências para uma identidade que o slice anterior já tornou durável.

Ordem	Slice	Resultado obrigatório antes do próximo
0	Bootstrap seguro	Runtime database/migrations podem executar em shipping legacy sem assumir UI ou network ownership.
1	Source bridge	ensureRuntimeSourceIdentity e legacy_source_map são atômicos, idempotentes, concorrência-safe e resumable.
2	Item/Origin backfill	feed_item.id resolve por legacy_item_map; nenhum GUID é reconstruído e nenhum merge heurístico acontece.
3	Durable user-state bridge	Bookmarks, snapshots, read/action state, imported Sources, collections e preferences têm caminho verificável de coexistência/rollback.
4	New-ingress identity capture	Novos itens preservam external keys antes da redução para o modelo legacy.
5	Migration audit	Coverage, unresolved mappings e conflicts são contáveis; qualquer perda potencial de durable state bloqueia cutover.
6	Card identity separation	Compatibility identity e PublicationCardID são tipos/owners distintos; nenhum hash legacy é aceito como published occurrence.
7	Publication/presentation handoff	Runtime-published cards usam PublicationCardID persistido em actions, exposure e restore governed pelo runtime.
8	Controlled cutover	Somente após audit verde uma superfície pode trocar ownership; rollback legacy permanece disponível pela janela definida em ADR-004/release policy.
Slices MAY be divided into smaller PRs. Their dependency order MUST NOT be inverted.

PR-15's previously completed single-acquisition-owner/background-refresh work is not reopened por esta migração; card identity/publication cutover pertence aos slices 6–7.

17.10 Riscos de perda de dados por tabela/estado
Autoridade / tabela	Risco durante migração	Regra mínima de preservação
catalog_source / catalog identity	Tratar UInt32/row identity como runtime SourceID; perder continuidade após rebuild/canonicalization change.	Resolver exclusivamente por persisted mapping + canonicalization version; nunca cast/re-derive.
runtime-v2.sqlite.legacy_source_map	Source alocada sem mapping após crash; mapping concorrente divergente.	Allocation + mapping no mesmo write transaction; replay idempotente; conflito tipado/auditável.
feedmine.sqlite.feed_item	Retention remover row antes que identity/user state seja bridged; tentativa de reconstruir GUID inexistente.	FeedItem.id é opaco; backfill/mapping não depende de recuperar GUID; nenhuma deleção adicional pela migração.
runtime-v2.sqlite.legacy_item_map	Merge heurístico, re-point ou perda de item unresolved.	Mapping additive; confidence explícita; conflicts/unresolved bloqueiam cutover da referência durável.
user.sqlite.bookmark_item	Rekey para runtime integer quebrar bookmarks ou rollback.	Preservar (list_id, item_id) legacy durante compatibility window; projetar via mapping.
user.sqlite.bookmark_snapshot	Bookmark sobreviver sem conteúdo, mas perder payload mínimo necessário à hidratação.	Snapshot continua durability root conforme ADR-004; migration não depende da existência futura de feed_item.
feedmine.sqlite.feed_item.is_read e timestamps de interação existentes	Retention/cutover apagar read/click/consume semantics.	Copiar/projetar antes de mudar authority; não considerar migration concluída enquanto estado referenciado estiver sem representação.
user.sqlite.imported_source	Substituir source_identity por runtime ID e perder request URL/continuidade.	Preservar row/key legacy; runtime Source é associada por bridge aditivo.
user.sqlite.source_collection_member	Membership deixar de resolver após Source reallocation/canonicalization bump.	Preservar source_identity; resolver runtime Source por mapping, nunca por cast/digest.
Legacy source enable/toggle/history state	V2 aparecer com eligibility diferente do usuário após cutover.	Inventariar e projetar todo estado que altera eligibility antes da troca de ownership.
UserDefaults de filtros/contexto (filterRegion, taxonomy, content type, mood, languages e correlatos)	Startup V2 silenciosamente resetar o contexto visível.	Ler/preservar ou migrar explicitamente; ausência de equivalência é migration-audit failure, não default silencioso.
source_health e validators HTTP	Perda causa refetch/revalidation desnecessário e pode alterar timing de bootstrap.	Classificar como operational/reconstructible; não confundir sua perda com perda de identity ou user state.
published_card / history keyed by card	Alias compatibility ser tratado como FK de publication, gerando no-op ou history incorreto.	Somente ID persistido pela publication transaction entra no runtime history/action path.
A migration audit MUST distinguir:

mapped
unmapped-but-allocatable
unresolved
conflicted
durable-reference-at-risk
durable-reference-at-risk > 0 impede cutover.

17.11 Rollback e irreversibilidade
Até o primeiro cutover V2:

todo trabalho desta seção é aditivo;
apagar/recriar apenas o runtime database deve deixar o produto legacy semanticamente íntegro;
nenhum schema legacy é rekeyed;
nenhum user state legacy é removido.
Depois que uma superfície passa a ser V2-owned, rollback ainda é suportado enquanto a compatibility window mantiver as authorities legacy necessárias.

Remoção de tabelas, conteúdo ou caminhos legacy é um gate posterior. Ela não pertence ao bootstrap nem ao primeiro cutover.

Um migration que só funciona depois de apagar a origem legacy viola esta seção.

17.12 Itens que permanecem decisão humana
As seguintes decisões não são inferidas pelo migration code:

Quando Runtime V2 vira shipping default.

preparar/migrar primeiro e cortar em release posterior;
cutover audit-gated no mesmo release;
rollout staged/flagged.
A escolha altera risco operacional, não a identidade definida neste ADR.
Duração da compatibility/rollback window.

uma release;
múltiplas releases;
até critério quantitativo explícito.
A escolha determina quando remoção legacy pode começar.
Retenção de longo prazo de read/click/consume depois que o conteúdo deixa o corpus ativo.

acompanhar content retention;
janela independente;
retenção mais longa.
ADR-004 deve congelar a política antes de qualquer GC que possa apagar fatos necessários.
Gate humano de freeze e de release.
O código pode provar invariantes e migration coverage; ele não transforma sozinho o status deste ADR em aprovado nem autoriza o cutover público.

Não permanecem pendentes de humano:

converter versus não converter catalog SourceID: não converter;
missing Source mapping: ensure/allocate;
ambiguous identity: não auto-merge;
reconstruir GUID histórico: não reconstruir;
rekey destrutivo de bookmarks/user state: proibido;
usar bridge hash como PublicationCardID: proibido;
descartar durable references unresolved: proibido.
PARTE 2 — EDIÇÕES EXATAS
Edição 1 — inserir o anexo antes da seção de traceability
ARQUIVO: docs/runtime-v2/adrs/ADR-003.md

ÂNCORA: ## Traceability

SUBSTITUIR POR:

## §17. Plano de migração normativo (anexo)

seguido integralmente pelo conteúdo da PARTE 1 acima a partir do primeiro parágrafo após esse heading até o final de §17.12, e então:

## Traceability

MOTIVO: tornar o plano de migração parte normativa do ADR sem reescrever as decisões D1–D19 e sem depender de um documento externo para executar o handoff da §16.

Edição 2 — remover da §16 a afirmação de que o plano detalhado ainda está ausente
ARQUIVO: docs/runtime-v2/adrs/ADR-003.md
ÂNCORA: a frase verbatim da §16 que declara que o plano de migração detalhado ainda precisa ser produzido/delegado não está presente nos fatos textuais disponíveis nesta conversa nem no snapshot 70f7b06b acessível; portanto uma âncora literal não pode ser fornecida sem inventar texto.
SUBSTITUIR POR: The normative migration plan is §17 of this ADR. The eight migration inputs above are its required inputs, not a delegation to a future document.
MOTIVO: depois da inserção de §17, qualquer afirmação de que o plano ainda falta passa a contradizer o próprio ADR. Antes do commit, esta substituição deve ser aplicada usando como âncora a frase literal da §16 do working tree, sem aproximação textual.
Status: não alterar. A inserção do plano fecha um pré-requisito do Gate 0, mas não constitui o sign-off humano dos sete ADRs. A linha atual deve permanecer Proposed — freeze pending sign-off (Gate 0 not complete) até a sessão de Gate 0 ser aprovada.