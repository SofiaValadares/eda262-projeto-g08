#!/usr/bin/env bash
# =============================================================================
# pipeline.sh — orquestra a ingestão (g08 / varejo-ecommerce)
#
#   carga                     sobe os 24 lotes no raw e roda o job (todas)
#   lote YYYY-MM              sobe 1 lote e reprocessa YYYY-MM e o mês anterior
#                             (o lote M pode trazer venda atrasada de M-1)
#   executar [PARTICOES]      roda o job (default: todas)
#   backfill P1[,P2...]       reprocessa SÓ as partições pedidas
#   relatorio [JOB_RUN_ID]    mostra o relatório JSON de uma execução
#
# Idempotência: subir o mesmo lote de novo sobrescreve a MESMA chave S3 no raw;
# o job recalcula cada partição a partir do raw inteiro e SUBSTITUI a partição.
# Rodar qualquer comando N vezes => mesmo resultado, sem duplicata.
# =============================================================================
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../verificacao/_lib.sh
source "${AQUI}/../../verificacao/_lib.sh"
check_cmd aws
[[ -n "$PY" ]] || { echo "python3 não encontrado"; exit 1; }

DADOS="${AQUI}/../dados/raw"
RAW_PREFIX="s3://${BUCKET_RAW}/${SCENARIO}/vendas"

garante_dados() {
  if ! ls "${DADOS}"/vendas_lote_*.csv >/dev/null 2>&1; then
    info "Gerando lotes raw determinísticos (gerar_raw.py)"
    "$PY" "${AQUI}/gerar_raw.py" --saida "${DADOS}"
  fi
}

sobe_lote() {
  local lote="$1" f="${DADOS}/vendas_lote_${1}.csv"
  [[ -f "$f" ]] || { echo "Lote não encontrado: $f"; exit 1; }
  command -v cygpath >/dev/null 2>&1 && f="$(cygpath -w "$f")"   # Git Bash no Windows
  aws s3 cp "$f" "${RAW_PREFIX}/vendas_lote_${lote}.csv" --region "$REGION" --only-show-errors
  echo "  raw <- vendas_lote_${lote}.csv"
}

mes_anterior() {
  "$PY" -c "import sys; a,m=map(int,sys.argv[1].split('-')); a,m=(a,m-1) if m>1 else (a-1,12); print(f'{a}-{m:02d}')" "$1"
}

executa() {
  glue_run "$1" || { echo -e "${RED}Job falhou: ${GLUE_ERR:-}${NC}"; exit 1; }
  glue_relatorio "$GLUE_RUN_ID"
  echo ""
}

cmd="${1:-}"; shift || true
case "$cmd" in
  carga)
    garante_dados
    info "Subindo lotes para ${RAW_PREFIX}/"
    for f in "${DADOS}"/vendas_lote_*.csv; do
      l=$(basename "$f" .csv); sobe_lote "${l#vendas_lote_}"
    done
    executa todas
    ;;
  lote)
    [[ $# -ge 1 ]] || { echo "uso: pipeline.sh lote YYYY-MM"; exit 2; }
    garante_dados
    sobe_lote "$1"
    executa "$(mes_anterior "$1"),$1"
    ;;
  executar)
    executa "${1:-todas}"
    ;;
  backfill)
    [[ $# -ge 1 ]] || { echo "uso: pipeline.sh backfill YYYY-MM[,YYYY-MM...]"; exit 2; }
    executa "$1"
    ;;
  relatorio)
    if [[ $# -ge 1 ]]; then glue_relatorio "$1"; else
      aws s3 ls "s3://${BUCKET_ARTEFATOS}/execucoes/" --region "$REGION"
    fi
    ;;
  *)
    sed -n '2,16p' "$0"; exit 2 ;;
esac
