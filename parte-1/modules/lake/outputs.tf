output "lake_trusted_bucket" {
  value = aws_s3_bucket.lake_trusted.bucket
}

output "athena_results_bucket" {
  value = aws_s3_bucket.athena_results.bucket
}

output "athena_workgroup" {
  value = aws_athena_workgroup.main.name
}

output "glue_database" {
  value = aws_glue_catalog_database.catalog.name
}

output "glue_table" {
  value = aws_glue_catalog_table.venda_varejo_trusted.name
}
