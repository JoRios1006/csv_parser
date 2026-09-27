#!/bin/bash

# STREAMING_CHUNK:Configurando variables y directorio...
# ==========================================
# CONFIGURACIÓN INICIAL
# ==========================================
DIRECTORIO_REPORTES="reportes_optimizacion"
BINARIOS=("parser_opt" "parser_opt_a")
CSV_ARCHIVO="movimientos.csv"

# Colores para la consola
VERDE="\e[32m"
AMARILLO="\e[33m"
ROJO="\e[31m"
RESET="\e[0m"

echo -e "${VERDE}Iniciando suite de Benchmarking para C (Zero-Copy CSV)...${RESET}"

# Verificar si el CSV existe
if [ ! -f "$CSV_ARCHIVO" ]; then
    echo -e "${ROJO}Error: El archivo $CSV_ARCHIVO no existe.${RESET}"
    echo "Por favor, crea un archivo de prueba grande antes de continuar."
    exit 1
fi

# Crear directorio de reportes limpio
rm -rf "$DIRECTORIO_REPORTES"
mkdir -p "$DIRECTORIO_REPORTES"

# STREAMING_CHUNK:Ejecutando iteraciones sobre los binarios...
# ==========================================
# BUCLE DE ANÁLISIS
# ==========================================
for BIN in "${BINARIOS[@]}"; do
    if [ ! -f "./$BIN" ]; then
        echo -e "${AMARILLO}Advertencia: Binario ./$BIN no encontrado. Saltando...${RESET}"
        continue
    fi

    echo -e "\n${AMARILLO}==========================================${RESET}"
    echo -e "${AMARILLO}Analizando binario: ./$BIN${RESET}"
    echo -e "${AMARILLO}==========================================${RESET}"

    # STREAMING_CHUNK:Analizando llamadas al sistema con strace...
    # 1. STRACE: Resumen de llamadas al sistema (Syscalls)
    # Usamos -c para obtener una tabla resumen de conteo y tiempos
    echo "-> 1/4 Ejecutando strace (Syscalls profiling)..."
    strace -c -o "$DIRECTORIO_REPORTES/${BIN}_strace_resumen.txt" ./$BIN > /dev/null
    
    # STRACE detallado: Captura la secuencia exacta de syscalls (ideal para ver los mmap y madvise en acción)
    strace -o "$DIRECTORIO_REPORTES/${BIN}_strace_completo.txt" ./$BIN > /dev/null

    # STREAMING_CHUNK:Analizando memoria con Valgrind...
    # 2. VALGRIND: Análisis de memoria (Fugas y accesos inválidos)
    # Memcheck es pesado, por lo que tardará un poco más
    echo "-> 2/4 Ejecutando Valgrind Memcheck (Memory profiling)..."
    valgrind --tool=memcheck \
             --leak-check=full \
             --show-leak-kinds=all \
             --track-origins=yes \
             --log-file="$DIRECTORIO_REPORTES/${BIN}_valgrind_memcheck.txt" \
             ./$BIN > /dev/null

    # VALGRIND: Massif (Perfilado de memoria Heap)
    # Muy útil para ver cómo crece la Arena que implementamos
    echo "-> 3/4 Ejecutando Valgrind Massif (Heap allocator profiling)..."
    valgrind --tool=massif \
             --massif-out-file="$DIRECTORIO_REPORTES/${BIN}_valgrind_massif.out" \
             ./$BIN > /dev/null

    # STREAMING_CHUNK:Analizando rendimiento de CPU con Perf...
    # 3. PERF: Contadores de hardware (Ciclos de CPU, Caché, Ramificaciones)
    # Redirigimos stderr a stdout porque perf stat escribe sus resultados allí por defecto
    echo "-> 4/4 Ejecutando Perf Stat (Hardware counters)..."
    perf stat -e task-clock,cycles,instructions,cache-references,cache-misses,branches,branch-misses,page-faults \
              -o "$DIRECTORIO_REPORTES/${BIN}_perf_stat.txt" \
              ./$BIN > /dev/null

    echo -e "${VERDE}Reportes de $BIN generados exitosamente.${RESET}"
done

# STREAMING_CHUNK:Finalizando script y mostrando instrucciones...
# ==========================================
# RESUMEN FINAL
# ==========================================
echo -e "\n${VERDE}¡Análisis completado!${RESET}"
echo "Los resultados están en la carpeta: $DIRECTORIO_REPORTES/"
echo "Archivos generados por cada binario:"
echo "  - *_strace_resumen.txt    (Tabla de Syscalls llamadas y % de tiempo)"
echo "  - *_strace_completo.txt   (Traza lineal de las llamadas al Kernel)"
echo "  - *_valgrind_memcheck.txt (Fugas, variables sin inicializar, buffer overruns)"
echo "  - *_valgrind_massif.out   (Snapshot del Heap. Ver con: ms_print archivo)"
echo "  - *_perf_stat.txt         (Uso de CPU, Cache Misses, e IPC (Instrucciones por Ciclo))"
