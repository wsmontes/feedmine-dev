# ORDEM POR RISCO

| Ordem | Item | Classe | O que quebra na prática |
|---|---|---|---|
| 1 | **Definir qual binário é o 1.0: build 17 já `VALID` ou árvore atual Runtime V2** | **(c) ambíguo** | O build 17 enviado à Apple é `1.0 (17)` do SHA `4df951c4`. Já `70f7b06b` está **2 commits à frente do `main`** e altera extensamente app + Runtime V2, mas ainda declara build `17`. Não são o mesmo RC. Tentar tratar a árvore atual como “build 17” quebra a rastreabilidade e não gera um novo build aceitável no App Store Connect. |
| 2 | **Bar final de release sobre o SHA exato que será enviado** | **(a)** | Sem ele, mudanças pós-build-17 podem ter regressão em persistência, feed, reader ou jornada e ainda assim parecer “prontas” porque apenas os testes Runtime V2 passaram. |
| 3 | **Campos obrigatórios do App Store Connect** | **(b)** | Privacy Policy URL, App Privacy, metadata e screenshots ainda não estão fechados; sem isso o 1.0 não chega a um submission completo para App Review. |
| 4 | **Runtime V2 gate, se a árvore atual entrar no 1.0** | **(a)** | `test_runtime_v2_boundaries.sh` verde prova fronteiras estáticas, não comportamento. O gate completo precisa provar package + app. Seu run está corretamente em andamento. |
| 5 | **Dogfood do binário TestFlight que será efetivamente submetido** | **(b)** | Simulator e build local não provam instalação real, signing, reader/network no device, background audio nem upgrade sobre dados existentes. |
| 6 | **Performance física, se a árvore atual substituir o build 17** | **(a), requer device** | O próprio runner declara resultado de simulator como `INCONCLUSIVE`; regressões graves de launch/scroll podem passar nos gates funcionais. |
| 7 | **Open findings internos do Runtime V2** | **não bloqueiam o 1.0 atual por si só** | Ex.: `catalogSourceID=0` recusado em `v2Full`. Fresh install sem request resolve para `.legacy`; portanto não seguraria o build 17 público. Não transformaria isso em blocker de release agora. |

**Minha escolha para publicar mais rápido e com menor risco:** se não existe correção pós-build-17 que seja obrigatória para o usuário, publique o **build 17 já `VALID`** e deixe a árvore Runtime V2 para o próximo build. O build 17 já tem evidência de `474/0 ×3` + jornada `17/17`. Se a árvore atual precisa entrar no 1.0, ela passa a ser um **novo RC, build 18**.

# EXECUTÁVEL POR OMP

## A. Gate Runtime V2 — já em execução

Comando real:

```bash
bash scripts/validation/run_runtime_v2_tests.sh
Critério codificado pelo runner:

exit code 0;
package: >= 45 testes, 0 failures;
app plan: >= 400 passed, 0 failed;
última linha: Runtime V2 test gate: PASS.
Para 70f7b06b, a evidência registrada no próprio repo é mais forte: 501 package / 0 e 608 app / 0. Portanto, para essa árvore eu trataria uma contagem significativamente inferior como investigação obrigatória mesmo que ainda ultrapasse os floors.

Se falhar por espaço:

bash scripts/validation/clean_validation_artifacts.sh --build

e repetir sem builds concorrentes.

B. Gate final de publicação — item (a) de maior risco
Comando real:

scripts/release-acceptance.sh

Para a árvore 70f7b06b, verde objetivo:

build-for-testing exit 0;
três execuções consecutivas de feedmineTests;
referência atual dessa árvore: 608 testes / 0 failures em cada execução;
nenhum ** TEST ... FAILED **;
jornada:
JORNADA superficies-obrigatorias=17/17 ausentes=[];
journey xcodebuild exit 0;
saída final:
== BAR OK ... ==;
script exit 0.
Para o build 17 antigo, a referência certificada era 474/0 ×3 + 17/17. Não misture os dois números: eles correspondem a árvores diferentes.

C. Provar o archive antes de qualquer upload de um novo RC
Depois de o candidato estar em commit limpo:

scripts/release-testflight.sh --dry-run

Critério verde:

exit 0;
archived: version=1.0 build=<novo-build> sha=<HEAD>;
SHA arquivado igual ao git rev-parse --short HEAD;
PAIRING OK: TestFlight build 1.0 (...) = ...;
DRY RUN: archive verificado, nada foi enviado e nenhuma tag criada.
Importante: o próprio script aborta com exit 9 se houver working tree suja. Logo, se a árvore atual for o RC, é necessária autorização para produzir um commit local do candidato antes desse passo. Isso não implica push.

D. Performance física, se houver novo build
Comando real:

FEEDMINE_DEVICE_ID=<UDID> bash scripts/validation/run_performance.sh device

Verde objetivo:

exit 0;
.xcresult com resultado Passed;
failedTests = 0;
número de testes executados > 0.
O runner não codifica um floor de contagem, então não inventaria um. Registre a contagem real do .xcresult como baseline do RC.

O que eu NÃO usaria como blocker isolado
run_smoke.sh teve no baseline um histórico de failures dependentes de conteúdo/network. O release-acceptance.sh é o gate de produto mais forte e deliberadamente valida a jornada real. Eu não seguraria um 1.0 verde no acceptance bar apenas porque um smoke antigo reproduziu expectativas de conteúdo não determinísticas.

HUMANO
Hard blockers para “Submit for Review”
Privacy Policy URL pública e alcançável.
App Privacy preenchido de acordo com o executável real.
Metadata: subtitle, description, keywords, support URL, copyright, category, age rating, review contact/notes.
Screenshots do RC aprovado.
Esses quatro não são “qualidade desejável”: impedem fechar corretamente o submission no App Store Connect.

docs/AppStoreSubmission.md ainda fala em 1.0 (2), então seus release facts estão obsoletos; os cinco TODOs continuam úteis, mas o documento não deve ser usado para identificar o build corrente.

Gate humano de qualidade
instalar o mesmo build TestFlight candidato;
testar no device ao menos:
clean install → onboarding → feed;
abrir reader;
bookmark → terminate → relaunch;
upgrade sobre instalação anterior com dados;
offline → online;
podcast/audio + background/lock screen;
scroll longo;
filtros/composer;
Source View.
Adicionar internal TestFlight testers é útil para esse processo, mas não é, por si só, uma limitação técnica do binário.

DIAGNÓSTICO DO ESCOLHIDO
Escolhido: certificar a árvore atual como novo release candidate, caso você decida não publicar diretamente o build 17.

O defeito mecânico está aqui:

feedmine/Info.plist:88-89
<key>CFBundleVersion</key>
<string>17</string>
e a referência acompanha o mesmo valor:

project.yml:46
CFBundleVersion: "17"
Enquanto isso:

build 1.0 (17) já foi enviado e ficou VALID;
esse build corresponde ao SHA 4df951c4af4ecd675ad48100bd4b941f1b766421;
70f7b06b está 2 commits à frente de main e contém o Runtime V2 + alterações no app.
Além disso, scripts/release-testflight.sh:39 lê diretamente esse CFBundleVersion, e o script prova o SHA do archive contra HEAD.

Portanto, se 70f7b06b/working tree atual for o release candidate, ele não pode continuar sendo build 17.

Correção mínima
Somente se a decisão for “Runtime V2 atual entra no 1.0”:

--- a/feedmine/Info.plist
+++ b/feedmine/Info.plist
@@
-    <string>17</string>
+    <string>18</string>
e manter a referência consistente:

--- a/project.yml
+++ b/project.yml
@@
-        CFBundleVersion: "17"
+        CFBundleVersion: "18"
Não rodar xcodegen. O .xcodeproj continua sendo a autoridade.

Depois:

bash scripts/validation/run_runtime_v2_tests.sh
scripts/release-acceptance.sh
scripts/release-testflight.sh --dry-run

Se qualquer um falhar, não subir build 18.

ENTREGA DO CHAT
Minha parte fechada para esta rodada é a decisão operacional de release:

CAMINHO A — menor risco / publicação mais rápida
-----------------------------------------------
RC = build 17 / SHA 4df951c4
Runtime V2 posterior não entra no 1.0.
Não gerar novo binary.
Fechar App Store metadata/privacy/screenshots.
Dogfood build 17 no TestFlight.
Submit for Review.

CAMINHO B — árvore atual precisa entrar no 1.0
----------------------------------------------
RC novo = build 18.
Bump 17 → 18 em Info.plist + project.yml.
Runtime gate PASS.
Release acceptance: 608/0 ×3 + 17/17 + exit 0.
Commit limpo autorizado.
release-testflight.sh --dry-run → PAIRING OK.
Dogfood físico.
Só então upload do build 18.
Também fecho uma distração importante: eu não bloquearia a publicação do build 17 por ADR-003, D20–D23 ou pelo restante do Runtime V2. Isso é trabalho de arquitetura/evolução e o launch sem request continua .legacy. Para o objetivo “FeedMine 1.0 na App Store”, o que resta é escolher o RC, provar exatamente esse RC e fechar o App Store Connect.