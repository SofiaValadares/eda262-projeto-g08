-- [D] Trusted real: Parquet/Snappy particionado por ano_mes (isola o efeito da partição vs [C]).
SELECT ano_mes, categoria_produto, SUM(valor_total) AS faturamento_bruto, SUM(quantidade) AS qtd_itens_vendidos
FROM "{{DB_TRUSTED}}".vendas_trusted
WHERE {{FILTRO}}
GROUP BY 1, 2
ORDER BY 1, 2
