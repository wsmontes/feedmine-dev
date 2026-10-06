[[ROUND 15 — PR-00: A MIGRAÇÃO ADITIVA CONCRETA]]

Fatos novos, do checkout (o pacote `Packages/FeedRuntimeV2`, storage do runtime):

@@FACTS@@

[[TAREFA]]

Escreva a especificação executável do primeiro passo de código do seu plano: a migração aditiva que o PR-00 precisa, no molde exato do arquivo `Migrations/RuntimeMigrations.swift` (mesmo estilo de identificador das migrações existentes, seguindo a numeração já usada).

Entregue, nesta ordem:

1. IDENTIFICADOR E POSIÇÃO — o identificador da nova migração (no estilo dos existentes), de qual migração ela depende, e por que a posição é essa.

2. DDL — o SQL completo, tabela por tabela, aditivo (nada de ALTER destrutivo, nada de rekey). Toda tabela com PK explícito, as colunas com tipo e nullability, os índices, e as FKs se houver. Inclua os `CHECK` que as invariantes do ADR-003 exigem (id positivo, versão > 0).

3. INVARIANTES QUE O DDL FAZ CUMPRIR — uma linha por invariante, dizendo qual cláusula a garante.

4. IDEMPOTÊNCIA — como a migração se comporta se rodar duas vezes, e onde exatamente o `ON CONFLICT`/`IF NOT EXISTS` entra. Se a idempotência depender do runner, diga qual linha do runner (`knownMigrationIdentifiers` / `through`) a garante.

5. TESTE QUE PROVA — nome do teste, arquivo de teste onde entra, o arranjo (banco vazio, banco já migrado, banco com linha em conflito) e a asserção que o torna falso se a migração regredir.

6. O QUE ESTA MIGRAÇÃO NÃO FAZ — três linhas, para o implementador não inventar escopo.

Não escreva código Swift. SQL sim, completo.

Formato: markdown, máximo ~2000 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
