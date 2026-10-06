[[ROUND 5 — CHECKLIST DE GATE 0 (FREEZE DOS SETE ADRs)]]

Fatos novos:

@@FACTS@@

[[TAREFA]]

Produza o checklist de Gate 0 que autoriza o freeze dos sete ADRs, no formato que um revisor humano usa numa sessão única de sign-off.

Estrutura:
1. PRÉ-CONDIÇÕES — o que precisa ser verdade no repositório antes de a sessão começar (artefatos, testes verdes, relatórios), cada uma com o comando ou arquivo que a comprova.
2. POR ADR (ADR-001 … ADR-007) — em uma tabela: o que o sign-off aprova, a evidência exigida, quem pode assinar (papel), e o que fica explicitamente FORA do escopo do freeze.
3. BLOQUEIOS ABERTOS — a lista consolidada do que impede o freeze hoje, na ordem em que precisa ser resolvido, com o slice que resolve cada um.
4. ORDEM DE EXECUÇÃO PÓS-FREEZE — a sequência dos PRs (PR-00, PR-01, …) com dependências, e o ponto de não retorno de cada um.
5. CRITÉRIO DE ABORTO — o que faz a sessão de freeze ser interrompida em vez de aprovada.

Formato: markdown, máximo ~2500 palavras, tabelas onde couber, citando path:line.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document; sem resumo.
