# RC 18 — o bump de build e a prova do archive (procedimento verificado)

> **Consequência que decide o seu trabalho:** os **11 consertos** deste pacote estão na *árvore* (worktree), não no commit `70f7b06b`. Publicar o build **17** (já enviado, do commit `4df951c4`) significa **não embarcar nenhum deles**. Eles só entram se você escolher um build novo — 18.

## Por que 18 e não 17

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
