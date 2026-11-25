# Benchmark de custo — mesma pergunta, 5 arranjos de armazenamento

- Data: 2026-11-25T14:22Z · Região: us-east-1 · Workgroup: `eda262-g08-workgroup`
- Preço Athena: USD 5/TB, piso de 10 MB faturados por consulta
- Recorte de 1 mês: `ano_mes = '2025-06'`

## Armazenamento

| Arranjo | Bytes no S3 | MiB | Arquivos |
|---|---:|---:|---:|
| [A] raw CSV (sem camadas) | 49972998 | 47.658 | 24 |
| [B] trusted CSV, sem partição (formato Parte 1) | 20224210 | 19.287 | 3 |
| [C] trusted Parquet, sem partição | 20814896 | 19.851 | 3 |
| [D] trusted Parquet particionado | 22742416 | 21.689 | 24 |
| [E] refined Parquet particionado | 44615 | 0.043 | 24 |

## Consulta da pergunta de negócio

| Arranjo | Recorte | QueryExecutionId | Bytes varridos | MiB | USD faturado | Linhas | ms |
|---|---|---|---:|---:|---:|---:|---:|
| [A] raw CSV (sem camadas) | ano inteiro | `17d0c271-1764-4dad-8a50-7d74a6b50585` | 49972998 | 47.658 | 0.00022725 | 168 | 3363
 |
| [A] raw CSV (sem camadas) | 1 mês | `19eded6a-0bfe-4681-83e1-9667bf735155` | 49972998 | 47.658 | 0.00022725 | 7 | 3433
 |
| [B] trusted CSV, sem partição (formato Parte 1) | ano inteiro | `b1b351ec-1fe7-4b32-bf60-3aabca15f9ea` | 20223970 | 19.287 | 0.00009197 | 168 | 1988
 |
| [B] trusted CSV, sem partição (formato Parte 1) | 1 mês | `0103eaa9-eb5b-42bd-a245-3a3db05dbc34` | 20223970 | 19.287 | 0.00009197 | 7 | 1796
 |
| [C] trusted Parquet, sem partição | ano inteiro | `0825aa5d-91e1-4e82-9564-c651b5f12edc` | 6855948 | 6.538 | 0.00004768 | 168 | 970
 |
| [C] trusted Parquet, sem partição | 1 mês | `505d03d5-b756-4130-bda1-06f58e4e4bc5` | 6856085 | 6.538 | 0.00004768 | 7 | 745
 |
| [D] trusted Parquet particionado | ano inteiro | `b7021ce8-320f-496e-b825-90cc02aab6c8` | 6708475 | 6.398 | 0.00004768 | 168 | 1083
 |
| [D] trusted Parquet particionado | 1 mês | `894b2e7a-655d-4049-9726-2e3544d49b3b` | 265618 | 0.253 | 0.00004768 | 7 | 711 |
| [E] refined Parquet particionado | ano inteiro | `131ae5db-a969-4d0e-9f65-b6d1554e624f` | 6371 | 0.006 | 0.00004768 | 168 | 695
 |
| [E] refined Parquet particionado | 1 mês | `13ca065b-9b28-4bad-af5e-76eb1807289a` | 269 | 0.000 | 0.00004768 | 7 | 716
 |

> A linha [D] 1 mês foi remedida isoladamente: a 1ª tentativa caiu por falha de rede
> ("Could not connect to the endpoint URL"), não por erro da consulta.

## Prova cruzada

IGUAIS — 168 linhas (categoria x mês) idênticas entre [A] raw e [E] refined.
