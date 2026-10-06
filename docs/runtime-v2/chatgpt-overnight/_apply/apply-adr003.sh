#!/usr/bin/env bash
# Aplica a emenda (18-emenda-adr003.md), as substituições declaradas (21-edicoes-no-adr003.md,
# materializadas em substitutions.tsv) e o anexo (07b-anexo-corrigido.md) no ADR-003 do repo.
#
# SEGURO POR PADRÃO: sem --apply, apenas valida âncoras e imprime o plano. Nada é escrito.
#
# Uso:
#   ./apply-adr003.sh                 # dry-run (modo split)
#   ./apply-adr003.sh --simple        # dry-run, emenda inteira num único ponto
#   ./apply-adr003.sh --apply         # escreve (backup antes em _apply/backup/)
#   ADR_PATH=/tmp/copia.md ./apply-adr003.sh --apply   # ensaia numa cópia
#
# Ordem da operação: (1) Substitutions.tsv na linha correspondente; (2) blocos da emenda;
# (3) anexo no fim. Toda âncora tem de existir exatamente uma vez, senão o script aborta
# sem ter escrito nada.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
ADR="${ADR_PATH:-$PKG/../adrs/ADR-003.md}"
AMEND="$PKG/18-emenda-adr003.md"
ANNEX="$PKG/07b-anexo-corrigido.md"
SUBS="$HERE/substitutions.tsv"

APPLY=0
MODE=split
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --simple) MODE=simple ;;
    *) echo "argumento desconhecido: $a" >&2; exit 2 ;;
  esac
done

for f in "$ADR" "$AMEND" "$ANNEX" "$SUBS"; do
  [ -f "$f" ] || { echo "FALTANDO: $f" >&2; exit 1; }
done

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# ---------- recortes da emenda ----------
block() { awk -v s="$1" -v e="$2" 'BEGIN{on=0} $0 ~ s {on=1} on && $0 ~ e {exit} on {print}' "$3"; }
block '^\*\*D20 ' '^### ' "$AMEND" > "$TMPD/d.part"
block '^### Invariants added' '^### Compatibility' "$AMEND" > "$TMPD/inv.part"
block '^### Compatibility' '^### Named acceptance tests' "$AMEND" > "$TMPD/comp.part"
block '^### Named acceptance tests' '^### What this amendment' "$AMEND" > "$TMPD/test.part"
block '^### What this amendment' '^ZZZ_NEVER_MATCHES' "$AMEND" > "$TMPD/not.part"
for p in d inv comp test not; do
  [ -s "$TMPD/$p.part" ] || { echo "recorte vazio: $p.part — o formato de $AMEND mudou" >&2; exit 1; }
done
cp "$ANNEX" "$TMPD/annex.part"
# o bloco de testes da emenda entra sob "## Named acceptance tests": qualifica o heading para não duplicar
sed 's/^### Named acceptance tests$/### D20–D23 acceptance tests/' "$TMPD/test.part" > "$TMPD/test2.part"
mv "$TMPD/test2.part" "$TMPD/test.part"
ROWS="$HERE/traceability-rows.md"
[ -s "$ROWS" ] || { echo "FALTANDO: $ROWS" >&2; exit 1; }
cp "$ROWS" "$TMPD/rows.part"

# ---------- validação do ADR ----------
require_once() {
  local pat="$1" n
  n=$(grep -cF -- "$pat" "$ADR" || true)
  [ "$n" -eq 1 ] || { echo "ÂNCORA INVÁLIDA ($n ocorrências): $pat" >&2; exit 1; }
}
require_once '## Rejected alternatives'
require_once '## Edge cases'
require_once '## Traceability'
grep -qE '^\*\*D19 ' "$ADR" || { echo "D19 não encontrado — numeração mudou" >&2; exit 1; }
if grep -qE '^\*\*D20 ' "$ADR"; then echo "D20 já existe — emenda parece aplicada" >&2; exit 1; fi

# ---------- validação das substituições ----------
SUBST_COUNT=$(awk -F'\t' 'NF>=2{n++} END{print n+0}' "$SUBS")
while IFS=$'\t' read -r A _; do
  [ -z "${A:-}" ] && continue
  n=$(grep -cF -- "$A" "$ADR" || true)
  [ "$n" -eq 1 ] || { echo "SUBSTITUIÇÃO INVÁLIDA ($n ocorrências): ${A:0:70}" >&2; exit 1; }
done < "$SUBS"

echo "ADR:            $ADR  ($(wc -l < "$ADR") linhas, $(wc -c < "$ADR") bytes)"
echo "Modo:           $MODE"
echo "Substituições:  $SUBST_COUNT (linha a linha, contagem verificada)"
echo "Emenda:         D20–D23 $(wc -c < "$TMPD/d.part")B + invariantes $(wc -c < "$TMPD/inv.part")B + compatibilidade $(wc -c < "$TMPD/comp.part")B + testes $(wc -c < "$TMPD/test.part")B + limites $(wc -c < "$TMPD/not.part")B"
echo "Anexo:          $(wc -c < "$TMPD/annex.part") bytes"
echo "Maior D atual:  $(grep -oE '^\*\*D[0-9]+' "$ADR" | grep -oE '[0-9]+' | sort -n | tail -1)"
echo "Âncoras:        OK (únicas)"

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "DRY-RUN — nada foi escrito. Plano:"
  echo "  1. $SUBST_COUNT substituições pontuais (D2, edge case de canonicalization, faixa D1–D19)"
  if [ "$MODE" = split ]; then
    echo "  2. D20–D23 + compatibilidade + limites  ->  antes de '## Rejected alternatives'"
    echo "     invariantes novas                   ->  antes de '## Edge cases'"
    echo "     testes nomeados                     ->  antes de '## Traceability'"
  else
    echo "  2. emenda inteira                        ->  antes de '## Rejected alternatives'"
  fi
  echo "  3. anexo                                 ->  fim do arquivo"
  echo
  echo "Para aplicar: $0 --apply"
  exit 0
fi

# ---------- stage 1: substituições ----------
awk -F'\t' '
  NR==FNR { if (NF>=2) { n++; A[n]=$1; B[n]=$2 } next }
  { line=$0
    for (i=1;i<=n;i++) { p=index(line,A[i]); if (p>0) { line=substr(line,1,p-1) B[i] substr(line,p+length(A[i])); h[i]++ } }
    print line }
  END { for (i=1;i<=n;i++) if (h[i] != 1) { printf "substituição %d aplicada %d vez(es)\n", i, h[i]+0 > "/dev/stderr"; bad=1 } exit bad }
' "$SUBS" "$ADR" > "$TMPD/subst.md"
[ -s "$TMPD/subst.md" ] || { echo "stage 1 falhou" >&2; exit 1; }
grep -qF "$(awk -F'\t' 'NR==1{print substr($2,1,40)}' "$SUBS")" "$TMPD/subst.md" || { echo "pós-condição: substituição 1 ausente" >&2; exit 1; }

# ---------- stage 2+3: emenda e anexo ----------
OUT="$TMPD/out.md"
if [ "$MODE" = split ]; then
  awk -v d="$TMPD/d.part" -v c="$TMPD/comp.part" -v n="$TMPD/not.part" -v i="$TMPD/inv.part" -v t="$TMPD/test.part" -v a="$TMPD/annex.part" -v r="$TMPD/rows.part" '
    function emit(f,  line) { while ((getline line < f) > 0) print line; close(f) }
    index($0, "| Blueprint §112 (ADR-003 scope list) | D1–D23 ") == 1 { print; emit(r); next }
    /^## Rejected alternatives$/ { emit(d); print ""; emit(c); print ""; emit(n); print "" }
    /^## Edge cases$/            { emit(i); print "" }
    /^## Traceability$/          { emit(t); print "" }
    { print }
    END                          { print ""; emit(a) }
  ' "$TMPD/subst.md" > "$OUT"
else
  awk -v d="$TMPD/d.part" -v c="$TMPD/comp.part" -v i="$TMPD/inv.part" -v t="$TMPD/test.part" -v n="$TMPD/not.part" -v a="$TMPD/annex.part" -v r="$TMPD/rows.part" '
    function emit(f,  line) { while ((getline line < f) > 0) print line; close(f) }
    index($0, "| Blueprint §112 (ADR-003 scope list) | D1–D23 ") == 1 { print; emit(r); next }
    /^## Rejected alternatives$/ { emit(d); print ""; emit(i); print ""; emit(c); print ""; emit(t); print ""; emit(n); print "" }
    { print }
    END                          { print ""; emit(a) }
  ' "$TMPD/subst.md" > "$OUT"
fi

# ---------- pós-condições ----------
grep -qE '^\*\*D20 ' "$OUT" || { echo "pós-condição falhou: D20 ausente" >&2; exit 1; }
grep -qE '^\*\*D19 ' "$OUT" || { echo "pós-condição falhou: D19 perdido" >&2; exit 1; }
grep -q 'Plano de migração normativo' "$OUT" || { echo "pós-condição falhou: anexo ausente" >&2; exit 1; }
grep -q 'D1–D23' "$OUT" || { echo "pós-condição falhou: faixa D1–D23 ausente" >&2; exit 1; }
grep -q '### D20–D23 acceptance tests' "$OUT" || { echo "pós-condição falhou: heading dos testes da emenda ausente" >&2; exit 1; }
grep -q '| amendment D20–D23 | D20 |' "$OUT" || { echo "pós-condição falhou: linha de rastreabilidade de D20 ausente" >&2; exit 1; }
[ "$(grep -c '^### Named acceptance tests$' "$OUT" || true)" -eq 0 ] || { echo "pós-condição falhou: heading duplicado" >&2; exit 1; }
[ "$(grep -c '^## Named acceptance tests$' "$OUT" || true)" -eq 1 ] || { echo "pós-condição falhou: seção de testes não é única" >&2; exit 1; }
[ "$(wc -l < "$OUT")" -gt "$(wc -l < "$ADR")" ] || { echo "pós-condição falhou: nenhuma linha acrescentada" >&2; exit 1; }

mkdir -p "$HERE/backup"
STAMP="$(date +%Y%m%d-%H%M%S)"
cp "$ADR" "$HERE/backup/$(basename "$ADR").$STAMP"
echo "backup: $HERE/backup/$(basename "$ADR").$STAMP"
mv "$OUT" "$ADR"
echo "aplicado: $(wc -l < "$ADR") linhas, $(wc -c < "$ADR") bytes (antes: $(wc -c < "$HERE/backup/$(basename "$ADR").$STAMP") bytes)"
echo "revise com: git diff -- docs/runtime-v2/adrs/$(basename "$ADR")"
