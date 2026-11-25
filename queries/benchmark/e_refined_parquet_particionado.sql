-- [E] Refined real: agregado categoria x mês, Parquet particionado por ano_mes.
SELECT ano_mes, categoria_produto, faturamento_bruto, qtd_itens_vendidos
FROM "{{DB_REFINED}}".faturamento_categoria_mes
WHERE {{FILTRO}}
ORDER BY 1, 2
