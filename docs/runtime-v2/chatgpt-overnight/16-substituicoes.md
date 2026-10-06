ARQUIVO: 01-plano-de-migracao.md
ANCORA: **Escopo:** migração delegada pela §16 do ADR-003.
NOVO: **Escopo:** migração requerida por `docs/superpowers/plans/2026-09-17-feedmine-runtime-v2-revised.md` §5.2, no parágrafo que começa com “Inventariar também lidos, clicked history, fontes importadas, fontes desabilitadas, coleções, Smart Feeds, filtros persistidos e busca persistente.”
MOTIVO: ADR-003 não possui §16; o handoff de migração vem do plano revisado de 2026-09-17.

ARQUIVO: 01-plano-de-migracao.md
ANCORA: normalização de identidade força HTTPS, remove `www`, porta, trailing slash e parâmetros inclusive `token`, `auth`, `key`, `signature` e `access_token`
NOVO: normalização de identidade força HTTPS, remove `www`, omite apenas portas default (80 para HTTP e 443 para HTTPS), preserva portas não-default, remove trailing slash e parâmetros inclusive `token`, `auth`, `key`, `signature` e `access_token`
MOTIVO: `OPMLParser.swift:719-723` preserva portas não-default na identidade.

ARQUIVO: 01-plano-de-migracao.md
ANCORA: [NAO FORNECIDA]
NOVO: [AGUARDAR ÂNCORA LITERAL ANTES DE SUBSTITUIR]
MOTIVO: preciso da frase completa atual de `01-plano-de-migracao.md` que contém literalmente `SQLiteCatalogStore.swift:186-196`; a substituição deverá trocar essa referência por `SQLiteCatalogStore.swift:216-217` sem alterar o restante da frase.

ARQUIVO: 01-plano-de-migracao.md
ANCORA: Fato ainda insuficiente: foram fornecidos os nomes das keys filter*, mas não o tipo/encoding de cada valor. Isso não impede preservá-las; impede qualquer tradução de formato.
NOVO: Fato suficiente para preservação tipada: `feedmine/Services/AppSettings.swift:65-92` expõe `filterRegion: String?`, `filterTaxonomyNodes: [String]`, `filterContentType: String`, `filterAutoExpire: Bool`, `filterSetAt: TimeInterval`, `filterLanguages: [String]` e `filterMood: String`. A migração deve preservar esses tipos e seus valores sem rekey ou tradução destrutiva.
MOTIVO: os tipos dos filtros estão explicitamente disponíveis no checkout.

ARQUIVO: 02-identidade-source-runtime.md
ANCORA: PublicationCardID real nasce na transaction de publicação (PublicationRepository.performCommit, PublicationRepository.swift:948)
NOVO: PublicationCardID real nasce na transaction de publicação (`PublicationRepository.performCommit` começa em `PublicationRepository.swift:903`; o `published_card` é inserido em `:1009-1041` e `PublicationCardID(db.lastInsertedRowID)` é criado em `:1042`)
MOTIVO: `:948` não é a linha de allocation; a allocation efetiva está em `:1042`.

ARQUIVO: 07b-anexo-corrigido.md
ANCORA: ## §1. Plano de migração normativo (anexo)
NOVO: ## Plano de migração normativo (anexo)
MOTIVO: ADR-003 não usa seções numeradas §1/§16; o anexo não deve introduzir uma numeração inexistente.