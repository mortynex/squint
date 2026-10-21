#ifndef ONIGSHIM_H
#define ONIGSHIM_H
#include <stdint.h>

// Scanner: an ordered list of Oniguruma regexes (UTF-16LE), searched like vscode-oniguruma's OnigScanner.
void *shim_scanner_new(const uint16_t *const *patterns, const int *lengths, int count);
void shim_scanner_free(void *scanner);
// Searches `s` (UTF-16, `len` units) from `start`. On match returns the pattern index and fills
// `out` with [start0,end0,start1,end1,...] (UTF-16 units, 0,0 for unmatched groups) and `*ngroups`.
// Returns -1 if nothing matched. `out` must hold at least 2*maxgroups ints.
int shim_scanner_find(void *scanner, int strId, const uint16_t *s, int len, int start, int32_t *out, int maxgroups, int *ngroups);
#endif
