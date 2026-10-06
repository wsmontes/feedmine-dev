# Patch pronto: linha de Privacy Policy em Settings (bloqueador de submissão)

**Estado verificado:** `feedmine/Views/SettingsSheetView.swift:243-271` tem Versão/Fontes/Re-watch Intro e a seção Feedback com "Send Feedback" (mailto) e "FeedKit on GitHub" — **nenhuma linha de Privacy Policy**. O grep de "privacy" no app só encontra anotação de log e um `privacyNote` de UI (`CuratedFeedInspectorView.swift:305`). O repo já registra a pendência: `docs/AppStoreSubmission.md:40`.

**Por que não apliquei:** a Apple exige a URL da política **alcançável**; adicionar o link antes de publicar a página colocaria um link morto no build que vai à Apple. Assim que a URL existir, é esta a mudança:

## 1. Endereço da política em um lugar só

Acrescente ao arquivo onde o app guarda links fixos (ou crie `feedmine/Support/AppLinks.swift`):

```swift
enum AppLinks {
    /// Published privacy policy. Apple requires this URL in App Store Connect *and*
    /// reachable inside the app; keep both pointing at the same page.
    static let privacyPolicy = URL(string: "https://<SEU-DOMINIO>/privacy")!
}
```

## 2. A linha em Settings

**Âncora exata** (o bloco atual, verbatim de `SettingsSheetView.swift:261-270`):

```swift
                Section {
                    Link(destination: URL(string: "mailto:wmontes@gmail.com?subject=Feedmine%20Feedback")!) {
                        Label("Send Feedback", systemImage: "envelope.fill")
                    }
                    Link(destination: URL(string: "https://github.com/nmdias/FeedKit")!) {
                        Label("FeedKit on GitHub", systemImage: "link")
                    }
                } header: { Text("Feedback") } footer: {
```

**Substituir por:**

```swift
                Section {
                    Link(destination: AppLinks.privacyPolicy) {
                        Label("Privacy Policy", systemImage: "hand.raised.fill")
                    }
                    Link(destination: URL(string: "mailto:wmontes@gmail.com?subject=Feedmine%20Feedback")!) {
                        Label("Send Feedback", systemImage: "envelope.fill")
                    }
                    Link(destination: URL(string: "https://github.com/nmdias/FeedKit")!) {
                        Label("FeedKit on GitHub", systemImage: "link")
                    }
                } header: { Text("Feedback") } footer: {
```

## 3. Verificação

1. Árvore limpa antes: `git status --porcelain` (o `release-testflight.sh` aborta com exit 9 em árvore suja).
2. `xcodebuild test -only-testing:feedmineTests` — a suíte compila o alvo do app inteiro, então o patch é verificado pela compilação.
3. No device: abrir Settings → a linha aparece → tocar abre a página publicada (não pode dar 404; a Apple costuma reprovar link quebrado).
4. App Store Connect: o mesmo URL no campo *Privacy Policy URL* do App Information.
