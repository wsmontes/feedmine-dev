# RC 18 — o bump de build e a prova do archive (procedimento verificado)

> **Consequência que decide o seu trabalho:** os **15 consertos** estão no commit **`816d1dd9`** (`816d1dd9` = C-06; o pacote começou em `8f9e0d02` = "fix(release): fourteen defects from the review, and build 18"), com o build já em **18**. O build **17** (entregue de `4df951c4`) não carrega nenhum deles.

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

### Retentativa em 13:33 — mesmo bloqueio, requisição nova

`scripts/release-testflight.sh` re-rodado sobre o HEAD atual (`816d1dd9`, 15 consertos, barra verde `BAR OK 11:34:37`): arquivou, pareou (`PAIRING OK: TestFlight build 1.0 (18) = 816d1dd93ffee0389a0f2f2ab6a6cfccdecc9a37`) e o `AppsService` recusou de novo, com id de requisição **novo** (`U2TKFRZQO3DD3V4BJYJRHEI74E`): `403 FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED`. Nada enviado, nenhuma tag criada. Não existe endpoint de API para assinar contrato — é ação do *Account Holder*.

### ENVIADO — build 18 no TestFlight (13:45)

Depois do contrato assinado, o mesmo comando publicou, sem nenhuma outra mudança:

```
== building 1.0 (18) from ad52a54c ==
archived: version=1.0 build=18 sha=ad52a54c
PAIRING OK: TestFlight build 1.0 (18) = ad52a54c2d939eabdb9b4969910e5fdc29a15ad4
Upload succeeded.
tag ios/1.0-build.18-ad52a54c created (local, not pushed)
```

- **`Upload succeeded`** é a confirmação da Apple (o `AppsService` aceitou o binário); o processamento do TestFlight leva alguns minutos até o build ficar selecionável.
- **Tag local:** `ios/1.0-build.18-ad52a54c` (o script nunca pusha). O SHA `ad52a54c` é o commit de docs sobre o `816d1dd9` — o mesmo código que fechou `BAR OK 11:34:37` (611 testes ×3 + jornada 17/17).
- **O que isso NÃO resolve:** App Privacy, metadados, screenshots, testadores e as Review Notes continuam atrás do Connect; e o dogfood em device pode ser feito pelo TestFlight agora (não precisa mais do `.ipa` de desenvolvimento).

### Enquanto o contrato está pendente: dogfood local, sem tocar no Connect

O bloqueio do upload **não gasta** o archive assinado. Dele saiu um `.ipa` de **desenvolvimento**, que não fala com o `AppsService`:

- **Artefato:** `.build/feedmine-1.0-18-dev.ipa` (73,7 MB, sha256 `d61cf7cb…`; a pasta `.build/` é ignorada pelo git).
- **Verificado por dentro** (o mesmo emparelhamento do TestFlight, agora no arquivo que vai ao telefone): `CFBundleVersion = 18`, `CFBundleShortVersionString = 1.0`, **`FeedmineGitSHA = 816d1dd9`**.
- **Assinatura:** `Apple Development: wmontes@gmail.com (BU5227WFYX)`, profile `iOS Team Provisioning Profile: *`, válido até 2027-06-07.
- **Devices autorizados — exatamente os dois telefones do dono:**

| Telefone (`devicectl`) | UDID no profile |
|---|---|
| Wagner's iPhone 14 Plus (`D28AP`) | `00008110-00067D861486201E` |
| iPhone (129) — iPhone 15 (`D37AP`) | `00008120-000260903ED1A01E` |

Instalação (telefone plugado; qualquer um dos dois serve):

```bash
xcrun devicectl device install app --device 00008110-00067D861486201E \
  /Users/wagnermontes/Documents/GitHub/feedmine/.build/feedmine-1.0-18-dev.ipa
```

Isso destrava o dogfood do build 18 **sem** depender do contrato: mesma árvore, mesmo build e mesmo SHA que o TestFlight receberá quando o contrato for assinado. O que **não** substitui: revisão da App Store, App Privacy e metadados — esses continuam atrás do Connect.



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
