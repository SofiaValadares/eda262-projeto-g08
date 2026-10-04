module "lake" {
  source = "./modules/lake"

  project_prefix     = var.project_prefix
  scenario_slug      = var.scenario_slug
  mandatory_tags     = var.mandatory_tags
  trusted_table_name = var.trusted_table_name
  trusted_data_key   = var.trusted_data_key
  trusted_data_file  = "${path.module}/files/venda_varejo_trusted.csv"
}
