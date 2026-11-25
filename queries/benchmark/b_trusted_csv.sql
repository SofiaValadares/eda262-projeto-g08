-- [B] Trusted em CSV, sem partição (o formato da Parte 1), mesmo conteúdo.
SELECT ano_mes, categoria_produto, SUM(valor_total) AS faturamento_bruto, SUM(quantidade) AS qtd_itens_vendidos
FROM "{{DB_TRUSTED}}".bench_trusted_csv
WHERE {{FILTRO}}
GROUP BY 1, 2
ORDER BY 1, 2
