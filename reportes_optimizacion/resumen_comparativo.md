# Resumen comparativo — parser_opt vs parser_opt_a

Generado: Tue Sep 29 01:46:41 -03 2026

## Tamaño: original

| Binario | cycles | instructions | IPC | cache-miss % | task-clock (msec) |
|---|---|---|---|---|---|
| parser_opt | 700574402 | 1531638059 | 2.19 | 50.76% | 219.42 |
| parser_opt_a | 368128289 | 617768771 | 1.68 | 74.18% | 119.35 |

## Tamaño: 1k

| Binario | cycles | instructions | IPC | cache-miss % | task-clock (msec) |
|---|---|---|---|---|---|
| parser_opt | 3111502 | 2875944 | 0.92 | 52.69% | 1.04 |
| parser_opt_a | 1623392 | 1304364 | 0.80 | 49.18% | 0.55 |

## Tamaño: 100k

| Binario | cycles | instructions | IPC | cache-miss % | task-clock (msec) |
|---|---|---|---|---|---|
| parser_opt | 134594979 | 243227969 | 1.81 | 49.16% | 43.49 |
| parser_opt_a | 41414897 | 80308965 | 1.94 | 55.72% | 13.04 |

## Tamaño: 1M

| Binario | cycles | instructions | IPC | cache-miss % | task-clock (msec) |
|---|---|---|---|---|---|
| parser_opt | 1183209002 | 2448861734 | 2.07 | 46.28% | 372.06 |
| parser_opt_a | 417031419 | 875004153 | 2.10 | 71.63% | 131.49 |

> Nota: valores de una sola línea representativa por perf con `-r 15`;
> abrir los `*_perf_stat.txt` individuales para ver el desvío estándar completo.
