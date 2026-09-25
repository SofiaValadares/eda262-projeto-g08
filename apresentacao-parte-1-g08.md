# Apresentação AV1 — Grupo 08 (g08)

**Arquivo-fonte para exportação PDF:** `apresentacao-parte-1-g08.pdf`  
**Duração:** pitch estrito de **5 minutos**  
**Identidade visual CESAR School (orientação):**

- Fonte: **Arial**
- Máximo ≈ **5 tópicos** por slide
- Cor **laranja** apenas para acentos/destaques (títulos auxiliares, números-chave)
- Fundo claro; texto escuro; pouco ruído visual

---

## Slide 1 — Cenário de Varejo e Pergunta Analítica

**Título:** Varejo / E-Commerce em Batch — g08

- Domínio: vendas online processadas em lote (`varejo-ecommerce`)
- Pergunta: **faturamento bruto** e **qtd. de itens** por **categoria** e **mês**
- Métrica: `SUM(qtd × preço)` + `SUM(qtd)`
- Sujeira no raw: casing de categoria, datas texto, preços ≤ 0, duplicatas
- Entrega: prefixo `eda262-g08-` · tags `turma` / `grupo` / `projeto`

> *Fala (≈60s):* contextualizar o negócio, ler a pergunta analítica e citar as sujeiras como motivação da camada trusted.

---

## Slide 2 — Arquitetura IaC

**Título:** Terraform → S3 Trusted · Glue Catalog · Athena

- Backend remoto: S3 state + DynamoDB lock (+ workspaces)
- Lake trusted: `eda262-g08-lake-trusted`
- Catálogo: `eda262-g08-catalog` + tabela `venda_varejo_trusted`
- **Schema declarado no Terraform — sem Glue Crawler**
- Workgroup: `eda262-g08-workgroup` (resultados em bucket dedicado)

> *Fala (≈60s):* desenhar o fluxo raw→trusted→Athena; enfatizar IaC e ausência de crawler.

---

## Slide 3 — Demonstração e Evidências

**Título:** Deploy · SQL · Custo · Destroy limpo

- `terraform init/apply` sobe 100% da infra versionada
- Query em `queries/consulta_analitica.sql` responde a pergunta
- Aceite: `./verificacao/verifica.sh` → `[PASSA]` / `[FALHA]`
- Custo Athena medido (MB varridos → USD) registrado em `DECISOES.md`
- `terraform destroy` com `force_destroy` — sem recursos órfãos

> *Fala (≈60s):* mostrar evidência rápida (output/terminal ou print); citar destroy limpo.

---

## Slide 4 — Decisões de Engenharia

**Título:** Grão da Tabela e Números de Custo

- **Grão:** 1 registro = 1 **item vendido** (linha de item)
- Por quê: agregação por categoria/mês sem double-count
- Tipagem CSV: OpenCSVSerDe + `CAST` na query (confiável no Athena)
- Custo: **USD 5,00 / TB** varrido → dataset AV1 ≪ US$ 0,01
- Tabela de medição em `DECISOES.md` (atualizar com QueryExecutionId real)

> *Fala (≈60s):* defender o grão; mostrar 1 número de custo medido/simulado.

---

## Slide 5 — Guia de Defesa Individual

**Título:** Perguntas Prováveis do Docente

| Pergunta | Resposta curta |
|----------|----------------|
| Por que não usaram Crawler? | Schema é contrato; Terraform declara tipos/local — evita drift e atende o enunciado. |
| Qual o grão? | Um registro por item vendido; permite `SUM(qtd*preço)` por categoria/mês. |
| Como as tags são garantidas? | `default_tags` no provider AWS + checagem no `verifica.sh`. |
| O destroy deixa órfãos? | Não: `force_destroy` em buckets/workgroup; tudo criado pelo Terraform. |
| Como mediram custo? | `DataScannedInBytes` do Athena × US$ 5/TB; script imprime MB e USD. |

> *Fala (≈60s):* cada membro ensaiar 1 resposta; fechar com “infra reproduzível e mensurável”.

---

## Checklist de ensaio (5 min)

1. Slide 1 — cenário + pergunta (1 min)  
2. Slide 2 — arquitetura IaC (1 min)  
3. Slide 3 — evidências ao vivo/print (1 min)  
4. Slide 4 — grão + custo (1 min)  
5. Slide 5 — uma pergunta de defesa (1 min)

**Exportação:** abrir este roteiro no Keynote/PowerPoint/Google Slides (Arial), aplicar laranja só em destaques, exportar `apresentacao-parte-1-g08.pdf`.
