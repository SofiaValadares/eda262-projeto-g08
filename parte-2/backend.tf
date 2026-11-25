# Backend remoto: S3 (state) + DynamoDB (lock) — o mesmo bootstrap da Parte 1,
# com uma chave de state própria (parte-2/terraform.tfstate).
#
#   terraform init \
#     -backend-config="bucket=eda262-g08-tfstate" \
#     -backend-config="key=parte-2/terraform.tfstate" \
#     -backend-config="region=us-east-1" \
#     -backend-config="dynamodb_table=eda262-g08-tfstate-lock" \
#     -backend-config="encrypt=true"
#
# Workspaces: o state fica isolado por workspace no mesmo backend; o workspace
# "default" usa os nomes canônicos que o verifica.sh espera.

terraform {
  backend "s3" {}
}
