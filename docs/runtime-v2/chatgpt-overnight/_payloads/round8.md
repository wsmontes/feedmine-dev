[[ROUND 8 — FALSIFICAÇÃO DA SUA PRÓPRIA REVISÃO]]

No round 4 você listou defeitos (R1..Rn) nos sete ADRs, com severidades, a partir dos fatos D1–D4 do checkout. Antes de qualquer um desses defeitos ser usado para bloquear um freeze, quero que você tente derrubar a sua própria lista. Uma revisão adversarial que não se falsifica não vale nada.

[[TAREFA]]

1. Para cada defeito R-n: TENTE REFUTAR. Procure a leitura em que a afirmação do ADR é compatível com o fato que você citou — escopo diferente do que a decisão cobre, artefato diferente do citado, decisão que fala de um alvo futuro enquanto o fato descreve o presente, ou citação de teste/arquivo que o próprio ADR já marca como proposta. Se conseguir refutar, escreva veredito REFUTADO e o argumento em uma linha.
2. Mantenha como CONFIRMADO apenas o que sobreviver à tentativa de refutação, e reclassifique a severidade (BLOQUEADOR / CORREÇÃO / NOTA).
3. O que depender de um fato que você NÃO recebeu (código que não está nos digests D1–D4) é INDETERMINADO — nunca bloqueador por si só; diga qual arquivo/linha eu precisaria ler para resolver.
4. Feche com: o número de BLOQUEADOR sobreviventes, e para cada um dos sete ADRs, PODE CONGELAR / NÃO PODE, em uma linha.

Formato: tabela com (ID, veredito, argumento de refutação, severidade final) mais as duas linhas de fechamento. Máximo ~2000 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
