#include "onigshim.h"
#include "oniguruma.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define MAXG 64
// Last search result per regex, reusable while searching the same string from a later start position.
typedef struct { int strId, from, pos, ngroups; int32_t caps[2 * MAXG]; } Cache;
// Regexes are compiled on first use (a search often stops at an earlier pattern that matches at the start position),
// so a pattern stays in `pats` until then.
typedef struct { int n; regex_t **regs; uint16_t **pats; int *lens; unsigned char *compiled; OnigRegion *region; Cache *cache; unsigned char *cacheable; } Scanner;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_init = 0;
static void init_once(void) {
  pthread_mutex_lock(&g_lock);
  if (!g_init) {
    OnigEncoding encs[] = { ONIG_ENCODING_UTF16_LE };
    onig_initialize(encs, 1);
    g_init = 1;
  }
  pthread_mutex_unlock(&g_lock);
}

// Compiled regexes by pattern, kept for the life of the process: grammars repeat the same patterns across many
// scanners (a rule's patterns appear in every scanner that includes the rule), and compiling dominates first use.
typedef struct { uint64_t hash; int len; uint16_t *pat; regex_t *reg; } Entry;
static Entry *g_table;
static size_t g_cap, g_count;

static uint64_t hash_pattern(const uint16_t *p, int len) {
  uint64_t h = 1469598103934665603ULL;
  for (int i = 0; i < len; i++) { h ^= p[i]; h *= 1099511628211ULL; }
  return h ? h : 1;
}

static void table_insert(Entry e) {
  size_t i = e.hash & (g_cap - 1);
  while (g_table[i].hash) i = (i + 1) & (g_cap - 1);
  g_table[i] = e;
  g_count++;
}

// Returns the compiled regex for a pattern (NULL if it does not compile), compiling it on first request.
static regex_t *regex_for(const uint16_t *p, int len) {
  uint64_t h = hash_pattern(p, len);
  pthread_mutex_lock(&g_lock);
  if (g_cap) {
    for (size_t i = h & (g_cap - 1); g_table[i].hash; i = (i + 1) & (g_cap - 1)) {
      Entry *e = &g_table[i];
      if (e->hash == h && e->len == len && memcmp(e->pat, p, (size_t)len * 2) == 0) {
        pthread_mutex_unlock(&g_lock);
        return e->reg;
      }
    }
  }
  regex_t *reg = NULL;
  OnigErrorInfo einfo;
  const UChar *u = (const UChar *)p;
  if (onig_new(&reg, u, u + (size_t)len * 2, ONIG_OPTION_CAPTURE_GROUP, ONIG_ENCODING_UTF16_LE, ONIG_SYNTAX_DEFAULT, &einfo) != ONIG_NORMAL) reg = NULL;
  if ((g_count + 1) * 2 > g_cap) {
    Entry *old = g_table;
    size_t oldCap = g_cap;
    g_cap = g_cap ? g_cap * 2 : 1024;
    g_table = calloc(g_cap, sizeof(Entry));
    g_count = 0;
    for (size_t i = 0; i < oldCap; i++) if (old[i].hash) table_insert(old[i]);
    free(old);
  }
  uint16_t *copy = malloc((size_t)(len > 0 ? len : 1) * 2);
  memcpy(copy, p, (size_t)len * 2);
  table_insert((Entry){ h, len, copy, reg });
  pthread_mutex_unlock(&g_lock);
  return reg;
}

void *shim_scanner_new(const uint16_t *const *patterns, const int *lengths, int count) {
  init_once();
  Scanner *sc = calloc(1, sizeof(Scanner));
  size_t n = count > 0 ? count : 1;
  sc->n = count;
  sc->regs = calloc(n, sizeof(regex_t *));
  sc->pats = calloc(n, sizeof(uint16_t *));
  sc->lens = calloc(n, sizeof(int));
  sc->compiled = calloc(n, 1);
  sc->region = onig_region_new();
  sc->cache = calloc(n, sizeof(Cache));
  sc->cacheable = calloc(n, 1);
  for (int i = 0; i < count; i++) {
    sc->lens[i] = lengths[i];
    sc->pats[i] = malloc((size_t)(lengths[i] > 0 ? lengths[i] : 1) * 2);
    memcpy(sc->pats[i], patterns[i], (size_t)lengths[i] * 2);
    sc->cacheable[i] = 1;  // \G (start-of-search anchor) makes results depend on the start position
    for (int k = 0; k + 1 < lengths[i]; k++) if (patterns[i][k] == '\\' && patterns[i][k + 1] == 'G') { sc->cacheable[i] = 0; break; }
  }
  return sc;
}

void shim_scanner_free(void *p) {
  Scanner *sc = p;
  if (!sc) return;
  for (int i = 0; i < sc->n; i++) free(sc->pats[i]);  // the regexes belong to the shared table
  onig_region_free(sc->region, 1);
  free(sc->regs); free(sc->pats); free(sc->lens); free(sc->compiled); free(sc->cache); free(sc->cacheable);
  free(sc);
}

int shim_scanner_find(void *p, int strId, const uint16_t *s, int len, int start, int32_t *out, int maxgroups, int *ngroups) {
  Scanner *sc = p;
  const UChar *base = (const UChar *)s, *end = base + (size_t)len * 2;
  int best = -1, bestPos = 0x7fffffff;
  for (int i = 0; i < sc->n; i++) {
    if (!sc->compiled[i]) {
      sc->regs[i] = regex_for(sc->pats[i], sc->lens[i]);
      sc->compiled[i] = 1;
      free(sc->pats[i]);
      sc->pats[i] = NULL;
    }
    regex_t *reg = sc->regs[i];
    if (!reg) continue;
    Cache *ca = &sc->cache[i];
    int pos;
    if (sc->cacheable[i] && ca->strId == strId && ca->from <= start && (ca->pos < 0 || ca->pos >= start)) {
      pos = ca->pos;
    } else {
      onig_region_clear(sc->region);
      int r = onig_search(reg, base, end, base + (size_t)start * 2, end, sc->region, ONIG_OPTION_NONE);
      pos = r < 0 ? -1 : r / 2;
      ca->strId = strId; ca->from = start; ca->pos = pos;
      if (pos >= 0) {
        int n = sc->region->num_regs < MAXG ? sc->region->num_regs : MAXG;
        ca->ngroups = n;
        for (int g = 0; g < n; g++) {
          int b = sc->region->beg[g], e = sc->region->end[g];
          ca->caps[2 * g] = b < 0 ? 0 : b / 2;
          ca->caps[2 * g + 1] = e < 0 ? 0 : e / 2;
        }
      }
    }
    if (pos < 0) continue;
    if (pos < bestPos) {
      bestPos = pos; best = i;
      if (pos == start) break;
    }
  }
  if (best >= 0) {
    Cache *ca = &sc->cache[best];
    *ngroups = ca->ngroups;
    for (int k = 0; k < 2 * ca->ngroups && k < 2 * maxgroups; k++) out[k] = ca->caps[k];
  }
  return best;
}
