[[ROUND 21 — AS EDIÇÕES QUE FALTAM PARA A EMENDA SER APLICÁVEL]]

Uma auditoria local leu o `ADR-003.md` integral e verificou a sua emenda D20–D23 decisão por decisão: 39 compatibilidades, mas **3 conflitos** e 6 indeterminados. Veredito: **NÃO PRONTO PARA APLICAR**. Motivos: (a) o conflito D20 × D2 está identificado mas a substituição da frase do D2 não foi declarada no formato aplicável; (b) D23 conflita com o bullet de edge case `ADR-003.md:385`; (c) a faixa "D1–D19" em `ADR-003.md:452` precisa virar D1–D23 quando a emenda entrar.

Linhas verbatim do arquivo real e os trechos do parecer:

@@FACTS@@

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
