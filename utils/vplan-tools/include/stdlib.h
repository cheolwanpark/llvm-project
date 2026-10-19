#ifndef VPLAN_TOOLS_STDLIB_H
#define VPLAN_TOOLS_STDLIB_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void exit(int) __attribute__((noreturn));
void abort(void) __attribute__((noreturn));
int abs(int);
long labs(long);
void *malloc(size_t);
void *calloc(size_t, size_t);
void free(void *);
#ifdef __cplusplus
}
#endif
#endif
