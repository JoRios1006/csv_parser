# Análisis de rendimiento: `parser_opt` vs `parser_opt_a`

Comparación de dos versiones de un parser de CSV en C — `csv.c` (binario `parser_opt`) y su variante optimizada `csv_a.c` (binario `parser_opt_a`) — sobre el archivo de entrada `movimientos.csv` (506 bytes), usando `perf stat`, `valgrind --tool=memcheck`, `valgrind --tool=massif` y `strace`.

## Archivos

| Fuente | Binario | Reportes |
|---|---|---|
| `csv.c` | `parser_opt` | `parser_opt_perf_stat.txt`, `parser_opt_valgrind_memcheck.txt`, `parser_opt_valgrind_massif.out`, `parser_opt_strace_completo.txt`, `parser_opt_strace_resumen.txt` |
| `csv_a.c` | `parser_opt_a` | `parser_opt_a_perf_stat.txt`, `parser_opt_a_valgrind_memcheck.txt`, `parser_opt_a_valgrind_massif.out`, `parser_opt_a_strace_completo.txt`, `parser_opt_a_strace_resumen.txt` |

## 1. Diferencias de diseño

| Aspecto | `csv.c` (`parser_opt`) | `csv_a.c` (`parser_opt_a`) |
|---|---|---|
| Mapeo de archivo | `mmap(PROT_READ, MAP_PRIVATE)` | `mmap(PROT_READ\|PROT_WRITE, MAP_PRIVATE)` — copy-on-write, permite mutar el buffer |
| `madvise` | 2 llamadas separadas: `MADV_SEQUENTIAL`, luego `MADV_WILLNEED` | 1 llamada combinada: `MADV_SEQUENTIAL\|MADV_WILLNEED` |
| Extracción de líneas | `leer_linea_mmap` **copia** cada línea a un buffer temporal de 512 B | `parse_next_line` muta `\n`/`\r` a `\0` directamente sobre el mmap (zero-copy real) |
| Tokenización | `strtok` sobre el buffer copiado (no reentrante) | `tokenize_csv_line` reemplaza `,` por `\0` directamente en el mmap |
| Registro de columnas | `struct Registro` con arreglo de punteros | arreglo local de `char*` apuntando al mmap, sin struct intermedia |
| Buffer de salida | Arena de 4096 B compartida entre copias de entrada y salida; formatea con `snprintf` | Arena dedicada solo a salida, alineada a página; formatea a mano con `memcpy` (`append_to_buffer`) |
| Memoria dinámica | 0 `malloc`/`free` | 0 `malloc`/`free` |

**Conclusión de diseño:** `parser_opt` reduce llamadas a `read()` mapeando el archivo, pero sigue copiando cada línea a un buffer auxiliar antes de tokenizar. `parser_opt_a` elimina esa copia: parsea y tokeniza in-place sobre la memoria mapeada, y sustituye `snprintf` por concatenación manual.

## 2. `perf stat`

| Métrica | `parser_opt` | `parser_opt_a` |
|---|---|---|
| task-clock | 0,29 msec | 0,65 msec |
| cycles | 841.408 | 744.319 |
| instructions | 478.119 | 473.111 |
| IPC (insn/cycle) | 0,57 | 0,64 |
| cache-references | 11.302 | 11.873 |
| cache-misses | 4.394 (38,88 %) | 3.404 (28,67 %) |
| branches | 105.010 | 104.427 |
| page-faults | 32 | 32 |
| tiempo transcurrido | 0,001009977 s | 0,001885550 s |

`parser_opt_a` tiene menos ciclos de CPU, mejor IPC y una tasa de cache-misses considerablemente menor (28,67 % vs 38,88 %) — coherente con eliminar la copia de cada línea a un buffer temporal. El tiempo de pared (wall-clock) sale más alto en esta corrida puntual, pero con una entrada de 506 bytes y ejecuciones sub-milisegundo el ruido de scheduling domina la medición; no es una muestra suficiente para concluir sobre latencia real. Se recomienda repetir con `perf stat -r 20` y un archivo de entrada de tamaño representativo.

## 3. `valgrind --memcheck`

Ambos binarios reportan exactamente los mismos 2 avisos: *"Conditional jump or move depends on uninitialised value(s)"* dentro de `_dl_init_paths` / `fillin_rpath` — código interno del cargador dinámico de glibc, no del programa. Idéntico en ambas versiones, por lo tanto no atribuible a los cambios del parser.

Resumen de heap en ambos: `0 allocs, 0 frees, 0 bytes allocated` — **no leaks possible**. Ninguna versión usa memoria dinámica; toda la memoria proviene de `mmap` y buffers estáticos/stack.

## 4. `valgrind --massif`

Ambos archivos `.out` contienen un único snapshot (`time=0`, `mem_heap_B=0`, `heap_tree=empty`). Confirma lo visto en memcheck: no hay actividad de heap en ninguna de las dos versiones, así que massif no aporta información diferencial entre ellas.

## 5. `strace`

Secuencia de syscalls idéntica en ambos (`execve`, `brk` ×5, `arch_prctl`, `set_tid_address`, `set_robust_list`, `rseq`, `prlimit64`, `readlinkat`, `getrandom`, `openat`, `fstat`, `mmap`, `madvise`, `write`, `munmap`, `close`, `exit_group`), con dos diferencias puntuales:

- **Flags de `mmap`**: `PROT_READ` (`parser_opt`) vs `PROT_READ|PROT_WRITE` (`parser_opt_a`).
- **Cantidad de `madvise`**: 2 llamadas en `parser_opt` vs 1 en `parser_opt_a` → total de syscalls: **22 vs 21**.

El `write()` final es idéntico en ambos: 315 bytes, mismo contenido (`"El producto 'Alquiler y Servicio..."`).

## Conclusiones

1. `parser_opt_a` logra zero-copy real: parsea y tokeniza directamente sobre la memoria mapeada en vez de copiar cada línea a un buffer temporal.
2. Reduce 1 syscall (`madvise` combinado) y evita el overhead de formateo de `snprintf`.
3. Mejor IPC y menor tasa de cache-misses en la corrida medida; el tiempo de pared no es concluyente dado el tamaño mínimo de la entrada (506 B) y la duración sub-milisegundo del proceso.
4. Ninguna de las dos versiones usa memoria dinámica ni presenta leaks; los avisos de memcheck son idénticos en ambas y provienen del cargador dinámico, no del código propio.

## Próximos pasos sugeridos

- Repetir `perf stat` con `-r 20` (o más) y un CSV de tamaño real de producción para obtener medias y desviaciones estándar confiables.
- Considerar `perf record`/`perf report` para descartar ruido de scheduler en mediciones tan cortas.
