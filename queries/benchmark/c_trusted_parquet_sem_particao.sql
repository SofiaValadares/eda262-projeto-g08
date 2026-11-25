-- [C] Trusted em Parquet/Snappy, SEM partição (isola o efeito do formato).
SELECT ano_mes, categoria_produto, SUM(valor_total) AS faturamento_bruto, SUM(quantidade) AS qtd_itens_vendidos
FROM "{{DB_TRUSTED}}".bench_trusted_parquet
WHERE {{FILTRO}}
GROUP BY 1, 2
ORDER BY 1, 2
