[[PARTE 3/3]]

CRITÉRIOS DE REVIEW DA APPLE QUE PODEM REPROVAR
Privacy Policy dentro do app — BLOQUEADOR.
Apple exige link para a política no App Store Connect e dentro do app, facilmente acessível. Hoje SettingsSheetView.swift:243-271 tem Feedback/FeedKit, mas não Privacy Policy. Adicionar “Privacy Policy” em Settings antes do build final. 

Conteúdo de terceiros — risco principal.
FeedMine agrega RSS, sites, podcasts e vídeos. A Apple exige que o app tenha direito/permissão para acessar/exibir serviços e conteúdo de terceiros. Review Notes devem explicar que o app é um reader, acessa URLs públicas fornecidas/publicadas pelas fontes e preserva atribuição/link original. Evitar afirmar propriedade sobre conteúdo. 

WKWebView + JavaScript.
ArticleReaderView.swift:38-76 carrega a página original em WKWebView com JS habilitado e oferece abertura no Safari. Isso é legítimo, mas teste no RC links, redirects, páginas quebradas e comportamento de navegação. Não apresentar WebView como conteúdo produzido pelo FeedMine.

Links externos.
Não há compra, assinatura ou checkout externo detectado. Portanto não introduzir CTA de pagamento/assinatura durante a preparação da submissão.

Login.
Não existe conta/login. Logo Sign in with Apple não se aplica; Review Notes devem dizer explicitamente “No account required.” A regra de login alternativo só é relevante para apps que usam login social/terceiro. 

Permissões/privacy.
Não há câmera, microfone, localização, contatos ou ATT. Não adicionar permission strings “preventivamente”. O acesso ao clipboard (ClipboardBanner.swift:73-99) deve continuar apenas local.

ATS/media.
NSAllowsArbitraryLoadsForMedia=true é amplo. Confirmar no archive que é realmente necessário para playback; não ampliar ATS além disso.

O QUE SÓ O HUMANO FAZ — EM ORDEM
Publicar a Privacy Policy em URL HTTPS pú