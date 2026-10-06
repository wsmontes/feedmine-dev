[[ROUND 21 — AS EDIÇÕES QUE FALTAM PARA A EMENDA SER APLICÁVEL]]

Uma auditoria local leu o `ADR-003.md` integral e verificou a sua emenda D20–D23 decisão por decisão: 39 compatibilidades, mas **3 conflitos** e 6 indeterminados. Veredito: **NÃO PRONTO PARA APLICAR**. Motivos: (a) o conflito D20 × D2 está identificado mas a substituição da frase do D2 não foi declarada no formato aplicável; (b) D23 conflita com o bullet de edge case `ADR-003.md:385`; (c) a faixa "D1–D19" em `ADR-003.md:452` precisa virar D1–D23 quando a emenda entrar.

Linhas verbatim do arquivo real e os trechos do parecer:

### ADR-003.md:25 (frase do D2 que a emenda diz substituir)
**D2 — The catalog ID is a different type, aliased, never converted.** The app-level `FeedEngine.SourceID` (`UInt32`, `Identities.swift:32-37`) is and remains the *catalog* identity. Bridges refer to it as `CatalogSourceID`; there is no `init` on `FeedDomain.SourceID` taking a `CatalogSourceID`, no `UInt32`/`UInt64` narrowing on the path, and no computation of a runtime ID from a URL digest. The only translation is a persisted lookup in `legacy_source_map` (D18), which fails when no mapping exists.

### ADR-003.md:385 (edge case conflitante com D23)
- Canonicalization version bump: the same URL can yield a different `editorial_key` under a new version. Continuity must be declared in `legacy_source_map`; without a declaration, a new `source` row is created and the divergence is recorded, never merged by URL similarity.

### ADR-003.md:452 (faixa D1-D19)
| Blueprint §112 (ADR-003 scope list) | D1–D19 | 1–20 | PR-02, PR-03 | proposed |

### contexto de :450-454
| Plan §19 #40 (ADR-005 owner) | D8, D9, D13 | 3, 15 | PR-10, PR-17 | proposed |
| Plan §5.1 legacy mapping / rollback | D4, D18 | 11, 18 | PR-02, PR-04 | proposed |
| Blueprint §112 (ADR-003 scope list) | D1–D19 | 1–20 | PR-02, PR-03 | proposed |
| Blueprint §44 / plan §20.3 tombstones | D13, D15 | 15, 20 | PR-03, PR-16 | proposed |
| Blueprint §105 / plan §16 (renderer network = 0) | D7, D15 (identity rows carry no protocol payload) | 10, 16 | PR-03, PR-11 | proposed |

### trechos CONFLITA/INDETERMINADO do parecer
Legenda de veredito: **COMPATÍVEL** / **CONFLITA** / **INDETERMINADO**.
| D20 × D2 | **CONFLITA** | `ADR-003.md:25` verbatim: "The only translation is a persisted lookup in `legacy_source_map` (D18), which fails when no mapping exists." vs. D20: "it may request creation of a mapping only when the catalog input supplies a valid durable `EditorialSourceKey`…". | Aplicar a substituição textual que a **própria emenda** fornece na seção "Compatibility with existing decisions → D2" (
| D21 × D12 | **INDETERMINADO** | `ADR-003.md:45` "the conflicting mapping is refused **and recorded** as `ambiguous_alias`" + `ADR-003.md:365` "always leaves an `ambiguous_alias` conflict behind". D21 diz apenas "rolls back rather than exposing an allocated-but-unmapped Source" — não especifica se a linha `identity_conflict` sobrevive ao rollback. | Declarar em D21 que o registro de conflito é escrito fora da t
| **D23 × Edge case "Canonicalization version bump"** | **CONFLITA** | `ADR-003.md:385` verbatim: "- Canonicalization version bump: the same URL can yield a different `editorial_key` under a new version. Continuity must be declared in `legacy_source_map`; **without a declaration, a new `source` row is created** and the divergence is recorded, never merged by URL similarity." vs. D23: "If more than one runtime Source
Dois pontos **INDETERMINADOS** (não contradição, mas lacuna):
1. 07b §1.9 (fatia 1) marca o nome do teste como `[INDETERMINADO — requer leitura de Packages/FeedRuntimeV2/Tests/FeedStorageTests/]`; a emenda preenche com caminhos/nomes que **não existem** no repo (ver §5). Ou seja, o INDETERMINADO do 07b não é de fato resolvido pela emenda.
**NÃO PRONTO** — D23/INV-M7 conflita com o bullet verbatim `ADR-003.md:385` ("without a declaration, a new `source` row is created" vs. "creates no automatic mapping"), e a emenda só declara a substituição de D2; as edições obrigatórias em `:385` e `:452` (D1–D19→D1–D23) não estão declaradas, e D21×D12 fica INDETERMINADO quanto à sobrevivência da linha `identity_conflict` ao rollback.


[[TAREFA]]

Reemita o que falta, como LISTA DE SUBSTITUIÇÕES MECÂNICAS prontas para aplicar, cada uma no formato:

ARQUIVO: docs/runtime-v2/adrs/ADR-003.md
ANCORA: <texto exato que existe hoje — copie da transcrição acima, sem parafrasear>
NOVO: <texto que substitui>
MOTIVO: <uma linha>

Cubra, no mínimo:
1. A frase do D2 em `:25` que afirma que o lookup "fails when no mapping exists" — reescreva-a de modo que ela permaneça verdadeira **com** D20 (o lookup deixa de ser o único caminho quando existe `EditorialSourceKey` durável válido, e o que falha é a resolução sem chave válida).
2. O bullet de edge case em `:385` sobre bump de canonicalization version — torne-o consistente com D23 (sem declaração, nenhum mapping automático é criado; a continuidade exige declaração).
3. A faixa "D1–D19" (ou o texto equivalente) em `:452`, para incluir D20–D23.
4. Qualquer outra edição que o parecer exigir para a emenda ficar aplicável sem contradição.

Regras:
- Não use número de linha como âncora: use o texto verbatim.
- Se alguma âncora necessária não estiver nas transcrições, escreva `ANCORA: [NAO FORNECIDA]` e diga qual trecho eu devo te mandar.
- Se, em vez de editar o ADR, for mais correto reescrever uma das suas decisões novas (D20 ou D23), diga isso explicitamente e dê a nova redação integral da decisão.

Formato: markdown, máximo ~1200 palavras, apenas as substituições e as notas.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
