# Trabalho noturno — coordenação ChatGPT ⇄ repo Feedmine

Executor: OMP (agente local, com acesso ao checkout e à janela do Chrome do usuário).
Worker: ChatGPT, na conversa do projeto **Feedmine** (chatgpt.com), janela Chrome pid 80010.
Iniciado: 2026-10-05 (noite). Nada foi commitado.

## Protocolo (medido, não presumido)

|Etapa|Mecanismo|Limite medido|
|---|---|---|
|Enviar (curto)|clipboard + ⌘V no textarea + `Return`|até ~2 400 caracteres: o texto fica no textarea|
|Enviar (longo)|clipboard + ⌘V + **clique no botão `Send`** (irmão do textarea, via `parent()→children()`)|**≥ 20 000 caracteres em uma única mensagem**: o ChatGPT converte o paste em *anexo de texto colado* (`button "Show in text field"`, `button "Remove pasted text attachment"`) e o composer cresce; o valor do textarea fica vazio — **não confira o textarea, confira o chip do anexo**|
|Esperar|sonda do botão de ação do composer (`Stop` = gerando; `Start Voice` = ocioso)|1 chamada de ferramenta por round; **0 token de modelo durante a espera**|
|Extrair|clique no corpo, ⌘A, ⌘C → fatia renderizada da conversa → corte entre marcadores → arquivo|janela renderizada limitada; rolar para cima e recapturar quando o documento exceder|
|Não poluir contexto|todo o texto vai para arquivo; o agente local só vê bytes/início/fim|—|

**Capacidade que muda o desenho do loop:** a conversa tem **acesso ao GitHub** do projeto (provado: transcreveu verbatim a linha 25 de `docs/runtime-v2/adrs/ADR-003.md` no commit `70f7b06b`, texto que nunca lhe foi enviado) e **executa trabalho de leitura no repo** (a árvore mostra `Inspecting Privacy Policy Route Content`, `Searched 1 website`, `Analyzed`). Ela não roda testes nem Xcode. Portanto: mande **tarefa**, não dados. Observação dele: o ref `fix/release-1.0-final-hardening` **não existe no remoto** (404); o que ele vê é o commit `70f7b06b`.

**Limite de recepção (aprendido na marra):** a janela renderizada da conversa não sustenta documentos longos — ⌘A/⌘C copia só o que está no DOM *layoutado*. Sintoma medido: o corpo da resposta tinha `height = 0` (nó fora de layout) e a captura devolvia 3,3 KB (prompt + faixa de atividade). Medidas que funcionam, nesta ordem: (1) clicar em **`button "Scroll to bottom"`** — foi o que deu geometria real ao texto (y=445, altura 45); (2) clicar dentro do parágrafo e só então ⌘A/⌘C; (3) se o documento for grande, **pedir a reemissão em partes numeradas** (`[[PARTE k/3]]`, ≤2 000 caracteres cada) — foi assim que este pacote foi colhido, com a mesma técnica de chunking usada para enviar. Note também que **todo nó de texto da árvore é truncado em ~81 caracteres**, o que inviabiliza reconstruir a resposta a partir da AX.

Fatos: nenhum ADR existente foi modificado. Tudo é escrito em `chatgpt-overnight/`.

## Limite de operação do canal (medido em 2026-10-06, ~05:30)

A conversa do pacote de submissão **derrubou o canal**: com o documento grande renderizado, a janela do Chrome deixou de ser exposta à acessibilidade (`AxFailed: native window 27684 was not found in the application's accessibility windows — the search stopped at its limit of 5000 nodes or depth 24`), o teclado em segundo plano passou a ser recusado (`BackgroundUnavailable`) e, minutos depois, **o Chrome não aparecia mais na lista de janelas** (encerrou). Tentei o app nativo do ChatGPT como alternativa: ele responde à AX, mas o outline dele é dominado por ~45 raízes duplicadas (`AXApplication`/`AXMenuBar`) e não expõe o composer (`search_ui` por `role: textarea` → 0 matches).

**Regra que sai disso:** rotacionar a conversa **antes** de ela renderizar documento grande (o usuário já recomendava ~10 iterações; o limite técnico é mais duro que isso). Para receber documento longo, peça em partes numeradas desde o início — foi o que funcionou aqui (3 partes), e o custo de pedir depois é descobrir que a janela ficou inoperável.

## Rounds

|#|Objetivo|Payload|Saída|
|---|---|---|---|
|1|Plano normativo de migração (§16 do ADR-003)|4 digests do checkout (`_digests/D1..D4`, 22,2 KB) enviados em 12 partes|`01-plano-de-migracao.md` (19,5 KB): CONTRADIÇÕES · M1–M8 · FATIAS · RISCO DE PERDA DE DADOS · DECISÕES HUMANAS|
|2|Decisão de identidade de runtime para sources de catálogo (A1–A7)|`_payloads/round2-task.md` + fatos curados|`02-identidade-source-runtime.md`|
|3|Fronteira da identidade de card / PR-15 (C1–C6)|`_payloads/round3-task.md` + fatos curados|`03-fronteira-card-identity.md`|
|4|Revisão adversarial dos 7 ADRs contra o checkout (R1..Rn)|`_payloads/round4-task.md` + fatos curados|`04-revisao-adversarial-adrs.md`|
|5|Checklist de Gate 0 / freeze|`_payloads/round5-task.md` + fatos curados|`05-checklist-gate0.md`|
|6|Registro consolidado + conflitos internos + backlog PR-00..PR-09|`_payloads/round6.md`|`06-registro-backlog.md`|
|7|Anexo para colar no ADR-003 (v1)|`_payloads/round7.md`|`07-anexo-section16.md`|
|8|Falsificação da própria revisão adversarial|`_payloads/round8.md`|`08-falsificacao-defeitos.md`|
|9|Kit de handoff (prompt de continuidade + PR-00 + decisões)|`_payloads/round9.md`|`09-handoff-kit.md`|
|10|Lacuna de testes (355 citações auditadas no repo)|`_payloads/round10.md` + auditorias locais|`10-lacuna-de-testes.md`|
|11|Backlog em YAML executável|`_payloads/round11.md`|`11-plano-executavel.yaml`|
|12|Errata contra a revisão local independente|`_payloads/round12.md`|`12-errata.md`|
|13|Reemissão do anexo já corrigido|`_payloads/round13.md`|`07b-anexo-corrigido.md`|
|14|YAML executável corrigido (alvos reais do repo)|`_payloads/round14.md`|`11b-plano-executavel-corrigido.yaml`|

## Verificações locais (não são palavras do worker)

- Revisores independentes (família de modelo diferente, acesso ao repo): `/tmp/review-identity.md`, `/tmp/review-gates.md`, `/tmp/review-final.md`.
- Auditoria de testes citados pelos ADRs: `/tmp/test-audit-a.md`, `/tmp/test-audit-b.md` → 256 existem, 82 renomeados, 17 ausentes.
- Segundo auditor para os 17 ausentes: `/tmp/verify-absent.md`.
- YAML `11b`: parse OK, 17 passos, rollback em todos, zero referência inexistente.
- Citações dos entregáveis: 78 caminhos, 1 inexistente (arquivo proposto, não citação falsa).

## Diretórios

- `_digests/` — recortes factuais do working tree (path:line), feitos por subagentes de leitura.
- `_payloads/` — o que foi/é enviado, íntegro.
- `_raw/` — capturas brutas da página e cópias de conversa.
- `01..05-*.md` — entregáveis.

## Ressalvas operacionais

- Chrome sinalizou "High memory usage" durante o round 1 (conversa longa). Risco de lentidão.
- A conversa acumula os digests; rounds seguintes enviam só fatos novos.
- Se o Chrome fechar, o estado do trabalho (payloads e entregáveis) está todo em disco.
