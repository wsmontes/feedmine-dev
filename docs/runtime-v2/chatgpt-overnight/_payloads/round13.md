[[ROUND 13 — REEMISSÃO: ANEXO CORRIGIDO]]

Reemita, já corrigido pela errata do round 12, o artefato que se cola em `docs/runtime-v2/adrs/ADR-003.md`.

Correções obrigatórias em relação à versão anterior:
- O ADR-003 NÃO tem §16. O anexo não substitui nem preenche nenhuma §16. Numere-o pelo próximo número livre de seção do arquivo e diga em uma linha de onde vem a delegação que ele cumpre, nomeando o documento certo (o plano de 2026-09-17, com o parágrafo que pede os insumos de migração) — não invente número de seção do ADR.
- Nenhuma citação de linha que a auditoria marcou como errada pode reaparecer: alocação de `PublicationCardID` em `PublicationRepository.swift:1009-1042`; `MainFeedCardBridge.cardID(forLegacyItemID:)` em `:234-245` (chamada em `:188`); throw de colisão em `SQLiteCatalogStore.swift:216-217`; `AppSettings.swift:65-92` expõe os tipos dos filtros; `OPMLParser.swift:719-723` omite apenas portas default.
- Onde não houver evidência, escreva `[INDETERMINADO — requer leitura de <arquivo>]` em vez de afirmar.

Conteúdo a manter, integral: as decisões M1–M8 (com o que muda, o que não muda e a invariante), a ordem das fatias com pré-requisito/teste/rollback, os riscos de perda de dados tabela por tabela com o que é BLOQUEADOR, e o que permanece pendente de decisão humana.

Formato: texto final, pronto para colar, sem comentários sobre o próprio texto, sem histórico de mudanças, máximo ~3000 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; o documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
