#!/usr/bin/env bash
# =============================================================================
# verifica.sh — Script de aceite da Parte 2 (AV2) · Grupo g08 / eda262
#
# Uso:
#   ./verificacao/verifica.sh [regiao]               # aceite completo (~4 min; roda 1 backfill no Glue)
#   ./verificacao/verifica.sh [regiao] --rapido      # pula o teste ao vivo de backfill/idempotência
#   ./verificacao/verifica.sh [regiao] --destroyed   # confirma destroy sem órfãos
#
# Pré-requisitos: terraform apply (parte-2) + ./parte-2/ingestao/pipeline.sh carga
# Requer: aws CLI v2, python3, credenciais da conta que fez o apply.
#
# Critérios (seção 4.2 do guia):
#   1. Recursos, nomes e ausência de crawler         4. Lake Formation: permissão por camada
#   2. Tags obrigatórias                             5. Ingestão idempotente + backfill
#   3. Trusted/refined em Parquet particionado       6. Pergunta respondida + meta de custo
# =============================================================================
set -uo pipefail

REGION="${1:-${AWS_DEFAULT_REGION:-us-east-1}}"
MODE="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# META DE CUSTO (DECISOES.md §5): a pergunta de negócio não pode passar do piso
# faturável do Athena (10 MiB => USD 0,0000477 por execução).
META_BYTES=10485760
MES_TESTE="2025-06"      # recorte mensal usado na meta da trusted
PARTICAO_BACKFILL="2024-01"
N_PARTICOES_ESPERADAS=24

PASSA=0; FALHA=0
pass() { echo -e "${GREEN}[PASSA]${NC} $1"; PASSA=$((PASSA + 1)); }
fail() { echo -e "${RED}[FALHA]${NC} $1"; FALHA=$((FALHA + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }

has_mandatory_tags() {
  "$PY" -c '
import json, sys
required = {"turma": "eda262", "grupo": "g08", "projeto": "engenharia-de-dados"}
data = json.loads(sys.stdin.read().strip() or "{}")
t = data.get("TagSet") or data.get("Tags") or {}
tags = {x["Key"]: x["Value"] for x in t} if isinstance(t, list) else t
sys.exit(0 if all(tags.get(k) == v for k, v in required.items()) else 1)
'
}

check_cmd aws
[[ -n "$PY" ]] || { echo "python3 não encontrado"; exit 1; }
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION") || exit 1
info "Conta: ${ACCOUNT_ID} | Região: ${REGION} | Prefixo: ${PREFIX}"
ARN_GLUE="arn:aws:glue:${REGION}:${ACCOUNT_ID}"

# =============================================================================
if [[ "$MODE" == "--destroyed" ]]; then
  header "Destroy limpo — nenhum recurso do g08 pode sobrar"
  LEFT=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
    --tag-filters Key=grupo,Values=g08 Key=turma,Values=eda262 --query 'ResourceTagMappingList[].ResourceARN' --output text)
  [[ -z "$LEFT" || "$LEFT" == "None" ]] && pass "Nenhum recurso com tags grupo=g08/turma=eda262" || fail "Ainda existem: ${LEFT}"
  for b in "$BUCKET_RAW" "$BUCKET_TRUSTED" "$BUCKET_REFINED" "$BUCKET_RESULTS" "$BUCKET_ARTEFATOS"; do
    aws s3api head-bucket --bucket "$b" --region "$REGION" >/dev/null 2>&1 && fail "Bucket ainda existe: $b" || pass "Bucket removido: $b"
  done
  for db in "$DB_RAW" "$DB_TRUSTED" "$DB_REFINED"; do
    aws glue get-database --name "$db" --region "$REGION" >/dev/null 2>&1 && fail "Database ainda existe: $db" || pass "Database removido: $db"
  done
  aws athena get-work-group --work-group "$WORKGROUP" --region "$REGION" >/dev/null 2>&1 && fail "Workgroup ainda existe" || pass "Workgroup removido"
  aws glue get-job --job-name "$GLUE_JOB" --region "$REGION" >/dev/null 2>&1 && fail "Glue job ainda existe" || pass "Glue job removido"
  for r in "$ROLE_ANALISTA" "$ROLE_ENGENHEIRO" "$ROLE_GLUE" "$ROLE_LF"; do
    aws iam get-role --role-name "$r" >/dev/null 2>&1 && fail "Role ainda existe: $r" || pass "Role removida: $r"
  done
  REG=$(aws lakeformation list-resources --region "$REGION" --query "ResourceInfoList[?contains(ResourceArn, '${PREFIX}lake-')].ResourceArn" --output text)
  [[ -z "$REG" || "$REG" == "None" ]] && pass "Nenhuma localização ${PREFIX}lake-* registrada no Lake Formation" || fail "Ainda registradas: $REG"
  LG=$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "$LOG_GROUP" --query 'length(logGroups)' --output text)
  [[ "$LG" == "0" ]] && pass "Log group removido: ${LOG_GROUP}" || fail "Log group ainda existe: ${LOG_GROUP}"
  echo ""; echo -e "PASSA: ${PASSA} | FALHA: ${FALHA}"
  [[ "$FALHA" -gt 0 ]] && exit 1 || exit 0
fi

# =============================================================================
header "1) Recursos com prefixo ${PREFIX} (Terraform, sem crawler)"
# =============================================================================
for b in "$BUCKET_RAW" "$BUCKET_TRUSTED" "$BUCKET_REFINED" "$BUCKET_RESULTS" "$BUCKET_ARTEFATOS"; do
  check "Bucket existe: s3://${b}" "aws s3api head-bucket --bucket '$b' --region '$REGION'"
done
check "Athena workgroup existe: ${WORKGROUP}" "aws athena get-work-group --work-group '$WORKGROUP' --region '$REGION'"
CUTOFF=$(aws athena get-work-group --work-group "$WORKGROUP" --region "$REGION" --query 'WorkGroup.Configuration.BytesScannedCutoffPerQuery' --output text 2>/dev/null)
[[ "$CUTOFF" =~ ^[0-9]+$ ]] && pass "Workgroup com guarda de custo por consulta: ${CUTOFF} bytes ($(mib "$CUTOFF") MiB)" || fail "Workgroup sem BytesScannedCutoffPerQuery"
for pair in "$DB_RAW:$T_RAW" "$DB_TRUSTED:$T_TRUSTED" "$DB_REFINED:$T_REFINED"; do
  db="${pair%%:*}"; t="${pair##*:}"
  check "Database + tabela com schema declarado: ${db}.${t}" "aws glue get-table --database-name '$db' --name '$t' --region '$REGION'"
done
MCR=$(aws glue get-job --job-name "$GLUE_JOB" --region "$REGION" --query 'Job.ExecutionProperty.MaxConcurrentRuns' --output text 2>/dev/null)
[[ "$MCR" == "1" ]] && pass "Glue job ${GLUE_JOB} existe (max_concurrent_runs = 1)" || fail "Glue job ${GLUE_JOB} ausente ou com concorrência != 1 (${MCR})"
CRAWLERS=$(aws glue get-crawlers --region "$REGION" --query "length(Crawlers[?starts_with(Name, '${PREFIX}')])" --output text 2>/dev/null || echo 0)
[[ "$CRAWLERS" == "0" ]] && pass "Nenhum Glue Crawler ${PREFIX}* (schema declarado no Terraform)" || fail "${CRAWLERS} crawler(s) ${PREFIX}*"

# =============================================================================
header "2) Tags obrigatórias (turma, grupo, projeto)"
# =============================================================================
for b in "$BUCKET_RAW" "$BUCKET_TRUSTED" "$BUCKET_REFINED" "$BUCKET_RESULTS" "$BUCKET_ARTEFATOS"; do
  check "Tags no bucket ${b}" "aws s3api get-bucket-tagging --bucket '$b' --region '$REGION' | has_mandatory_tags"
done
check "Tags no workgroup ${WORKGROUP}" "aws athena list-tags-for-resource --resource-arn 'arn:aws:athena:${REGION}:${ACCOUNT_ID}:workgroup/${WORKGROUP}' --region '$REGION' --output json | has_mandatory_tags"
for db in "$DB_RAW" "$DB_TRUSTED" "$DB_REFINED"; do
  check "Tags no database ${db}" "aws glue get-tags --resource-arn '${ARN_GLUE}:database/${db}' --region '$REGION' --output json | has_mandatory_tags"
done
check "Tags no Glue job ${GLUE_JOB}" "aws glue get-tags --resource-arn '${ARN_GLUE}:job/${GLUE_JOB}' --region '$REGION' --output json | has_mandatory_tags"
for r in "$ROLE_ANALISTA" "$ROLE_ENGENHEIRO" "$ROLE_GLUE" "$ROLE_LF"; do
  check "Tags na role IAM ${r}" "aws iam list-role-tags --role-name '$r' --output json | has_mandatory_tags"
done

# =============================================================================
header "3) Trusted e refined em Parquet particionado"
# =============================================================================
for pair in "$DB_TRUSTED:$T_TRUSTED:$BUCKET_TRUSTED:vendas" "$DB_REFINED:$T_REFINED:$BUCKET_REFINED:faturamento_categoria_mes"; do
  IFS=: read -r db t bucket pfx <<< "$pair"
  TJSON=$(aws glue get-table --database-name "$db" --name "$t" --region "$REGION" --output json 2>/dev/null || echo '{}')
  echo "$TJSON" | "$PY" -c "
import json,sys
t=json.load(sys.stdin)['Table']; sd=t['StorageDescriptor']
ok = 'parquet' in sd['SerdeInfo']['SerializationLibrary'].lower() and [k['Name'] for k in t.get('PartitionKeys',[])]==['ano_mes']
sys.exit(0 if ok else 1)" 2>/dev/null \
    && pass "${db}.${t}: SerDe Parquet + chave de partição ano_mes" \
    || fail "${db}.${t}: não é Parquet particionado por ano_mes"
  LIST=$(aws s3 ls "s3://${bucket}/${SCENARIO}/${pfx}/" --recursive --region "$REGION" 2>/dev/null)
  NPART=$(echo "$LIST" | grep -o 'ano_mes=[0-9-]*' | sort -u | wc -l | tr -d ' ')
  NFILES=$(echo "$LIST" | grep -c 'ano_mes=' || true)
  NPARQ=$(echo "$LIST" | grep 'ano_mes=' | grep -c '\.parquet$' || true)
  [[ "$NPART" -ge "$N_PARTICOES_ESPERADAS" ]] && pass "s3://${bucket}: ${NPART} partições ano_mes=* (esperado >= ${N_PARTICOES_ESPERADAS})" \
    || fail "s3://${bucket}: ${NPART} partições (rode ./parte-2/ingestao/pipeline.sh carga)"
  [[ "$NFILES" -gt 0 && "$NFILES" == "$NPARQ" ]] && pass "s3://${bucket}: ${NPARQ}/${NFILES} arquivos de dados são .parquet" \
    || fail "s3://${bucket}: ${NPARQ}/${NFILES} arquivos .parquet"
done

# =============================================================================
header "4) Lake Formation — permissão por camada"
# =============================================================================
REGS=$(aws lakeformation list-resources --region "$REGION" --query 'ResourceInfoList[].ResourceArn' --output text 2>/dev/null)
for b in "$BUCKET_RAW" "$BUCKET_TRUSTED" "$BUCKET_REFINED"; do
  [[ "$REGS" == *"arn:aws:s3:::${b}"* ]] && pass "Localização registrada no Lake Formation: s3://${b}" || fail "s3://${b} não registrado no Lake Formation"
done
for pair in "$DB_RAW:$T_RAW" "$DB_TRUSTED:$T_TRUSTED" "$DB_REFINED:$T_REFINED"; do
  db="${pair%%:*}"; t="${pair##*:}"
  N=$(aws lakeformation list-permissions --region "$REGION" --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS \
      --resource "{\"Table\":{\"DatabaseName\":\"${db}\",\"Name\":\"${t}\"}}" --query 'length(PrincipalResourcePermissions)' --output text 2>/dev/null || echo "?")
  [[ "$N" == "0" ]] && pass "${db}.${t}: sem IAM_ALLOWED_PRINCIPALS (acesso decidido pelo Lake Formation)" \
    || fail "${db}.${t}: IAM_ALLOWED_PRINCIPALS ainda tem ${N} permissão(ões)"
done

testa_acesso() { # persona camada db tabela esperado(OK|NEGADO)
  local persona="$1" camada="$2" db="$3" t="$4" esperado="$5" got
  if como_role "$persona" athena_exec "SELECT COUNT(*) FROM \"${db}\".\"${t}\""; then got="OK"; else got="NEGADO"; fi
  # Sem GRANT, o Lake Formation esconde a tabela: o Athena responde TABLE_NOT_FOUND.
  local motivo=""; [[ "$got" == "NEGADO" ]] && motivo=" — ${ATH_REASON:0:110}"
  if [[ "$got" == "$esperado" ]]; then pass "persona ${persona##*-} lê ${camada}: ${got} (esperado ${esperado})${motivo}"
  else fail "persona ${persona##*-} lê ${camada}: ${got} (esperado ${esperado})${motivo}"; fi
}
testa_acesso "$ROLE_ANALISTA"   refined "$DB_REFINED" "$T_REFINED" OK
testa_acesso "$ROLE_ANALISTA"   trusted "$DB_TRUSTED" "$T_TRUSTED" NEGADO
testa_acesso "$ROLE_ANALISTA"   raw     "$DB_RAW"     "$T_RAW"     NEGADO
testa_acesso "$ROLE_ENGENHEIRO" raw     "$DB_RAW"     "$T_RAW"     OK
testa_acesso "$ROLE_ENGENHEIRO" trusted "$DB_TRUSTED" "$T_TRUSTED" OK
testa_acesso "$ROLE_ENGENHEIRO" refined "$DB_REFINED" "$T_REFINED" OK
if como_role "$ROLE_ANALISTA" aws s3 ls "s3://${BUCKET_REFINED}/" --region "$REGION" >/dev/null 2>&1; then
  fail "persona analista lê o bucket refined direto no S3 (deveria ser só via Lake Formation)"
else
  pass "persona analista NÃO acessa o S3 direto: leitura só por credencial do Lake Formation"
fi

# =============================================================================
header "5) Ingestão idempotente + backfill"
# =============================================================================
if athena_exec "SELECT COUNT(*), COUNT(DISTINCT id_venda) FROM vendas_trusted" "$DB_TRUSTED"; then
  read -r TOT DIST < <(athena_rows)
  [[ "$TOT" == "$DIST" && "$TOT" -gt 0 ]] && pass "trusted sem duplicata: ${TOT} linhas = ${DIST} id_venda distintos" \
    || fail "trusted com duplicata: ${TOT} linhas vs ${DIST} id_venda distintos"
else
  fail "Não consegui contar a trusted: ${ATH_REASON}"
fi
SQL_CONS="SELECT (SELECT SUM(valor_total) FROM \"${DB_TRUSTED}\".vendas_trusted) = (SELECT SUM(faturamento_bruto) FROM \"${DB_REFINED}\".faturamento_categoria_mes)"
athena_exec "$SQL_CONS" && [[ "$(athena_scalar)" == "true" ]] \
  && pass "refined consistente com trusted (SUM(faturamento_bruto) = SUM(valor_total))" \
  || fail "refined diverge da trusted"

SNAP_SQL="SELECT ano_mes, COUNT(*), COUNT(DISTINCT id_venda), CAST(MAX(processado_em) AS varchar) FROM vendas_trusted GROUP BY 1 ORDER BY 1"
if [[ "$MODE" == "--rapido" ]]; then
  info "--rapido: teste ao vivo de backfill/idempotência pulado (ver evidencias/parte-2/)"
else
  athena_exec "$SNAP_SQL" "$DB_TRUSTED" && ANTES=$(athena_rows)
  info "Backfill ao vivo: reprocessando SÓ a partição ${PARTICAO_BACKFILL} (partição que já existe)"
  if glue_run "$PARTICAO_BACKFILL"; then
    pass "Job de backfill --PARTICOES=${PARTICAO_BACKFILL} SUCCEEDED (${GLUE_SECS}s)"
    athena_exec "$SNAP_SQL" "$DB_TRUSTED" && DEPOIS=$(athena_rows)
    RES=$(ANTES="$ANTES" DEPOIS="$DEPOIS" P="$PARTICAO_BACKFILL" "$PY" -c "
import os
def parse(s): return {l.split('\t')[0]: l.split('\t')[1:] for l in s.strip().splitlines()}
a, d, p = parse(os.environ['ANTES']), parse(os.environ['DEPOIS']), os.environ['P']
mesmas_contagens = all(a[k][:2] == d.get(k, [None, None])[:2] for k in a) and a.keys() == d.keys()
sem_dup = all(v[0] == v[1] for v in d.values())
alvo_mudou = a[p][2] != d[p][2]
outras_iguais = all(a[k][2] == d[k][2] for k in a if k != p)
tot = sum(int(v[0]) for v in d.values())
print(int(mesmas_contagens), int(sem_dup), int(alvo_mudou), int(outras_iguais), tot, a[p][0], d[p][0], a[p][2].replace(' ','T'), d[p][2].replace(' ','T'))
")
    read -r R_CONT R_DUP R_ALVO R_OUTRAS R_TOT R_PA R_PD R_TA R_TD <<< "$(echo "$RES" | tr -d '\r')"
    [[ "$R_CONT" == "1" ]] && pass "Rodar de novo não duplica: contagem de TODAS as partições igual antes/depois (total ${R_TOT}; ${PARTICAO_BACKFILL}: ${R_PA} -> ${R_PD})" \
      || fail "Contagens mudaram depois do reprocessamento"
    [[ "$R_DUP" == "1" ]] && pass "Depois do backfill: COUNT(*) = COUNT(DISTINCT id_venda) em todas as partições" || fail "Duplicata depois do backfill"
    [[ "$R_ALVO" == "1" ]] && pass "Backfill reescreveu ${PARTICAO_BACKFILL}: processado_em ${R_TA} -> ${R_TD}" || fail "Partição ${PARTICAO_BACKFILL} não foi reescrita"
    [[ "$R_OUTRAS" == "1" ]] && pass "Backfill não tocou nas outras $((N_PARTICOES_ESPERADAS - 1)) partições (processado_em inalterado)" || fail "Backfill alterou outras partições"
  else
    fail "Job de backfill falhou: ${GLUE_STATE:-} ${GLUE_ERR:-}"
  fi
fi

# =============================================================================
header "6) Pergunta de negócio no Athena + meta de custo"
# =============================================================================
QUERY_FILE="${REPO_ROOT}/queries/consulta_analitica.sql"
if athena_exec "$(cat "$QUERY_FILE")" "$DB_REFINED"; then
  NL=$(athena_rows | wc -l | tr -d ' ')
  pass "Pergunta respondida na refined: ${NL} linhas (categoria x mês) · QueryExecutionId ${ATH_ID}"
  info "Bytes varridos: ${ATH_BYTES} ($(mib "$ATH_BYTES") MiB) | faturado: USD $(custo_usd "$ATH_BYTES") | ${ATH_MS} ms"
  [[ "$ATH_BYTES" -le "$META_BYTES" ]] \
    && pass "META DE CUSTO cumprida (refined): ${ATH_BYTES} B <= ${META_BYTES} B => USD $(custo_usd "$ATH_BYTES") (piso)" \
    || fail "META DE CUSTO estourada (refined): ${ATH_BYTES} B > ${META_BYTES} B"
  info "Amostra (6 primeiras linhas):"; athena_rows | head -6 | sed 's/^/    /'
else
  fail "Pergunta falhou na refined: ${ATH_REASON}"
fi

SQL_T="SELECT categoria_produto, SUM(valor_total), SUM(quantidade) FROM vendas_trusted WHERE ano_mes = '${MES_TESTE}' GROUP BY 1"
if athena_exec "$SQL_T" "$DB_TRUSTED"; then
  [[ "$ATH_BYTES" -le "$META_BYTES" ]] \
    && pass "META DE CUSTO cumprida (trusted, 1 mês com poda de partição): ${ATH_BYTES} B ($(mib "$ATH_BYTES") MiB) <= ${META_BYTES} B" \
    || fail "META DE CUSTO estourada (trusted, 1 mês): ${ATH_BYTES} B"
else
  fail "Consulta mensal na trusted falhou: ${ATH_REASON}"
fi

# =============================================================================
header "Resumo"
# =============================================================================
echo -e "Critérios avaliados: $((PASSA + FALHA))"
echo -e "${GREEN}[PASSA]${NC}: ${PASSA}"
echo -e "${RED}[FALHA]${NC}: ${FALHA}"
if [[ "$FALHA" -gt 0 ]]; then echo -e "${RED}Resultado final: FALHA${NC}"; exit 1; fi
echo -e "${GREEN}Resultado final: PASSA${NC}"
