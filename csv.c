#include <fcntl.h>
#include <stdalign.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_COLS 10

typedef struct {
  char *valores[MAX_COLS];
} Registro;

typedef struct {
  alignas(4096) char pagina[4096];
  size_t offset;
} MemoriaCSV;

void *arena_push(MemoriaCSV *mem, size_t size) {
  if (mem->offset + size > sizeof(mem->pagina)) return NULL;
  void *ptr = &mem->pagina[mem->offset];
  mem->offset += size;
  return ptr;
}

char *obtener_valor(Registro *reg, int idx) {
  if (idx < 0 || idx >= MAX_COLS) return NULL;
  return reg->valores[idx];
}

int buscar_columna(char *cabeceras[], int num_cols, const char *nombre) {
  for (int i = 0; i < num_cols; i++) {
    if (cabeceras[i] && strcmp(cabeceras[i], nombre) == 0) return i;
  }
  return -1;
}

// Función helper para extraer una línea del mapa de memoria sin hacer copias
// Modifica la coma/salto de línea a '\0' sobre un buffer temporal de trabajo
size_t leer_linea_mmap(const char *csv, size_t csv_size, size_t pos, char *dest, size_t dest_max) {
  if (pos >= csv_size) return 0;

  size_t len = 0;
  while (pos + len < csv_size && csv[pos + len] != '\n' && csv[pos + len] != '\r' && len < dest_max - 1) {
    dest[len] = csv[pos + len];
    len++;
  }

  dest[len] = '\0';

  // Saltear caracteres de nueva línea (\r, \n) para la siguiente iteración
  while (pos + len < csv_size && (csv[pos + len] == '\n' || csv[pos + len] == '\r')) {
    len++;
  }

  return len; // Devuelve cuántos bytes avanzamos en el archivo mapeado
}

int main() {
  // 1. Abrir archivo con descriptor POSIX
  int fd = open("movimientos.csv", O_RDONLY);
  if (fd == -1) return EXIT_FAILURE;

  struct stat st;
  if (fstat(fd, &st) == -1 || st.st_size == 0) {
    close(fd);
    return EXIT_FAILURE;
  }
  size_t csv_size = st.st_size;

  // 2. MAPEAR EL ARCHIVO ENTERO A RAM
  // csv_data es literalmente un arreglo 'char[]' que contiene todo el archivo
  char *csv_data = mmap(NULL, csv_size, PROT_READ, MAP_PRIVATE, fd, 0);
  if (csv_data == MAP_FAILED) {
    close(fd);
    return EXIT_FAILURE;
  }

  // Indicar al Kernel que lea de forma secuencial (optimización de Page Cache)
  madvise(csv_data, csv_size, MADV_SEQUENTIAL);
  madvise(csv_data, csv_size, MADV_WILLNEED);

  MemoriaCSV mem = {0};

  // Reservar buffers en nuestra Arena
  char *cabeceras_buf = (char *)arena_push(&mem, 512);
  char *linea_buf = (char *)arena_push(&mem, 512);
  char *out_buf = &mem.pagina[mem.offset];
  size_t out_capacity = sizeof(mem.pagina) - mem.offset;
  size_t out_len = 0;

  size_t cursor = 0; // Apunta a la posición actual dentro del arreglo mapeado `csv_data`

  // 3. Leer cabeceras directamente desde el puntero mmap
  size_t bytes_leidos = leer_linea_mmap(csv_data, csv_size, cursor, cabeceras_buf, 512);
  if (bytes_leidos == 0) goto cleanup;
  cursor += bytes_leidos;

  char *cabeceras[MAX_COLS] = {0};
  int num_columnas = 0;

  char *token = strtok(cabeceras_buf, ",");
  while (token != NULL && num_columnas < MAX_COLS) {
    while (*token == ' ') token++;
    cabeceras[num_columnas++] = token;
    token = strtok(NULL, ",");
  }

  int idx_monto = buscar_columna(cabeceras, num_columnas, "monto_real");
  int idx_categoria = buscar_columna(cabeceras, num_columnas, "categoria");

  // 4. Recorrer el archivo mapeado como si fuera un arreglo usando el cursor
  while ((bytes_leidos = leer_linea_mmap(csv_data, csv_size, cursor, linea_buf, 512)) > 0) {
    cursor += bytes_leidos;
    if (linea_buf[0] == '\0') continue;

    Registro reg = {0};
    int col_actual = 0;

    char *val = strtok(linea_buf, ",");
    while (val != NULL && col_actual < num_columnas) {
      while (*val == ' ') val++;
      reg.valores[col_actual++] = val;
      val = strtok(NULL, ",");
    }

    char *precio = obtener_valor(&reg, idx_monto);
    char *nombre = obtener_valor(&reg, idx_categoria);

    if (precio && nombre) {
      int escritos = snprintf(out_buf + out_len, out_capacity - out_len,
                              "El producto '%s' cuesta: %s\n", nombre, precio);

      if (escritos > 0 && (size_t)escritos < (out_capacity - out_len)) {
        out_len += escritos;
      } else {
        write(STDOUT_FILENO, out_buf, out_len);
        out_len = 0;
      }
    }
  }

  if (out_len > 0) {
    write(STDOUT_FILENO, out_buf, out_len);
  }

cleanup:
  // Desmapear archivo de la memoria y cerrar el descriptor
  munmap(csv_data, csv_size);
  close(fd);

  return 0;
}
