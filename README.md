# EDA262 — Projeto Grupo 08 (g08)

**Disciplina:** Engenharia de Dados (CESAR School)  
**Entrega:** Parte 1 (AV1) — branch `main`, tag `av1-entrega`  
**Cenário:** `varejo-ecommerce`  
**Prefixo AWS:** `eda262-g08-`

## Visão geral

Provisionamento IaC (Terraform) de um mini data lake analítico na AWS:

| Recurso | Nome |
|---------|------|
| Bucket trusted | `eda262-g08-lake-trusted` |
| Bucket resultados Athena | `eda262-g08-athena-results` |
| Athena Workgroup | `eda262-g08-workgroup` |
| Glue Database (catalog) | `eda262-g08-catalog` |
| Glue Table (schema explícito) | `venda_varejo_trusted` |

**Não há Glue Crawler.** O schema da tabela trusted é declarado no Terraform.

Tags obrigatórias (via `default_tags` do provider): `turma=eda262`, `grupo=g08`, `projeto=engenharia-de-dados`.

## Pré-requisitos

- Terraform `>= 1.5`
- AWS CLI v2 autenticado na conta de avaliação
- Permissões para S3, Athena, Glue, DynamoDB e IAM básicos da conta
- Python 3 (usado pelo `verifica.sh`)

## Estrutura do repositório

```text
eda262-projeto-g08/
├── README.md
├── DECISOES.md
├── apresentacao-parte-1-g08.md
├── data/venda_varejo_raw.csv
├── queries/consulta_analitica.sql
├── verificacao/verifica.sh
└── parte-1/
    ├── bootstrap/          # S3 tfstate + DynamoDB lock
    ├── files/venda_varejo_trusted.csv
    ├── backend.tf
    ├── providers.tf
    ├── variables.tf
    ├── main.tf
    ├── outputs.tf
    └── terraform.tfvars.example
```

## Deploy

### 1) Bootstrap do backend remoto (uma vez por conta)

```bash
cd parte-1/bootstrap
terraform init
terraform apply -auto-approve
cd ..
```

Isso cria:

- Bucket `eda262-g08-tfstate` (state versionado + criptografado)
- Tabela DynamoDB `eda262-g08-tfstate-lock` (state lock)

### 2) Inicializar o stack principal com backend S3 + workspaces

```bash
cd parte-1
cp terraform.tfvars.example terraform.tfvars   # opcional

terraform init \
  -backend-config="bucket=eda262-g08-tfstate" \
  -backend-config="key=parte-1/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=eda262-g08-tfstate-lock" \
  -backend-config="encrypt=true"

# Workspaces (opcional, mas suportado)
terraform workspace new av1 || terraform workspace select av1

terraform plan
terraform apply -auto-approve
```

O `apply` sobe buckets, workgroup, catálogo Glue (schema explícito) e faz upload do CSV trusted.

### 3) Conferir outputs

```bash
terraform output
```

## Executar a consulta analítica

Manualmente (Athena CLI):

```bash
aws athena start-query-execution \
  --work-group eda262-g08-workgroup \
  --query-execution-context Database=eda262-g08-catalog \
  --query-string file://../queries/consulta_analitica.sql
```

Ou use o script de aceite (recomendado):

```bash
chmod +x verificacao/verifica.sh
./verificacao/verifica.sh us-east-1
```

O script valida:

1. Existência dos recursos com prefixo `eda262-g08-`
2. Presença das 3 tags obrigatórias
3. Ausência de Glue Crawler do grupo
4. Execução da query no Athena (`[PASSA]` / `[FALHA]` em cores)

## Destroy (100% limpo)

Ordem recomendada:

```bash
# 1) Stack principal (force_destroy nos buckets + workgroup)
cd parte-1
terraform destroy -auto-approve

# 2) Backend (somente após o destroy do stack principal)
cd bootstrap
terraform destroy -auto-approve
```

Garantias anti-órfão:

- `force_destroy = true` nos buckets S3 (trusted, athena-results, tfstate)
- `force_destroy = true` no Athena Workgroup
- Lifecycle de 7 dias nos resultados Athena
- Nenhum recurso fora do Terraform (sem crawler manual)

## Tag Git de entrega

```bash
git tag -a av1-entrega -m "Entrega AV1 — Parte 1 g08"
git push origin main --tags
```

## Documentação complementar

- Decisões de grão e custo: [`DECISOES.md`](./DECISOES.md)
- Roteiro de slides (5 min): [`apresentacao-parte-1-g08.md`](./apresentacao-parte-1-g08.md)
