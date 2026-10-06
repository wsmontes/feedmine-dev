[[ROUND 19 — CONSERTAR A ESPECIFICAÇÃO DE TESTES DO PR-00]]

A auditoria local do seu artefato `15-pr00-migracao-aditiva.md` encontrou dois defeitos na seção de testes:

1. **Redundância:** os três testes propostos já têm cobertura nas suítes existentes — `MigrationTests.swift:39-40,104-121` e `RuntimeSchemaTests.swift:233-241,552-585`.
2. **T3 é falso-positivo:** como escrito, T3 PASSA com o writer atual. `LegacyMappingStore.swift:17-28` usa `INSERT … ON CONFLICT DO NOTHING` sem verificar o resultado, ou seja, um conflito divergente é absorvido silenciosamente. O seu §4 exige o contrário (conflito divergente tem de ser detectado). Um teste que passa contra o comportamento defeituoso não prova nada.

Outros fatos confirmados pela auditoria: o DDL que você citou bate com o schema real (`source` em `RuntimeMigrations.swift:221-231`; `legacy_source_map` em `:414-423`; `legacy_item_map` em `:425-432`); a cadeia de migrações vai de v1 a v7 e o identificador que você propôs não conflita; nenhum dos três nomes de teste existe hoje no repo.

[[TAREFA]]

Reemita APENAS a seção de testes do `15-pr00-migracao-aditiva.md` (não o documento inteiro), como texto final pronto para substituir a seção atual:

1. Para cada teste proposto: mantenha, funda com um teste existente nomeado, ou elimine. Diga qual dos dois motivos se aplica, citando a suíte existente correspondente.
2. O teste de detecção de conflito divergente: escreva a asserção exata que **falha** contra `LegacyMappingStore.swift:17-28` como está hoje e passa depois da correção. Deixe explícito o arranjo (duas linhas divergentes para a mesma chave) e o resultado que a implementação atual produz hoje (o que a torna um teste real).
3. Nomeie cada teste no formato do repo e diga o arquivo de destino, marcando `criar` quando o arquivo ainda não existe.
4. Liste o que essa seção NÃO deve testar (para o implementador não inflar escopo).

Máximo ~800 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
