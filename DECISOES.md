# DECISOES.md — Arquitetura e Engenharia (AV1 / g08)

**Grupo:** g08  
**Cenário:** varejo-ecommerce  
**Pergunta analítica:** *Qual o faturamento total (receita bruta) e a quantidade total de itens vendidos agrupados por categoria de produto e por mês?*

---

## 1. Grão declarado da tabela trusted

| Aspecto | Decisão |
|---------|---------|
| **Nome da tabela** | `eda262-g08-catalog.venda_varejo_trusted` |
| **Grão** | **Um registro = um item vendido (linha de item da transação)** |
| **Chave de negócio** | `id_venda` (identificador da linha de venda/item) |
| **Não é** | Um registro por pedido agregado, nem por cliente/dia |

### Justificativa

A pergunta analítica exige:

1. **Receita bruta** = `SUM(quantidade * preco_unitario)`
2. **Quantidade total de itens** = `SUM(quantidade)`
3. Agregação por **categoria** e **mês**

Com grão em nível de **item de venda**, a agregação é uma projeção natural (`GROUP BY`), sem risco de double-counting típico de fatos já pré-agregados. Se o grão fosse “pedido” com valor total já sumarizado, perderíamos a composição por categoria quando o pedido misturasse categorias — cenário comum em e-commerce.

### Campos e tipagem semântica

| Campo | Semântica | Observação |
|-------|-----------|------------|
| `id_venda` | Identificador do item/venda | Unicidade na trusted após deduplicação |
| `id_cliente` | Cliente | Dimensão degenerada |
| `data_venda` | Data (YYYY-MM-DD) | Normalizada a partir de formatos sujos |
| `categoria_produto` | Categoria | Title Case canônico |
| `quantidade` | Itens na linha | Inteiro > 0 |
| `preco_unitario` | Preço unitário | Decimal; apenas valores > 0 na trusted |

O schema físico no Glue usa `string` em todas as colunas por restrição do **OpenCSVSerDe** (leitura CSV confiável no Athena). A tipagem semântica é aplicada via `CAST` na consulta — decisão explícita de engenharia para evitar falhas silenciosas de SerDe com tipos `date`/`decimal` em CSV.

---

## 2. Tratamento da sujeira (raw → trusted)

Dataset raw: `data/venda_varejo_raw.csv` (~100 linhas, com sujeiras propositalmente).

| Sujeira | Tratamento na trusted |
|---------|------------------------|
| Categorias com casing inconsistente (`Eletronicos` / `eletronicos` / `ELETRONICOS`) | Normalização para Title Case canônico |
| Datas como texto (`YYYY/MM/DD`, `DD-MM-YYYY`) | Parse e padronização `YYYY-MM-DD` |
| `preco_unitario` ≤ 0 | **Descarte** da linha (não é venda válida para receita) |
| Linhas duplicadas | Deduplicação por `id_venda` (mantém a primeira ocorrência válida) |

Arquivo publicado no lake: `parte-1/files/venda_varejo_trusted.csv` → `s3://eda262-g08-lake-trusted/varejo-ecommerce/`.

> Na AV1 o foco é **schema declarado + consulta**. A transformação raw→trusted está materializada no artefato trusted versionado no repositório (reprodutível), sem Glue Crawler e sem job ETL pesado.

---

## 3. Decisões de IaC

| Decisão | Motivo |
|---------|--------|
| Schema Glue **explícito** no Terraform | Atende requisito; evita crawler (proibido) e drift de tipos |
| `default_tags` no provider AWS | Garante as 3 tags em todos os recursos sem repetição |
| Bucket separado de resultados Athena | Isola dados do lake vs. artefatos efêmeros de query |
| `force_destroy` em S3 e Workgroup | `terraform destroy` limpa 100% sem órfãos |
| Backend S3 + DynamoDB (bootstrap) | State remoto + lock; suporte a workspaces |
| Sem crawler / sem recursos manuais | Tudo versionado; destroy previsível |

---

## 4. Custo por consulta medido no Athena

Fórmula oficial Athena (preço sob demanda clássico):

\[
\text{Custo USD} = \frac{\text{Bytes varridos}}{2^{40}} \times 5{,}00
\]

(USD **5,00 por TB** varrido; mínimo prático frequentemente observado em queries minúsculas.)

### Tabela de medição (preencher/atualizar após execução real)

| Data | QueryExecutionId | Workgroup | Bytes varridos | MB varridos | Custo estimado (USD) | Observação |
|------|------------------|-----------|----------------|-------------|----------------------|------------|
| _a preencher_ | _a preencher_ | `eda262-g08-workgroup` | _CLI_ | _CLI_ | _fórmula_ | Rodar `verifica.sh` ou Console |
| 2026-03-25* | *(simulado)* | `eda262-g08-workgroup` | 12 288 | ≈ 0,0117 | ≈ 0,00000006 | CSV trusted ~88 linhas; volume típico de dataset AV1 |

\*Linha simulada com volume realista para o dataset do repositório (~poucos KB no S3; Athena reporta bytes efetivamente lidos). **Substituir** pelos valores do `get-query-execution` após o deploy na conta do grupo.

### Como atualizar os números reais

```bash
# Após ./verificacao/verifica.sh — o script já imprime MB e USD.
# Ou manualmente:
aws athena get-query-execution \
  --query-execution-id <ID> \
  --query 'QueryExecution.Statistics.DataScannedInBytes'
```

Custo simulado realista para esta AV1: **≪ USD 0,01** por execução (dataset de laboratório). O valor pedagógico está em **medir e registrar**, não no montante absoluto.

---

## 5. Resposta esperada da consulta

A query em `queries/consulta_analitica.sql` retorna:

- `categoria_produto`
- `ano_mes` (`YYYY-MM`)
- `faturamento_bruto`
- `qtd_itens_vendidos`

Ordenação: mês → categoria. Isso responde diretamente à pergunta analítica do cenário.
