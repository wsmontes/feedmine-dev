[[ROUND 18 — EMENDA AO ADR-003: RESOLUÇÃO DE MAPPING AUSENTE E LIFECYCLE DA CANONICALIZATION VERSION]]

Você identificou, no round 17, que o seu próprio plano conflita com o D2 vigente do ADR-003: o plano transforma "mapping ausente" em gatilho de alocação de `SourceID`, enquanto o D2 torna a tradução catálogo → runtime um lookup persistido em `legacy_source_map`, com ausência de linha como resultado terminal. Isso bloqueia o Gate 0 para essa parte. Fatos, verbatim do repositório:

@@FACTS@@

[[TAREFA]]

Escreva a EMENDA ao ADR-003 que resolve isso, no formato de texto pronto para inserção no arquivo `docs/runtime-v2/adrs/ADR-003.md`, seguindo o estilo normativo do próprio ADR (numeração de decisões continuando a existente, uma afirmação por decisão, imperativa e verificável).

A emenda tem de conter, no mínimo:

1. DECISÕES NOVAS (numere continuando a sequência do ADR): (a) o que acontece quando não existe linha em `legacy_source_map` para um `(catalog_source_key, canonicalization_version)` — quem decide a política, e sob qual condição a alocação é permitida; (b) quem é o dono do ato de alocação (qual componente) e em que transação ele ocorre; (c) a semântica de `canonicalization_version`: o que a incrementa, quem a escreve, e o que acontece com as linhas de versões anteriores (imutáveis? consultadas? ambas?).
2. INVARIANTES — as que o D2 e o D18 existentes continuam impondo, explicitamente preservadas, e as novas que a emenda acrescenta.
3. COMPATIBILIDADE COM D2/D18 — uma linha por decisão preexistente afetada, dizendo que ela permanece válida e por quê. Se a emenda exigir reinterpretar uma decisão existente, diga exatamente qual frase do ADR precisa mudar e dê a substituição.
4. TESTES NOMEADOS — os nomes de teste que provam cada decisão nova, no estilo das seções de teste do ADR, indicando arquivo de destino.
5. O QUE A EMENDA NÃO AUTORIZA — três linhas: os caminhos que continuam proibidos depois dela.

Formato: markdown, máximo ~1800 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; documento em markdown dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
