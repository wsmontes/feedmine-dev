[[ROUND 11 — PLANO EXECUTÁVEL EM YAML]]

Você tem, nesta conversa, o plano de migração, os adendos A e C, a revisão dos sete ADRs, o checklist de Gate 0, o registro com backlog PR-00..PR-09, a falsificação e a lacuna de testes. O repositório é Swift/iOS com pacote SPM `Packages/FeedRuntimeV2`; os testes ficam em `feedmineTests/` e `Packages/FeedRuntimeV2/Tests/`; há TestPlans em `TestPlans/` (FeedMine-RuntimeV2, FeedMine-Smoke, entre outros); o alvo de app é o esquema Xcode do projeto em `feedmine.xcodeproj`.

[[TAREFA]]

Converta o backlog em um plano executável, no formato de UM bloco YAML único. Nada de prosa fora do YAML, exceto uma linha antes e uma linha depois.

Esquema obrigatório:

version: 1
generated_for: feedmine-runtime-v2-migration
preconditions:
  - id: P1
    check: <comando shell read-only exato que comprova>
    expect: <saída esperada>
steps:
  - id: PR-00-01
    title: <uma frase>
    depends_on: [<ids>]
    kind: <doc_edit | additive_migration | code | test | measurement>
    targets:
      - path: <arquivo exato>
        change: <edição em uma frase>
    verify:
      command: <comando exato: xcodebuild/swift test com o alvo nomeado, ou script do repo em scripts/validation/>
      expect: <o que a saída prova>
    rollback: <como desfazer>
    stop_condition: <humano | automático: condição observável>
    human_decision: <id da decisão humana equivalente, ou null>
human_decisions:
  - id: H1
    question: <pergunta fechada>
    options: [<opção A>, <opção B>]
    default_if_undecided: <o caminho que o agente segue>
    blocks: [<ids de steps>]

Regras: `verify.command` tem de ser um comando que existe no repo (cite o script real quando houver, por exemplo em `scripts/validation/`); não invente alvos de Xcode — se não tiver certeza do nome do esquema, escreva `PARADA: HUMANO — confirmar nome do esquema`. Todo step tem rollback. Nada de step que dependa do que não existe no checkout.

Máximo ~2500 palavras equivalentes de YAML.

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; em seguida o YAML dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document.
