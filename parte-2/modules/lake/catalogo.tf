locals {
  db_names = { for c in local.camadas : c => "${var.project_prefix}${c}${var.name_suffix}" }

  s3_paths = {
    raw     = "s3://${aws_s3_bucket.camada["raw"].bucket}/${var.scenario_slug}/vendas/"
    trusted = "s3://${aws_s3_bucket.camada["trusted"].bucket}/${var.scenario_slug}/vendas/"
    refined = "s3://${aws_s3_bucket.camada["refined"].bucket}/${var.scenario_slug}/faturamento_categoria_mes/"
  }

  parquet = {
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"
    serde         = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
  }

  # Projeção de partição: o Athena calcula as partições a partir do template,
  # sem MSCK REPAIR / crawler / BatchCreatePartition. Partição nova escrita pelo
  # job fica visível na hora e o job não precisa de permissão de escrita no catálogo.
  projecao_ano_mes = {
    "projection.enabled"               = "true"
    "projection.ano_mes.type"          = "date"
    "projection.ano_mes.format"        = "yyyy-MM"
    "projection.ano_mes.range"         = "${var.particao_inicio},NOW"
    "projection.ano_mes.interval"      = "1"
    "projection.ano_mes.interval.unit" = "MONTHS"
  }
}

# -----------------------------------------------------------------------------
# Um database por camada => permissão por camada no Lake Formation fica limpa
# (GRANT no database inteiro, não tabela a tabela).
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_database" "camada" {
  for_each    = local.db_names
  name        = each.value
  description = "Camada ${each.key} do lake g08 (${var.scenario_slug})"

  tags = { camada = each.key }
}

# -----------------------------------------------------------------------------
# RAW — CSV como chegou do sistema de origem (tudo string; nada é corrigido aqui)
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "raw" {
  name          = "vendas_raw"
  database_name = aws_glue_catalog_database.camada["raw"].name
  description   = "Lotes CSV brutos de vendas (1 arquivo por lote mensal). Grão: 1 linha recebida (pode ter duplicata e sujeira)."
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "EXTERNAL"               = "TRUE"
    "classification"         = "csv"
    "skip.header.line.count" = "1"
  }

  storage_descriptor {
    location      = local.s3_paths["raw"]
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "vendas_raw_csv"
      serialization_library = "org.apache.hadoop.hive.serde2.OpenCSVSerde"
      parameters = {
        "separatorChar" = ","
        "quoteChar"     = "\""
        "escapeChar"    = "\\"
      }
    }

    columns {
      name = "id_venda"
      type = "string"
    }
    columns {
      name = "id_cliente"
      type = "string"
    }
    columns {
      name    = "data_venda"
      type    = "string"
      comment = "3 formatos misturados + inválidas"
    }
    columns {
      name    = "categoria_produto"
      type    = "string"
      comment = "caixa/acento/espaço inconsistentes"
    }
    columns {
      name = "quantidade"
      type = "string"
    }
    columns {
      name    = "preco_unitario"
      type    = "string"
      comment = "pode vir <= 0 ou com vírgula decimal"
    }
  }
}

# -----------------------------------------------------------------------------
# TRUSTED — Parquet/Snappy particionado por ano_mes
# Grão: 1 registro = 1 item vendido, único por id_venda
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "trusted" {
  name          = "vendas_trusted"
  database_name = aws_glue_catalog_database.camada["trusted"].name
  description   = "Vendas limpas e deduplicadas. Grão: 1 item vendido (chave id_venda). Partição: ano_mes."
  table_type    = "EXTERNAL_TABLE"

  parameters = merge(local.projecao_ano_mes, {
    "EXTERNAL"                  = "TRUE"
    "classification"            = "parquet"
    "parquet.compression"       = "SNAPPY"
    "storage.location.template" = "${local.s3_paths["trusted"]}ano_mes=$${ano_mes}/"
  })

  partition_keys {
    name    = "ano_mes"
    type    = "string"
    comment = "yyyy-MM da data_venda"
  }

  storage_descriptor {
    location      = local.s3_paths["trusted"]
    input_format  = local.parquet.input_format
    output_format = local.parquet.output_format

    ser_de_info {
      name                  = "vendas_trusted_parquet"
      serialization_library = local.parquet.serde
    }

    columns {
      name    = "id_venda"
      type    = "bigint"
      comment = "chave de negócio (única na trusted)"
    }
    columns {
      name = "id_cliente"
      type = "bigint"
    }
    columns {
      name = "data_venda"
      type = "date"
    }
    columns {
      name    = "categoria_produto"
      type    = "string"
      comment = "canônica: Eletronicos, Moda, Casa, Esportes, Livros, Beleza, Alimentos"
    }
    columns {
      name = "quantidade"
      type = "int"
    }
    columns {
      name = "preco_unitario"
      type = "decimal(10,2)"
    }
    columns {
      name    = "valor_total"
      type    = "decimal(12,2)"
      comment = "quantidade * preco_unitario"
    }
    columns {
      name    = "lote_origem"
      type    = "string"
      comment = "lote raw de onde veio a versão vencedora (linhagem)"
    }
    columns {
      name    = "processado_em"
      type    = "timestamp"
      comment = "execução do job que escreveu a partição"
    }
  }
}

# -----------------------------------------------------------------------------
# REFINED — resposta da pergunta de negócio pré-agregada (Parquet, por ano_mes)
# Grão: 1 registro = 1 categoria x 1 mês
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "refined" {
  name          = "faturamento_categoria_mes"
  database_name = aws_glue_catalog_database.camada["refined"].name
  description   = "Faturamento bruto e itens vendidos por categoria e mês. Grão: categoria x mês. Partição: ano_mes."
  table_type    = "EXTERNAL_TABLE"

  parameters = merge(local.projecao_ano_mes, {
    "EXTERNAL"                  = "TRUE"
    "classification"            = "parquet"
    "parquet.compression"       = "SNAPPY"
    "storage.location.template" = "${local.s3_paths["refined"]}ano_mes=$${ano_mes}/"
  })

  partition_keys {
    name = "ano_mes"
    type = "string"
  }

  storage_descriptor {
    location      = local.s3_paths["refined"]
    input_format  = local.parquet.input_format
    output_format = local.parquet.output_format

    ser_de_info {
      name                  = "faturamento_categoria_mes_parquet"
      serialization_library = local.parquet.serde
    }

    columns {
      name = "categoria_produto"
      type = "string"
    }
    columns {
      name = "faturamento_bruto"
      type = "decimal(18,2)"
    }
    columns {
      name = "qtd_itens_vendidos"
      type = "bigint"
    }
    columns {
      name = "qtd_linhas_venda"
      type = "bigint"
    }
    columns {
      name = "processado_em"
      type = "timestamp"
    }
  }
}

# -----------------------------------------------------------------------------
# Athena
# -----------------------------------------------------------------------------
resource "aws_athena_workgroup" "main" {
  name          = "${var.project_prefix}workgroup${var.name_suffix}"
  description   = "Workgroup do g08 (${var.scenario_slug}) — Parte 2"
  state         = "ENABLED"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    # Guarda de custo: nenhuma consulta passa de var.athena_bytes_cutoff varridos.
    bytes_scanned_cutoff_per_query = var.athena_bytes_cutoff

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/query-results/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}
