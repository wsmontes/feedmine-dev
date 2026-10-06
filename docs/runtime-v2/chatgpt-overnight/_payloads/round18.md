[[ROUND 18 — EMENDA AO ADR-003: RESOLUÇÃO DE MAPPING AUSENTE E LIFECYCLE DA CANONICALIZATION VERSION]]

Você identificou, no round 17, que o seu próprio plano conflita com o D2 vigente do ADR-003: o plano transforma "mapping ausente" em gatilho de alocação de `SourceID`, enquanto o D2 torna a tradução catálogo → runtime um lookup persistido em `legacy_source_map`, com ausência de linha como resultado terminal. Isso bloqueia o Gate 0 para essa parte. Fatos, verbatim do repositório:

### ADR-003 D2 (head)
**D2 — The catalog ID is a different type, aliased, never converted.** The app-level `FeedEngine.SourceID` (`UInt32`, `Identities.swift:32-37`) is and remains the *catalog* identity. Bridges refer to it as `CatalogSourceID`; there is no `init` on `FeedDomain.SourceID` taking a `CatalogSourceID`, no `UInt32`/`UInt64` narrowing on the path, and no computation of a runtime ID from a URL digest. The

**D3 — Local row IDs are positive `Int64` with a checked encoding.** Every runtime table that stores a local identity uses `INTEGER PRIMARY KEY` in the positive `Int64` range, allocated by SQLite/GRDB, with `CHECK (id > 0)` so `0` stays reserved and unreachable. Legacy values enter through a checked conversion that throws on `0`, negatives and out-of-range values; truncating casts of the kind fo

### ADR-003 D18 (head)
**D18 — Legacy bridges are the only legacy identity path.** `legacy_source_map` maps catalog source identity (key + id + canonicalization version) to a runtime source; `legacy_item_map` maps the legacy TEXT item id to an `origin_record`/`origin_revision` with an explicit confidence. While the coexistence window of ADR-004 holds, runtime IDs are never used as the bookmark key: bookmarks keep the 

**D19 — No array index and no batch ordinal is an identity.** Nothing durable keys on array position, row order, batch order or viewport index. Ordinals exist only inside an acquisition batch or a published edition, are regenerated per batch/edition, and always accompany a real identity (`PublicationCardID`, `OriginRecordID`, durable action key — ADR-001/004/007).

### M1 do plano (head)
## M1 — FeedSource / SourceID

**Decisão M1:** nunca converter `FeedEngine.SourceID(UInt32)` para `FeedDomain.SourceID(UInt64)`. O único vínculo permitido é mapping explícito.

**Muda**

| Elemento | Mudança |
|---|---|
| `legacy_source_map` | Continua sendo a ponte para sources provenientes do catálogo. |
| `FeedDomain.SourceID` | Continua sendo alocado por `RuntimeSourceRegistry`. |
| runtime schema | Adicionar mapping genérico para sources persistidas fora do catálogo, principalmente `imported_source`/collections. |
| Swift | Introduzir resolver `LegacySourceIdentityResolver`; entrada = persisted `source_identity`, saída = runtime `SourceID`. |

DDL novo no próximo runtime migration:

```sql
CREATE TABLE legacy_source_identity_map (
    legacy_source_identity TEXT NOT NULL,

### Conflito M1 x D2 (round 17)
### M1 versus D2 — BLOQUEADOR real de Gate 0

**Leitura existente do ADR:** D2, intitulada **“The catalog ID is a different type, aliased, never converted”**, não apenas proíbe conversão; no texto vigente já auditado, a tradução catalog → runtime é descrita como lookup persistido em `legacy_source_map` **que falha quando não existe mapping**.

**O que M1 mudaria:** transformaria ausência de mapping de resultado terminal em operação de criação:

```text
missing mapping
→ allocate runtime SourceID
→ persist mapping atomically
→ return SourceID
Isso não é mera implementação de D2. É mudança da semântica de resolução de uma condição que o ADR já tornou normativa.

Consequência: enquanto ADR-003 for normativo no repositório, M1 não pode implementar missing → ensure/allocate sem amendment do ADR-003. Esse conflito é BLOQUEADOR de Gate 0/implementação dessa parte de M1.


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
