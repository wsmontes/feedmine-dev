# Round 17 — Quanto do plano M1–M8 já está decidido pelo ADR-003

## 1. Mapa M → D

- **M1 — FeedSource / SourceID → CONFLITO parcial com D2; restante coberto por D1, D2, D3, D4 e D18.** D1 já fixa Source como unidade editorial FeedMine-owned; D2 separa catalog ID e proíbe conversão; D3 fixa IDs locais positivos; D4 separa durable editorial key de row ID; D18 fixa o bridge legacy. O ponto novo/conflitante é a política **missing mapping → ensure/allocate**, porque o texto normativo vigente de D2 descreve o lookup persistido como falhando quando não há mapping.
- **M2 — FeedItem / OriginRecord / OriginRevision → D8, D10, D12, D16 e D18.** External keys são opacas, GUID não é URL, aliases ambíguos não fundem, ausência de identidade forte usa fallback low-confidence e o bridge legacy é o único caminho; tratar `FeedItem.id` histórico como opaco é implementação dessas decisões, não nova identidade.
- **M3 — CatalogIdentity → NOVO.** D4 separa durable key de row ID e D12 impede merge ambíguo, mas os títulos D1–D19 não decidem a política completa de **versionamento da canonicalização**, imutabilidade dos mappings antigos e quando duas versões podem apontar para o mesmo runtime SourceID.
- **M4 — Persistence e migrations → NOVO.** Nenhuma D1–D19 decide política geral de migrations append-only, proibição de rekey/delete legacy, ordem de bootstrap ou rollback de storage; isso pertence principalmente ao domínio de durability/migration, não ao conteúdo normativo listado de ADR-003.
- **M5 — Referências duráveis do usuário → NOVO.** D18 determina o caminho de identidade legacy, mas não decide preservação/migração de bookmarks, read/click state, imported sources, collections, Smart Feeds, filtros, buscas ou a regra “durable reference unresolved bloqueia cutover”.
- **M6 — Identidade de apresentação → NOVO.** D19 proíbe array index/batch ordinal como identidade, mas não decide que compatibility card alias é distinto de `PublicationCardID`, nem quando uma occurrence publicada deve receber seu ID persistido; isso é matéria de publication/presentation.
- **M7 — Fronteira RSS → D8, D10 e D16.** Opaque external keys, GUID não tratado como URL e fallback low-confidence já determinam a semântica; “capturar antes de `FeedItem` perder a evidência” é mecanismo de implementação dessas decisões.
- **M8 — Compatibilidade de release → NOVO.** Nenhuma D1–D19 decide bootstrap versus cutover, shipping default, janela de rollback ou momento de remoção do legado.

## 2. O que sobra de novo

### M1 — somente a política de missing mapping

Exige autorização normativa para:

> quando `legacy_source_map` não contém a chave, o runtime pode alocar uma nova `SourceID` e persistir atomicamente o mapping, em vez de terminar a resolução como missing.

Todo o restante de M1 já deriva de D1/D2/D3/D4/D18.

### M3 — lifecycle da canonicalização

Ainda precisa decidir explicitamente:

- `canonicalization_version` faz parte da chave do mapping;
- mappings de versões anteriores são imutáveis;
- uma versão nova pode apontar para a mesma runtime Source somente com continuidade inequívoca;
- ambiguidade impede associação automática, sem auto-merge.

D4 e D12 dão princípios compatíveis, mas não fecham esse lifecycle.

### M4 — política de migração

Ainda precisa de autoridade normativa para:

- migration aditiva/append-only;
- nenhuma alteração de `feed_item.id`;
- nenhum rekey/move/delete de user data durante coexistência;
- rollback mantendo as autoridades legacy intactas;
- bootstrap resumível antes de qualquer cutover.

Isso não é decidido pelas D1–D19.

### M5 — continuidade do estado do usuário

Ainda precisa decidir:

- quais durable references precisam ser bridged antes do cutover;
- que estado unresolved bloqueia uma superfície;
- como bookmarks/read/click/imported sources/collections/Smart Feeds/filters/search sobrevivem ao cutover;
- que a migração não pode descartar uma referência durável não resolvida.

D18 resolve **por onde identidade legacy entra**, não a política de preservação desses dados.

### M6 — identity boundary de cards

Ainda precisa decidir explicitamente:

- compatibility alias não é `PublicationCardID`;
- `PublicationCardID` somente existe para occurrence persistida pela publication;
- actions/exposure de superfície V2-owned usam o ID persistido, não hash de `FeedItem.id`.

D19 elimina ordinal/index como identidade, mas não fecha essa boundary.

### M8 — release/cutover

Ainda precisa decidir:

- bootstrap não implica ownership;
- momento em que V2 pode virar shipping default;
- rollback window;
- condição para remover bridges/readers legacy.

Esses são contratos de rollout, não de content identity.

---

## 3. Conflitos

### M1 versus D2 — BLOQUEADOR real de Gate 0

**Leitura existente do ADR:** D2, intitulada **“The catalog ID is a different type, aliased, never converted”**, não apenas proíbe conversão; no texto vigente já auditado, a tradução catalog → runtime é descrita como lookup persistido em `legacy_source_map` **que falha quando não existe mapping**.

**O que M1 mudaria:** transformaria ausência de mapping de resultado terminal em operação de criação:

```text
missing mapping
→ allocate runtime SourceID
→ persist mapping atomically
→ return SourceID
Isso não é mera implementação de D2. É mudança da semântica de resolução de uma condição que o ADR já tornou normativa.

Consequência: enquanto ADR-003 for normativo no repositório, M1 não pode implementar missing → ensure/allocate sem amendment do ADR-003. Esse conflito é BLOQUEADOR de Gate 0/implementação dessa parte de M1.

Não há outro conflito demonstrado entre M2–M8 e D1–D19: os demais casos são implementação de decisões existentes ou decisões fora do escopo já fechado pelo ADR-003.

4. Veredito
(c) HÍBRIDO. M2 e M7, e grande parte de M1, são implementação direta de D1–D19; M3/M4/M5/M6/M8 introduzem contratos ainda não decididos por ADR-003, e a política missing mapping → ensure/allocate de M1 conflita com D2 vigente.

O objeto mínimo que falta não precisa ser um novo ADR de identidade inteiro: é um amendment ao ADR-003 para a resolução de missing legacy Source mapping e lifecycle de canonicalization_version. Persistence/user-state/card-publication/rollout devem ser autorizados pelos ADRs que já possuem esses respectivos domínios, em vez de ampliar ADR-003 artificialmente.