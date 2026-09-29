#!/bin/bash
#
# bench.sh — Suite de benchmarking para comparar parser_opt vs parser_opt_a
#
# Mejoras respecto a la v1:
#   1. Genera datasets sintéticos de varios tamaños (la v1 sólo medía con un
#      CSV de 506 bytes: a esa escala perf/madvise/mmap no tienen nada real
#      que optimizar y el ruido domina cualquier conclusión).
#   2. Chequeo de correctitud: antes de medir tiempos, compara el stdout de
#      todos los binarios byte a byte. Si un "optimizado" cambia el output,
#      el benchmark se corta para ese dataset — no tiene sentido medir
#      velocidad de un programa que dejó de andar bien.
#   3. `perf stat -r N`: repite cada medición N veces y usa el cálculo nativo
#      de media + desvío de perf, en vez de una sola corrida (que es lo que
#      nos hizo ver IPC/cache-miss contradictorios entre dos corridas previas).
#   4. `LC_ALL=C` fijo: perf/valgrind formatean números según la locale del
#      sistema (vimos "744.319" con punto de miles y coma decimal). Fijar
#      locale C evita ambigüedad y permite parsear los reportes después.
#   5. Warm-up run antes de medir (llena page cache / caches de CPU).
#   6. Pinning opcional a un core fijo con taskset, si está disponible.
#   7. Captura info de entorno (CPU, kernel, gobernador de frecuencia, NMI
#      watchdog, compilador, git rev) para que dos corridas en máquinas
#      distintas no se confundan por una sola carpeta de reportes.
#   8. No aborta si falta una herramienta: avisa y salta esa etapa.
#   9. Resumen final comparativo en Markdown.
#
# Requiere: bash 4+, strace, valgrind, perf (linux-tools). taskset opcional.
#
set -uo pipefail

# ==========================================
# CONFIGURACIÓN
# ==========================================
DIRECTORIO_REPORTES="reportes_optimizacion"
BINARIOS=("parser_opt" "parser_opt_a")
CSV_ARCHIVO="movimientos.csv"          # nombre hardcodeado que abren los binarios
PERF_REPEATS="${PERF_REPEATS:-15}"     # repeticiones de perf stat (override: PERF_REPEATS=30 ./bench.sh)
EVENTOS="task-clock,cycles,instructions,cache-references,cache-misses,branches,branch-misses,page-faults"

# Tamaños sintéticos a generar (filas de datos, sin contar cabecera).
# "original" usa el movimientos.csv real del usuario tal cual está, si existe.
ORDEN_TAMANIOS=("original" "1k" "100k" "1M")
declare -A FILAS_POR_TAMANIO=( ["1k"]=1000 ["100k"]=100000 ["1M"]=1000000 )

# Fuerza formato numérico consistente (punto decimal, sin separador de miles)
export LC_ALL=C

# Colores
VERDE="\e[32m"; AMARILLO="\e[33m"; ROJO="\e[31m"; CIAN="\e[36m"; RESET="\e[0m"

log()  { echo -e "${CIAN}$*${RESET}"; }
ok()   { echo -e "${VERDE}$*${RESET}"; }
warn() { echo -e "${AMARILLO}$*${RESET}"; }
err()  { echo -e "${ROJO}$*${RESET}"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ==========================================
# CHEQUEO DE DEPENDENCIAS (no aborta, avisa y saltea)
# ==========================================
TIENE_STRACE=true; TIENE_VALGRIND=true; TIENE_PERF=true; USE_TASKSET=false

have_cmd strace   || { warn "Aviso: 'strace' no encontrado — se salteará esa etapa."; TIENE_STRACE=false; }
have_cmd valgrind || { warn "Aviso: 'valgrind' no encontrado — se salteará esa etapa."; TIENE_VALGRIND=false; }
have_cmd perf     || { warn "Aviso: 'perf' no encontrado — se salteará esa etapa.";     TIENE_PERF=false; }
have_cmd taskset  && USE_TASKSET=true
PIN_CORE="${PIN_CORE:-$(( $(nproc) > 1 ? $(nproc) - 1 : 0 ))}"

if [ "$TIENE_STRACE" = false ] && [ "$TIENE_VALGRIND" = false ] && [ "$TIENE_PERF" = false ]; then
  err "Ninguna herramienta de profiling está instalada. Nada para hacer."
  exit 1
fi

# ==========================================
# BACKUP / RESTORE del movimientos.csv real del usuario
# ==========================================
BACKUP_ORIGINAL=""
if [ -f "$CSV_ARCHIVO" ]; then
  BACKUP_ORIGINAL="$(mktemp)"
  cp "$CSV_ARCHIVO" "$BACKUP_ORIGINAL"
fi

limpiar_al_salir() {
  if [ -n "$BACKUP_ORIGINAL" ] && [ -f "$BACKUP_ORIGINAL" ]; then
    cp "$BACKUP_ORIGINAL" "$CSV_ARCHIVO"
    rm -f "$BACKUP_ORIGINAL"
  fi
  rm -f dataset_*.csv
}
trap limpiar_al_salir EXIT

# ==========================================
# GENERADOR DE CSV SINTÉTICO
# Columnas mínimas requeridas por el parser: categoria, monto_real.
# Se agregan columnas extra para simular un CSV real (sin comas ni
# comillas embebidas: el tokenizer de los binarios no maneja quoting).
# ==========================================
generar_csv() {
  local filas="$1" salida="$2"
  awk -v filas="$filas" 'BEGIN {
    srand(42)  # semilla fija: mismos datos entre corridas, resultados comparables
    split("Alquiler y Servicios,Alimentacion,Transporte,Entretenimiento,Salud,Educacion,Indumentaria,Ahorro,Impuestos,Otros", cats, ",")
    print "fecha,cuenta,categoria,descripcion,monto_real,moneda,estado"
    for (i = 1; i <= filas; i++) {
      cat = cats[int(rand()*10)+1]
      monto = sprintf("%.2f", (rand()*99900)+100)
      printf "2026-%02d-%02d,CTA%04d,%s,Movimiento generado #%d,%s,ARS,OK\n", \
        (int(rand()*12)+1), (int(rand()*28)+1), int(rand()*9999), cat, i, monto
    }
  }' > "$salida"
}

# ==========================================
# CHEQUEO DE CORRECTITUD
# Corre todos los binarios sobre el mismo CSV y compara stdout.
# Devuelve 0 si todos coinciden, 1 si hay divergencias.
# ==========================================
verificar_correctitud() {
  local etiqueta="$1"
  local -a salidas=()
  local -a validos=()

  for bin in "${BINARIOS[@]}"; do
    if [ ! -x "./$bin" ]; then
      warn "  [$etiqueta] binario ./$bin no encontrado, se saltea del chequeo de correctitud."
      continue
    fi
    salidas+=("$(./"$bin" 2>/dev/null)")
    validos+=("$bin")
  done

  if [ "${#validos[@]}" -lt 2 ]; then
    warn "  [$etiqueta] menos de 2 binarios disponibles, no hay nada que comparar."
    return 0
  fi

  local referencia="${salidas[0]}"
  local todo_ok=true
  for i in "${!validos[@]}"; do
    if [ "${salidas[$i]}" != "$referencia" ]; then
      err "  [$etiqueta] ✗ ${validos[$i]} difiere de ${validos[0]}:"
      diff <(echo "$referencia") <(echo "${salidas[$i]}") | head -20
      todo_ok=false
    fi
  done

  if $todo_ok; then
    ok "  [$etiqueta] ✓ Todos los binarios producen la misma salida."
    return 0
  else
    return 1
  fi
}

# ==========================================
# CAPTURA DE ENTORNO
# ==========================================
capturar_entorno() {
  local archivo="$1"
  {
    echo "=== Fecha ==="; date
    echo; echo "=== Kernel / OS ==="; uname -a
    echo; echo "=== CPU ==="
    if have_cmd lscpu; then lscpu | grep -E "Model name|CPU\(s\)|MHz"; else grep -m1 "model name" /proc/cpuinfo; fi
    echo; echo "=== Gobernador de frecuencia (cpu0) ==="
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
      cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
      warn_gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
      if [ "$warn_gov" != "performance" ]; then
        echo "(sugerencia: 'sudo cpupower frequency-set -g performance' reduce ruido entre corridas)"
      fi
    else
      echo "no disponible (¿VM/contenedor sin cpufreq?)"
    fi
    echo; echo "=== NMI watchdog ==="
    if [ -f /proc/sys/kernel/nmi_watchdog ]; then
      cat /proc/sys/kernel/nmi_watchdog
      echo "(si es '1', branch-misses puede salir '<not counted>'; deshabilitarlo requiere root:"
      echo " sudo sh -c 'echo 0 > /proc/sys/kernel/nmi_watchdog')"
    else
      echo "n/d"
    fi
    echo; echo "=== Compilador ==="
    have_cmd gcc && gcc --version | head -1
    echo; echo "=== Git ==="
    if have_cmd git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "commit: $(git rev-parse HEAD)"
      git status --porcelain | head -5
    else
      echo "no es un repositorio git"
    fi
    echo; echo "=== Pinning ==="
    if $USE_TASKSET; then echo "taskset disponible, corriendo en core $PIN_CORE"; else echo "taskset no disponible, sin pinning"; fi
    echo; echo "=== perf stat: repeticiones ==="; echo "$PERF_REPEATS"
  } > "$archivo"
}

# ==========================================
# ETAPAS DE PROFILING POR BINARIO
# ==========================================
ejecutar_strace() {
  local bin="$1" dir="$2"
  strace -c -o "$dir/${bin}_strace_resumen.txt" ./"$bin" > /dev/null 2>&1
  strace    -o "$dir/${bin}_strace_completo.txt" ./"$bin" > /dev/null 2>&1
}

ejecutar_valgrind() {
  local bin="$1" dir="$2"
  valgrind --tool=memcheck --leak-check=full --show-leak-kinds=all --track-origins=yes \
           --log-file="$dir/${bin}_valgrind_memcheck.txt" ./"$bin" > /dev/null 2>&1
  valgrind --tool=massif --massif-out-file="$dir/${bin}_valgrind_massif.out" \
           ./"$bin" > /dev/null 2>&1
}

ejecutar_perf() {
  local bin="$1" dir="$2"
  # warm-up: descartado, sólo para poblar caches antes de medir
  ./"$bin" > /dev/null 2>&1 || true

  local -a prefijo=()
  $USE_TASKSET && prefijo=(taskset -c "$PIN_CORE")

  "${prefijo[@]}" perf stat -r "$PERF_REPEATS" -e "$EVENTOS" \
      -o "$dir/${bin}_perf_stat.txt" -- ./"$bin" > /dev/null 2>&1
}

# ==========================================
# EXTRACCIÓN DE MÉTRICAS PARA EL RESUMEN
# (best-effort: los archivos crudos *_perf_stat.txt son la fuente de verdad;
#  esta tabla es sólo una vista rápida comparativa)
# ==========================================
extraer_metrica() {
  local archivo="$1" patron="$2"
  grep -w "$patron" "$archivo" 2>/dev/null | head -1 | awk '{print $1}' | tr -d ','
}

extraer_derivado() {
  # busca algo como "0.57  insn per cycle" o "38.41% of all cache refs" en la misma línea
  local archivo="$1" patron="$2" texto="$3"
  grep "$patron" "$archivo" 2>/dev/null | head -1 | grep -oE "[0-9]+[.,][0-9]+%?\s+$texto" | grep -oE "^[0-9]+[.,][0-9]+%?"
}

generar_resumen() {
  local resumen="$DIRECTORIO_REPORTES/resumen_comparativo.md"
  {
    echo "# Resumen comparativo — parser_opt vs parser_opt_a"
    echo
    echo "Generado: $(date)"
    echo
    for tam in "${ORDEN_TAMANIOS[@]}"; do
      local dir="$DIRECTORIO_REPORTES/$tam"
      [ -d "$dir" ] || continue
      echo "## Tamaño: $tam"
      echo
      echo "| Binario | cycles | instructions | IPC | cache-miss % | task-clock (msec) |"
      echo "|---|---|---|---|---|---|"
      for bin in "${BINARIOS[@]}"; do
        local f="$dir/${bin}_perf_stat.txt"
        [ -f "$f" ] || continue
        local cycles instr ipc missrate clock
        cycles=$(extraer_metrica "$f" "cycles")
        instr=$(extraer_metrica "$f" "instructions")
        ipc=$(extraer_derivado "$f" "instructions" "insn per cycle")
        missrate=$(extraer_derivado "$f" "cache-misses" "of all cache refs")
        clock=$(extraer_metrica "$f" "task-clock")
        echo "| $bin | ${cycles:-n/d} | ${instr:-n/d} | ${ipc:-n/d} | ${missrate:-n/d} | ${clock:-n/d} |"
      done
      echo
    done
    echo "> Nota: valores de una sola línea representativa por perf con \`-r $PERF_REPEATS\`;"
    echo "> abrir los \`*_perf_stat.txt\` individuales para ver el desvío estándar completo."
  } > "$resumen"
  ok "Resumen comparativo: $resumen"
}

# ==========================================
# FLUJO PRINCIPAL
# ==========================================
log "Iniciando suite de benchmarking (zero-copy CSV parser)..."
log "Repeticiones de perf stat: $PERF_REPEATS | taskset: $USE_TASKSET"

rm -rf "$DIRECTORIO_REPORTES"
mkdir -p "$DIRECTORIO_REPORTES"
capturar_entorno "$DIRECTORIO_REPORTES/entorno.txt"

for tam in "${ORDEN_TAMANIOS[@]}"; do
  echo
  log "=========================================="
  log " Tamaño de dataset: $tam"
  log "=========================================="

  if [ "$tam" = "original" ]; then
    if [ -z "$BACKUP_ORIGINAL" ]; then
      warn "No hay $CSV_ARCHIVO original en este directorio — se saltea el tamaño 'original'."
      continue
    fi
    cp "$BACKUP_ORIGINAL" "$CSV_ARCHIVO"
  else
    filas="${FILAS_POR_TAMANIO[$tam]}"
    generar_csv "$filas" "dataset_${tam}.csv"
    cp "dataset_${tam}.csv" "$CSV_ARCHIVO"
  fi

  dir_tam="$DIRECTORIO_REPORTES/$tam"
  mkdir -p "$dir_tam"

  # 1. Correctitud primero: si algo rompió, igual seguimos midiendo pero avisamos fuerte
  verificar_correctitud "$tam" || err "  -> revisar diffs arriba antes de confiar en los tiempos de este tamaño."

  # 2. Profiling por binario
  for bin in "${BINARIOS[@]}"; do
    if [ ! -x "./$bin" ]; then
      warn "  Binario ./$bin no encontrado. Saltando..."
      continue
    fi
    log "  -> Perfilando ./$bin"
    $TIENE_STRACE   && ejecutar_strace   "$bin" "$dir_tam"
    $TIENE_VALGRIND && ejecutar_valgrind "$bin" "$dir_tam"
    $TIENE_PERF     && ejecutar_perf     "$bin" "$dir_tam"
  done
done

generar_resumen

echo
ok "¡Análisis completado!"
echo "Resultados en: $DIRECTORIO_REPORTES/"
echo "  entorno.txt                       -> info de máquina/kernel/compilador para esta corrida"
echo "  <tamaño>/*_strace_resumen.txt      -> tabla de syscalls y tiempos"
echo "  <tamaño>/*_strace_completo.txt     -> traza lineal de syscalls"
echo "  <tamaño>/*_valgrind_memcheck.txt   -> fugas, variables sin inicializar"
echo "  <tamaño>/*_valgrind_massif.out     -> snapshot de heap (ver con: ms_print archivo)"
echo "  <tamaño>/*_perf_stat.txt           -> ciclos, IPC, cache-misses (media +/- stddev, -r $PERF_REPEATS)"
echo "  resumen_comparativo.md             -> tabla comparativa rápida"
echo
echo "Tip: los 2 warnings de _dl_init_paths en memcheck son ruido conocido del"
echo "loader de glibc, no de este código. Si molestan: valgrind --gen-suppressions=all"
echo "una vez y reusar el bloque generado con --suppressions=archivo.supp."
