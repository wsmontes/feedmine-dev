# Pacote de submissão — App Store (produzido pelo worker com acesso ao repo, 2026-10-06)

> Reemitido em 3 partes porque a janela renderizada da conversa não sustenta documentos longos (ver a nota de extração em `_index.md`). Conteúdo íntegro das três partes, na ordem.

[[PARTE 1/3]]

METADADOS
Subtitle — en-US:
Your feeds, your way
Subtitle — pt-BR:
Seus feeds, do seu jeito

Promotional text — en-US:
Follow news, podcasts, videos and independent sources in one personal feed — no account, no ads and built around the sources you choose.

Promotional text — pt-BR:
Acompanhe notícias, podcasts, vídeos e fontes independentes em um feed pessoal — sem conta, sem anúncios e baseado nas fontes que você escolhe.

Description — en-US
FeedMine is a source-first reader for news, podcasts, videos and independent publishing. Start with a broad feed or build your own from the catalog and feeds you add. Search sources and saved content, apply filters, create collections and Smart Feeds, bookmark stories, import OPML and play podcast or video content. Your reading state and preferences stay on your device, and cached content can remain available when you launch offline. No account required.

Description — pt-BR
FeedMine é um leitor centrado nas fontes para notícias, podcasts, vídeos e publicações independentes. Comece com um feed amplo ou monte o seu usando o catálogo e feeds adicionados por você. Pesquise fontes e conteúdo salvo, use filtros, crie coleções e Smart Feeds, salve itens, importe OPML e reproduza podcasts ou vídeos. Seu histórico de leitura e preferências ficam no dispositivo, e conteúdo em cache pode continuar disponível ao abrir o app offline. Não exige conta.

Keywords — en-US (92):
rss,feeds,news,podcasts,reader,articles,video,bookmarks,opml,offline,feed reader,news reader

Keywords — pt-BR (96):
rss,feeds,notícias,podcasts,leitor,artigos,vídeos,favoritos,opml,offline,feed,leitor de notícias

APP PRIVACY
Data Type	Coletado?	Identidade?	Tracking?	Finalidade / evidência
Usage Data / leitura	Não	Não	Não	Estado is_read/opened_at/clicked_at fica em SQLite local — FeedStore.swift:3832-3873, 6142-6163
User Content / bookmarks	Não	Não	Não	Bookmarks ficam em user.sqlite — UserStateStore.swift:198-223
Search History	Não	Não	Não	Busca é feita em SQLite/FTS local — SearchEngine.swift:186-220, 294-314
User Content / feeds importados	Não	Não	Não	URLs/títulos importados persistem localmente — UserStateStore.swift:864-910
Identifiers	Não	Não	Não	Sem conta/tracking; manifest declara tracking false — PrivacyInfo.xcprivacy:21-28
Location	Não	Não	Não	Nenhuma permissão/API de localização declarada em Info.plist
Diagnostics/Analytics	Não	Não	Não	Instrumentação é OSSignposter, local; não envia telemetria — FeedMetrics.swift:8-38; FeedMineSignposts.swift:17-27
Explicitamente não coletado: nome, email, telefone, endereço, localização, contatos, fotos, saúde, finanças, identificadores de usuário/dispositivo, advertising ID, histórico de busca enviado ao desenvolvedor, histórico de navegação enviado ao desenvolvedor, analytics, crash telemetry, advertising data ou tracking cross-app/site.

O manifest confirma NSPrivacyCollectedDataTypes = [] e NSPrivacyTracking = false — PrivacyInfo.xcprivacy:21-28.

---

[[PARTE 2/3]]

PRIVACY POLICY
A página deve declarar, de forma explícita:

No account: FeedMine não exige cadastro, login, nome, email ou perfil.
No developer collection: o desenvolvedor não coleta, recebe ou vende dados pessoais, analytics ou dados de uso.
No tracking/ads: sem advertising SDK, ATT ou tracking entre apps/sites.
Local-first data: bookmarks, histórico de leitura/abertura, preferências, filtros, coleções, Smart Feeds e feeds importados ficam armazenados localmente no aparelho.
Search: buscas de conteúdo e fontes são executadas contra os bancos locais do app; termos não são enviados ao FeedMine.
Clipboard: o app pode ler texto do clipboard localmente para sugerir a adição de uma URL; o conteúdo não é enviado ao desenvolvedor (ClipboardBanner.swift:73-99).
Network: o app conecta diretamente a feeds, sites, imagens, podcasts e vídeos de terceiros para obter/exibir conteúdo (FeedHTTPSync.swift:7-29; ArticleReaderView.swift:38-76). Esses terceiros podem receber dados normais de uma conexão web, como IP, e seguem suas próprias políticas.
Web content: artigos podem abrir dentro de WKWebView, com JavaScript habilitado; páginas de terceiros podem usar seus próprios cookies/storage (ArticleReaderView.swift:38-76).
Retention/deletion: dados locais permanecem enquanto necessários ao funcionamento do app e são removidos com a exclusão do app, salvo material exportado pelo usuário.
Children: o app não é projetado para coletar dados de crianças.
Incluir data de vigência, contato de privacidade e identificação de Wawasoft/FeedMine.
A URL precisa estar publicada publicamente antes da submissão.
SCREENSHOTS
O target é somente iPhone (TARGETED_DEVICE_FAMILY = 1), portanto não há screenshots obrigatórios de iPad.

Mínimo obrigatório atual da Apple: 1 screenshot, para iPhone com Dynamic Island — medium display. 

Tamanhos aceitos em portrait:

1179 × 2556 px, ou
1206 × 2622 px. 
Screenshot mínimo que eu usaria:

Main timeline, já populada com cards de tipos variados — produzida por FeedScreen.swift + FeedItemView.swift / FeedItemCardView.swift.
Embora uma imagem seja suficiente para submissão, para a página comercial eu capturaria também: Composer/onboarding, Catalog search/Source View, Article reader e podcast player — todas funcionalidades efetivamente “I

---

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
