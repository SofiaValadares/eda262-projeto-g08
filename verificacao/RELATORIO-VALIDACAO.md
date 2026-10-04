# Relatório de Validação na AWS — Parte 1 (AV1 / g08)

**Responsável:** Pessoa 1 — Testes na AWS & Validação
**Data da execução:** 2026-10-04
**Conta AWS:** `325583868777` (usuário `eda-grupo08`) · **Região:** `us-east-1`
**Branch:** `entrega-exercicio-03`
**Terraform:** v1.15.8 · provider `hashicorp/aws` v5.100.0

---

## Status geral

| # | Tarefa | Status | Evidência |
|---|--------|--------|-----------|
| 1 | `terraform apply` sobe a infraestrutura | ✅ | bootstrap `5 added` + stack `12 added`; plan pós-apply `No changes` |
| 2 | Consulta no Athena, custo real e `verifica.sh` | ✅ | `verifica.sh`: **11/11 PASSA**; 3.296 bytes varridos; US$ 0,00004768 |
| 3 | `terraform destroy` sem órfãos | ✅ | `12 destroyed` + `5 destroyed`; `verifica.sh --destroyed`: **5/5 PASSA** |

---

## 0) Linha de base (antes do apply)

Para que o teste de destroy provasse algo, a conta foi inspecionada antes:
todos os nomes `eda262-g08-*` estavam livres e a busca por tags retornava zero.

```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=grupo,Values=g08 Key=turma,Values=eda262 \
  --query "length(ResourceTagMappingList)" --output text
# -> 0
```

---

## 1) Tarefa 1 — a infraestrutura sobe

**Bootstrap** (`parte-1/bootstrap`, state local):

```
Apply complete! Resources: 5 added, 0 changed, 0 destroyed.
tfstate_bucket     = "eda262-g08-tfstate"
tfstate_lock_table = "eda262-g08-tfstate-lock"
```

**Stack principal** (`parte-1`, backend S3 + lock DynamoDB, workspace `default`):

```
Apply complete! Resources: 12 added, 0 changed, 0 destroyed.
```

Recursos criados: buckets `eda262-g08-lake-trusted` e `eda262-g08-athena-results`
(com public access block, SSE, versionamento no trusted e lifecycle de 7 dias nos
resultados), objeto `varejo-ecommerce/venda_varejo_trusted.csv`, workgroup
`eda262-g08-workgroup`, database `eda262-g08-catalog` e tabela `venda_varejo_trusted`.

**Idempotência:** `terraform plan` logo após o apply →
`No changes. Your infrastructure matches the configuration.`

**Aviso do init:** `The parameter "dynamodb_table" is deprecated. Use parameter
"use_lockfile"`. Não impede nada hoje; ver pendências.

---

## 2) Tarefa 2 — consulta, custo real e `verifica.sh`

### 2.1 Resultado do `verifica.sh us-east-1`

```
1) Existência dos recursos         6/6 PASSA  (inclui: nenhum Glue Crawler)
2) Tags obrigatórias               4/4 PASSA  (2 buckets, workgroup, database)
3) Execução da consulta no Athena  1/1 PASSA
Critérios avaliados: 11 | PASSA: 11 | FALHA: 0
Resultado final: PASSA
```

### 2.2 Medição da consulta `queries/consulta_analitica.sql`

| Campo | Valor |
|-------|-------|
| QueryExecutionId | `a223ed5d-6f7d-4b31-91f9-32dcb48e2378` |
| Conclusão | 2026-10-04 01:14:10 (UTC-3) |
| Workgroup | `eda262-g08-workgroup` |
| Status | `SUCCEEDED` |
| Bytes varridos | **3.296 B** (~0,0031 MB) — o CSV trusted inteiro |
| Tempo de motor | 516 ms |
| Custo pela fórmula do script | US$ 0,000000015 |
| Bytes faturados | 10.485.760 B (mínimo de 10 MB por consulta) |
| **Custo real faturado** | **US$ 0,00004768** |

**Por que dois custos.** O `verifica.sh` calcula `bytes / 2^40 × 5` e não aplica o
mínimo faturável de 10 MB do Athena. Num dataset de 3 KB isso faz o número impresso
ficar ~3.000× abaixo do que a AWS cobra. O custo real de cada execução desta
consulta é o piso: **US$ 0,00004768**.

### 2.3 Resposta da consulta

60 linhas (categoria × mês, jan–dez/2024). Amostra:

| categoria_produto | ano_mes | faturamento_bruto | qtd_itens_vendidos |
|---|---|---|---|
| Beleza | 2024-01 | 460.56 | 3 |
| Casa | 2024-01 | 2957.88 | 6 |
| Livros | 2024-01 | 3514.08 | 14 |
| Eletronicos | 2024-02 | 4606.27 | 15 |
| Moda | 2024-09 | 5235.49 | 17 |
| Beleza | 2024-07 | 4682.92 | 17 |

Os nomes de categoria saem no padrão canônico único (`Eletronicos`, sem variações de
caixa), o que confirma que a normalização raw → trusted descrita no `DECISOES.md`
chegou ao lake.

---

## 3) Tarefa 3 — destroy sem órfãos

Ordem executada: stack principal primeiro, backend depois (o inverso deixaria os 12
recursos do stack sem state).

```
parte-1:            Destroy complete! Resources: 12 destroyed.
parte-1/bootstrap:  Destroy complete! Resources: 5 destroyed.
```

**Prova — `verifica.sh us-east-1 --destroyed`:**

```
[PASSA] Nenhum recurso com tags grupo=g08/turma=eda262
[PASSA] Bucket removido: eda262-g08-lake-trusted
[PASSA] Bucket removido: eda262-g08-athena-results
[PASSA] Workgroup removido
[PASSA] Glue database removido
PASSA: 5 | FALHA: 0
```

**Checagem adicional** (o script não cobre o backend):

```
eda262-g08-tfstate        removido
eda262-g08-tfstate-lock   removido
```

A conta voltou exatamente à linha de base da seção 0. Os buckets estavam com objetos
no momento do destroy (CSV trusted, resultados do Athena e versões do state) e foram
esvaziados pelo `force_destroy = true` sem erro de `BucketNotEmpty`.

---

## 4) Pendências e riscos

- **State do bootstrap é local.** Fica só na máquina de quem rodou o apply e é
  ignorado pelo git. Se for perdido, bucket de state e tabela de lock viram órfãos que
  o Terraform não remove mais. Neste teste o destroy usou o state local e funcionou.
- **`dynamodb_table` deprecado** no backend S3 nesta versão do Terraform; migrar para
  `use_lockfile = true` quando conveniente.
- **`verifica.sh` subestima custo** (sem o piso de 10 MB) — ver 2.2.
- **`DECISOES.md` seção 4** preenchida com os números desta execução.
- **Estado final da conta:** infraestrutura **destruída**. Para a correção ao vivo,
  basta rodar de novo os dois `apply` (seção 1).
- **Rotacionar a access key** usada nesta validação, que foi compartilhada em texto puro.
