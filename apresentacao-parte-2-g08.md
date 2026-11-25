# Apresentação AV2 — Grupo 08 (g08)

**Exportar como:** `apresentacao-parte-2-g08.pdf` · **Tempo:** 5 min (corta em 5:00) · **Forma:** Arial, um título por slide, ≤ 5 tópicos, marcadores quadrados, laranja só em números e palavras-chave, gráfico monocromático com a série principal em laranja.

---

## Slide 1 — Mesma pergunta, lake de verdade  *(≈45 s)*

- Cenário `varejo-ecommerce`: vendas online processadas em lote
- Pergunta: **faturamento bruto** e **itens vendidos** por **categoria** e **mês**
- Parte 1 → Parte 2: de 1 tabela CSV para **3 camadas em Parquet particionado**
- Volume: **1.223.286** linhas raw em 24 lotes mensais (**47,7 MiB**)
- Sujeira real: 3 formatos de data, acento/caixa, preço ≤ 0, **22.791 duplicatas**

> *Fala:* a pergunta é a mesma da AV1; o que muda é o que o lake aguenta: custo, reprocessamento e acesso.

## Slide 2 — Arquitetura  *(≈60 s)*

Diagrama: `raw (CSV) → job Glue → trusted (Parquet, ano_mes) → refined (Parquet, ano_mes) → Athena`

- 100% Terraform, 3 módulos: **lake**, **ingestao**, **governanca** · backend S3 + DynamoDB
- 1 bucket e 1 database por camada: `eda262-g08-lake-{raw,trusted,refined}`
- Schema declarado, **sem crawler**; projeção de partição (sem MSCK)
- **Lake Formation:** analista lê só refined; engenheiro lê as 3
- Workgroup com guarda de **1 GiB** por consulta

## Slide 3 — Demonstração  *(≈75 s)*

- `terraform apply` → `pipeline.sh carga` → `verifica.sh`: **55/55 PASSA**
- Pergunta na refined: **168 linhas**, **6.371 B** varridos, **USD 0,00004768**
- Analista na trusted/raw: **negado** (o LF esconde a tabela)
- Backfill de 2024-01 apagada: volta com **41.603** linhas exatas; outras 23 intactas
- `terraform destroy` + `verifica.sh --destroyed`: nada sobra

> *Fala:* mostrar o print do verifica.sh e o do backfill (evidencias/parte-2/).

## Slide 4 — Decisões com número  *(≈75 s)*

Gráfico de barras (MiB varridos, pergunta ano inteiro; refined em laranja):
raw CSV 47,66 · trusted CSV 19,29 · Parquet 6,54 · Parquet particionado 6,40 · **refined 0,006**

- **Formato:** CSV → Parquet = **3× menos** bytes (19,29 → 6,54 MiB)
- **Partição** mensal: 1 mês cai de 6,54 para **0,25 MiB** (**26×**)
- **Grão/chave:** item vendido, `id_venda` único: **1.173.520 = 1.173.520** distintos
- **Meta de custo ≤ 10 MiB por consulta:** refined usa **0,06%** dela
- Raw → refined: **99,99%** menos bytes; **79%** menos USD (limitado pelo piso de 10 MB)

## Slide 5 — Idempotência  *(≈45 s)*

- Overwrite **dinâmico** de partição + dedup no raw inteiro → nunca há *append*
- Job 2× seguidas: **1.173.520** linhas e **R$ 2.873.905.622,54** nas duas
- Só `processado_em` muda: dado reescrito, não somado
- Prova cruzada: pergunta calculada direto do raw == refined (**168/168** linhas)

---

## Defesa individual — perguntas prováveis

| Pergunta | Resposta curta (com número) |
|---|---|
| Por que `ano_mes` e não dia? | A pergunta é mensal. Diária daria ~731 arquivos de ~31 KB; mensal são 24 de ~0,9 MiB. A consulta mensal cai de 6,54 para 0,25 MiB. |
| Parquet não diminuiu o armazenamento? | Quase não (19,3 vs 19,9 MiB): ids e timestamp são quase todos distintos. O ganho é ler só 4 colunas: 3× menos varrido. |
| Qual é a meta de custo? | ≤ 10 MiB por execução, o piso faturável (USD 0,00004768). Refined: 6.371 B. Raw: 47,66 MiB = 4,8× o piso. |
| Como garantem que não duplica? | Partição recalculada do raw inteiro e substituída; dedup por `id_venda` com desempate fixo; `max_concurrent_runs = 1`. |
| E se o lote chegar atrasado? | O job lê o raw inteiro; a venda vai para a partição da data dela. `pipeline.sh lote M` reprocessa M e M-1. |
| Como o Lake Formation decide? | As duas personas têm o mesmo IAM e nenhum S3. Locais registrados no LF, `IAM_ALLOWED_PRINCIPALS` revogado das tabelas, GRANT por tabela. |
| Por que não mexeram nos admins do LF? | A conta é compartilhada: `data_lake_settings` é da conta toda e o destroy apagaria a configuração dos outros grupos. Quem cria a tabela pode conceder nela. |
| O destroy deixa órfão? | Não: `force_destroy`, log group criado pelo Terraform, role própria no LF. `verify --destroyed` confere por tag e por nome. |

**Ensaio:** 5 slides × ~1 min. Cada integrante decora uma linha da tabela acima.
