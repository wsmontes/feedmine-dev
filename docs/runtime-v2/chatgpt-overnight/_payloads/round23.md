[[ROUND 23 — CONSERTAR A COMPOSIÇÃO DA EMENDA NO ADR]]

A emenda D20–D23 foi inserida no ADR (numa cópia) e um auditor leu o **resultado aplicado**. Veredito: NÃO APTO, com quatro defeitos. Fatos verbatim:

@@FACTS@@

[[TAREFA]]

Produza as correções, cada uma como substituição mecânica (ARQUIVO / ANCORA verbatim / NOVO / MOTIVO) ou como texto integral quando a âncora não fizer sentido:

1. **Bloco `### Compatibility with existing decisions`** — ele ainda diz "Replace the existing sentence…" citando uma frase do D2 que **já não existe** no arquivo (a substituição foi aplicada). Reescreva o bloco inteiro de modo que ele descreva o estado **depois** da substituição: o que D20 acrescenta ao que o D2 passa a dizer. Sem referência a texto removido e sem instrução de edição dentro do ADR.

2. **Título duplicado** — a subseção de testes da emenda entra sob `## Named acceptance tests`, gerando `### Named acceptance tests` dentro de `## Named acceptance tests`. Dê o título correto para a subseção (por exemplo qualificando pelo escopo) e o texto da âncora de heading a substituir.

3. **Rastreabilidade** — o auditor aponta que a célula `1–30` não fecha (20 invariantes numeradas + INV-M1…INV-M10) e que o PR-01 não tem fonte na emenda. Dê as linhas de rastreabilidade corrigidas para D20, D21, D22 e D23 (formato de tabela do ADR), com a faixa de invariantes **correta e verificável** e o PR que de fato produz a evidência segundo o seu backlog.

4. **Anexo §1.9 e `ensureRuntimeSourceIdentity`** — o anexo marca como INDETERMINADO um teste que o próprio corpo do ADR nomeia, e usa `ensureRuntimeSourceIdentity` sem que o termo esteja definido no corpo. Corrija as duas coisas: a linha do §1.9 (aponte o teste real do ADR) e a definição do termo, ou substitua o termo pelo nome da decisão que o ADR usa.

Regras: âncora verbatim, sem número de linha; se faltar o texto de alguma âncora, escreva `ANCORA: [NAO FORNECIDA]` e diga o que eu preciso te enviar. Máximo ~1500 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
