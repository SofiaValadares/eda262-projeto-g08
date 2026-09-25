# Backend remoto: S3 (state) + DynamoDB (lock).
# Pré-requisito: aplicar o bootstrap em ./bootstrap (ou criar bucket/tabela manualmente).
# Workspaces: use `terraform workspace new <nome>` — o state fica isolado por workspace no mesmo backend.
#
# Inicialização típica (valores alinhados ao bootstrap):
#   terraform init \
#     -backend-config="bucket=eda262-g08-tfstate" \
#     -backend-config="key=parte-1/terraform.tfstate" \
#     -backend-config="region=us-east-1" \
#     -backend-config="dynamodb_table=eda262-g08-tfstate-lock" \
#     -backend-config="encrypt=true"

terraform {
  backend "s3" {
    # Valores sensíveis/ambiente via -backend-config (ver README e terraform.tfvars.example).
  }
}
