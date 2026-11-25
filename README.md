# EDA262 — Projeto Grupo 08 (g08)

**Disciplina:** Engenharia de Dados (CESAR School)  
**Entrega atual:** Parte 2 (AV2) — branch `main`, tag `av2-entrega`, código em [`parte-2/`](./parte-2)  
**Entrega anterior:** Parte 1 (AV1) — tag `av1-entrega`, código em [`parte-1/`](./parte-1)  
**Cenário:** `varejo-ecommerce` · **Prefixo AWS:** `eda262-g08-` · **Região:** `us-east-1`

**Pergunta de negócio:** *qual o faturamento bruto e a quantidade de itens vendidos, por categoria de produto e por mês?*

Decisões de engenharia (grão, chaves, partição, formato, custo), cada uma com número medido: [`DECISOES.md`](./DECISOES.md).

---

## Arquitetura (Parte 2)

```text
 sistema de origem          RAW (CSV)               TRUSTED (Parquet)            REFINED (Parquet)
 24 lotes mensais  ──►  eda262-g08-lake-raw  ──►  eda262-g08-lake-trusted  ──►  eda262-g08-lake-refined
 (gerar_raw.py)         vendas_raw               vendas_trusted               faturamento_categoria_mes
                        1 linha recebida         1 item vendido (id_venda)    1 categoria x 1 mês
                        sem partição             partição ano_mes             partição ano_mes
                                    └────── job Glue eda262-g08-etl-vendas ──────┘
                                     (idempotente, backfill via --PARTICOES)

 Lake Formation:   engenheiro → raw, trusted, refined      analista → só refined
 Athena:           eda262-g08-workgroup (guarda de 1 GiB por consulta)
```

| Recurso | Nome | Módulo |
|---|---|---|
| Buckets das camadas | `eda262-g08-lake-raw`, `-lake-trusted`, `-lake-refined` | `lake` |
| Bucket de resultados Athena / artefatos do job | `eda262-g08-athena-results`, `eda262-g08-artefatos` | `lake` |
| Glue databases (1 por camada) | `eda262-g08-raw`, `eda262-g08-trusted`, `eda262-g08-refined` | `lake` |
| Tabelas (schema declarado, **sem crawler**) | `vendas_raw`, `vendas_trusted`, `faturamento_categoria_mes` | `lake` |
| Athena workgroup | `eda262-g08-workgroup` | `lake` |
| Job Glue + role + log group | `eda262-g08-etl-vendas`, `eda262-g08-glue-etl`, `/eda262-g08/glue/etl-vendas` | `ingestao` |
| Localizações registradas no Lake Formation + role | 3 buckets de camada, `eda262-g08-lf-registro` | `governanca` |
| Personas | `eda262-g08-analista`, `eda262-g08-engenheiro` | `governanca` |

Todos os recursos levam as tags `turma=eda262`, `grupo=g08`, `projeto=engenharia-de-dados` (via `default_tags`).

> **Conta compartilhada.** O Terraform **não** gerencia `aws_lakeformation_data_lake_settings`
> (admins e defaults da conta inteira): o destroy desse recurso apagaria a configuração de
> outros grupos. Também não é preciso ser *Data Lake Administrator*: quem cria database e
> tabelas recebe permissão com *grant option* sobre elas, e é isso que o Terraform usa.

## Pré-requisitos

- Terraform `>= 1.5` (testado com 1.15.8, provider `hashicorp/aws` 5.x)
- AWS CLI v2 autenticado na conta (permissões de administrador: S3, Glue, Athena, IAM, Lake Formation, DynamoDB, CloudWatch Logs)
- Python 3 (gerador de dados e scripts) — só biblioteca padrão
- Bash (Linux/macOS, ou Git Bash no Windows)
- ~2 GB livres em disco (provider AWS)

## Estrutura

```text
eda262-projeto-g08/
├── README.md · DECISOES.md · apresentacao-parte-2-g08.md
├── parte-2/
│   ├── bootstrap/                # S3 (tfstate) + DynamoDB (lock)
│   ├── modules/lake/             # buckets, Glue Catalog, Athena
│   ├── modules/ingestao/         # job Glue, role, logs
│   ├── modules/governanca/       # Lake Formation + personas
│   ├── glue/etl_vendas.py        # ETL raw -> trusted -> refined
│   ├── ingestao/gerar_raw.py     # gera os 24 lotes raw (determinístico)
│   ├── ingestao/pipeline.sh      # carga / lote / backfill / executar
│   └── main.tf, backend.tf, providers.tf, variables.tf, outputs.tf
├── queries/consulta_analitica.sql      # a pergunta (camada refined)
├── queries/benchmark/*.sql             # a pergunta em 5 arranjos (custo)
├── ferramentas/benchmark_custo.sh      # mede formato x partição x camada
├── verificacao/verifica.sh             # aceite PASSA/FALHA (Parte 2)
├── evidencias/parte-2/                 # saídas reais
└── parte-1/ …                          # entrega AV1 (preservada)
```

## Deploy

### 1) Backend remoto (uma vez por conta)

```bash
cd parte-2/bootstrap
terraform init
terraform apply -auto-approve
```

Cria `eda262-g08-tfstate` (S3 versionado/criptografado) e `eda262-g08-tfstate-lock` (DynamoDB).

### 2) Stack principal

```bash
cd parte-2
terraform init \
  -backend-config="bucket=eda262-g08-tfstate" \
  -backend-config="key=parte-2/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=eda262-g08-tfstate-lock" \
  -backend-config="encrypt=true"
terraform workspace show        # "default" = nomes canônicos esperados pelo verifica.sh
terraform apply -auto-approve
```

### 3) Dados e ingestão

```bash
cd parte-2
python3 ingestao/gerar_raw.py              # 24 lotes, 1.223.286 linhas, ~48 MiB (seed fixa)
./ingestao/pipeline.sh carga               # sobe os lotes no raw + job (todas as partições)
./ingestao/pipeline.sh backfill 2024-01    # reprocessa só 2024-01
./ingestao/pipeline.sh lote 2025-12        # (re)ingere um lote: reprocessa 2025-11 e 2025-12
```

Cada execução grava um relatório (linhas lidas, descartes por regra, duplicatas removidas,
linhas por partição) em `s3://eda262-g08-artefatos/execucoes/<JobRunId>.json`.

### 4) Aceite

```bash
./verificacao/verifica.sh us-east-1            # completo (~4 min, roda 1 backfill ao vivo)
./verificacao/verifica.sh us-east-1 --rapido   # sem o backfill ao vivo
./ferramentas/benchmark_custo.sh us-east-1     # opcional: refaz a medição de custo do DECISOES
```

### Consulta manual

```bash
aws athena start-query-execution --work-group eda262-g08-workgroup \
  --query-execution-context Database=eda262-g08-refined \
  --query-string "$(cat queries/consulta_analitica.sql)"
```

## Destroy (sem órfãos)

```bash
cd parte-2 && terraform destroy -auto-approve
cd bootstrap && terraform destroy -auto-approve
cd ../.. && ./verificacao/verifica.sh us-east-1 --destroyed
```

- `force_destroy` em todos os buckets (inclui versões do raw) e no workgroup.
- Log group do job é criado pelo Terraform (não pelo Glue), então sai no destroy.
- Lake Formation: registros de localização e GRANTs são recursos Terraform; os grants de
  tabela somem junto com as tabelas. Nenhuma configuração da conta é alterada.
- Role própria para o registro no Lake Formation (não o service-linked role, que ficaria).

## Parte 1

O roteiro da AV1 continua válido na tag `av1-entrega`. Nesta branch os artefatos da Parte 1
foram renomeados: `verificacao/verifica-parte-1.sh`, `verificacao/RELATORIO-VALIDACAO-parte-1.md`,
`queries/consulta_analitica_parte-1.sql`.
