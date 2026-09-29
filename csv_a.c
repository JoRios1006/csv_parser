#include <fcntl.h>
#include <stdalign.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_COLS 10
#define PAGE_SIZE 4096

// Nuestra Arena, ahora se usará exclusivamente como un búfer de salida
// ultra-rápido
typedef struct {
  alignas(PAGE_SIZE) char pagina[PAGE_SIZE];
} MemoriaCSV;

// ==========================================
// 1. GESTIÓN DE ARCHIVOS Y MEMORIA
// ==========================================

static inline char *map_file_to_memory(const char *filepath, int *out_fd,
                                       size_t *out_size) {
  *out_fd = open(filepath, O_RDONLY);
  if (*out_fd == -1)
    return NULL;

  struct stat st;
  if (fstat(*out_fd, &st) == -1 || st.st_size == 0) {
    close(*out_fd);
    return NULL;
  }
  *out_size = st.st_size;

  // CLAVE: Usamos PROT_WRITE y MAP_PRIVATE.
  // Esto nos permite modificar la memoria (Zero-Copy) sin alterar el archivo
  // real en disco.
  char *data = mmap(NULL, *out_size, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_POPULATE, *out_fd, 0);
  if (data == MAP_FAILED) {
    close(*out_fd);
    return NULL;
  }

  // Pre-carga agresiva para lectura secuencial
  madvise(data, *out_size, MADV_SEQUENTIAL | MADV_WILLNEED);
  return data;
}

static inline void cleanup_file(char *csv_data, size_t size, int fd) {
  if (csv_data)
    munmap(csv_data, size);
  if (fd != -1)
    close(fd);
}

// ==========================================
// 2. PARSEO ZERO-COPY
// ==========================================

// Avanza el cursor, encuentra el fin de línea, lo muta a '\0' y devuelve la
// línea.
static inline char *parse_next_line(char **cursor, const char *end) {
  if (*cursor >= end)
    return NULL;
  char *start = *cursor;
  size_t remaining = end - start;
  // Búsqueda vectorizada del salto de línea
  char *newline = (char *)memchr(start, '\n', remaining);
  if (newline) {
    // Retrocedemos un byte para manejar la secuencia \r\n de Windows
    if (newline > start && *(newline - 1) == '\r') {
      *(newline - 1) = '\0';
    } else {
      *newline = '\0';
    }
    *cursor = newline + 1;
  } else {
    *cursor = (char *)end;
  }
  return start;
}

// Tokenizador ultra-rápido: Reemplaza las comas por '\0' directamente en el
// buffer
static inline int tokenize_csv_line(char *line, char *tokens[],
                                    size_t lengths[], int max_tokens) {
  int count = 0;
  char *p = line;
  while (*p == ' ')
    p++;
  tokens[count] = p;

  while (*p && count < max_tokens) {
    if (*p == ',') {
      *p = '\0';
      // Calculamos la longitud con latencia cero mediante resta de punteros
      lengths[count] = (size_t)(p - tokens[count]);
      count++;
      char *next = p + 1;
      while (*next == ' ')
        next++;
      if (count < max_tokens)
        tokens[count] = next;
    }
    p++;
  }
  // Registrar la longitud del último token procesado
  if (count < max_tokens) {
    lengths[count] = (size_t)(p - tokens[count]);
    count++;
  }

  return count;
}

static inline int find_column_index(char *headers[], int num_cols,
                                    const char *target) {
  for (int i = 0; i < num_cols; i++) {
    if (headers[i] && strcmp(headers[i], target) == 0)
      return i;
  }
  return -1;
}

// ==========================================
// 3. SALIDA OPTIMIZADA (Sustituto de snprintf)
// ==========================================

static inline void flush_buffer(MemoriaCSV *mem, ssize_t *offset) {
  if (*offset > 0) {
    write(STDOUT_FILENO, mem->pagina, *offset);
    *offset = 0;
  }
}

static inline void append_to_buffer(MemoriaCSV *mem, const char *str,
                                    size_t len, ssize_t *offset) {
  // Si no cabe, vaciamos la arena
  if (*offset + len > PAGE_SIZE) {
    flush_buffer(mem, offset);
  }
  // Si el string es mas grande que la arena (raro, pero seguro)
  if (len >= PAGE_SIZE) {
    write(STDOUT_FILENO, str, len);
    return;
  }
  // Copia rápida (memcpy es una función intrínseca compilada a instrucciones
  // asm eficientes)
  memcpy(mem->pagina + *offset, str, len);
  *offset += len;
}

// Reemplaza a snprintf concatenando cadenas directamente (muchísimo más rápido)
static inline void
format_and_append_product(MemoriaCSV *mem, const char *nombre,
                          size_t len_nombre, const char *precio,
                          size_t len_precio, ssize_t *offset) {
  const char *p1 = "El producto '";
  const char *p2 = "' cuesta: ";
  const char *p3 = "\n";

  // Uso directo de longitudes pre-calculadas y tamaños literales conocidos
  append_to_buffer(mem, p1, 13, offset);
  append_to_buffer(mem, nombre, len_nombre, offset);
  append_to_buffer(mem, p2, 10, offset);
  append_to_buffer(mem, precio, len_precio, offset);
  append_to_buffer(mem, p3, 1, offset);
}

// ==========================================
// 4. FLUJO PRINCIPAL LINEAL
// ==========================================

int main() {
  int fd;
  size_t csv_size;

  // 1. Cargar archivo (Mapeado con PROT_WRITE para Zero-Copy)
  char *csv_data = map_file_to_memory("movimientos.csv", &fd, &csv_size);
  if (!csv_data)
    return EXIT_FAILURE;

  MemoriaCSV output_arena = {0};
  ssize_t offset = 0;

  char *cursor = csv_data;
  const char *end_of_file = csv_data + csv_size;

  // 2. Extraer cabeceras
  char *header_line = parse_next_line(&cursor, end_of_file);
  if (!header_line)
    goto end;

  char *headers[MAX_COLS];
  size_t header_lengths[MAX_COLS]; // Agregado para cumplir con la nueva firma
  int num_cols =
      tokenize_csv_line(header_line, headers, header_lengths, MAX_COLS);

  int idx_monto = find_column_index(headers, num_cols, "monto_real");
  int idx_categoria = find_column_index(headers, num_cols, "categoria");

  if (idx_monto < 0 || idx_categoria < 0) {
    goto end; // Faltan columnas requeridas
  }

  // 3. Procesar las líneas de manera secuencial
  while (cursor < end_of_file) {
    char *line = parse_next_line(&cursor, end_of_file);
    if (!line || *line == '\0')
      continue;

    char *cols[MAX_COLS];
    size_t lengths[MAX_COLS];
    int cols_count = tokenize_csv_line(line, cols, lengths, MAX_COLS);

    if (cols_count > idx_categoria && cols_count > idx_monto) {
      char *nombre = cols[idx_categoria];
      size_t len_nombre = lengths[idx_categoria];

      char *precio = cols[idx_monto];
      size_t len_precio = lengths[idx_monto];

      format_and_append_product(&output_arena, nombre, len_nombre, precio,
                                len_precio, &offset);
    }
  }

  // 4. Forzar escritura de lo que quedó en el búfer final
  flush_buffer(&output_arena, &offset);

end:
  cleanup_file(csv_data, csv_size, fd);
  return 0;
}
