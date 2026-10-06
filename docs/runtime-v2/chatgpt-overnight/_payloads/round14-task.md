[[ROUND 14 — PLANO EXECUTÁVEL, VERSÃO CORRIGIDA]]

Fatos novos: os alvos de verificação que REALMENTE existem neste checkout (nada fora desta lista pode virar `verify.command`):

@@FACTS@@

[[TAREFA]]

Reemita o plano executável em YAML único, corrigido:
- Todo `verify.command` tem de usar apenas alvos/scripts/testplans da lista acima. Se um passo precisa de verificação que não existe, escreva `verify.command: "PARADA: HUMANO — falta <o que>"` em vez de inventar.
- Corrija as citações de linha que a auditoria marcou erradas (PublicationCardID em `PublicationRepository.swift:1009-1042`; `MainFeedCardBridge.cardID(forLegacyItemID:)` em `:234-245`; throw de colisão em `SQLiteCatalogStore.swift:216-217`).
- Nenhum passo pode tocar `feed_item.id`, nem rekey/mover/apagar dado do usuário: toda migração é aditiva e a autoridade legada permanece até o cutover explícito. Se algum passo precisar disso, ele não existe — remova.
- `kind` só pode ser doc_edit, additive_migration, code, test ou measurement. Cada passo com `depends_on`, `rollback` e `stop_condition`.

Mantenha o esquema já usado na versão anterior (version, preconditions, steps, human_decisions).

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; o YAML dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document; sem prosa além de uma linha de abertura.
