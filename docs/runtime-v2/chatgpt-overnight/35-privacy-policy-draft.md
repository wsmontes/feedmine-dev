# Política de Privacidade — rascunho pronto para publicar

> **Isto é um rascunho técnico, não parecer jurídico.** Ele descreve o que o executável faz hoje, conferido no código; revise antes de publicar. A Apple exige esta página **publicada em URL alcançável** e **linkada dentro do app** (ver `36-patch-privacy-row.md`) — hoje nenhuma das duas existe, e o próprio repo registra isso (`docs/AppStoreSubmission.md:40`, `docs/release/1.0-checklist.md:663`).

FeedMine — Política de Privacidade
Última atualização: <data>

## Resumo em uma frase

O FeedMine não exige conta, não coleta dados pessoais, não usa analytics nem publicidade, e guarda o que você faz no próprio aparelho.

## Quais dados o app trata

**Nada é enviado ao desenvolvedor.** O app não tem cadastro, login, nome, e-mail ou perfil. A auditoria de fonte registra: sem analytics, sem SDK de publicidade, sem tracking entre apps ou sites (`docs/AppStoreSubmission.md:20-26`).

**O que fica no seu aparelho (e só nele):**

- feeds que você adiciona e o catálogo de fontes;
- itens lidos, abertos, clicados e consumidos;
- bookmarks, coleções e listas;
- preferências e filtros (idioma, região, tipo de conteúdo, humor, presets);
- cache de imagens, páginas e artigos, para o app abrir mais rápido e funcionar offline.

Base legal, quando aplicável: execução do serviço no seu aparelho. Nada é compartilhado com terceiros pelo desenvolvedor.

## O que sai do aparelho, e para onde

Quando você usa o app, ele faz requisições de rede **diretamente do seu aparelho** para publicar o conteúdo que você escolheu:

- os servidores/feeds (RSS, Atom, JSON Feed) das fontes que você adicionou ou do catálogo;
- servidores de imagens e de mídia (incluindo YouTube e provedores de podcast) para miniaturas e áudio;
- a Apple, quando você atualiza o app pela App Store.

Esses terceiros recebem o endereço IP do seu aparelho e os dados técnicos usuais da requisição (user agent, cabeçalhos), como qualquer navegador faria; o conteúdo que eles servem é regido pelas políticas deles. O desenvolvedor do FeedMine não intermedeia, não registra e não recebe essas requisições.

O app **não** usa identificador de publicidade, **não** rastreia você entre apps ou sites e **não** vende dados.

## Retenção e exclusão

Os dados ficam no seu aparelho até você removê-los:

- apagar um bookmark, uma coleção ou uma fonte remove o vínculo — o conteúdo em cache pode permanecer até ser expurgado pela política de retenção do app;
- desinstalar o app apaga tudo o que ficou no contêiner dele;
- como nada é enviado ao desenvolvedor, não existe cópia remota para solicitar exclusão.

## Crianças

O app não é direcionado a crianças e não coleta dados de ninguém, de qualquer idade.

## Alterações

Se esta política mudar, a data acima muda junto; mudanças relevantes serão indicadas na descrição da versão na App Store.

## Contato

wmontes@gmail.com
