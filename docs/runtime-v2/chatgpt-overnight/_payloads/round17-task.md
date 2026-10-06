[[ROUND 17 — QUANTO DO SEU PLANO JÁ ESTÁ DECIDIDO PELO ADR-003]]

O ADR-003 já é normativo no repositório e contém decisões D1..D19. Você produziu um plano de migração com decisões M1..M8. Antes de qualquer trabalho de implementação, preciso saber o que é novo.

@@FACTS@@

[[TAREFA]]

1. MAPA M → D — para cada M1..M8: a decisão correspondente que já existe no ADR-003 (número exato da decisão), ou NOVO se o ADR não decide aquilo, ou CONFLITO se o ADR decide o contrário. Uma linha por M, com o motivo apoiado no título da decisão.
2. O QUE SOBRA DE NOVO — a lista apenas dos itens NOVO e CONFLITO, cada um com o que ele exige que o ADR ainda não autoriza.
3. CONFLITOS — para cada CONFLITO: qual leitura do ADR sustenta a decisão existente, e o que a sua proposta mudaria. Se houver conflito real, ele é BLOQUEADOR de Gate 0.
4. VEREDITO — em uma linha: a migração proposta é (a) implementação de decisões já tomadas, (b) decisão nova que precisa de ADR novo, ou (c) híbrido — e no caso (b)/(c) qual seria o objeto mínimo do ADR que falta.

Não invente títulos de decisão: os que você tem estão nos fatos. Se não tiver certeza de um mapeamento, escreva INDETERMINADO e diga qual texto do ADR eu preciso te mandar.

Formato: markdown, máximo ~1500 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
