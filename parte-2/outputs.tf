output "buckets_camadas" {
  description = "Bucket de cada camada do lake."
  value       = module.lake.buckets
}

output "s3_paths" {
  description = "Prefixo S3 de cada tabela."
  value       = module.lake.s3_paths
}

output "athena_results_bucket" {
  value = module.lake.athena_results_bucket
}

output "artefatos_bucket" {
  value = module.lake.artefatos_bucket
}

output "athena_workgroup" {
  value = module.lake.athena_workgroup
}

output "glue_databases" {
  value = module.lake.databases
}

output "glue_tabelas" {
  value = module.lake.tabelas
}

output "glue_job" {
  value = module.ingestao.job_name
}

output "glue_log_group" {
  value = module.ingestao.log_group
}

output "persona_analista_role_arn" {
  value = module.governanca.analista_role_arn
}

output "persona_engenheiro_role_arn" {
  value = module.governanca.engenheiro_role_arn
}

output "proximos_passos" {
  value = <<-EOT
    1) python3 ingestao/gerar_raw.py
    2) ./ingestao/pipeline.sh carga            # sobe os 24 lotes no raw e roda o job (todas as partições)
    3) ./ingestao/pipeline.sh backfill 2024-01 # reprocessa só a partição 2024-01
    4) ../verificacao/verifica.sh us-east-1
  EOT
}
