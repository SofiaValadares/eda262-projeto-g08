#!/usr/bin/env bash
# =============================================================================
# verifica.sh — Script de aceite AV1 (Grupo g08 / eda262)
# Executar na conta AWS do avaliador (credenciais configuradas).
# Uso: ./verificacao/verifica.sh [regiao]
# =============================================================================
set -euo pipefail

REGION="${1:-${AWS_DEFAULT_REGION:-us-east-1}}"
MODE="${2:-}"
PREFIX="eda262-g08-"
BUCKET_TRUSTED="${PREFIX}lake-trusted"
BUCKET_RESULTS="${PREFIX}athena-results"
WORKGROUP="${PREFIX}workgroup"
GLUE_DB="${PREFIX}catalog"
GLUE_TABLE="venda_varejo_trusted"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
QUERY_FILE="${REPO_ROOT}/queries/consulta_analitica.sql"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

PASSA=0
FALHA=0

pass()  { echo -e "${GREEN}[PASSA]${NC} $1"; PASSA=$((PASSA + 1)); }
fail()  { echo -e "${RED}[FALHA]${NC} $1"; FALHA=$((FALHA + 1)); }
info()  { echo -e "${CYAN}==>${NC} $1"; }
header() {
  echo ""
  echo -e "${YELLOW}------------------------------------------------------------${NC}"
  echo -e "${YELLOW}$1${NC}"
  echo -e "${YELLOW}------------------------------------------------------------${NC}"
}

check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo -e "${RED}Erro: comando '$1' não encontrado.${NC}"
    exit 1
  fi
}

# Valida turma/grupo/projeto em um mapa JSON de tags { "Key": "...", "Value": "..." }[]
# ou formato Glue get-tags: { "Tags": { "k": "v" } }
# ou Resource Groups: ResourceTagMappingList
has_mandatory_tags() {
  python3 -c '
import json, sys
required = {"turma": "eda262", "grupo": "g08", "projeto": "engenharia-de-dados"}
raw = sys.stdin.read().strip() or "{}"
data = json.loads(raw)
tags = {}
if "TagSet" in data:
    tags = {t["Key"]: t["Value"] for t in data.get("TagSet") or []}
elif "Tags" in data and isinstance(data["Tags"], dict):
    tags = data["Tags"]
elif "Tags" in data and isinstance(data["Tags"], list):
    tags = {t["Key"]: t["Value"] for t in data["Tags"]}
elif "ResourceTagMappingList" in data:
    maps = data.get("ResourceTagMappingList") or []
    if maps:
        tags = {t["Key"]: t["Value"] for t in maps[0].get("Tags") or []}
ok = all(tags.get(k) == v for k, v in required.items())
sys.exit(0 if ok else 1)
'
}

check_cmd aws
check_cmd python3

if [[ ! -f "$QUERY_FILE" ]]; then
  echo -e "${RED}Arquivo de query não encontrado: ${QUERY_FILE}${NC}"
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
info "Conta AWS: ${ACCOUNT_ID} | Região: ${REGION} | Prefixo: ${PREFIX}"

# Modo --destroyed: confirma que o destroy não deixou recurso órfão do grupo
if [[ "$MODE" == "--destroyed" ]]; then
  header "Destroy limpo (nenhum recurso eda262-g08-)"
  LEFT=$(aws resourcegroupstaggingapi get-resources --region "$REGION"     --tag-filters Key=grupo,Values=g08 Key=turma,Values=eda262     --query 'length(ResourceTagMappingList)' --output text)
  [[ "$LEFT" == "0" ]] && pass "Nenhum recurso com tags grupo=g08/turma=eda262" || fail "${LEFT} recurso(s) ainda existem com as tags do grupo"
  for b in "${BUCKET_TRUSTED}" "${BUCKET_RESULTS}"; do
    aws s3api head-bucket --bucket "$b" --region "$REGION" 2>/dev/null && fail "Bucket ainda existe: $b" || pass "Bucket removido: $b"
  done
  aws athena get-work-group --work-group "$WORKGROUP" --region "$REGION" >/dev/null 2>&1 && fail "Workgroup ainda existe" || pass "Workgroup removido"
  aws glue get-database --name "$GLUE_DB" --region "$REGION" >/dev/null 2>&1 && fail "Glue database ainda existe" || pass "Glue database removido"
  echo -e "PASSA: ${PASSA} | FALHA: ${FALHA}"
  [[ "$FALHA" -gt 0 ]] && exit 1 || exit 0
fi

# =============================================================================
header "1) Existência dos recursos com prefixo ${PREFIX}"
# =============================================================================

if aws s3api head-bucket --bucket "$BUCKET_TRUSTED" --region "$REGION" 2>/dev/null; then
  pass "Bucket S3 trusted existe: s3://${BUCKET_TRUSTED}"
else
  fail "Bucket S3 trusted NÃO encontrado: s3://${BUCKET_TRUSTED}"
fi

if aws s3api head-bucket --bucket "$BUCKET_RESULTS" --region "$REGION" 2>/dev/null; then
  pass "Bucket S3 resultados Athena existe: s3://${BUCKET_RESULTS}"
else
  fail "Bucket S3 resultados Athena NÃO encontrado: s3://${BUCKET_RESULTS}"
fi

if aws athena get-work-group --work-group "$WORKGROUP" --region "$REGION" >/dev/null 2>&1; then
  pass "Athena Workgroup existe: ${WORKGROUP}"
else
  fail "Athena Workgroup NÃO encontrado: ${WORKGROUP}"
fi

if aws glue get-database --name "$GLUE_DB" --region "$REGION" >/dev/null 2>&1; then
  pass "Glue Database (catalog) existe: ${GLUE_DB}"
else
  fail "Glue Database NÃO encontrado: ${GLUE_DB}"
fi

if aws glue get-table --database-name "$GLUE_DB" --name "$GLUE_TABLE" --region "$REGION" >/dev/null 2>&1; then
  pass "Glue Table trusted existe: ${GLUE_DB}.${GLUE_TABLE}"
else
  fail "Glue Table trusted NÃO encontrada: ${GLUE_DB}.${GLUE_TABLE}"
fi

CRAWLER_COUNT=$(aws glue get-crawlers --region "$REGION" \
  --query "length(CrawlerList[?starts_with(Name, '${PREFIX}')])" --output text 2>/dev/null || echo "0")
if [[ "$CRAWLER_COUNT" == "0" || "$CRAWLER_COUNT" == "None" ]]; then
  pass "Nenhum Glue Crawler com prefixo ${PREFIX} (schema explícito no Terraform)"
else
  fail "Encontrado(s) ${CRAWLER_COUNT} Glue Crawler(s) com prefixo ${PREFIX} — proibido"
fi

# =============================================================================
header "2) Tags obrigatórias (turma, grupo, projeto)"
# =============================================================================

if aws s3api get-bucket-tagging --bucket "$BUCKET_TRUSTED" --region "$REGION" 2>/dev/null | has_mandatory_tags; then
  pass "Tags obrigatórias presentes no bucket ${BUCKET_TRUSTED}"
else
  fail "Tags obrigatórias AUSENTES ou incorretas no bucket ${BUCKET_TRUSTED}"
fi

if aws s3api get-bucket-tagging --bucket "$BUCKET_RESULTS" --region "$REGION" 2>/dev/null | has_mandatory_tags; then
  pass "Tags obrigatórias presentes no bucket ${BUCKET_RESULTS}"
else
  fail "Tags obrigatórias AUSENTES ou incorretas no bucket ${BUCKET_RESULTS}"
fi

WG_ARN="arn:aws:athena:${REGION}:${ACCOUNT_ID}:workgroup/${WORKGROUP}"
if aws athena list-tags-for-resource --resource-arn "$WG_ARN" --region "$REGION" --output json 2>/dev/null | has_mandatory_tags; then
  pass "Tags obrigatórias presentes no workgroup ${WORKGROUP}"
else
  fail "Tags obrigatórias AUSENTES ou incorretas no workgroup ${WORKGROUP}"
fi

DB_ARN="arn:aws:glue:${REGION}:${ACCOUNT_ID}:database/${GLUE_DB}"
if aws glue get-tags --resource-arn "$DB_ARN" --region "$REGION" --output json 2>/dev/null | has_mandatory_tags; then
  pass "Tags obrigatórias presentes no Glue Database ${GLUE_DB}"
else
  fail "Tags obrigatórias AUSENTES ou incorretas no Glue Database ${GLUE_DB}"
fi

# =============================================================================
header "3) Execução da consulta analítica no Athena"
# =============================================================================

QUERY_STRING=$(cat "$QUERY_FILE")
EXEC_ID=$(aws athena start-query-execution \
  --region "$REGION" \
  --work-group "$WORKGROUP" \
  --query-execution-context "Database=${GLUE_DB}" \
  --query-string "$QUERY_STRING" \
  --query QueryExecutionId \
  --output text 2>/dev/null || true)

if [[ -z "${EXEC_ID}" ]]; then
  fail "Não foi possível iniciar a query no Athena"
else
  info "QueryExecutionId: ${EXEC_ID}"
  STATUS="RUNNING"
  for _ in $(seq 1 60); do
    STATUS=$(aws athena get-query-execution \
      --region "$REGION" \
      --query-execution-id "$EXEC_ID" \
      --query 'QueryExecution.Status.State' \
      --output text)
    if [[ "$STATUS" == "SUCCEEDED" || "$STATUS" == "FAILED" || "$STATUS" == "CANCELLED" ]]; then
      break
    fi
    sleep 2
  done

  if [[ "$STATUS" == "SUCCEEDED" ]]; then
    pass "Consulta analítica executada com sucesso no Athena"
    DATA_SCANNED=$(aws athena get-query-execution \
      --region "$REGION" \
      --query-execution-id "$EXEC_ID" \
      --query 'QueryExecution.Statistics.DataScannedInBytes' \
      --output text)
    MB=$(python3 -c "print(round(int('${DATA_SCANNED}')/1048576, 6))")
    COST=$(python3 -c "print(round((int('${DATA_SCANNED}')/1099511627776)*5.0, 10))")
    info "Bytes varridos: ${DATA_SCANNED} (~${MB} MB) | Custo estimado: USD ${COST}"
    echo ""
    info "Amostra do resultado (até 20 linhas):"
    aws athena get-query-results \
      --region "$REGION" \
      --query-execution-id "$EXEC_ID" \
      --max-results 20 \
      --output table || true
  else
    REASON=$(aws athena get-query-execution \
      --region "$REGION" \
      --query-execution-id "$EXEC_ID" \
      --query 'QueryExecution.Status.StateChangeReason' \
      --output text 2>/dev/null || echo "n/a")
    fail "Consulta Athena finalizou com status ${STATUS}: ${REASON}"
  fi
fi

# =============================================================================
header "Resumo"
# =============================================================================
TOTAL=$((PASSA + FALHA))
echo -e "Critérios avaliados: ${TOTAL}"
echo -e "${GREEN}[PASSA]${NC}: ${PASSA}"
echo -e "${RED}[FALHA]${NC}: ${FALHA}"

if [[ "$FALHA" -gt 0 ]]; then
  echo -e "${RED}Resultado final: FALHA${NC}"
  exit 1
fi

echo -e "${GREEN}Resultado final: PASSA${NC}"
exit 0
