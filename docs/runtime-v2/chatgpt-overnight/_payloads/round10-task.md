[[ROUND 10 — LACUNA DE TESTES DOS SETE ADRs]]

Fatos novos: a auditoria dos nomes de teste que os próprios sete ADRs citam nas suas seções de testes nomeados, resolvidos contra o código de teste real do repositório (`feedmineTests/`, `Packages/FeedRuntimeV2/Tests/`). Linha por citação: `ADR | identificador citado | ADR:linha | EXISTE em path:linha | AUSENTE | RENOMEADO para <nome>`.

@@FACTS@@

Total: 72 citados existem, 24 foram renomeados, 7 estão ausentes — os ausentes estão listados acima com o ADR e a linha.

[[TAREFA]]

1. LACUNA POR ADR — tabela: ADR, testes ausentes, o comportamento que o ADR promete, e o veredito: (a) o teste é necessário e a ausência BLOQUEIA o freeze, (b) o teste é necessário mas pode entrar depois do freeze, (c) o ADR deve ser corrigido porque o comportamento mudou de lugar (se for o caso, diga qual teste real cobre isso hoje).

2. ESPECIFICAÇÃO DOS TESTES QUE FALTAM — para cada teste com veredito (a): nome exato do teste, arquivo onde entra, o arranjo mínimo (tabelas/linhas que precisam existir), a asserção que o torna falso se a implementação regredir, e o que ele NÃO deve testar. Sem código Swift — especificação em prosa curta e precisa.

3. EDIÇÕES DE TEXTO NOS ADRs — para os vereditos (c): a âncora verbatim a substituir em cada arquivo e o texto novo, uma linha por edição.

4. RENOMEADOS — regra de manutenção: os 24 nomes que mudaram devem ser atualizados no texto do ADR? Diga sim/não e por quê, em duas linhas.

Formato: markdown, máximo ~2500 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
