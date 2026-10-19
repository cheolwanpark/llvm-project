#include <stdint.h>
uint32_t pure(uint32_t x) { return x * x + 5; }
uint32_t helper(const uint32_t *p) { return *p * 3; }
uint32_t effect(uint32_t *p) {
  *p = *p * UINT32_C(1664525) + UINT32_C(1013904223);
  return *p;
}
double square(double x) { return x * x + 1.0; }
