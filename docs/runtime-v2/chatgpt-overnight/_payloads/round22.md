[[ROUND 22 — REDAÇÃO FINAL DO D21]]

A auditoria local deixou um ponto indeterminado: D21 × D12. O D12 governa conflito de alias de identidade externa; o D21 precisa garantir a mesma propriedade normativa no caminho de allocation (conflito detectado não pode ser absorvido em silêncio nem perder sua evidência por rollback). A sua própria nota diz que D12 **não** muda.

Fatos verbatim:

@@FACTS@@

[[TAREFA]]

1. Reescreva o D21 na íntegra, mantendo tudo o que ele já decide e acrescentando, com uma frase normativa e verificável, a propriedade do conflito: o que acontece quando a transação de allocation encontra um mapping divergente, e como a evidência sobrevive ao rollback.
2. Diga, em uma linha, por que essa redação não altera nem reinterpreta o D12.
3. Diga, em uma linha, se a mudança exige alguma edição no bloco "Invariants added or preserved by D20–D23" da emenda; se exigir, dê a invariante nova ou a substituição, no formato `ANCORA: … / NOVO: …`.

Formato de saída: primeiro um bloco com o D21 final (texto integral, começando em `**D21 —`), e depois as duas linhas. Máximo ~700 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
