[[ROUND 20 — LINHAS DE RASTREABILIDADE PARA D20–D23]]

A emenda que você escreveu (D20–D23) vai entrar no ADR-003, mas a tabela `## Traceability` do ADR associa cada decisão a uma linha do plano, a ids de invariante e ao PR que produz a evidência. Sem essas linhas, a emenda fica órfã.

Fatos do arquivo real:

@@FACTS@@

[[TAREFA]]

1. LINHAS DA TABELA — escreva as linhas novas da tabela `## Traceability` para D20, D21, D22 e D23, no formato exato das existentes (colunas: Blueprint/plan row | ADR decision id | Invariant ids | PR that must produce the evidence | Status). Para "Blueprint/plan row", aponte a linha do plano que originou cada decisão; se a decisão for nova (não rastreada ao plano), escreva `amendment D20–D23` e diga isso explicitamente.
2. IDS DE INVARIANTE — para cada linha, os ids que a decisão faz cumprir: os preexistentes que ela preserva **e** as invariantes novas que a emenda acrescenta (numere-as continuando a sequência existente, e dê o texto de cada invariante nova em uma linha).
3. PR — o PR que deve produzir a evidência de cada decisão, usando a numeração do backlog (`PR-00`…`PR-09`) que você já produziu; se a evidência só existir depois do freeze, diga qual PR é o responsável.
4. STATUS — o valor de Status que essas linhas devem ter hoje, coerente com o fato de que o ADR continua `Proposed` e nenhuma implementação existe ainda.
5. Se algo depender de decisão humana, escreva `PARADA: HUMANO — <a pergunta>` na célula em vez de inventar.

Formato: markdown, máximo ~900 palavras. Só as linhas e as explicações mínimas.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
