# -----------------------------------------------------------------------------
# Parte 2 (AV2) — g08 / varejo-ecommerce
#
#   lake        : buckets raw/trusted/refined, Glue Catalog (1 database por camada,
#                 schema declarado, sem crawler) e workgroup do Athena
#   ingestao    : job Glue (PySpark) idempotente raw -> trusted -> refined
#   governanca  : Lake Formation — registro das 3 camadas e permissão por camada
#                 para as personas analista (só refined) e engenheiro (tudo)
# -----------------------------------------------------------------------------

locals {
  # workspace "default" => nomes canônicos; outros workspaces ganham sufixo.
  ws = terraform.workspace == "default" ? "" : "-${terraform.workspace}"
}

module "lake" {
  source = "./modules/lake"

  project_prefix      = var.project_prefix
  name_suffix         = local.ws
  scenario_slug       = var.scenario_slug
  particao_inicio     = var.particao_inicio
  athena_bytes_cutoff = var.athena_bytes_cutoff
}

module "ingestao" {
  source = "./modules/ingestao"

  project_prefix   = var.project_prefix
  name_suffix      = local.ws
  artefatos_bucket = module.lake.artefatos_bucket
  raw_bucket       = module.lake.buckets["raw"]
  trusted_bucket   = module.lake.buckets["trusted"]
  refined_bucket   = module.lake.buckets["refined"]
  raw_path         = module.lake.s3_paths["raw"]
  trusted_path     = module.lake.s3_paths["trusted"]
  refined_path     = module.lake.s3_paths["refined"]
  script_file      = "${path.module}/glue/etl_vendas.py"
}

module "governanca" {
  source = "./modules/governanca"

  project_prefix        = var.project_prefix
  name_suffix           = local.ws
  buckets               = module.lake.buckets
  athena_results_bucket = module.lake.athena_results_bucket
  athena_workgroup_arn  = module.lake.athena_workgroup_arn
  databases             = module.lake.databases
  tabelas               = module.lake.tabelas
}
