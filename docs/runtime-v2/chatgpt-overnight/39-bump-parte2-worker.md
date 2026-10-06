rindo a janela de race.

(b) Confirmação decisiva em uma execução: após gate 3, faça shutdown/boot/bootstatus, sem rebuild, e rode a jornada. Se voltar 17/17, está isolado: estado do Simulator/HID, não imagem/build. No failure atual procure:
presented=0 + miss_cause=feed_unchanged_verified + 91-reader-missing.png mostrando o mesmo feed. Depois correlacione window tap, card tap e reader presented: ambos taps ausentes = HID/harness; window tap presente e card tap ausente = gesture/overlay. Se aparecer reader_blank=1, é outro defeito: reader abriu, WKWebView não renderizou.

(c) Correção mínima: script, não app: faça release-acceptance.sh chamar release-journey.sh em vez de duplicar uma versão mais fraca dele, ou pelo menos reinicie o Simulator antes da jornada. Secundariamente, remova a captura duplicada antes do tap. Eu não mexeria no caminho de imagem para “corrigir” isto.

[[CORREÇÃO DO SEU DIAGNÓSTICO + PEDIDO DA PARTE 2]]

Sua parte 1 acertou o mecanismo geral (tap perdido) e errou dois fatos que eu verifiquei no repo:

1. release-acceptance.sh TAMBÉM faz simctl shutdown -> boot -> bootstatus antes da jornada (scripts/release-acceptance.sh:75-77), igual ao release-journey.sh:76-78. A diferença que você apontou não existe.
2. Você disse que o chamador faz outra captura entre a checagem final e o tap. O stableTappableCard() revalida existência + isFullyVisible + frame IDÊNTICO antes de retornar, e a captura 92-reader-pre-tap do chamador está rotulada de propósito como "last observation before synthesis, taken here on purpose".

O que fecha o caso é o comentário do próprio harness: "One tap, and its failure is a FINDING, not a flake: ... a retap would convert a real defect into a green journey." Ou seja, a classe feed_unchanged_verified (mesmo card presente, visível e hittable, nada apareceu) é tratada como DEFEITO DO APP — tap ignorado com o pipeline de startup rodando — e não como flake. A correlação que medi (mudanças no caminho de imagem => jornada 15/17) passa a ser carga/timing, não semântica.

[[PARTE 2]]
Com essa premissa corrigida: o passo mecânico para subir de 17 para 18 e provar o archive (scripts/release-testflight.sh --dry-run). Diga os arquivos exatos onde o número aparece e por quê, o que o dry-run tem de imprimir para ser verde, e o que NÃO fazer (ex.: regenerar o .xcodeproj).
…

Fechado. Vou tratar a premissa corrigida como definitiva e focar só no versionamento mecânico: onde o 17 está, o que vira 18, e quais sinais o dry-run exige.




