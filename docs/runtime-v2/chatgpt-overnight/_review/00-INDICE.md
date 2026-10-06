# Revisão de código — Feedmine 1.0 (índice)

Revisores locais independentes (somente leitura, com o checkout) + verificação própria do OMP.
Base: HEAD `70f7b06b`, `fix/release-1.0-final-hardening`.

| Arquivo | Ângulo | Veredito do revisor | Verificação do OMP |
|---|---|---|---|
| `cr-persistence.md` | persistência/integridade | 1 BLOQUEADOR + 4 ALTO + 5 MÉDIO + 4 BAIXO | **P-01 verificado** (`initError` escrito e nunca lido: `FeedLoader.swift:669,680`; fallback `FeedStore.empty()` em `:689`). **P-02 verificado** (`FeedItemRecord` init zera `isRead/openedAt/clickedAt/consumedAt` em `FeedStore.swift:8482-8485` e `record.update(db)` grava todas as colunas — chamado em `:4798`) |
| `cr-crash.md` | crash/robustez | 3 BLOQUEADOR + 12 ALTO | **CR-02 verificado**: `AudioPlayerManager.swift:364` grava `self.currentTime = time.seconds` **sem** `isFinite` (o código guarda `dur.isFinite` para `duration` em `:367`, mas não para o tempo corrente), e `formatTime` faz `Int(t)` — NaN de `AVPlayerItem.time` aborta. **CR-01 qualificado**: o vetor exige `duration = +inf`, que `extractDuration` (Int) não produz; verificar `att.durationInSeconds` (`RSSFetcher.swift:485,853`) antes de manter BLOQUEADOR |
| `cr-security.md` | segurança/privacidade | 2 ALTO + 6 MÉDIO | **S-01 verificado** (`FeedItemCardView.swift:516`: `open(URL(string: item.url)!)`-style sem checagem de scheme, rótulo diz "Safari"). **S-02 verificado com nuance**: `publicKeyHex = ""` (`CatalogUpdateService.swift:51`) faz `verifySignature` dar `return` (`:119-121`) — mas há comentário explicando que o canal remoto não é usado no 1.0; o defeito é **fail-open**, não uso ativo |
| `cr-concurrency.md` | concorrência/isolamento | **39 achados: 1 BLOQUEADOR + 9 ALTO + 22 MÉDIO + 7 BAIXO** (9 fatias paralelas; as severidades altas reconferidas por leitura direta). Top: C-01 flush de exposição com falha pegajosa; C-02 `shakeReshuffle` perde itens do interleave; C-04 cancelamento contado como falha de fonte (backoff 2 min–24 h); C-06 `raceWithDeadline` não é deadline duro; C-07 dedup de download quebrada | **C-01 verificado pelo OMP**: a FK \`exposure_fact (edition_id, card_id) → published_card ON DELETE RESTRICT\` existe (\`RuntimeMigrations.swift:704-707\`) e o \`catch\` de \`attemptFlush\` (\`FeedSession.swift:722-724\`) **só incrementa a estatística** — o lote \`unconfirmed\` permanece, a falha é determinística e o histórico só sai por overflow. **Latente para o 1.0**: a lane V2 não é a que embarca (launch = \`.legacy\`) |
| `defeitos.md` | achados próprios do OMP | 6 entradas (1 corrigida) | OMP-1 corrigido no código; OMP-2..OMP-6 registrados |

Copiados para cá: cr-persistence.md (10672 bytes), cr-concurrency.md (ausente bytes), cr-crash.md (18917 bytes), cr-security.md (14604 bytes).
