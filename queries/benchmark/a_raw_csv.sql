-- [A] A pergunta respondida DIRETO do raw (CSV, sem camadas).
-- Mesmas regras de limpeza e dedup do job Glue, em SQL. Serve de linha de base
-- de custo e de prova cruzada: o resultado tem que bater com a refined.
WITH base AS (
  SELECT
    try_cast(trim(id_venda) AS bigint)   AS id_venda,
    try_cast(trim(id_cliente) AS bigint) AS id_cliente,
    CASE
      WHEN regexp_like(trim(data_venda), '^\d{4}-\d{2}-\d{2}$') THEN try(date(date_parse(trim(data_venda), '%Y-%m-%d')))
      WHEN regexp_like(trim(data_venda), '^\d{4}/\d{2}/\d{2}$') THEN try(date(date_parse(trim(data_venda), '%Y/%m/%d')))
      WHEN regexp_like(trim(data_venda), '^\d{2}-\d{2}-\d{4}$') THEN try(date(date_parse(trim(data_venda), '%d-%m-%Y')))
    END AS data_venda,
    lower(translate(trim(categoria_produto), 'áàâãéêíóôõúüçÁÀÂÃÉÊÍÓÔÕÚÜÇ', 'aaaaeeiooouucAAAAEEIOOOUUC')) AS cat,
    CASE WHEN regexp_like(trim(quantidade), '^-?\d+$') THEN try_cast(trim(quantidade) AS integer) END AS quantidade,
    CASE
      WHEN regexp_like(trim(preco_unitario), '^-?\d+,\d{1,2}$') THEN try_cast(replace(trim(preco_unitario), ',', '.') AS decimal(10,2))
      WHEN regexp_like(trim(preco_unitario), '^-?\d+(\.\d+)?$') THEN try_cast(trim(preco_unitario) AS decimal(10,2))
    END AS preco_unitario,
    regexp_extract("$path", 'vendas_lote_(\d{4}-\d{2})\.csv', 1) AS lote_origem
  FROM "{{DB_RAW}}".vendas_raw
),
validos AS (
  SELECT * FROM base
  WHERE id_venda IS NOT NULL AND id_cliente IS NOT NULL AND data_venda IS NOT NULL
    AND cat IN ('eletronicos','moda','casa','esportes','livros','beleza','alimentos')
    AND quantidade > 0 AND preco_unitario > 0
),
dedup AS (
  SELECT *, row_number() OVER (
    PARTITION BY id_venda
    ORDER BY lote_origem DESC, data_venda DESC, preco_unitario DESC, quantidade DESC, cat, id_cliente
  ) AS rn
  FROM validos
)
SELECT
  date_format(data_venda, '%Y-%m')                     AS ano_mes,
  upper(substr(cat, 1, 1)) || substr(cat, 2)           AS categoria_produto,
  SUM(CAST(quantidade * preco_unitario AS decimal(12,2))) AS faturamento_bruto,
  SUM(quantidade)                                       AS qtd_itens_vendidos
FROM dedup
WHERE rn = 1 AND {{FILTRO_RAW}}
GROUP BY 1, 2
ORDER BY 1, 2
