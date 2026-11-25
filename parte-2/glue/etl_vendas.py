"""
eda262-g08 — ETL raw -> trusted -> refined (cenário varejo-ecommerce)

Idempotência
------------
1. A saída de uma partição é FUNÇÃO PURA do raw inteiro: a partição ano_mes=P da
   trusted é recalculada a partir de TODAS as linhas do raw cuja data limpa cai em
   P (inclusive as que chegaram atrasadas em lotes posteriores).
2. Deduplicação por chave de negócio (id_venda) sobre o raw inteiro, ANTES de
   filtrar partições, com desempate determinístico (lote mais recente vence).
3. Escrita com partitionOverwriteMode=dynamic: cada partição presente no resultado
   é SUBSTITUÍDA (não anexada). Rodar N vezes => mesmo conteúdo, zero duplicata.
4. O job tem max_concurrent_runs = 1 (Terraform): duas execuções não disputam a
   mesma partição.

Backfill
--------
--PARTICOES=2024-01[,2024-02...] reprocessa só essas partições; as demais não
são tocadas (o arquivo e o processado_em delas ficam iguais). --PARTICOES=todas
reprocessa tudo.
"""
import json
import sys
from datetime import datetime, timezone

import boto3
from awsglue.utils import getResolvedOptions
from pyspark.sql import SparkSession, Window
from pyspark.sql import functions as F
from pyspark.sql.types import DecimalType

ARGS = getResolvedOptions(
    sys.argv,
    ["JOB_NAME", "RAW_PATH", "TRUSTED_PATH", "REFINED_PATH", "RELATORIO_PATH", "PARTICOES"],
)
# --JOB_RUN_ID é tratado internamente pelo getResolvedOptions (pedir de novo dá conflito)
ARGS["JOB_RUN_ID"] = next(
    (sys.argv[i + 1] for i, a in enumerate(sys.argv[:-1]) if a == "--JOB_RUN_ID"),
    ARGS.get("job_run_id", "sem-run-id"),
)

spark = (
    SparkSession.builder.appName(ARGS["JOB_NAME"])
    .config("spark.sql.sources.partitionOverwriteMode", "dynamic")
    .config("spark.sql.legacy.timeParserPolicy", "CORRECTED")
    .config("spark.sql.session.timeZone", "UTC")
    .config("spark.sql.parquet.compression.codec", "snappy")
    .config("mapreduce.fileoutputcommitter.marksuccessfuljobs", "false")
    .getOrCreate()
)
spark.sparkContext._jsc.hadoopConfiguration().set("mapreduce.fileoutputcommitter.marksuccessfuljobs", "false")

CATEGORIAS = ["Eletronicos", "Moda", "Casa", "Esportes", "Livros", "Beleza", "Alimentos"]
PROCESSADO_EM = datetime.now(timezone.utc).replace(microsecond=0)
particoes_arg = ARGS["PARTICOES"].strip().lower()
PARTICOES = None if particoes_arg in ("", "todas", "all") else sorted({p.strip() for p in particoes_arg.split(",") if p.strip()})

# ---------------------------------------------------------------- 1. leitura raw
raw = (
    spark.read.option("header", True).option("quote", '"').option("escape", '"')
    .csv(ARGS["RAW_PATH"])
    .withColumn("lote_origem", F.regexp_extract(F.input_file_name(), r"vendas_lote_(\d{4}-\d{2})\.csv", 1))
)
total_raw = raw.count()

# ---------------------------------------------------------------- 2. limpeza
d = F.trim(F.col("data_venda"))
data_limpa = (
    F.when(d.rlike(r"^\d{4}-\d{2}-\d{2}$"), F.to_date(d, "yyyy-MM-dd"))
    .when(d.rlike(r"^\d{4}/\d{2}/\d{2}$"), F.to_date(d, "yyyy/MM/dd"))
    .when(d.rlike(r"^\d{2}-\d{2}-\d{4}$"), F.to_date(d, "dd-MM-yyyy"))
)
cat_limpa = F.initcap(F.lower(F.translate(F.trim(F.col("categoria_produto")), "áàâãéêíóôõúüçÁÀÂÃÉÊÍÓÔÕÚÜÇ", "aaaaeeiooouucAAAAEEIOOOUUC")))
q = F.trim(F.col("quantidade"))
p = F.trim(F.col("preco_unitario"))
preco_limpo = F.when(p.rlike(r"^-?\d+,\d{1,2}$"), F.regexp_replace(p, ",", ".")).otherwise(p)

tipado = raw.select(
    F.trim(F.col("id_venda")).cast("bigint").alias("id_venda"),
    F.trim(F.col("id_cliente")).cast("bigint").alias("id_cliente"),
    data_limpa.alias("data_venda"),
    cat_limpa.alias("categoria_produto"),
    F.when(q.rlike(r"^-?\d+$"), q.cast("int")).alias("quantidade"),
    F.when(preco_limpo.rlike(r"^-?\d+(\.\d+)?$"), preco_limpo.cast(DecimalType(10, 2))).alias("preco_unitario"),
    "lote_origem",
)

regras = {
    "id_invalido": F.col("id_venda").isNull() | F.col("id_cliente").isNull(),
    "data_invalida": F.col("data_venda").isNull(),
    "categoria_desconhecida": ~F.col("categoria_produto").isin(CATEGORIAS) | F.col("categoria_produto").isNull(),
    "quantidade_invalida": F.col("quantidade").isNull() | (F.col("quantidade") <= 0),
    "preco_invalido": F.col("preco_unitario").isNull() | (F.col("preco_unitario") <= 0),
}
# motivo do descarte = primeira regra violada (para o relatório)
motivo = F.lit(None).cast("string")
for nome, cond in reversed(list(regras.items())):
    motivo = F.when(cond, F.lit(nome)).otherwise(motivo)
classificado = tipado.withColumn("motivo_descarte", motivo).cache()
descartes = {r["motivo_descarte"]: r["count"] for r in classificado.groupBy("motivo_descarte").count().collect() if r["motivo_descarte"]}
validos = classificado.filter(F.col("motivo_descarte").isNull()).drop("motivo_descarte")
total_validos_com_dup = validos.count()

# ---------------------------------------------------------------- 3. dedup (raw inteiro)
w = Window.partitionBy("id_venda").orderBy(
    F.col("lote_origem").desc(), F.col("data_venda").desc(), F.col("preco_unitario").desc(),
    F.col("quantidade").desc(), F.col("categoria_produto"), F.col("id_cliente"),
)
trusted = (
    validos.withColumn("_rn", F.row_number().over(w)).filter("_rn = 1").drop("_rn")
    .withColumn("valor_total", (F.col("quantidade") * F.col("preco_unitario")).cast(DecimalType(12, 2)))
    .withColumn("processado_em", F.lit(PROCESSADO_EM).cast("timestamp"))
    .withColumn("ano_mes", F.date_format("data_venda", "yyyy-MM"))
)
total_trusted_global = trusted.count()

# ---------------------------------------------------------------- 4. filtro de partições (backfill)
if PARTICOES is not None:
    trusted = trusted.filter(F.col("ano_mes").isin(PARTICOES))
trusted = trusted.select(
    "id_venda", "id_cliente", "data_venda", "categoria_produto", "quantidade",
    "preco_unitario", "valor_total", "lote_origem", "processado_em", "ano_mes",
).cache()

# ---------------------------------------------------------------- 5. escrita trusted (overwrite dinâmico)
(
    trusted.repartition("ano_mes").sortWithinPartitions("data_venda", "id_venda")
    .write.mode("overwrite").partitionBy("ano_mes").parquet(ARGS["TRUSTED_PATH"])
)

# ---------------------------------------------------------------- 6. refined (agregado da pergunta)
refined = (
    trusted.groupBy("ano_mes", "categoria_produto")
    .agg(
        F.sum("valor_total").cast(DecimalType(18, 2)).alias("faturamento_bruto"),
        F.sum("quantidade").cast("bigint").alias("qtd_itens_vendidos"),
        F.count(F.lit(1)).cast("bigint").alias("qtd_linhas_venda"),
    )
    .withColumn("processado_em", F.lit(PROCESSADO_EM).cast("timestamp"))
    .select("categoria_produto", "faturamento_bruto", "qtd_itens_vendidos", "qtd_linhas_venda", "processado_em", "ano_mes")
)
refined.coalesce(1).write.mode("overwrite").partitionBy("ano_mes").parquet(ARGS["REFINED_PATH"])

# ---------------------------------------------------------------- 7. relatório da execução
por_particao = {r["ano_mes"]: r["count"] for r in trusted.groupBy("ano_mes").count().collect()}
relatorio = {
    "job_run_id": ARGS["JOB_RUN_ID"],
    "processado_em": PROCESSADO_EM.isoformat(),
    "particoes_solicitadas": PARTICOES or "todas",
    "linhas_raw": total_raw,
    "descartes_por_regra": descartes,
    "linhas_validas_antes_dedup": total_validos_com_dup,
    "duplicatas_removidas": total_validos_com_dup - total_trusted_global,
    "linhas_trusted_total": total_trusted_global,
    "linhas_escritas_nesta_execucao": sum(por_particao.values()),
    "particoes_escritas": dict(sorted(por_particao.items())),
}
print("RELATORIO_ETL " + json.dumps(relatorio, ensure_ascii=False))
bucket, _, prefixo = ARGS["RELATORIO_PATH"].replace("s3://", "").partition("/")
boto3.client("s3").put_object(
    Bucket=bucket,
    Key=f"{prefixo.rstrip('/')}/{ARGS['JOB_RUN_ID']}.json",
    Body=json.dumps(relatorio, ensure_ascii=False, indent=2).encode("utf-8"),
    ContentType="application/json",
)
