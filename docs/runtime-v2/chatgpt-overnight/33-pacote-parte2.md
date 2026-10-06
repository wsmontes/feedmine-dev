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