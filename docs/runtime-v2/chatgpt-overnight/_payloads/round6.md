[[ROUND 6 — CONSOLIDAÇÃO, CONFLITOS E BACKLOG]]

Nesta mesma conversa você produziu cinco artefatos: o plano normativo de migração (round 1), o adendo A de identidade de runtime do Source (round 2), o adendo C de identidade de card (round 3), a revisão adversarial dos sete ADRs (round 4) e o checklist de Gate 0 (round 5). Não recebeu fatos novos de código — trabalhe com o que já tem.

[[TAREFA]]

1. REGISTRO DE DECISÕES — tabela com: ID (D-xx), a decisão em uma linha, o artefato de origem (plano / adendo A / adendo C / revisão / gate), status (FECHADA / PENDENTE-HUMANO), e o que a bloqueia.

2. CONFLITOS INTERNOS — todo ponto em que seus próprios artefatos divergem entre si (inclusive onde o round 4 desmente algo do round 1 ou do round 2). Para cada um: os dois lados, qual vence e por quê.

3. BACKLOG PR-00..PR-n — numa tabela: PR, objetivo em uma frase, alvos (arquivos/tabelas), pré-requisito, o teste nomeado que prova o slice, critério de rollback, esforço (P/M/G). A ordem é obrigatória por dependência; diga em uma linha por que a ordem é essa.

4. O QUE NÃO EXIGE HUMANO — a lista ordenada do que um agente com acesso ao repositório pode executar hoje sem aprovação (edições de documento, migrations aditivas, testes novos, instrumentação), cada item com o arquivo exato e o resultado observável esperado.

5. O QUE SÓ UM HUMANO DECIDE — fechado, com as opções e a consequência de cada uma.

Formato: markdown, máximo ~3000 palavras, denso, sem repetir texto dos artefatos anteriores.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
