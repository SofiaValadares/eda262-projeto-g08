#!/usr/bin/env bash
# =============================================================================
# benchmark_custo.sh — mede, no Athena, o custo da MESMA pergunta em 5 arranjos
# de armazenamento, para sustentar com número as decisões de FORMATO, PARTIÇÃO e
# CAMADA (DECISOES.md). Cada arranjo roda 2 vezes: ano inteiro e 1 mês.
#
#   [A] raw CSV (sem camadas)          [D] trusted Parquet particionado (real)
#   [B] trusted CSV (formato Parte 1)  [E] refined Parquet particionado (real)
#   [C] trusted Parquet sem partição
#
# [B] e [C] são tabelas temporárias (CTAS a partir da trusted, mesmo conteúdo).
# O workgroup força o local de saída, então o Athena grava o CTAS dentro do
# bucket de resultados; lemos esse local no catálogo e apagamos tudo no fim.
#
# Uso: ./ferramentas/benchmark_custo.sh [regiao] [mes_filtro]
# Saída: tabela markdown em evidencias/parte-2/benchmark_custo.md
# =============================================================================
set -euo pipefail
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "${AQUI}/.." && pwd)"
REGION="${1:-${AWS_DEFAULT_REGION:-us-east-1}}"
MES="${2:-2025-06}"
source "${RAIZ}/verificacao/_lib.sh"
check_cmd aws

OUT="${RAIZ}/evidencias/parte-2/benchmark_custo.md"
mkdir -p "$(dirname "$OUT")"

render() { # arquivo filtro -> SQL
  sed -e "s/{{DB_RAW}}/${DB_RAW}/g" -e "s/{{DB_TRUSTED}}/${DB_TRUSTED}/g" -e "s/{{DB_REFINED}}/${DB_REFINED}/g" \
      -e "s/{{FILTRO}}/$2/g" -e "s/{{FILTRO_RAW}}/$3/g" "${RAIZ}/queries/benchmark/$1"
}

roda_ddl() {
  athena_exec "$1" || { echo -e "${RED}DDL falhou: ${ATH_REASON}${NC}"; echo "$1"; exit 1; }
}

local_tabela() {
  aws glue get-table --database-name "$DB_TRUSTED" --name "$1" --region "$REGION"     --query 'Table.StorageDescriptor.Location' --output text 2>/dev/null || true
}

limpa_bench() {
  local t loc
  for t in bench_trusted_csv bench_trusted_parquet; do
    loc=$(local_tabela "$t")
    [[ -n "$loc" && "$loc" != "None" ]] && aws s3 rm "${loc%/}/" --recursive --region "$REGION" --only-show-errors || true
  done
  athena_exec "DROP TABLE IF EXISTS \`${DB_TRUSTED}\`.\`bench_trusted_csv\`" >/dev/null || true
  athena_exec "DROP TABLE IF EXISTS \`${DB_TRUSTED}\`.\`bench_trusted_parquet\`" >/dev/null || true
}

tamanho() { # s3://prefixo -> "bytes arquivos"
  aws s3 ls "$1" --recursive --summarize --region "$REGION" \
    | awk '/Total Objects/{o=$3} /Total Size/{s=$3} END{print s+0, o+0}'
}

header "Preparando tabelas temporárias [B] CSV e [C] Parquet sem partição"
limpa_bench
COLS="id_venda, id_cliente, data_venda, categoria_produto, quantidade, preco_unitario, valor_total, lote_origem, processado_em, ano_mes"
roda_ddl "CREATE TABLE \"${DB_TRUSTED}\".bench_trusted_csv
  WITH (format='TEXTFILE', field_delimiter=',')
  AS SELECT ${COLS} FROM \"${DB_TRUSTED}\".vendas_trusted"
roda_ddl "CREATE TABLE \"${DB_TRUSTED}\".bench_trusted_parquet
  WITH (format='PARQUET', write_compression='SNAPPY')
  AS SELECT ${COLS} FROM \"${DB_TRUSTED}\".vendas_trusted"

declare -A ARQ=(
  [A]="a_raw_csv.sql" [B]="b_trusted_csv.sql" [C]="c_trusted_parquet_sem_particao.sql"
  [D]="d_trusted_parquet_particionado.sql" [E]="e_refined_parquet_particionado.sql"
)
declare -A NOME=(
  [A]="raw CSV (sem camadas)" [B]="trusted CSV, sem partição (formato Parte 1)"
  [C]="trusted Parquet, sem partição" [D]="trusted Parquet particionado"
  [E]="refined Parquet particionado"
)
declare -A LOCAL=(
  [A]="s3://${BUCKET_RAW}/${SCENARIO}/vendas/" [B]="$(local_tabela bench_trusted_csv)" [C]="$(local_tabela bench_trusted_parquet)"
  [D]="s3://${BUCKET_TRUSTED}/${SCENARIO}/vendas/" [E]="s3://${BUCKET_REFINED}/${SCENARIO}/faturamento_categoria_mes/"
)

{
  echo "# Benchmark de custo — mesma pergunta, 5 arranjos de armazenamento"
  echo ""
  echo "- Data: $(date -u +%Y-%m-%dT%H:%MZ) · Região: ${REGION} · Workgroup: \`${WORKGROUP}\`"
  echo "- Preço Athena: USD 5/TB, piso de 10 MB faturados por consulta"
  echo "- Recorte de 1 mês: \`ano_mes = '${MES}'\`"
  echo ""
  echo "## Armazenamento"
  echo ""
  echo "| Arranjo | Bytes no S3 | MiB | Arquivos |"
  echo "|---|---:|---:|---:|"
} > "$OUT"

for k in A B C D E; do
  read -r b o < <(tamanho "${LOCAL[$k]}")
  echo "| [$k] ${NOME[$k]} | ${b} | $(mib "$b") | ${o} |" >> "$OUT"
done

{
  echo ""
  echo "## Consulta da pergunta de negócio"
  echo ""
  echo "| Arranjo | Recorte | QueryExecutionId | Bytes varridos | MiB | USD faturado | Linhas | ms |"
  echo "|---|---|---|---:|---:|---:|---:|---:|"
} >> "$OUT"

header "Executando a pergunta em cada arranjo"
for k in A B C D E; do
  for recorte in "ano inteiro" "1 mês"; do
    if [[ "$recorte" == "1 mês" ]]; then f="ano_mes = '${MES}'"; fr="date_format(data_venda, '%Y-%m') = '${MES}'"
    else f="1 = 1"; fr="1 = 1"; fi
    sql=$(render "${ARQ[$k]}" "$f" "$fr")
    if athena_exec "$sql"; then
      n=$(athena_rows | wc -l | tr -d ' ')
      [[ "$k" == "A" && "$recorte" == "ano inteiro" ]] && athena_rows > "${RAIZ}/evidencias/parte-2/.resp_raw.tsv"
      [[ "$k" == "E" && "$recorte" == "ano inteiro" ]] && athena_rows > "${RAIZ}/evidencias/parte-2/.resp_refined.tsv"
      linha="| [$k] ${NOME[$k]} | ${recorte} | \`${ATH_ID}\` | ${ATH_BYTES} | $(mib "$ATH_BYTES") | $(custo_usd "$ATH_BYTES") | ${n} | ${ATH_MS} |"
    else
      linha="| [$k] ${NOME[$k]} | ${recorte} | \`${ATH_ID}\` | FALHOU: ${ATH_REASON} | | | | |"
    fi
    echo "$linha" | tee -a "$OUT"
  done
done

header "Prova cruzada: refined == pergunta calculada direto do raw"
if cmp -s "${RAIZ}/evidencias/parte-2/.resp_raw.tsv" "${RAIZ}/evidencias/parte-2/.resp_refined.tsv"; then
  msg="IGUAIS — $(wc -l < "${RAIZ}/evidencias/parte-2/.resp_refined.tsv" | tr -d ' ') linhas (categoria x mês) idênticas entre [A] raw e [E] refined."
else
  msg="DIFERENTES — ver diff entre .resp_raw.tsv e .resp_refined.tsv"
fi
echo "$msg"
{ echo ""; echo "## Prova cruzada"; echo ""; echo "$msg"; } >> "$OUT"
rm -f "${RAIZ}/evidencias/parte-2/.resp_raw.tsv" "${RAIZ}/evidencias/parte-2/.resp_refined.tsv"

header "Limpando tabelas temporárias"
limpa_bench
info "Resultado em ${OUT}"
