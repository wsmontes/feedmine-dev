[[ROUND 12 — ERRATA CONTRA REVISÃO INDEPENDENTE]]

Um revisor independente (modelo de outra família, com acesso direto ao repositório) auditou os seus artefatos desta conversa, afirmando cada veredito com path:line. Os resultados estão abaixo. Não aceite nada por educação: verifique cada item contra os fatos que você já recebeu (D1–D4 + os fatos deste round) e decida.

@@FACTS@@

[[TAREFA]]

1. PARA CADA ACHADO: veredito ACEITO / REJEITADO / PARCIAL, com o motivo em uma linha, usando apenas fatos. Se REJEITAR, cite o fato que sustenta a rejeição. Os cinco achados de identidade (ADR-003 sem §16; PublicationCardID :1009-1042; AppSettings.swift:65-92; porta não-default; citações de linha) têm de ser tratados um a um.

2. ERRATA NORMATIVA — o texto de correção dos pontos em que você errou, pronto para colar, um bloco por correção, no formato: ARQUIVO, ÂNCORA verbatim (o texto atual do seu artefato), SUBSTITUIR POR, MOTIVO.
   - em `01-plano-de-migracao.md`: a frase que atribui a delegação à "§16 do ADR-003" — a correção tem de nomear o documento certo;
   - em `02-identidade-source-runtime.md`: a citação de `PublicationRepository.swift:948` no item A7;
   - em `07-anexo-section16.md`: o título e o objeto do anexo (ele não substitui uma §16 que não existe no ADR) e as âncoras que dependiam dessa premissa;
   - em `04-revisao-adversarial-adrs.md` e `08-falsificacao-defeitos.md`: os defeitos que a revisão independente marcou como ERRADO e que a sua própria falsificação não derrubou.

3. SOBREVIVENTES — para cada um dos sete ADRs, com a lista já falsificada e auditada: existe algum BLOQUEADOR real? Nomeie-o ou escreva NENHUM, uma linha por ADR.

4. LIÇÃO — no máximo três linhas sobre que tipo de leitura produziu falso positivo na sua revisão adversarial, e a regra que evita repetir.

Formato: markdown, máximo ~2500 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
