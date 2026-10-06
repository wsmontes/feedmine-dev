[[ROUND 3 — DECISÃO: FRONTEIRA DA IDENTIDADE DE CARD / PR-15]]

Fatos novos:

@@FACTS@@

[[TAREFA]]

Decida a fronteira da identidade de card entre legado e runtime V2. Cada subseção com DECISÃO / CONSEQUÊNCIA / TESTE:

C1. Quem é dono da identidade de card em cada estágio: loader legado, `MainFeedCardBridge.cardID` (alias determinístico sobre o item id), publicação do runtime (`PublicationCardID` alocado em `PublicationRepository`)? Nomeie o dono por estágio e o que a troca de dono exige.
C2. O alias atual (SHA-256 do item id legado, 8 bytes, clampado em Int64) — pode continuar como identidade de apresentação? Se sim, sob qual invariante (estabilidade entre edições, colisão, reindexação). Se não, o que o substitui e em quantos slices.
C3. `legacy_item_map` (`legacy_item_id` PK) é a única ponte? O que acontece com um item que existe no feed legado e nunca foi mapeado quando a UI V2 renderiza: degrada, recusa, ou mapeia na hora?
C4. Sobrevivência do card id através de substituição de edição (edition replacement) e restauração a quente: o que precisa continuar válido e o que pode ser remintado.
C5. O conteúdo exato de PR-15: alvos (arquivos/tabelas), o que entra e o que fica de fora, e o teste nomeado que prova o fechamento.
C6. O que NÃO pode mudar agora no caminho legado (o app publica hoje com `fix/release-1.0-final-hardening`): liste as superfícies congeladas.

Formato: markdown, máximo ~2500 palavras, citando path:line.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document; sem resumo.
