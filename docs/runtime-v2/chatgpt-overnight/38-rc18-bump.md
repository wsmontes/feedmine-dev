# RC 18 — o bump de build e a prova do archive (procedimento verificado)

> **Consequência que decide o seu trabalho:** os **14 consertos** estão no commit **`8f9e0d02`** ("fix(release): fourteen defects from the review, and build 18"), com o build já em **18**. O build **17** (entregue de `4df951c4`) não carrega nenhum deles.

## Estado da publicação (executado em 2026-10-06, 10:2x)

**RC escolhido: 18** — publicar o 17 significaria não embarcar nenhum dos 14 consertos (o 17 saiu de `4df951c4`).

Feito, com evidência:

1. `feedmine/Info.plist` → `CFBundleVersion` = **18** (o alvo lê esse literal: `project.pbxproj:1543,1562` → `INFOPLIST_FILE = feedmine/Info.plist`).
2. Commit **`8f9e0d02`** — *"fix(release): fourteen defects from the review, and build 18"* (14 arquivos de código + testes + o pacote de docs desta revisão). Árvore limpa.
3. `scripts/release-testflight.sh --dry-run` → **verde**: `archived: version=1.0 build=18 sha=8f9e0d02` e `PAIRING OK: TestFlight build 1.0 (18) = 8f9e0d029c70b90ab9081c3d6114b178aab6c9ba`.
4. `scripts/release-testflight.sh` (envio real) → **arquivou e autenticou, e a Apple recusou por contrato**:

```
403 FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED
'A required agreement is missing or has expired.'
```

**Nada foi enviado** (`.build/tf-export` vazio) e **nenhuma tag foi criada** — o script sai antes disso. O que falta é uma ação **só sua**, no App Store Connect: aceitar o contrato pendente (App Store Connect → *Business* → **Agreements, Tax, and Banking**, ou o banner de contrato no topo). A chave de API está boa — a resposta é regra de negócio, não 401.

Depois de assinar, o mesmo comando publica:

```bash
cd /Users/wagnermontes/Documents/GitHub/feedmine
scripts/release-testflight.sh
```
Esperado: `Upload succeeded`, a tag local `ios/1.0-build.18-8f9e0d02` e a linha `BUILD 1.0 (18) = 8f9e0d02…`. Nada é pushado (a tag fica local, como o próprio script documenta).



| Fato | Onde |
|---|---|
| O build **17** enviado à Apple saiu do commit `4df951c4` | `git log -1 4df951c4` = "chore(release): bump build to 17" |
| A árvore atual (`70f7b06b`) está **2 commits à frente** e ainda declara 17 | `feedmine/Info.plist` → `CFBundleVersion` = 17 |
| O alvo do app lê o plist literal (não há variável de build) | `feedmine.xcodeproj/project.pbxproj:1543,1562` → `INFOPLIST_FILE = feedmine/Info.plist` |
| Logo, o mesmo número 17 cobre **dois binários diferentes** | — |

## Passos

1. **Editar `feedmine/Info.plist`**: `CFBundleVersion` de `17` para `18`. `CFBundleShortVersionString` continua `1.0` (o marketing version não muda num RChardening).
2. **`project.yml`** — opcional e **não obrigatório**: ele é *referência* e o próprio cabeçalho proíbe regenerar o `.xcodeproj` com `xcodegen`. Se editar o literal ali para manter a referência honesta, não rode o gerador.
3. **Commitar** (o candidato precisa de árvore limpa):
   ```bash
   git status --porcelain          # deve estar vazio além do que você quer commitar
   ```
   `scripts/release-testflight.sh` **aborta com exit 9** em árvore suja — é verificação, não sugestão.
4. **Provar o archive sem enviar:**
   ```bash
   scripts/release-testflight.sh --dry-run
   ```
   Verde objetivo:
   - `exit 0`;
   - `archived: version=1.0 build=18 sha=<HEAD curto>` — e o SHA arquivado **igual** a `git rev-parse --short HEAD`;
   - `PAIRING OK: TestFlight build 1.0 (18) = <sha>`;
   - `DRY RUN: archive verificado, nada foi enviado e nenhuma tag criada`.
5. **Se o dry-run passar**, o envio real é a mesma linha sem `--dry-run` — e aí é decisão sua (é o passo que publica).

## Antes de arquivar, o que a barra já cobre

`scripts/release-acceptance.sh` nesta árvore: **`BAR OK`** (gates 609/0 ×3 + jornada 17/17), com os 11 consertos aplicados. Fronteiras 8/8 e Runtime V2 501/0 + 608/0 também executados.

## O que a barra **não** cobre, e você precisa saber

O passo do reader da jornada falha com **mais frequência quando a árvore ganha trabalho no caminho de imagem** (3/3 execuções dentro da barra com tais mudanças, 3/3 sem). O harness **não repete o tap de propósito** — o comentário no teste diz que *"a retap would convert a real defect into a green journey"* — e a classificação do miss (`miss_cause=feed_unchanged_verified`, card ainda visível e hittable) descreve **tap ignorado com o pipeline de startup rodando**. Trate como achado do app, não como flake: se você vir `reader_not_presented=1` num RC, o log está em `/tmp/feedmine-journey.log` e o screenshot em `91-reader-missing.png`.
