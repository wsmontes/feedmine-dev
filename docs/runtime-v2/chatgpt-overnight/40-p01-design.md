[[PARTE 1/3]]

Correção mínima de produto: fail-closed. FeedStore.empty() continua só para manter o objeto inicializável; não vira um “modo normal”. Se o SQLite real falhar, Feedmine não deve mostrar um feed aparentemente zerado nem aceitar alterações.

UI: no próprio FeedScreen, antes do switch loader.feedDisplayPhase, usar ContentUnavailableView — não criar tela nova.

Texto:
“Your feed data couldn’t be opened”
“Feedmine couldn’t open its local database. Your saved data has not been deleted. Close and reopen the app. Changes are disabled until the database opens normally.”

Bloquear enquanto ativo: start() não inicia o store/fetch; header, refresh/shake, onboarding e qualquer fluxo de add/import/source toggle/bookmark/collection ficam inacessíveis. Ou seja, fallback = objeto de segurança, não banco temporário utilizável.

Patch
Em FeedLoader.swift, âncora verbatim:

/// Non-nil if the default FeedStore failed to initialize.
private(set) var initError: Error?
adicionar:

var persistenceUnavailable: Bool { initError != nil }
E em:

func start() async {
    await store.start()
trocar por:

func start() async {
    guard !persistenceUnavailable else {
        Log.db.error("Persistent store unavailable; startup blocked.")
        return
    }
    await store.start()
Em FeedScreen.swift, âncora:

if isSearching && hasCommittedSearch {
    unifiedSearchPanel
} else {
    switch loader.feedDisplayPhase {
trocar por:

if loader.persistenceUnavailable {
    ContentUnavailableView(
        "Your feed data couldn’t be opened",
        systemImage: "externaldrive.badge.exclamationmark",
        description: Text("Feedmine couldn’t open its local database. Your saved data has not been deleted. Close and reopen the app. Changes are disabled until the database opens normally.")
    )
    .accessibilityIdentifier("persistent-store-unavailable")
} else if isSearching && hasCommittedSearch {
E o restante da UI normal deve ficar .disabled(loader.persistenceUnavailable)/não renderizado.

Teste: FeedLoaderTests.testPersistentStoreFailureFailsClosed() usando factory injetável que lança: prova initError != nil, persistenceUnavailable == true, start() não inicializa o fallback como sessão normal e a superfície persistent-store-unavailable é a escolhida.