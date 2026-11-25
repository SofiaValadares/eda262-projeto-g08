#!/usr/bin/env bash
# =============================================================================
# Funções compartilhadas por verifica.sh, ingestao/pipeline.sh e
# ferramentas/benchmark_custo.sh. Só depende de aws CLI v2 e python3.
# =============================================================================

REGION="${REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
PREFIX="${PREFIX:-eda262-g08-}"
SUFFIX="${SUFFIX:-}"   # sufixo de workspace (vazio no default)

BUCKET_RAW="${PREFIX}lake-raw${SUFFIX}"
BUCKET_TRUSTED="${PREFIX}lake-trusted${SUFFIX}"
BUCKET_REFINED="${PREFIX}lake-refined${SUFFIX}"
BUCKET_RESULTS="${PREFIX}athena-results${SUFFIX}"
BUCKET_ARTEFATOS="${PREFIX}artefatos${SUFFIX}"
WORKGROUP="${PREFIX}workgroup${SUFFIX}"
DB_RAW="${PREFIX}raw${SUFFIX}"
DB_TRUSTED="${PREFIX}trusted${SUFFIX}"
DB_REFINED="${PREFIX}refined${SUFFIX}"
T_RAW="vendas_raw"
T_TRUSTED="vendas_trusted"
T_REFINED="faturamento_categoria_mes"
GLUE_JOB="${PREFIX}etl-vendas${SUFFIX}"
ROLE_ANALISTA="${PREFIX}analista${SUFFIX}"
ROLE_ENGENHEIRO="${PREFIX}engenheiro${SUFFIX}"
ROLE_GLUE="${PREFIX}glue-etl${SUFFIX}"
ROLE_LF="${PREFIX}lf-registro${SUFFIX}"
LOG_GROUP="/${PREFIX%-}/glue/etl-vendas${SUFFIX}"
SCENARIO="varejo-ecommerce"

# Preço Athena sob demanda: USD 5/TB, mínimo faturável de 10 MB por consulta.
ATHENA_USD_POR_TB=5
ATHENA_PISO_BYTES=10485760

export AWS_PAGER=""
# Git Bash no Windows: não converter "s3://..." / "/caminho" em caminho do Windows.
export MSYS_NO_PATHCONV=1

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'; NC='\033[0m'

info()   { echo -e "${CYAN}==>${NC} $*"; }
header() {
  echo ""
  echo -e "${YELLOW}------------------------------------------------------------${NC}"
  echo -e "${YELLOW}$*${NC}"
  echo -e "${YELLOW}------------------------------------------------------------${NC}"
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo -e "${RED}Erro: comando '$1' não encontrado.${NC}"; exit 1; }
}

# python3 no Linux/macOS; no Windows às vezes só existe "python".
PY="$(command -v python3 || command -v python || true)"

custo_usd() { # bytes -> custo faturado em USD (com piso)
  "$PY" -c "import sys; b=int(sys.argv[1] or 0); print(f'{max(b,$ATHENA_PISO_BYTES)/2**40*$ATHENA_USD_POR_TB:.8f}')" "$1"
}
mib() { "$PY" -c "import sys; print(f'{int(sys.argv[1] or 0)/1048576:.3f}')" "$1"; }

# -----------------------------------------------------------------------------
# Athena
#   athena_exec "SQL" [DATABASE]
#     => ATH_ID ATH_STATE ATH_BYTES ATH_MS ATH_REASON
# -----------------------------------------------------------------------------
athena_exec() {
  local sql="$1" db="${2:-}" out
  local -a ctx=()
  [[ -n "$db" ]] && ctx=(--query-execution-context "Database=${db}")
  ATH_ID="" ; ATH_STATE="" ; ATH_BYTES=0 ; ATH_MS=0 ; ATH_REASON=""
  local tentativa
  for tentativa in 1 2 3; do   # tolera falha momentânea de rede (não de permissão)
    if out=$(aws athena start-query-execution --region "$REGION" --work-group "$WORKGROUP" \
          "${ctx[@]}" --query-string "$sql" --query QueryExecutionId --output text 2>&1); then
      break
    fi
    [[ "$out" == *"Could not connect"* || "$out" == *"timed out"* ]] || break
    sleep 3
  done
  if [[ ! "$out" =~ ^[0-9a-f-]{36}$ ]]; then
    ATH_STATE="START_FAILED"; ATH_REASON="$out"; return 1
  fi
  ATH_ID="$out"
  local i json
  for i in $(seq 1 180); do
    json=$(aws athena get-query-execution --region "$REGION" --query-execution-id "$ATH_ID" --output json 2>/dev/null) || { sleep 2; continue; }
    ATH_STATE=$(echo "$json" | "$PY" -c "import json,sys; print(json.load(sys.stdin)['QueryExecution']['Status']['State'])")
    case "$ATH_STATE" in SUCCEEDED|FAILED|CANCELLED) break ;; esac
    sleep 1
  done
  read -r ATH_BYTES ATH_MS < <(echo "$json" | "$PY" -c "
import json,sys
s=json.load(sys.stdin)['QueryExecution'].get('Statistics',{})
print(s.get('DataScannedInBytes',0), s.get('EngineExecutionTimeInMillis',0))")
  ATH_REASON=$(echo "$json" | "$PY" -c "import json,sys; print(json.load(sys.stdin)['QueryExecution']['Status'].get('StateChangeReason',''))")
  [[ "$ATH_STATE" == "SUCCEEDED" ]]
}

# athena_rows => imprime o resultado da última consulta como TSV (sem cabeçalho)
athena_rows() {
  aws athena get-query-results --region "$REGION" --query-execution-id "${1:-$ATH_ID}" --output json \
    | "$PY" -c "
import json,sys
rows=json.load(sys.stdin)['ResultSet']['Rows'][1:]
for r in rows: print('\t'.join(c.get('VarCharValue','') for c in r['Data']))" | tr -d '\r'   # python no Windows emite CRLF
}

athena_scalar() { athena_rows "$@" | head -1 | cut -f1; }

# -----------------------------------------------------------------------------
# Personas: executa um comando com as credenciais de uma role assumida
#   como_role ROLE_NAME comando args...
# -----------------------------------------------------------------------------
como_role() {
  local role="$1"; shift
  local acct creds
  acct=$(aws sts get-caller-identity --query Account --output text)
  creds=$(aws sts assume-role --role-arn "arn:aws:iam::${acct}:role/${role}" \
    --role-session-name "verifica-${role}" --duration-seconds 900 --query Credentials --output json) || return 97
  local ak sk st
  ak=$(echo "$creds" | "$PY" -c "import json,sys; print(json.load(sys.stdin)['AccessKeyId'])")
  sk=$(echo "$creds" | "$PY" -c "import json,sys; print(json.load(sys.stdin)['SecretAccessKey'])")
  st=$(echo "$creds" | "$PY" -c "import json,sys; print(json.load(sys.stdin)['SessionToken'])")
  local rc=0
  local o_ak="${AWS_ACCESS_KEY_ID-}" o_sk="${AWS_SECRET_ACCESS_KEY-}" o_st="${AWS_SESSION_TOKEN-}" o_pf="${AWS_PROFILE-}"
  export AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" AWS_SESSION_TOKEN="$st"
  unset AWS_PROFILE
  "$@" || rc=$?
  if [[ -n "$o_ak" ]]; then export AWS_ACCESS_KEY_ID="$o_ak"; else unset AWS_ACCESS_KEY_ID; fi
  if [[ -n "$o_sk" ]]; then export AWS_SECRET_ACCESS_KEY="$o_sk"; else unset AWS_SECRET_ACCESS_KEY; fi
  if [[ -n "$o_st" ]]; then export AWS_SESSION_TOKEN="$o_st"; else unset AWS_SESSION_TOKEN; fi
  if [[ -n "$o_pf" ]]; then export AWS_PROFILE="$o_pf"; fi
  return $rc
}

# -----------------------------------------------------------------------------
# Glue
#   glue_run "PARTICOES"  => GLUE_RUN_ID GLUE_STATE GLUE_SECS
# -----------------------------------------------------------------------------
glue_run() {
  local particoes="${1:-todas}" args
  args=$("$PY" -c "import json,sys; print(json.dumps({'--PARTICOES': sys.argv[1]}))" "$particoes")
  GLUE_RUN_ID=$(aws glue start-job-run --region "$REGION" --job-name "$GLUE_JOB" \
    --arguments "$args" --query JobRunId --output text) || return 1
  info "Glue job ${GLUE_JOB} | run ${GLUE_RUN_ID} | --PARTICOES=${particoes}"
  local i json
  for i in $(seq 1 180); do
    sleep 10
    json=$(aws glue get-job-run --region "$REGION" --job-name "$GLUE_JOB" --run-id "$GLUE_RUN_ID" --output json)
    GLUE_STATE=$(echo "$json" | "$PY" -c "import json,sys; print(json.load(sys.stdin)['JobRun']['JobRunState'])")
    case "$GLUE_STATE" in SUCCEEDED|FAILED|STOPPED|TIMEOUT|ERROR) break ;; esac
    printf '.'
  done
  echo ""
  GLUE_SECS=$(echo "$json" | "$PY" -c "import json,sys; print(json.load(sys.stdin)['JobRun'].get('ExecutionTime',0))")
  GLUE_ERR=$(echo "$json" | "$PY" -c "import json,sys; print(json.load(sys.stdin)['JobRun'].get('ErrorMessage',''))")
  info "Estado: ${GLUE_STATE} | ${GLUE_SECS}s ${GLUE_ERR}"
  [[ "$GLUE_STATE" == "SUCCEEDED" ]]
}

glue_relatorio() { # imprime o relatório JSON gravado pelo job
  aws s3 cp "s3://${BUCKET_ARTEFATOS}/execucoes/${1:-$GLUE_RUN_ID}.json" - --region "$REGION"
}
