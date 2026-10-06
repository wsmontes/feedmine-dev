[[ROUND 16 — ÂNCORAS EXATAS PARA APLICAR A ERRATA]]

A auditoria independente aceitou parte da sua errata, mas recusou o essencial: as âncoras que você declarou "verbatim" NÃO coincidem com o texto atual dos artefatos, e as correções não foram aplicadas aos arquivos-alvo. Transcrições literais do texto atual estão abaixo — use-as, não a sua memória.

### Achados ERRADO que exigem âncora exata (artefatos 01, 02, 07b, 12)
| Artefato | Afirmação (citada) | Veredito | Evidência path:linha | Impacto se ERRADO |
| 01 §1 | A normalização de identidade remove `www`, **porta** e trailing slash | ERRADO (porta) | `feedmine/Services/OPMLParser.swift:704` (www), `:726-727` (trailing slash), mas `:719-723` **mantém** portas não-default na identidade (`authority += ":\(port)"`) | A análise de colisão (H4) as
| 01 §1 (escopo) | "migração delegada pela §16 do ADR-003" | ERRADO | `docs/runtime-v2/adrs/ADR-003.md` não possui §16: headings em `:9,:21,:61,:71,:357,:382,:402,:431`; o único "§16" é `:454` referindo `plan §16`, que é "SLOs, observabilidade e critérios de rollout" (`docs/superpowers/p
| 01 M5 | "não há tipo/encoding de cada `filter*`; isso impede qualquer tradução de formato" | ERRADO | `feedmine/Services/AppSettings.swift:65-92` expõe os tipos: `String?`, `[String]`, `String`, `Bool`, `TimeInterval` (`filterRegion`, `filterTaxonomyNodes`, `filterContentType`, `filterAutoExp
| 02 A7 | `PublicationCardID` nasce na transaction de publicação em `PublicationRepository.performCommit`, `PublicationRepository.swift:948` | ERRADO (linha) | `performCommit` inicia em `Packages/FeedRuntimeV2/Sources/FeedStorage/Publication/PublicationRepository.swift:903`; `INSERT INTO published

Escopo: leitura direta do checkout (sem build/teste). Nenhuma linha abaixo é inferida sem `path:linha`; onde o veredito é ERRADO, o fato que o sustenta está citado.
| 07b-anexo-corrigido.md | O anexo não reintroduz numeração de seção inexistente no ADR | ERRADO | Título `## §1. Plano de migração normativo (anexo)` em `07b-anexo-corrigido.md:1`; ADR-003 não tem seção §1 (`ADR-003.md:9,21,61,71,357,382,402,431`); a própria errata 07-A prescrevia hea
| 11-plano-executavel.yaml | `verify.command: swift test … --filter MigrationTests/testLegacySourceMapMigrationIsIdempotent` (PR-00-04) | ERRADO (teste inexistente hoje) | `grep -rn testLegacySourceMapMigrationIsIdempotent Packages/FeedRuntimeV2/Tests/` → 0 ocorrências; é o teste que o própri
| 12-errata.md | Cobre cada achado marcado ERRADO pela revisão independente, com veredito ACEITO/PARCIAL | CONFIRMADO | Tabela `#1-#25` em `12-errata.md:5-29` mapeia todos os ERRADO (04 R1-R11, 08 R11, 05 P0.4/P0.7/P0.8, numeração PR, 06 PR-02/PR-05, 10 §1/§1(c), 01 porta/§16/filtros, 02 A7) |
| 12-errata.md | “Corrige de fato” os defeitos ERRADO nos artefatos-alvo | ERRADO | Defeitos persistem: `01-plano-de-migracao.md:4` (§16), `:10` (porta), `:12` (`SQLiteCatalogStore.swift:186-196`), `:124` (tipos ausentes); `02-identidade-source-runtime.md:261` (`:948`); `04-revisao-adversarial-
| 12-errata.md | Âncoras declaradas “verbatim” coincidem com o texto atual dos artefatos | ERRADO | 01-B “`remove www, porta e trailing slash`” vs `01-plano-de-migracao.md:10` “remove `www`, porta, trailing slash”; 01-C “não há tipo/encoding de cada `filter*`…” vs `:124` “não
| 12-errata.md | Caracterização “`:948` = insert de `feed_segment`” (herdada da revisão aceita) | ERRADO (imprecisão) | `PublicationRepository.swift:948` = comentário `// Step 3: the immutable segment.`; `INSERT INTO feed_segment` em `:950-953` | Não muda o veredito (allocation real é `:1

### Onde o texto atual diverge (transcrições literais dos artefatos)
**Escopo:** migração delegada pela §16 do ADR-003.  
- **CONFIRMA, com risco maior que o ADR explicitou:** normalização de identidade força HTTPS, remove `www`, porta, trailing slash e parâmetros inclusive `token`, `auth`, `key`, `signature` e `access_token`; portanto 
- **CONFIRMA:** o catálogo também ancora identidade em URL canônica e digest de 32 bits; colisão é erro, não mecanismo de identidade editorial V2. (`feedmine/FeedEngine/CatalogIdentity.swift:12-26,56-61`; `feedmine
Fato ainda insuficiente: foram fornecidos os nomes das keys filter*, mas não o tipo/encoding de cada valor. Isso não impede preservá-las; impede qualquer tradução de formato. Portanto nenhuma tradução de filtros �
---
261:O card identity continua fora deste adendo: PublicationCardID real nasce na transaction de publicação (PublicationRepository.performCommit, PublicationRepository.swift:948) e o SHA-256 atual de MainFeedCardBridge c
---
## §1. Plano de migração normativo (anexo)



[[TAREFA]]

Reemita a errata como uma LISTA DE SUBSTITUIÇÕES MECÂNICAS, cada uma com âncora textual copiada LITERALMENTE de uma das transcrições acima (curta o bastante para ser única no arquivo, longa o bastante para não casar com outra linha). Formato exato, um bloco por substituição:

ARQUIVO: <nome do arquivo dentro de chatgpt-overnight/>
ANCORA: <texto exato que existe hoje no arquivo — inclusive a pontuação>
NOVO: <texto que substitui a âncora>
MOTIVO: <uma linha>

Regras:
- Se a âncora necessária não estiver nas transcrições acima, escreva `ANCORA: [NAO FORNECIDA]` e diga qual trecho eu preciso te mandar — não invente.
- Cubra, no mínimo: (a) a frase do 01 que atribui a delegação à "§16 do ADR-003"; (b) a afirmação do 01 de que a normalização remove "porta"; (c) a citação `SQLiteCatalogStore.swift:186-196`; (d) a afirmação do 01 de que os tipos dos filtros não estão disponíveis; (e) a citação de `PublicationRepository.swift:948` no 02; (f) o título do 07b que inventa "§1".
- Nada de reescrever o documento inteiro: só substituições pontuais. Máximo ~1200 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; a lista dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
