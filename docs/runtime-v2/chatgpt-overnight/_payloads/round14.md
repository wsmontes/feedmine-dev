[[ROUND 14 — PLANO EXECUTÁVEL, VERSÃO CORRIGIDA]]

Fatos novos: os alvos de verificação que REALMENTE existem neste checkout (nada fora desta lista pode virar `verify.command`):

### scripts/validation/
build_for_validation.sh
clean_validation_artifacts.sh
resolve_destination.py
run_performance.sh
run_runtime_v2_tests.sh
run_smoke.sh
summarize_results.sh
test_runtime_v2_boundaries.sh
test_validation_runners.sh

### alvos do Makefile
device-info sim-info audit-images all build install launch test test-ui test-device test-device-only test-ui-device test-sim test-sim-only test-ui-sim analyze build-release archive clean clean-all 

### TestPlans
FeedMine-Accessibility.xctestplan FeedMine-Performance.xctestplan FeedMine-ReleaseValidation.xctestplan FeedMine-RuntimeV2.xctestplan FeedMine-Smoke.xctestplan FeedMine-Usability.xctestplan 

### alvos de teste do SPM
Packages/FeedRuntimeV2/Package.swift:19:    name: "FeedRuntimeV2",
Packages/FeedRuntimeV2/Package.swift:25:        .library(name: "FeedDomain", targets: ["FeedDomain"]),
Packages/FeedRuntimeV2/Package.swift:26:        .library(name: "FeedStorage", targets: ["FeedStorage"]),
Packages/FeedRuntimeV2/Package.swift:27:        .library(name: "FeedRuntime", targets: ["FeedRuntime"]),
Packages/FeedRuntimeV2/Package.swift:28:        .library(name: "FeedConnectorSyndication", targets: ["FeedConnectorSyndication"]),
Packages/FeedRuntimeV2/Package.swift:29:        .library(name: "FeedMedia", targets: ["FeedMedia"]),
Packages/FeedRuntimeV2/Package.swift:30:        .library(name: "FeedUIBridge", targets: ["FeedUIBridge"]),
Packages/FeedRuntimeV2/Package.swift:39:            name: "FeedDomain",
Packages/FeedRuntimeV2/Package.swift:43:            name: "FeedStorage",
Packages/FeedRuntimeV2/Package.swift:46:                .product(name: "GRDB", package: "GRDB.swift"),
Packages/FeedRuntimeV2/Package.swift:51:            name: "FeedRuntime",
Packages/FeedRuntimeV2/Package.swift:56:            name: "FeedConnectorSyndication",

### scripts de verificacao na raiz
scripts/batch_discover_journalists.sh
scripts/batch_discover_writers.sh
scripts/enrich_loop.sh
scripts/finalize_radio_discovery.sh
scripts/generate_build_info.sh
scripts/generate_opml_manifest.sh
scripts/release-acceptance.sh
scripts/release-journey.sh
scripts/release-testflight.sh
scripts/test_feeds.sh
scripts/verify-card-resolution-invariants.sh
scripts/verify-runtime-v2-boundaries.sh


[[TAREFA]]

Reemita o plano executável em YAML único, corrigido:
- Todo `verify.command` tem de usar apenas alvos/scripts/testplans da lista acima. Se um passo precisa de verificação que não existe, escreva `verify.command: "PARADA: HUMANO — falta <o que>"` em vez de inventar.
- Corrija as citações de linha que a auditoria marcou erradas (PublicationCardID em `PublicationRepository.swift:1009-1042`; `MainFeedCardBridge.cardID(forLegacyItemID:)` em `:234-245`; throw de colisão em `SQLiteCatalogStore.swift:216-217`).
- Nenhum passo pode tocar `feed_item.id`, nem rekey/mover/apagar dado do usuário: toda migração é aditiva e a autoridade legada permanece até o cutover explícito. Se algum passo precisar disso, ele não existe — remova.
- `kind` só pode ser doc_edit, additive_migration, code, test ou measurement. Cada passo com `depends_on`, `rollback` e `stop_condition`.

Mantenha o esquema já usado na versão anterior (version, preconditions, steps, human_decisions).

CONTRATO DE ENTREGA: primeira linha exatamente [[DELIVERABLE-START]]; o YAML dentro de UM bloco de código; última linha exatamente [[DELIVERABLE-END]]; nada depois; sem canvas/Document; sem prosa além de uma linha de abertura.
