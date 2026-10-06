[[ROUND 16 — ÂNCORAS EXATAS PARA APLICAR A ERRATA]]

A auditoria independente aceitou parte da sua errata, mas recusou o essencial: as âncoras que você declarou "verbatim" NÃO coincidem com o texto atual dos artefatos, e as correções não foram aplicadas aos arquivos-alvo. Transcrições literais do texto atual estão abaixo — use-as, não a sua memória.

@@FACTS@@

[[TAREFA]]

Reemita a errata como uma LISTA DE SUBSTITUIÇÕES MECÂNICAS, cada uma com âncora textual copiada LITERALMENTE de uma das transcrições acima (curta o bastante para ser única no arquivo, longa o bastante para não casar com outra linha). Formato exato, um bloco por substituição:

ARQUIVO: <nome do arquivo dentro de chatgpt-overnight/>
ANCORA: <texto exato que existe hoje no arquivo — inclusive a pontuação>
NOVO: <texto que substitui a âncora>
MOTIVO: <uma linha>

Regras:
- Se a âncora necessária não estiver nas transcrições acima, escreva `ANCORA: [NAO FORNECIDA]` e diga qual trecho eu preciso te mandar — não invente.
- Cubra, no mínimo: (a) a frase do 01 que atribui a delegação à "§16 do ADR-003"; (b) a afirmação do 01 de que a normalização remove "porta"; (c) a citação `SQLiteCatalogStore.swift:186-196`; (d) a afirmação do 01 de que os tipos dos filtros não estão disponíveis; (e) a citação de `PublicationRepository.swift:948` no 02; (f) o título do 07b que inventa "§1".
- Nada de reescrever o documento inteiro: só substituições pontuais. Máximo ~1200 palavras.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; a lista dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
