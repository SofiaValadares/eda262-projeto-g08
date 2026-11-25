#!/usr/bin/env python3
"""
Gerador determinístico da camada RAW (cenário varejo-ecommerce / g08).

Simula o sistema de origem: um lote CSV por mês (2024-01 .. 2025-12), no mesmo
layout da Parte 1, com a mesma família de sujeira (e um pouco mais):

  * categoria com caixa inconsistente, acento e espaços  ("eletrônicos ", "MODA")
  * data em 3 formatos                                   (YYYY-MM-DD, YYYY/MM/DD, DD-MM-YYYY)
  * data inválida ou vazia                               ("31-02-2024", "")
  * preço <= 0 e preço com vírgula decimal               ("0.0", "-12.50", "123,45")
  * quantidade <= 0 ou não numérica                      ("0", "-1", "dois")
  * categoria desconhecida                               ("N/A", "")
  * duplicatas no mesmo lote e reenvio no lote seguinte  (mesmo id_venda)
  * chegada atrasada: venda do mês M que chega no lote M+1

Determinístico (seed fixa): rodar de novo gera arquivos idênticos byte a byte,
então o avaliador reproduz exatamente os números do DECISOES.md.

Uso:
  python3 gerar_raw.py [--saida DIR] [--linhas-por-lote N]
Só usa a biblioteca padrão.
"""
from __future__ import annotations

import argparse
import calendar
import csv
import hashlib
import os
import random
from datetime import date

SEED = 262_008
LOTES = [f"{a}-{m:02d}" for a in (2024, 2025) for m in range(1, 13)]
HEADER = ["id_venda", "id_cliente", "data_venda", "categoria_produto", "quantidade", "preco_unitario"]

# categoria canônica -> (peso, faixa de preço)
CATEGORIAS = {
    "Eletronicos": (18, (80.0, 4500.0)),
    "Moda": (22, (25.0, 600.0)),
    "Casa": (16, (15.0, 1800.0)),
    "Esportes": (12, (20.0, 1500.0)),
    "Livros": (12, (15.0, 250.0)),
    "Beleza": (12, (10.0, 400.0)),
    "Alimentos": (8, (5.0, 180.0)),
}
ACENTO = {"Eletronicos": "Eletrônicos"}

# sazonalidade simples (multiplicador de volume por mês)
SAZONAL = {1: 0.85, 2: 0.80, 3: 0.90, 4: 0.90, 5: 1.00, 6: 0.95,
           7: 0.95, 8: 1.00, 9: 0.95, 10: 1.05, 11: 1.35, 12: 1.30}


def suja_categoria(rng: random.Random, cat: str) -> str:
    r = rng.random()
    base = ACENTO.get(cat, cat) if rng.random() < 0.5 else cat
    if r < 0.70:
        return cat
    if r < 0.80:
        return base.lower()
    if r < 0.88:
        return base.upper()
    if r < 0.95:
        return f" {base} "
    return base.lower() + " "


def formata_data(rng: random.Random, d: date) -> str:
    r = rng.random()
    if r < 0.70:
        return d.strftime("%Y-%m-%d")
    if r < 0.85:
        return d.strftime("%Y/%m/%d")
    return d.strftime("%d-%m-%Y")


def gera_lote(rng: random.Random, lote: str, n_base: int, prox_id: int, atrasadas: list, reenvio: list):
    """Retorna (linhas, prox_id, atrasadas_para_proximo_lote, reenvio_para_proximo_lote)."""
    ano, mes = map(int, lote.split("-"))
    dias = calendar.monthrange(ano, mes)[1]
    n = int(n_base * SAZONAL[mes])
    cats = list(CATEGORIAS)
    pesos = [CATEGORIAS[c][0] for c in cats]

    linhas: list[list[str]] = []
    prox_atrasadas: list[list[str]] = []
    for _ in range(n):
        id_venda = prox_id
        prox_id += 1
        cat = rng.choices(cats, pesos)[0]
        lo, hi = CATEGORIAS[cat][1]
        d = date(ano, mes, rng.randint(1, dias))
        linha = [
            str(id_venda),
            str(rng.randint(1000, 60_999)),
            formata_data(rng, d),
            suja_categoria(rng, cat),
            str(rng.choices(range(1, 11), [30, 22, 14, 10, 7, 5, 4, 3, 3, 2])[0]),
            f"{rng.uniform(lo, hi):.2f}",
        ]

        # --- sujeira linha a linha ---
        r = rng.random()
        if r < 0.010:
            linha[5] = "0.0"                                   # preço zerado
        elif r < 0.013:
            linha[5] = f"-{rng.uniform(1, 50):.2f}"            # preço negativo
        elif r < 0.023:
            linha[5] = linha[5].replace(".", ",")              # vírgula decimal (válida após limpeza)
        elif r < 0.028:
            linha[4] = rng.choice(["0", "-1", "dois", ""])      # quantidade inválida
        elif r < 0.030:
            linha[3] = rng.choice(["N/A", "", "???"])           # categoria desconhecida
        elif r < 0.032:
            linha[2] = rng.choice(["", "31-02-2024", "2024-13-01", "ontem"])  # data inválida

        # 2% chegam atrasadas (vão no lote seguinte, com data deste mês)
        if rng.random() < 0.02 and lote != LOTES[-1]:
            prox_atrasadas.append(linha)
            continue
        linhas.append(linha)

    # duplicatas dentro do lote (1,5%)
    for linha in rng.sample(linhas, int(len(linhas) * 0.015)):
        linhas.append(list(linha))
    # reenvio: 0,5% das linhas deste lote aparecem de novo no lote seguinte
    prox_reenvio = [list(l) for l in rng.sample(linhas, int(len(linhas) * 0.005))]

    linhas.extend(atrasadas)
    linhas.extend(reenvio)
    rng.shuffle(linhas)
    return linhas, prox_id, prox_atrasadas, prox_reenvio


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    aqui = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--saida", default=os.path.join(aqui, "..", "dados", "raw"))
    ap.add_argument("--linhas-por-lote", type=int, default=50_000)
    args = ap.parse_args()

    os.makedirs(args.saida, exist_ok=True)
    rng = random.Random(SEED)
    prox_id, atrasadas, reenvio = 1, [], []
    total_linhas = total_bytes = 0
    for lote in LOTES:
        linhas, prox_id, atrasadas, reenvio = gera_lote(rng, lote, args.linhas_por_lote, prox_id, atrasadas, reenvio)
        caminho = os.path.join(args.saida, f"vendas_lote_{lote}.csv")
        with open(caminho, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f, lineterminator="\n")
            w.writerow(HEADER)
            w.writerows(linhas)
        tam = os.path.getsize(caminho)
        total_linhas += len(linhas)
        total_bytes += tam

    # impressão digital do conjunto (prova de determinismo)
    h = hashlib.sha256()
    for lote in LOTES:
        with open(os.path.join(args.saida, f"vendas_lote_{lote}.csv"), "rb") as f:
            h.update(f.read())
    print(f"lotes={len(LOTES)} linhas={total_linhas} bytes={total_bytes} "
          f"(~{total_bytes / 1048576:.1f} MiB) ids_unicos={prox_id - 1} sha256={h.hexdigest()[:16]}")
    print(f"saida={os.path.abspath(args.saida)}")


if __name__ == "__main__":
    main()
