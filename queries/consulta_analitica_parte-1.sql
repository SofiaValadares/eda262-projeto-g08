-- Consulta analítica (cenário varejo-ecommerce / g08)
-- Pergunta: Qual o faturamento total (receita bruta) e a quantidade total
--           de itens vendidos agrupados por categoria de produto e por mês?
--
-- Camada: trusted (Glue: eda262-g08-catalog.venda_varejo_trusted)
-- Grão: 1 registro = 1 item vendido na transação
--
-- Tipagem: OpenCSVSerDe expõe colunas como string; CASTs explícitos abaixo.

SELECT
  categoria_produto,
  date_format(CAST(data_venda AS DATE), '%Y-%m') AS ano_mes,
  SUM(CAST(quantidade AS INTEGER) * CAST(preco_unitario AS DECIMAL(10, 2))) AS faturamento_bruto,
  SUM(CAST(quantidade AS INTEGER)) AS qtd_itens_vendidos
FROM venda_varejo_trusted
GROUP BY
  categoria_produto,
  date_format(CAST(data_venda AS DATE), '%Y-%m')
ORDER BY
  ano_mes,
  categoria_produto;
