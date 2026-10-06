[[ROUND 4 — REVISÃO ADVERSARIAL DOS SETE ADRs CONTRA O CHECKOUT REAL]]

Você recebeu D1–D4 (working tree, 2026-10-05, HEAD 70f7b06b) e produziu o plano de migração e a decisão de identidade do Source.
O repositório JÁ CONTÉM os sete ADRs, escritos e com status "Proposed — freeze pending sign-off (Gate 0 not complete)": docs/runtime-v2/adrs/ADR-001..007.md (31–45 KB cada). Eles já estão referenciados como autoridade por docs/runtime-v2/baseline.md e rollout.md.

Fatos novos:

@@FACTS@@

[[TAREFA]]

Faça a revisão adversarial dos sete ADRs contra os fatos do checkout. Não reescreva os ADRs. Produza uma lista de defeitos acionável.

Para cada defeito: ID (R1..Rn), ADR e decisão (D-n) afetada, a AFIRMAÇÃO do ADR (citada), o FATO do checkout que a contradiz ou confirma (path:line), a severidade (BLOQUEADOR / CORREÇÃO / NOTA) e a correção mínima.

Regras:
- Só defeito com evidência nos fatos fornecidos. Sem opinião estética.
- Separe explicitamente: (a) contradições verificáveis, (b) afirmações não verificáveis com os fatos disponíveis, (c) nomes de teste/arquivo citados pelos ADRs que podem estar desatualizados.
- Termine com um veredito por ADR: PODE CONGELAR / NÃO PODE (com o motivo em uma linha).

Formato: markdown, máximo ~3000 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document; sem resumo.
