| Blueprint/plan row | ADR decision id | Invariant ids | PR that must produce the evidence | Status |
|---|---|---|---|---|
| amendment D20–D23 | D20 | 8, 11, 21, 22, 25, 30 | PR-01 | proposed |
| amendment D20–D23 | D21 | 7, 8, 11, 22, 23, 24, 25 | PR-01 | proposed |
| Plan §5.1 (`SourceID` runtime is allocated/persisted; persist catalog identity + canonicalization version → runtime source) + amendment D20–D23 | D22 | 7, 11, 26, 27 | PR-01 | proposed |
| Plan §5.1 (catalog rebuild reapplies mappings; no reallocation by row order) + amendment D20–D23 | D23 | 5, 11, 25, 27, 28, 29, 30 | PR-01 | proposed |

### Novos ids de invariante

Os invariantes existentes terminam em **20**. Portanto `INV-M1`…`INV-M10` entram como **21–30**, sem renumerar 1–20.

- **21 — No derived translation.** Nenhum `CatalogSourceID`, URL, digest, row order ou widening produz `FeedDomain.SourceID`; criação só ocorre por mapping persistido conforme D20–D21.
- **22 — Bridge before return.** Uma Source de catálogo só é devolvida como runtime `SourceID` depois de existir `legacy_source_map` durável correspondente.
- **23 — Single allocator.** Somente `RuntimeSourceRegistry` aloca a row/ID runtime; o resolver decide política, mas não fabrica o identificador.
- **24 — Atomic first mapping.** Primeira alocação e estabelecimento do bridge commitam atomicamente; falha não deixa mapping nem Source bridge-visible parcialmente estabelecidos.
- **25 — Existing mappings are authoritative.** Mapping exato existente é retornado e nunca silenciosamente re-pointed.
- **26 — Canonicalization versions are positive and explicit.** Toda versão persistida é explícita e `> 0`; Runtime V2 não a incrementa implicitamente.
- **27 — Version change does not renumber Sources.** Alterar `canonicalization_version` não cria nem reutiliza semanticamente uma Source por si só; continuidade precisa ser explícita.
- **28 — Historical mappings are immutable evidence.** Criar mapping para `N+1` não atualiza nem remove o mapping de `N`.
- **29 — Ambiguity never becomes merge.** Continuidade ambígua é conflito/refusal; jamais merge automático.
- **30 — `legacy_source_map` remains the only catalog legacy bridge.** D20–D23 não criam caminho paralelo de catalog identity → runtime Source.

### Por que cada linha usa esses invariantes

- **D20:** preserva **8** (nenhuma conversão legacy→runtime) e **11** (mapping sobrevive/reaplica após catalog rebuild); acrescenta **21** (sem derivação), **22** (bridge antes do retorno), **25** (mapping existente é autoritativo) e **30** (único bridge).
- **D21:** preserva **7** (ID local válido/positivo), **8** (não conversão) e **11** (Source não é renumerada); acrescenta **22–25** para allocator único, atomicidade e autoridade do mapping existente.
- **D22:** preserva **7** porque a versão continua sujeita ao domínio positivo do schema e **11** porque rebuild não renumera a Source; acrescenta **26–27** para ownership/semântica de `canonicalization_version`.
- **D23:** preserva **5** porque ambiguidade continua sem merge e **11** porque mapping histórico não é re-alocado por rebuild; acrescenta **25**, **27–30** para autoridade, continuidade explícita, imutabilidade histórica, refusal em ambiguidade e bridge único.

### Origem e PR

**D20 e D21 são decisões novas da emenda.** O plano §5.1 já exige Source runtime alocada/persistida e mapping durável, mas não define `missing → ensure`, policy owner nem atomicidade entre allocation e bridge; por isso a célula de origem deve ser literalmente `amendment D20–D23`.

**D22 e D23 têm raiz em Plan §5.1**, que já exige `(catalog identity + canonicalization version) → runtime source` e reaplicação de mappings após rebuild. A regra sobre quem avança a versão, imutabilidade das versões antigas e resolução de continuidade é acrescentada pela emenda, portanto a célula registra ambos.

**PR-01** é o responsável pela evidência pós-freeze: é o slice do backlog que implementa o Source bridge/atomic ensure e seus testes. PR-00 apenas incorpora/congela a emenda documental; ele não deve fingir evidência de implementação.

### Status

Todas as quatro linhas entram hoje como:

`proposed`

O ADR continua `Proposed` e D20–D23 ainda não possuem implementação/evidência landed. Nenhuma das quatro decisões depende de escolha humana adicional além do Gate 0 já aplicável ao conjunto dos ADRs.