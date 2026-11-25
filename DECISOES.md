# DECISOES.md — Decisões de engenharia (g08 · varejo-ecommerce)

**Pergunta de negócio:** *qual o faturamento bruto (receita) e a quantidade de itens vendidos, por categoria de produto e por mês?*

Documento **fechado** da Parte 2 (AV2). Cada decisão traz o número medido que a sustenta e o
arquivo de evidência de onde ele saiu. Medições de 2026-11-25, conta da turma, `us-east-1`,
workgroup `eda262-g08-workgroup`, preço Athena USD 5/TB com piso de 10 MB por consulta.

| # | Decisão | Escolha | Número que comprova |
|---|---|---|---|
| 1 | Grão | trusted: 1 item vendido · refined: 1 categoria × 1 mês | 1.173.520 linhas = 1.173.520 `id_venda` distintos · refined = 168 linhas = 7 categorias × 24 meses |
| 2 | Chaves | `id_venda` (trusted) · (`ano_mes`, `categoria_produto`) (refined) | 22.791 duplicatas removidas por `id_venda`; 0 duplicata após 4 execuções |
| 3 | Partição | `ano_mes` (mensal) em trusted e refined | consulta de 1 mês: 6,54 MiB sem partição → **0,25 MiB** com partição (26× menos) |
| 4 | Formato | CSV no raw · Parquet/Snappy em trusted e refined | pergunta (ano inteiro): 19,29 MiB em CSV → **6,40 MiB** em Parquet (3× menos) |
| 5 | Custo | **meta: ≤ 10 MiB varridos (= piso, USD 0,00004768) por execução** | refined: **6.371 B** → meta cumprida com folga de 1.645×; raw CSV: 47,66 MiB (USD 0,00022725) |
| 6 | Camadas + acesso | raw / trusted / refined, 1 database por camada, Lake Formation | analista: refined OK, trusted e raw **negados**; engenheiro: as 3 OK |
| 7 | Ingestão | job Glue idempotente, overwrite dinâmico de partição | 2ª execução: mesmas 1.173.520 linhas e R$ 2.873.905.622,54; backfill de 2024-01 restaurou 41.603 linhas exatas |

---

## 0. Dados

O dataset da Parte 1 (100 linhas, 3 KB) fica sempre abaixo do piso de 10 MB do Athena: nenhum
ganho de formato ou partição aparece no custo. Na Parte 2 o raw é gerado por
[`gerar_raw.py`](parte-2/ingestao/gerar_raw.py): mesmo schema e mesma família de sujeira, em volume.

| Medida | Valor |
|---|---|
| Lotes (1 CSV por mês, 2024-01 a 2025-12) | 24 |
| Linhas no raw | 1.223.286 |
| Tamanho do raw | 49.972.998 B (47,66 MiB) |
| Determinismo | seed fixa; duas gerações → mesmo sha256 `aab80e0dd8179024…` |

Sujeira e tratamento (relatório do job, [`01_carga_inicial_job.txt`](evidencias/parte-2/01_carga_inicial_job.txt)):

| Regra (raw → trusted) | Tratamento | Linhas |
|---|---|---:|
| Preço ≤ 0 ou não numérico | descarta | 15.870 |
| Quantidade ≤ 0 ou não numérica (`"dois"`, `""`) | descarta | 6.150 |
| Data vazia/inválida (`31-02-2024`, `ontem`) | descarta | 2.489 |
| Categoria desconhecida (`N/A`, `???`) | descarta | 2.466 |
| Data em 3 formatos (`YYYY-MM-DD`, `YYYY/MM/DD`, `DD-MM-YYYY`) | normaliza para `date` | — |
| Categoria com caixa/acento/espaço (`" eletrônicos "`, `MODA`) | normaliza para 7 nomes canônicos | — |
| Preço com vírgula decimal (`"123,45"`) | converte (linha válida) | — |
| Duplicata no lote e reenvio no lote seguinte | dedup por `id_venda` | 22.791 |
| **Resultado** | | **1.173.520** |

---

## 1. Grão

| Tabela | Grão | Linhas medidas |
|---|---|---:|
| `eda262-g08-raw.vendas_raw` | 1 linha **recebida** (pode repetir, pode estar suja) | 1.223.286 |
| `eda262-g08-trusted.vendas_trusted` | 1 **item vendido** (linha de venda) | 1.173.520 |
| `eda262-g08-refined.faturamento_categoria_mes` | 1 **categoria × 1 mês** | 168 |

**Por quê.** A pergunta soma receita (`quantidade × preco_unitario`) e itens por categoria e mês.
Com o grão de item na trusted, essa soma é um `GROUP BY` sem risco de contar em dobro, e um
pedido com itens de categorias diferentes continua divisível. A refined guarda a resposta já
agregada, que é o que o consumidor lê.

**Prova.** A pergunta calculada **direto do raw** (SQL com as mesmas regras, [`a_raw_csv.sql`](queries/benchmark/a_raw_csv.sql))
e lida da refined devolve **as mesmas 168 linhas, idênticas** ([`benchmark_custo.md`](evidencias/parte-2/benchmark_custo.md), "Prova cruzada").
O `verifica.sh` também confere `SUM(valor_total)` da trusted = `SUM(faturamento_bruto)` da refined.

## 2. Chaves

| Tabela | Chave | Garantia medida |
|---|---|---|
| trusted | `id_venda` (chave de negócio) | `COUNT(*) = COUNT(DISTINCT id_venda)` = 1.173.520, antes e depois de reexecuções |
| refined | (`ano_mes`, `categoria_produto`) | 168 = 7 × 24, uma linha por par |

**Desempate da dedup** (determinístico, para a reexecução dar o mesmo resultado): ganha a versão do
**lote mais recente** (`lote_origem DESC`), depois data, preço, quantidade, categoria e cliente.
A coluna `lote_origem` fica na trusted como linhagem.

**A dedup roda sobre o raw inteiro, antes de filtrar partições.** Se rodasse só dentro da partição
reprocessada, uma venda reenviada com data corrigida poderia existir em duas partições.

## 3. Partição

**Escolha:** `ano_mes` (`yyyy-MM`) em trusted e refined, com **projeção de partição** no Glue
Catalog (`projection.ano_mes.type = date`). Raw **sem** partição: guarda os lotes como chegaram.

| Medida | Valor |
|---|---|
| Partições na trusted / refined | 24 / 24 |
| Arquivos na trusted | 24 (1 por partição), 22.742.416 B → média **0,90 MiB/arquivo** |
| Linhas por partição | 39.096 (fev/25) a 66.010 (nov/24) |
| Pergunta, 1 mês, Parquet **sem** partição [C] | 6.856.085 B (6,54 MiB) |
| Pergunta, 1 mês, Parquet **com** partição [D] | **265.618 B (0,25 MiB)** → 26× menos |

**Por que mensal e não diária.** A pergunta é mensal: o filtro natural é um mês ou um intervalo de
meses, e a poda acontece exatamente nesse corte. Partição diária geraria ~731 arquivos de ~31 KB
(22,7 MB ÷ 731). Arquivos tão pequenos aumentam o custo de listar e abrir objetos sem reduzir
nada na consulta mensal. Com ~0,9 MiB por arquivo ainda estamos abaixo do ideal do Parquet
(dezenas a centenas de MB); se o volume crescer 100×, a partição mensal chega a ~90 MiB por
arquivo, que é a faixa certa.

**Por que projeção de partição.** O Athena calcula as partições pelo template, sem `MSCK REPAIR`,
crawler ou `BatchCreatePartition`. Partição nova escrita pelo job aparece na hora, e o job não
precisa de permissão de escrita no catálogo nem no Lake Formation.

## 4. Formato

| Camada | Formato | Motivo |
|---|---|---|
| raw | CSV, como recebido | auditoria: preserva o original byte a byte (bucket versionado) |
| trusted | Parquet + Snappy | colunar e tipado: a consulta lê só as colunas que usa |
| refined | Parquet + Snappy | idem; 168 linhas em 44.615 B |

Mesma pergunta, mesmo conteúdo, ano inteiro ([`benchmark_custo.md`](evidencias/parte-2/benchmark_custo.md)):

| Arranjo | Bytes varridos | MiB |
|---|---:|---:|
| [B] trusted em **CSV** (formato da Parte 1) | 20.223.970 | 19,29 |
| [C] trusted em **Parquet**, sem partição | 6.855.948 | 6,54 |

**Parquet varre 3× menos.** O armazenamento total quase não muda (19,3 MiB em CSV vs 19,9 MiB em
Parquet): `id_venda`, `id_cliente`, `lote_origem` e `processado_em` têm valores quase todos
distintos e não comprimem. O ganho vem de a pergunta ler só `categoria_produto`, `valor_total`,
`quantidade` e `ano_mes`, não de arquivo menor.

Os tipos também mudam: na Parte 1 o CSV obrigava tudo `string` + `CAST` na consulta. Agora a
trusted tem `bigint`, `date`, `int` e `decimal(10,2)`/`decimal(12,2)` no próprio arquivo.

## 5. Custo — meta declarada e cumprida

> **Meta:** a pergunta de negócio varre **no máximo 10 MiB (10.485.760 B) por execução**. Isso a
> mantém no piso de faturamento do Athena: **USD 0,00004768 por consulta**. Vale para a camada
> de consumo (refined) e para a consulta mensal na trusted.

| Consulta | Bytes varridos | % da meta | USD faturado | Status |
|---|---:|---:|---:|---|
| Pergunta na **refined**, ano inteiro [E] | **6.371** | 0,06% | 0,00004768 | ✅ cumprida |
| Pergunta na refined, 1 mês | 269 | 0,003% | 0,00004768 | ✅ |
| Pergunta na **trusted**, 1 mês [D] | 265.618 | 2,5% | 0,00004768 | ✅ cumprida |
| Pergunta na trusted, ano inteiro [D] | 6.708.475 | 64% | 0,00004768 | ✅ |
| *Referência:* trusted em CSV [B] | 20.223.970 | 193% | 0,00009197 | ❌ estoura |
| *Referência:* direto do raw CSV [A] | 49.972.998 | 477% | **0,00022725** | ❌ estoura |
| *Parte 1:* CSV de 100 linhas | 3.296 | — | 0,00004768 | (piso; amostra pequena) |

- **Bytes:** raw CSV → refined = 49.972.998 B → 6.371 B, **99,99% a menos**.
- **Custo por consulta:** USD 0,00022725 → 0,00004768, **79% a menos**. O piso de 10 MB limita
  a redução em dólar; abaixo dele não há como ficar mais barato.
- **Em escala:** 1.000 consultas por dia durante um ano custam USD 17,40 pela refined contra
  USD 82,95 pelo raw. Com 100× o volume de hoje, o raw passaria a USD 0,0227 por consulta,
  enquanto a refined (168 linhas por 2 anos) continua no piso. *(Extrapolação pela fórmula; não
  foi medida.)*
- **Guarda de custo:** o workgroup cancela qualquer consulta que passe de **1 GiB** varrido
  (`bytes_scanned_cutoff_per_query`), para nenhum erro de SQL virar conta alta.
- **Custo da ingestão:** job Glue com 2 workers G.1X levou 93–138 s por execução
  (2 DPU × 138 s × USD 0,44/DPU-h ≈ **USD 0,034** no pior caso).

O `verifica.sh` roda a pergunta e imprime `PASSA` só se os bytes ficarem ≤ meta.

## 6. Camadas e controle de acesso (Lake Formation)

| Persona (role IAM) | raw | trusted | refined |
|---|:---:|:---:|:---:|
| `eda262-g08-engenheiro` | SELECT | SELECT | SELECT |
| `eda262-g08-analista` | — | — | SELECT |
| `eda262-g08-glue-etl` (job) | S3 leitura | S3 escrita | S3 escrita |

- As duas personas têm **a mesma** política IAM: Athena, leitura do catálogo e
  `lakeformation:GetDataAccess`. **Nenhuma tem permissão S3 nos buckets do lake.** O que separa
  uma da outra é **só** o Lake Formation.
- As 3 localizações S3 são **registradas** no Lake Formation com uma role própria
  (`eda262-g08-lf-registro`). O Athena recebe credencial temporária do LF apenas para tabelas com GRANT.
- `IAM_ALLOWED_PRINCIPALS` é revogado das 3 tabelas logo após a criação. Sem isso, o default da
  conta deixaria qualquer usuário IAM ler e o LF não decidiria nada.
- O job não passa pelo LF: tem IAM de menor privilégio por camada (raw só leitura, nunca altera o que chegou).
- **Conta compartilhada:** o Terraform não toca em `data_lake_settings` (admins e defaults da conta
  inteira) e não precisa de Data Lake Admin. Quem cria a tabela recebe grant option sobre ela.
  Por isso os GRANTs são por tabela nomeada; o wildcard "todas as tabelas" exigiria admin.

Prova no `verifica.sh` ([`04_verifica.txt`](evidencias/parte-2/04_verifica.txt)): as 6 combinações
persona × camada dão o resultado esperado, e o analista também não consegue listar o bucket refined
direto no S3.

## 7. Ingestão idempotente e backfill

**Mecanismo.** O job recalcula cada partição a partir do raw **inteiro**, com dedup determinística,
e **substitui** a partição (`partitionOverwriteMode=dynamic`). Não existe *append*. Subir o mesmo
lote de novo sobrescreve a mesma chave S3 no raw. `max_concurrent_runs = 1` impede duas execuções
de disputarem a mesma partição.

**Reexecução** ([`02_idempotencia_reexecucao.txt`](evidencias/parte-2/02_idempotencia_reexecucao.txt)): mesmo job, mesmo raw, 2 vezes.

| | Linhas trusted | `id_venda` distintos | SUM(valor_total) | Arquivos | Linhas refined |
|---|---:|---:|---:|---:|---:|
| Após execução 1 | 1.173.520 | 1.173.520 | 2.873.905.622,54 | 24 | 168 |
| Após execução 2 | 1.173.520 | 1.173.520 | 2.873.905.622,54 | 24 | 168 |

Só `processado_em` mudou (14:06:04 → 14:09:52), prova de que os dados foram reescritos e não somados.

**Backfill** ([`03_backfill_particao.txt`](evidencias/parte-2/03_backfill_particao.txt)): a partição 2024-01 é apagada da trusted e da refined (simula perda), depois `pipeline.sh backfill 2024-01`.

| Momento | Linhas 2024-01 | SUM 2024-01 | Total trusted | `processado_em` 2024-02 / 2025-12 |
|---|---:|---:|---:|---|
| Antes | 41.603 | 100.948.656,26 | 1.173.520 | 14:09:52 |
| Partição perdida | 0 | — | 1.131.917 | 14:09:52 |
| Após backfill | **41.603** | **100.948.656,26** | **1.173.520** | 14:09:52 (intactas) |
| Backfill de novo | 41.603 | 100.948.656,26 | 1.173.520 | 14:09:52 |

O `verifica.sh` repete o teste ao vivo sem apagar nada: reprocessa 2024-01 e confere que as 24
contagens ficaram iguais, que só 2024-01 ganhou `processado_em` novo e que não há duplicata.

**Limite conhecido.** Se todas as linhas de uma partição sumirem do raw, o overwrite dinâmico não
esvazia essa partição, porque não há linha a escrever. No cenário (lotes só crescem) isso não
acontece; tratar exigiria apagar explicitamente as partições pedidas antes de escrever.

---

## 8. Decisões de IaC (Partes 1 e 2)

| Decisão | Motivo |
|---|---|
| 3 módulos: `lake`, `ingestao`, `governanca` | cada um com uma responsabilidade; o root só liga as saídas |
| Schema declarado no Terraform, sem crawler | contrato explícito; o `verifica.sh` checa que não há crawler |
| Backend S3 + DynamoDB, state `parte-2/terraform.tfstate` | mesmo bootstrap da Parte 1, state separado |
| Workspace `default` = nomes canônicos; outros ganham sufixo | evita colisão de nomes globais |
| `default_tags` no provider | as 3 tags obrigatórias em todo recurso |
| `force_destroy` em buckets e workgroup; log group do job criado pelo Terraform; role própria no registro LF | `destroy` sem órfão |
| Raw versionado; trusted/refined sem versão | raw é a fonte de verdade; as outras camadas são reconstruíveis pelo job |
