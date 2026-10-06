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