# FeedMine Runtime V2 — Gate 0 Freeze Checklist

**Objetivo:** sessão única de sign-off que muda `ADR-001…ADR-007` de **“Proposed — freeze pending sign-off (Gate 0 not complete)”** para arquitetura congelada.  
**Regra:** Gate 0 aprova decisões normativas; não declara implementação completa. `baseline.md` continua sendo registro de fatos/defeitos medidos, não prova automática de conformidade (`docs/runtime-v2/baseline.md:5`).

# 1. PRÉ-CONDIÇÕES

| # | Pré-condição | Evidência obrigatória |
|---|---|---|
| P0.1 | Os sete ADRs presentes e todos na mesma revisão que será assinada. | `docs/runtime-v2/adrs/ADR-001.md` … `ADR-007.md`; conferir status no header. |
| P0.2 | O índice de decisões D1…Dn de cada ADR bate com o documento efetivamente revisado; nenhum D foi renumerado silenciosamente. | Os próprios `ADR-00x.md` + tabela §19 do plano (`plano 2026-09-17:120-126`). |
| P0.3 | **Adendo A de ADR-003 incorporado ou referenciado normativamente:** allocation de runtime `SourceID`, bootstrap híbrido, `missing → ensure/allocate → refuse somente em falha`. | ADR-003 D2/D18 + implementação existente do bridge `RuntimeMigrations.swift:414-423`, `SourceRegistry.swift:30-65`; problema atual registrado em `rollout.md:118,155,338-342`. |
| P0.4 | **Adendo C de card identity incorporado ou referenciado:** alias do bridge não é `PublicationCardID`; runtime card ID só nasce em publication transaction. | `MainFeedCardBridge.swift:234-247`; `PublicationRepository.swift:1042`; `rollout.md:120,343-349`. |
| P0.5 | ADR-004 declara inequivocamente que bookmarks autoritativos estão em `user.sqlite`; as tabelas homônimas de `feedmine.sqlite` são legado. | `FeedStore.swift:7703-7737,7849-7869`; `BookmarkStore.swift:6-11`; `UserStateStore.swift:209-233`. |
| P0.6 | ADR-005 D17 está delimitado ao runtime V2; o audio probe do fetcher legacy está explicitamente classificado como coexistência. | `RSSFetcher.swift:499-533`. |
| P0.7 | ADR-007 D3/D4 só tratam como `PublicationCardID` real IDs vindos de `published_card`; persisted-position legacy não é apresentado como implementação de restore V2. | `MainFeedCardBridge.swift:234-247`; `FeedScreen.swift:15,1337,1452`; `rollout.md:49`; `baseline.md:1168,1259-1264`. |
| P0.8 | Referências factualmente antigas corrigidas, especialmente allocation em `PublicationRepository` e bookmark paths. | allocation real: `PublicationRepository.swift:1042`; bookmark writes: `BookmarkStore.swift:231-252,432-435`. |
| P0.9 | `baseline.md` atualizado após as correções acima, sem continuar descrevendo como aberta uma decisão já fechada. | `docs/runtime-v2/baseline.md`; preservar a distinção “measured fact vs proposed architecture” de `baseline.md:5`. |
| P0.10 | Test suite relevante verde e transcript preservado. | Suites existentes incluem `BackgroundRefreshDemandTests.swift`, `CardActionBoundaryTests.swift`, `CardPresentationTests.swift`, `CatalogIdentityContractTests.swift`, `FeedEngineBoundaryTests.swift`, etc. O comando exato de `xcodebuild` não foi fornecido nos fatos; **Gate 0 exige anexar o comando real usado pelo repo + resultado**, não inventar outro. |
| P0.11 | Stale Swift modules purgados antes da execução final, para impedir falso resultado de compilação. | risco documentado em `baseline.md:1474-1478,1539,1546`. |
| P0.12 | Zero mudança funcional necessária para “fazer o teste passar” durante a própria sessão de sign-off. | `git diff` limpo após preparar os documentos e antes da sessão. |

---

# 2. POR ADR

| ADR | O que o sign-off aprova | Evidência mínima exigida | Quem pode assinar | Explicitamente FORA do freeze |
|---|---|---|---|---|
| **ADR-001 Publication & Media** | Append-only publication; occurrence real = persisted `PublicationCardID`; commit transacional; payload/asset/action freeze; successor Edition; ordinal anchors. | `PublicationRepository.swift:1042`; `rollout.md:120,343-349`; prova documental de que bridge alias não é publication identity; persisted-position atual em `FeedScreen.swift:1337,1452` classificado como coexistência. | **Architecture owner + Runtime/Storage owner + Presentation owner** | Ativação da UI V2; aquisição de bytes de media; migração do scroll state legacy; remoção do bridge. |
| **ADR-002 Context & Revision** | Semântica de `ContextKey`, `EditorialRevision`, relevance qualifiers, render revision, warm restore, clocks e edition replacement. | Nenhuma contradição factual conhecida; dependência de Source identity já congelada pelo ADR-003. Ordem original exige 003 antes de 002 (`plano:120-122`). | **Architecture owner + Runtime owner** | Provar que todos os paths atuais já usam ContextKey; tuning de políticas/editorial selection. |
| **ADR-003 Identity/Source/Provenance** | Source FeedMine-owned; catalog/runtime IDs separados; Source/Provider/Binding/Target; external keys; aliases; Origin identity; legacy bridges; **Adendo A**. | `FeedSource.swift:14`; `CatalogIdentity.swift:12-26`; runtime `SourceRegistry.swift:30-65`; bridge `RuntimeMigrations.swift:414-433`; Source refusal atual `rollout.md:338-342`. | **Architecture owner + Runtime/Storage owner** | Remoção imediata das identidades URL-based do legado; rekey de `user.sqlite`; heurística de merge histórico. |
| **ADR-004 Durability & Retention** | Autoridade por DB, append-only revisions, user-action bridge, retention/recovery/migration/rollback. | Authority real: `FeedStore.swift:7703-7737`; `BookmarkStore.swift:6-11`; `UserStateStore.swift:209-458`; GRDB migrations independentes já inventariadas. | **Storage owner + Architecture owner + Release/QA owner** | Definição final de quotas numéricas/SLOs não medidos; §16 do baseline declara targets iniciais, não resultados (`baseline.md:628`). |
| **ADR-005 Connectors & Acquisition** | DTO boundary, backpressure, targets/leasing, frontier, budgets, validators, errors, credential hygiene, parser isolation. | Single-owner acquisition e demand ledger medidos; BGTask duplicate-tree fechado por `BackgroundRefreshDemandTests.testBackgroundDemandIssuesNoRequestForEndpointsAnotherProducerHolds`; probe legacy explicitamente fora do contrato V2 (`RSSFetcher.swift:499-533`). | **Acquisition/Connector owner + Architecture owner** | Retirada imediata do `RSSFetcher` legacy; segundo ecosystem connector; tuning de budgets. |
| **ADR-006 Concurrency & Admission** | TargetStamp, batch replay, checkpoint CAS, transaction boundaries, SupplyGeneration, stale-work rejection, publication serialization ownership. | Baseline reconhece comportamento de stale/conflict e alerta que `nextCheckpoint:nil` significa checkpoint ainda imóvel (`baseline.md:428`); conflict não pode ser confundido com stall (`baseline.md:443-444`). | **Runtime/Concurrency owner + Storage owner + Architecture owner** | Declarar checkpoint advancement “completo” no checkout; performance tuning ou paralelismo adicional. |
| **ADR-007 Exposure & History** | Exposure por `PublicationCardID` real, viewport coalescing, idempotency, history scope, bounded history, tombstones, monotonic clock. | `baseline.md:1300,1412` para tracker/intent; ausência de fake publication IDs garantida pelo Adendo C; persisted restore legacy explicitamente separado (`rollout.md:49`). | **Runtime owner + Presentation owner + Architecture owner** | Exposure correta para bridge aliases; migração imediata de todo read/bookmark overlay; alteração de threshold 50%/1000 ms por tuning. |

**Regra de assinatura:** nenhum ADR pode ser assinado apenas pelo autor do texto quando a decisão cria obrigação em outra boundary. Os papéis indicados acima precisam concordar com a obrigação, não apenas com a redação.

---

# 3. BLOQUEIOS ABERTOS

Ordem obrigatória para fechar Gate 0:

| Ordem | Bloqueio | Slice que resolve | Critério de fechamento |
|---:|---|---|---|
| 1 | **ADR-003 D2/D18 incompleto sem política de allocation de catalog Source.** Source Detail atualmente recusa por falta de runtime ID (`rollout.md:118,155,338-342`). | **DOC-G0-01 / incorporar Adendo A**; implementação posterior em PR-00/PR-01. | ADR declara evento `ensureRuntimeSourceIdentity`, bootstrap híbrido e regra missing→allocate. |
| 2 | **ADR-001/007 confundem potencialmente alias do bridge com `PublicationCardID`.** (`MainFeedCardBridge.swift:234-247`; `PublicationRepository.swift:1042`) | **DOC-G0-02 / incorporar Adendo C**; implementation PR-16/PR-17. | Texto distingue `FeedItem.id`, compatibility identity e persisted publication identity. |
| 3 | **ADR-007 D4 vs restore atual:** `lastScrollItemID` ainda é legado (`FeedScreen.swift:1337,1452`; `rollout.md:49`). | **DOC-G0-02** | D4 delimita same-edition materialisation; cold/warm persisted restore fica como implementação futura. |
| 4 | **ADR-004 authority ambiguity:** tabelas antigas de bookmark coexistem em content DB. | **DOC-G0-03** | tabela de authority nomeia `user.sqlite` como única autoridade de bookmarks. |
| 5 | **ADR-005 D17 sem coexistence qualification**, enquanto legacy faz audio probe. (`RSSFetcher.swift:499-533`) | **DOC-G0-04** | D17 explicitamente runtime-only até retirement do legacy fetcher. |
| 6 | **Referências line-based desatualizadas.** | **DOC-G0-05** | referências críticas atualizadas para símbolos/current lines; nenhuma assertion depende de linha antiga conhecida. |
| 7 | **Suite final ainda precisa de evidência reproduzível no HEAD de sign-off.** Baseline alerta stale-module trap (`baseline.md:1474-1478`). | **VERIFY-G0** | clean/stale-module purge + comando real do projeto + todas as suites requeridas verdes + transcript anexado. |

**Enquanto 1–7 não estiverem fechados, o status dos sete arquivos permanece “Proposed — freeze pending sign-off”.**

---

# 4. ORDEM DE EXECUÇÃO PÓS-FREEZE

Gate 0 congela arquitetura; somente depois começa a sequência de implementação/migração.

| PR | Conteúdo | Depende de | Ponto de não retorno |
|---|---|---|---|
| **PR-00** | Bootstrap de runtime/migration coordinator em launch legacy; migrations V2 podem existir sem ligar UI/network V2. | Gate 0 | **Nenhum:** runtime DB pode ser ignorado/removido; legacy DB intocado. |
| **PR-01** | Source bridge completo: allocation runtime + `legacy_source_map`/identity mappings + bootstrap híbrido. | PR-00 | **Nenhum para user data:** mapping é aditivo; rollback volta ao legacy. Mapping publicado incorreto exige migration corretiva, não overwrite. |
| **PR-02** | Backfill `feed_item` → Origin + `legacy_item_map`, sem GUID reconstruído nem merges heurísticos. | PR-01 | Primeiro compromisso semântico durável de mapping; ainda reversível funcionalmente porque legacy permanece autoridade. |
| **PR-03** | Captura/bridge de estado durável: bookmark resolution e `is_read/clicked_at/consumed_at`. | PR-02 | **Não pode apagar origem legacy.** Enquanto copy-only, rollback continua possível. |
| **PR-04** | Nova ingestão captura GUID/link cru antes do legacy hashing. | PR-02 | Nenhum se shadow-only; torna-se relevante quando runtime passa a ser owner de acquisition. |
| **PR-05** | Audit gate de migração: unresolved/conflicts bloqueiam cutover. | PR-01…04 | Nenhum; observabilidade apenas. |
| **PR-15** | Permanece fechado no escopo já medido: single acquisition owner/BGTask tree removida. Não recebe card publication cutover. | Já landed | Não reabrir para “resolver” card IDs por novo hash. |
| **PR-16 / C-ID-1** | Separar tipos: compatibility card identity ≠ `PublicationCardID`; preparar canonical→publication→presentation boundary. | Gate 0 + PR-02 | Nenhum para legacy se feature path permanece off. |
| **PR-17 / C-ID-2** | Runtime publication real alimenta `CardPresentation`; Exposure/actions recebem persisted `PublicationCardID`; Source revalidation conforme rollout. | PR-16 + publication path | **Primeiro ponto operacional de não retorno:** ativar V2 como owner visível para instalações reais. Requer rollback flag e legacy data ainda preservado. |
| **CUTOVER** | Mudar shipping default para runtime V2 somente após migration audit e release proof. | PR-17 + Gate release | Após remover legacy storage/path, rollback deixa de ser trivial. **Remoção do legacy é um gate separado, não parte do primeiro cutover.** |

A ordem arquitetural continua a do plano: **003 → 002 → 001 → 006 → 004 → 007 → 005** (`plano 2026-09-17:120-126`). A ordem de PR pode materializar infra compartilhada antes, mas não pode reabrir decisão já congelada sem novo amendment.

---

# 5. CRITÉRIO DE ABORTO

A sessão de Gate 0 deve ser **interrompida**, não aprovada condicionalmente, se ocorrer qualquer um destes:

1. Um dos sete ADRs ainda contradiz explicitamente um fato confirmado do checkout — especialmente catalog→runtime Source derivation, bridge alias tratado como publication ID, ou bookmark authority incorreta.
2. O Adendo A ou o Adendo C não está incorporado/referenciado de forma normativa nos ADRs que dependem deles.
3. Um revisor precisa interpretar duas decisões incompatíveis para explicar o mesmo caso real — por exemplo, `missingSourceMapping` significar “refuse” em um lugar e “allocate” em outro.
4. Qualquer ADR exige rekey/destructive migration de bookmarks, read state ou imported sources para ser verdadeiro no primeiro release.
5. A suite final falha, não compila limpa, ou só passa quando stale Swift modules permanecem presentes; o risco é conhecido (`baseline.md:1474-1478`).
6. O transcript de testes não identifica o HEAD/revisão assinada.
7. `baseline.md` ainda afirma como “open defect” algo fechado normativamente nesta sessão, ou afirma como “implemented” algo que é somente decisão.
8. Uma mudança textual feita durante a sessão altera semântica material de D1…Dn; nesse caso encerra-se a sessão, revisa-se o diff e convoca-se novo sign-off.
9. Algum signatário obrigatório rejeita a obrigação da sua boundary. “Aprovação com ressalva” equivale a **Gate 0 não concluído**.
10. Não é possível responder, para qualquer ADR, às três perguntas: **qual autoridade possui o dado/ID, onde ocorre o commit, e qual caminho de rollback/coexistência permanece válido?**

**Gate 0 só fecha quando os sete ADRs podem ser assinados simultaneamente sem exceção normativa escondida em `baseline.md`, `rollout.md` ou no caminho legacy ainda shipping.**