Você recebeu os fatos do checkout (D1–D4) e produziu o PLANO DE MIGRAÇÃO. Agora uma decisão normativa.

[[ROUND 2 — DECISÃO: IDENTIDADE DE RUNTIME PARA SOURCES DE CATÁLOGO]]

Fatos novos, lidos do working tree agora:

@@FACTS@@

[[TAREFA]]

Produza o documento normativo que fecha a identidade de runtime para sources de catálogo, como ADENDO ao ADR-003 (não um ADR novo). Decida — não ofereça opções.

Cada item abaixo é uma subseção com DECISÃO / CONSEQUÊNCIA / TESTE:

A1. Como um source de catálogo ganha um `SourceID` de runtime sem derivá-lo da URL nem do id de catálogo (D2/D18)? Qual é o evento de alocação e quem o dispara?
A2. O que substitui a recusa `runtimeIdentityUnavailable(.source)` no SurfacePlan, e sob qual condição exata a recusa continua sendo a resposta correta.
A3. Bootstrap de usuário existente (catálogo com centenas de sources, banco de runtime ainda ausente): alocação em lote, preguiçosa ou híbrida? Custo por launch, idempotência e resumibilidade (diga qual estado intermediário é permitido).
A4. Concorrência: `RuntimeSourceRegistry.sourceID` faz INSERT … ON CONFLICT DO NOTHING + SELECT. Isso é atômico o bastante? Se não, qual a correção mínima e qual teste prova.
A5. `legacy_source_map` com PK `(catalog_source_key, canonicalization_version)`: o que a version significa, quando muda, e o que acontece com as linhas antigas quando muda.
A6. Falha e degradação: quando a linha do mapa não existe (`missingSourceMapping`), a superfície degrada para legacy, recusa, ou aloca? Regra única, sem exceções por superfície.
A7. A relação desta decisão com ADR-002 (Context & Revision Model) e com a ordem de gates já fixada: o que precisa estar congelado antes.

Formato: markdown, máximo ~2500 palavras, denso, citando path:line dos fatos.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; em seguida o documento completo em markdown dentro de UM bloco de código; a última linha é exatamente [[DELIVERABLE-END]]; nada depois disso; sem canvas/Document; sem resumo; sem perguntas soltas.
