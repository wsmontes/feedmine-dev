[[PARTE 1/2]]

(a) Causa mais provável: não é regressão semântica no ArticleImageResolver/ImageLoader. É uma race de entrega do tap no Simulator, exposta por timing. release-acceptance.sh só faz simctl uninstall entre os 3 gates e a jornada; não reinicia o Simulator. Já release-journey.sh faz shutdown → boot → bootstatus imediatamente antes da jornada. O próprio histórico do repo já registrou exatamente este defeito: presented=0, miss_cause=feed_unchanged_verified e nenhum card tap, portanto o tap sintetizado nem chegou ao FeedItemView.onTapGesture. Mudanças no caminho de imagem provavelmente só deslocam timing/resource pressure e tornam essa race reproduzível depois de 609×3 testes.

Há ainda um bug pequeno no harness: stableTappableCard() captura 92-reader-pre-tap e promete que nada ocorrerá entre a checagem final e o tap, mas o caller faz outra capture("92-reader-pre-tap") antes de firstCard.tap(), reabrindo a janela de race.

(b) Confirmação decisiva em uma execução: após gate 3, faça shutdown/boot/bootstatus, sem rebuild, e rode a jornada. Se voltar 17/17, está isolado: estado do Simulator/HID, não imagem/build. No failure atual procure:
presented=0 + miss_cause=feed_unchanged_verified + 91-reader-missing.png mostrando o mesmo feed. Depois correlacione window tap, card tap e reader presented: ambos taps ausentes = HID/harness; window tap presente e card tap ausente = gesture/overlay. Se aparecer reader_blank=1, é outro defeito: reader abriu, WKWebView não renderizou.

(c) Correção mínima: script, não app: faça release-acceptance.sh chamar release-journey.sh em vez de duplicar uma versão mais fraca dele, ou pelo menos reinicie o Simulator antes da jornada. Secundariamente, remova a captura duplicada