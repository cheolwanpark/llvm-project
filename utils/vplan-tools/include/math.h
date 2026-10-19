/* Target library declarations; ordinary calls/builtins retain their semantics. */
#ifndef VPLAN_TOOLS_MATH_H
#define VPLAN_TOOLS_MATH_H
#ifdef __cplusplus
extern "C" {
#endif
#define VPLAN_MATH_UNARY(name) double name(double); float name##f(float); long double name##l(long double);
VPLAN_MATH_UNARY(fabs)
VPLAN_MATH_UNARY(sqrt)
VPLAN_MATH_UNARY(sin)
VPLAN_MATH_UNARY(cos)
VPLAN_MATH_UNARY(exp)
VPLAN_MATH_UNARY(log)
VPLAN_MATH_UNARY(log10)
VPLAN_MATH_UNARY(floor)
VPLAN_MATH_UNARY(ceil)
VPLAN_MATH_UNARY(acos)
VPLAN_MATH_UNARY(atan)
#undef VPLAN_MATH_UNARY
double pow(double, double);
float powf(float, float);
double fmin(double, double);
double fmax(double, double);
float fminf(float, float);
float fmaxf(float, float);
#ifdef __cplusplus
}
#endif
#endif
