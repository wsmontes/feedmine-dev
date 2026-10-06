[[PARTE 3/3]]

Candidato principal: reconciliação do card durante publicação de background/startup, não overlay.

Em FeedDisplayState.swift:261:

if !isAppend, !userInitiated, !visibleItems.isEmpty, !cards.isEmpty {

o pipeline faz merge sobre uma página já exibida e depois, em 287-290:

visibleCards = mergedCards
visibleItems = mergedItems
visibleItemsGeneration &+= 1
visibleCardsGeneration &+= 1
Mesmo preservando ordem/IDs, ele substitui os valores que alimentam a árvore SwiftUI. Pior: 316-317 incrementa as duas generations novamente após sair desse branch. Uma publicação de background pode portanto invalidar/recompor a timeline duas vezes.

O alvo do toque está em FeedScreen.swift:859-884:

ForEach(loader.dateSections) { section in
    ...
    ForEach(section.items) { item in
        FeedItemView(...)
        .id(item.id)
e o recognizer que precisa sobreviver está em FeedItemView.swift:53. A mesma ID/frame pode continuar aparecendo no XCUI enquanto SwiftUI troca/reconcilia a view backing entre touch-down e reconhecimento — exatamente compatível com feed_unchanged_verified + ausência de card tap.

Não achei overlay geral mais forte: ShakeDetector é allowsHitTesting(false) (FeedScreen:145); nightOverlay também (:978). OnboardingTipsView não existe quando -UITestSkipOnboarding marcou onboarding concluído. Os highPriorityGesture de FeedItemCardView:127/222 só existem quando onImageTap != nil (podcast), portanto não explicam o caso geral.

Confirmação decisiva: instrumentar publishCards com generation + IDs + timestamp e FeedItemView com onAppear/onDisappear. No próximo miss, usar TapTrace:

window tap presente
card tap ausente
publicação/reconciliação do mesmo item entre 92-reader-pre-tap e o tap
=> fecha o mecanismo.

A/B ainda mais forte: temporariamente impedir o branch 261 de substituir uma página já visível durante a janela da jornada. Se 15/17 virar 17/17 com as mesmas mudanças de imagem, o defeito está isolado nesse churn de publicação.