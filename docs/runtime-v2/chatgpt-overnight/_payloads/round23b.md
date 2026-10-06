[[ROUND 23 — CONSERTAR A COMPOSIÇÃO DA EMENDA NO ADR]]

A emenda D20–D23 foi inserida no ADR (numa cópia) e um auditor leu o **resultado aplicado**. Veredito: NÃO APTO, com quatro defeitos. Fatos verbatim:

### Achados do auditor (verbatim)
# Revisão do ADR-003 aplicado — `/tmp/ADR-copy.md`

Objeto: emenda D20–D23 (e anexo) aplicada ao ADR-003. Somente leitura. Comparado com o original `docs/runtime-v2/adrs/ADR-003.md` e com `docs/runtime-v2/chatgpt-overnight/18-emenda-adr003.md`.

| Item | Veredito | Evidência (linha verbatim do resultado) | Correção mínima |
|---|---|---|---|
| 1. Coerência do D2 editado com D20 | OK | `The only translation is through a persisted row in `legacy_source_map` (D18). ... When no row exists, D20–D21 may establish one only from a valid durable `EditorialSourceKey` and only when the mapping can be established without ambiguity. Resolution fails when no valid durable key 
| 2. Bullet de edge case × D23 | OK | `Declared continuity creates a new-version `legacy_source_map` row pointing to that existing source; declared distinctness may allocate a new source through D20–D21. Without either declaration, resolution is refused and the divergence is recorded; URL similarity never establishes continui
| 3. Faixa D1–D23 no texto de escopo | OK | `\| Blueprint §112 (ADR-003 scope list) \| D1–D23 \| 1–30 \| PR-01, PR-02, PR-03 \| proposed \|` (linha 522) | Quanto às decisões: correto — `**D1`…`**D23` existem cada uma exatamente uma vez (23 cabeçalhos distintos, sem buraco nem repetição; D20/D21/D22/D23 nas linhas
| 4. Invariantes e testes nomeados: seção e duplicação | PROBLEMA | `\| Blueprint §112 (ADR-003 scope list) \| D1–D23 \| 1–30 \| PR-01, PR-02, PR-03 \| proposed \|` (linha 522) e `### Named acceptance tests` (linha 482) | (a) `1–30` não confere: há 20 invariantes numerados (1–20) + 10 letrados (`INV-M1`…`INV-M10
| 5. Anexo duplica o corpo? | PROBLEMA | Anexo 1.9: `Nome exato: [INDETERMINADO — requer leitura de Packages/FeedRuntimeV2/Tests/FeedStorageTests/]` (linha 736) × corpo: `... LegacySourceIdentityResolutionTests.swift` (linha 484) | Duplicação textual confirmada (aceitável em parte, pois o anexo declara "não substitui nenh
| 6. Contradição entre a emenda e D1–D19 | PROBLEMA | `- **D2 — requires one textual amendment; its type-separation and no-conversion rules remain unchanged.** Replace the existing sentence:` (linha 73) e `> `The only translation is a persisted lookup in legacy_source_map (D18), which fails when no mapping exists.`` (linha

NÃO APTO (3 defeitos mecânicos corrigíveis: bloco "Replace the existing sentence" obsoleto e divergente do D2 aplicado; faixa de invariantes `1–30` sem itens numerados 21–30; anexo 1.9 marca como INDETERMINADO o teste que o corpo já nomeia).

### Bloco Compatibility atual (18-emenda)
### Compatibility with existing decisions

- **D2 — requires one textual amendment; its type-separation and no-conversion rules remain unchanged.** Replace the existing sentence:

  > `The only translation is a persisted lookup in legacy_source_map (D18), which fails when no mapping exists.`

  with:

  > `The only translation is through a persisted row in legacy_source_map (D18). An existing row is authoritative; when no row exists, D20–D21 may establish one only through the resolver/registry transaction defined there. Until that transaction commits, resolution fails, and no caller may derive,

- **D4 — remains valid without textual change.** `EditorialSourceKey(catalogIdentity, canonicalizationVersion)` remains the durable key separate from the local row ID; D22–D23 only define who versions that key and how version transitions preserve continuity.

- **D18 — remains valid without textual change.** Newly resolved catalog Sources still cross the legacy/runtime boundary exclusively through `legacy_source_map`; D20 changes how a missing row may be created, not which bridge is authoritative.

- **D1 — remains valid without textual change.** Any Source created under D20–D21 is still FeedMine-owned and receives an opaque runtime-allocated ID.

- **D3 — remains valid without textual change.** Allocation continues to use the positive checked SQLite/GRDB row identity; the resolver does not choose the integer.

- **D12 — remains valid without textual change.** D23 explicitly refuses ambiguous continuity rather than merging competing Sources.


### Invariantes da emenda (contagem)
INV-M1 INV-M10 INV-M2 INV-M3 INV-M4 INV-M5 INV-M6 INV-M7 INV-M8 INV-M9 
### Linhas de rastreabilidade do round 20
| Blueprint/plan row | ADR decision id | Invariant ids | PR that must produce the evidence | Status |
|---|---|---|---|---|
| amendment D20–D23 | D20 | 8, 11, 21, 22, 25, 30 | PR-01 | proposed |
| amendment D20–D23 | D21 | 7, 8, 11, 22, 23, 24, 25 | PR-01 | proposed |
| Plan §5.1 (`SourceID` runtime is allocated/persisted; persist catalog identity + canonicalization version → runtime source) + amendment D20–D23 | D22 | 7, 11, 26, 27 | PR-01 | proposed |
| Plan §5.1 (catalog rebuild reapplies mappings; no reallocation by row order) + amendment D20–D23 | D23 | 5, 11, 25, 27, 28, 29, 30 | PR-01 | proposed |

### Novos ids de invariante

### Anexo 1.9


[[TAREFA]]

Produza as correções, cada uma como substituição mecânica (ARQUIVO / ANCORA verbatim / NOVO / MOTIVO) ou como texto integral quando a âncora não fizer sentido:

1. **Bloco `### Compatibility with existing decisions`** — ele ainda diz "Replace the existing sentence…" citando uma frase do D2 que **já não existe** no arquivo (a substituição foi aplicada). Reescreva o bloco inteiro de modo que ele descreva o estado **depois** da substituição: o que D20 acrescenta ao que o D2 passa a dizer. Sem referência a texto removido e sem instrução de edição dentro do ADR.

2. **Título duplicado** — a subseção de testes da emenda entra sob `## Named acceptance tests`, gerando `### Named acceptance tests` dentro de `## Named acceptance tests`. Dê o título correto para a subseção (por exemplo qualificando pelo escopo) e o texto da âncora de heading a substituir.

3. **Rastreabilidade** — o auditor aponta que a célula `1–30` não fecha (20 invariantes numeradas + INV-M1…INV-M10) e que o PR-01 não tem fonte na emenda. Dê as linhas de rastreabilidade corrigidas para D20, D21, D22 e D23 (formato de tabela do ADR), com a faixa de invariantes **correta e verificável** e o PR que de fato produz a evidência segundo o seu backlog.

4. **Anexo §1.9 e `ensureRuntimeSourceIdentity`** — o anexo marca como INDETERMINADO um teste que o próprio corpo do ADR nomeia, e usa `ensureRuntimeSourceIdentity` sem que o termo esteja definido no corpo. Corrija as duas coisas: a linha do §1.9 (aponte o teste real do ADR) e a definição do termo, ou substitua o termo pelo nome da decisão que o ADR usa.

Regras: âncora verbatim, sem número de linha; se faltar o texto de alguma âncora, escreva `ANCORA: [NAO FORNECIDA]` e diga o que eu preciso te enviar. Máximo ~1500 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
