-- Consulta analítica — Parte 2 (cenário varejo-ecommerce / g08)
-- Pergunta: Qual o faturamento total (receita bruta) e a quantidade total
--           de itens vendidos, por categoria de produto e por mês?
--
-- Camada:  refined  (database eda262-g08-refined, contexto da execução)
-- Tabela:  faturamento_categoria_mes — Parquet/Snappy, particionada por ano_mes
-- Grão:    1 registro = 1 categoria x 1 mês (já agregado pelo job a partir da trusted)
-- Custo:   meta <= 10 MiB varridos por execução (ver DECISOES.md §5)

SELECT
  ano_mes,
  categoria_produto,
  faturamento_bruto,
  qtd_itens_vendidos
FROM faturamento_categoria_mes
ORDER BY
  ano_mes,
  categoria_produto;
