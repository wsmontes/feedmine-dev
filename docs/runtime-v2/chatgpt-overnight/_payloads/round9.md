[[ROUND 9 — KIT DE HANDOFF EXECUTÁVEL]]

Você produziu, nesta conversa: plano de migração, adendo A (identidade de Source), adendo C (identidade de card), revisão adversarial dos sete ADRs, checklist de Gate 0, registro consolidado com backlog PR-00..PR-09 e a falsificação dos defeitos. O repositório tem os sete ADRs em `docs/runtime-v2/adrs/` com status "Proposed — freeze pending sign-off (Gate 0 not complete)"; nada foi congelado ainda.

[[TAREFA]]

Produza três artefatos, nesta ordem:

1. PROMPT DE CONTINUIDADE — um bloco único, pronto para colar, que um humano entregue a uma sessão NOVA deste projeto para retomar o trabalho sem esta conversa. Ele deve conter: o estado atual em 5 linhas, os artefatos que existem (nomes exatos), a decisão que está aberta, e a primeira coisa a fazer. Máximo 400 palavras. Não é um resumo: é uma instrução.

2. CHECKLIST DE PR-00 PARA UM AGENTE COM ACESSO AO REPO — passos ordenados, com: arquivo exato a tocar ou criar, a edição descrita em uma frase, o comando de verificação (teste do Xcode/swift test, com o alvo nomeado), e a condição de parada. Inclua o passo que cria o mapa `legacy_source_map` como migration aditiva e o teste que prova idempotência. Se algum passo exige decisão humana, escreva PARADA: HUMANO no lugar do comando, em vez de inventar.

3. AS DECISÕES HUMANAS COM RECOMENDAÇÃO — cada uma: a pergunta fechada, as opções, a recomendação em uma linha com o motivo, e o que acontece se o humano não decidir (o caminho que o agente segue por padrão).

Formato: markdown, máximo ~2500 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
