#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define DECL(ret, name, args) extern ret name args; extern ret ref_##name args
DECL(int32_t, integer_chain, (const int32_t *, const int32_t *, uint64_t, int32_t));
DECL(float, reassoc_chain, (const float *, const float *, uint64_t, float));
DECL(double, double_chain, (const double *, const double *, uint64_t, double));
DECL(float, reassoc_fmuladd_product, (const float *, const float *, uint64_t, float));
DECL(float, reassoc_negative_zero, (const float *, uint64_t));
DECL(float, readonly_sum, (const float *, uint64_t, float));
DECL(float, invariant, (uint64_t, float, float));
DECL(double, invariant_chain, (uint64_t, double, double, double));
DECL(float, invariant_with_map, (uint64_t *, uint64_t, float, float));
DECL(void, readonly_minmax, (const float *, float *, float, float));
DECL(void, shared_pair, (const float *, const float *, float *, uint64_t, float, float));
DECL(void, shared_guarded, (const float *, const float *, const uint8_t *, float *, uint64_t, float, float));
DECL(float, selected_contribution, (const float *, const uint8_t *, uint64_t, float));
DECL(uint32_t, conditional_division, (const uint32_t *, const uint8_t *, uint64_t, uint32_t, uint32_t));
DECL(void, four_accumulators, (const float *, const float *, float *));
DECL(void, eight_accumulators, (const float *, const float *, float *));
DECL(void, readonly_liveout, (const float *, float *, uint64_t *, uint64_t, float));
DECL(void, nested_readonly, (const float *, float *, uint64_t, uint64_t, float));
DECL(float, conditional_minmax, (const float *, const uint8_t *, uint64_t, float));
DECL(float, conditional_minmax_finite, (const float *, const uint8_t *, uint64_t, float));
DECL(void, signed_unsigned_widening, (const uint8_t *, uint32_t *, uint64_t, uint32_t, uint32_t));
DECL(void, mixed_widening, (const float *, double *, uint64_t, float, double));
DECL(void, shared_eight, (const float *, const float *, float *));
DECL(float, conditional_minmax_ninf, (const float *, const uint8_t *, uint64_t, float));
DECL(int32_t, smin_chain, (const int32_t *, const int32_t *, uint64_t, int32_t));
DECL(int32_t, smax_chain, (const int32_t *, const int32_t *, uint64_t, int32_t));
DECL(uint32_t, umin_chain, (const uint32_t *, const uint32_t *, uint64_t, uint32_t));
DECL(uint32_t, umax_chain, (const uint32_t *, const uint32_t *, uint64_t, uint32_t));
DECL(float, minnum_chain, (const float *, const float *, uint64_t, float));
DECL(float, maxnum_chain, (const float *, const float *, uint64_t, float));
float bounded[64];
DECL(float, bounded_global_stream, (float));
static unsigned checks;
static void check(double a, double b, const char *name, unsigned n) {
  ++checks;
  if ((isnan(a) && isnan(b)) || (a == b && (a != 0 || signbit(a) == signbit(b)))) return;
  fprintf(stderr, "%s N=%u: reference %.17g (%d), transformed %.17g (%d)\n", name, n, a, signbit(a), b, signbit(b));
  exit(1);
}
#define CMP(name, ...) check(ref_##name(__VA_ARGS__), name(__VA_ARGS__), #name, n)
static uint32_t seed = 7729;
static uint32_t rnd(void) { seed = seed * 1664525u + 1013904223u; return seed; }
extern void fission_check_allocations(void);
extern void *fission_guarded_input(size_t);
extern void __wrap_free(void *);
int main(void) {
  static const unsigned counts[] = {0,1,2,3,4,5,7,8,15,16,17,31,32,33,63,64,65,127,128,129,255,256,257,511,512,513};
  float a[1024], b[1024], out[8], ref[8];
  double da[1024], db[1024];
  int32_t ia[1024], ib[1024];
  uint32_t den[1024], iw[2], iwref[2]; uint8_t flags[1024], bytes[1024];
  double dw[2], dwref[2];
  uint64_t mapped[1024], mapped_ref[1024];
  for (unsigned t=0; t<16; ++t) {
    for (unsigned i=0;i<1024;++i) {
      ia[i]=(int)(rnd()%129)-64; ib[i]=(int)(rnd()%129)-64;
      a[i]=da[i]=ia[i]/16.0; b[i]=db[i]=ib[i]/16.0;
      bytes[i]=rnd();
      flags[i]=(rnd()%3)!=0; den[i]=flags[i] ? 1+rnd()%29 : 0;
    }
    for (unsigned k=0; k<sizeof(counts)/sizeof(counts[0]); ++k) {
      unsigned n=counts[k];
      float init=(int)t-8;
      CMP(integer_chain,ia,ib,n,91);
      CMP(smin_chain,ia,ib,n,91);CMP(smax_chain,ia,ib,n,-91);
      CMP(umin_chain,(uint32_t*)ia,(uint32_t*)ib,n,0xfffffffeu);
      CMP(umax_chain,(uint32_t*)ia,(uint32_t*)ib,n,3u);
      CMP(minnum_chain,a,b,n,1.0f);CMP(maxnum_chain,a,b,n,-1.0f);
      CMP(conditional_minmax_ninf,a,flags,n,1.0f);
      signed_unsigned_widening(bytes,iw,n,0xfffffff0u,17);ref_signed_unsigned_widening(bytes,iwref,n,0xfffffff0u,17);
      for(unsigned j=0;j<2;++j) check(iwref[j],iw[j],"signed_unsigned_widening",n);
      mixed_widening(a,dw,n,init,init+0.125);ref_mixed_widening(a,dwref,n,init,init+0.125);
      for(unsigned j=0;j<2;++j) check(dwref[j],dw[j],"mixed_widening",n);
      CMP(reassoc_chain,a,b,n,init);
      CMP(double_chain,da,db,n,(double)init);
      CMP(reassoc_fmuladd_product,a,b,n,init);
      CMP(readonly_sum,a,n,init);
      CMP(invariant,n,init,0.125f);
      CMP(invariant_chain,n,(double)init,0.125,0.25);
      CMP(selected_contribution,a,flags,n,init);
      CMP(conditional_division,den,flags,n,0xfffffff0u,0xffffffffu);
      CMP(conditional_minmax_finite,a,flags,n,init);
      shared_pair(a,b,out,n,init,init+1); ref_shared_pair(a,b,ref,n,init,init+1);
      for(unsigned j=0;j<2;++j) check(ref[j],out[j],"shared_pair",n);
      shared_guarded(a,b,flags,out,n,init,init+1); ref_shared_guarded(a,b,flags,ref,n,init,init+1);
      for(unsigned j=0;j<2;++j) check(ref[j],out[j],"shared_guarded",n);
      uint64_t idx, idxref;
      readonly_liveout(a,out,&idx,n,init);ref_readonly_liveout(a,ref,&idxref,n,init);
      check(ref[0],out[0],"readonly_liveout",n);
      if(idx!=idxref || idx!=(uint64_t)n-1) {fprintf(stderr,"induction live-out mismatch N=%u\n",n);return 1;} ++checks;
      for(unsigned j=0;j<8;++j) out[j]=ref[j]=123.0f;
      nested_readonly(a,out,n,3,init);ref_nested_readonly(a,ref,n,3,init);
      for(unsigned j=0;j<8;++j) check(ref[j],out[j],"nested_readonly",n);
      memset(mapped,0xa5,sizeof(mapped)); memset(mapped_ref,0xa5,sizeof(mapped_ref));
      check(ref_invariant_with_map(mapped_ref,n,init,0.5),invariant_with_map(mapped,n,init,0.5),"invariant_with_map",n);
      if(memcmp(mapped,mapped_ref,sizeof(mapped))) {fprintf(stderr,"Map output/bounds mismatch N=%u\n",n);return 1;} ++checks;
    }
    unsigned n=31;
    for(unsigned i=0;i<64;++i) bounded[i]=a[i];
    check(ref_bounded_global_stream(3.0f),bounded_global_stream(3.0f),"bounded_global_stream",64);
    readonly_minmax(a,out,-3,3);ref_readonly_minmax(a,ref,-3,3);
    for(unsigned j=0;j<2;++j) check(ref[j],out[j],"readonly_minmax",n);
    four_accumulators(a,b,out);ref_four_accumulators(a,b,ref);
    for(unsigned j=0;j<4;++j) check(ref[j],out[j],"four_accumulators",256);
    shared_eight(a,b,out);ref_shared_eight(a,b,ref);
    for(unsigned j=0;j<8;++j) check(ref[j],out[j],"shared_eight",n);
    eight_accumulators(a,b,out);ref_eight_accumulators(a,b,ref);
    for(unsigned j=0;j<8;++j) check(ref[j],out[j],"eight_accumulators",n);
  }
  for(unsigned k=0;k<sizeof(counts)/sizeof(counts[0]);++k) {
    unsigned n=counts[k];
    memset(flags,0,sizeof(flags));
    for(unsigned i=0;i<1024;++i) {a[i]=b[i]=-0.0f;da[i]=db[i]=-0.0;}
    CMP(double_chain,da,db,n,-0.0);
    CMP(invariant,n,-0.0f,-0.0f);
    CMP(invariant_chain,n,-0.0,-0.0,-0.0);
    CMP(readonly_sum,a,n,-0.0f);
    CMP(reassoc_negative_zero,a,n);
    CMP(conditional_division,NULL,flags,n,0xffffffffu,0xffffffffu);
    const float special[] = {-0.0f,INFINITY,-INFINITY,NAN};
    for(unsigned s=0;s<4;++s) {
      // Null source addresses and zero denominators are only on skipped paths.
      shared_guarded(NULL,NULL,flags,out,n,special[s],special[s]);
      ref_shared_guarded(NULL,NULL,flags,ref,n,special[s],special[s]);
      for(unsigned j=0;j<2;++j) check(ref[j],out[j],"skipped shared_guarded",n);
      CMP(selected_contribution,a,flags,n,special[s]);
      CMP(conditional_minmax,NULL,flags,n,special[s]);
      CMP(conditional_minmax_ninf,NULL,flags,n,special[s]);
      CMP(conditional_minmax_finite,NULL,flags,n,special[s]);
      CMP(readonly_sum,a,n,special[s]);
      CMP(invariant_chain,n,(double)special[s],1.0,2.0);
    }
  }
  { unsigned n=1; ia[0]=ib[0]=INT32_MAX; CMP(integer_chain,ia,ib,n,INT32_MIN); }
  { unsigned n=0; CMP(readonly_sum,NULL,n,-0.0f); CMP(reassoc_chain,NULL,NULL,n,3.0f); }
  // No FP operation executes on the original all-skipped path: preserve
  // NaN sign, payload and signaling bit, rather than only its classification.
  {
    static const uint32_t patterns[]={0x7fc12345u,0xffcabcdeu,0x7f800001u,0xff800001u,0x00000000u,0x80000000u,0x00000001u,0x80000001u};
    unsigned n=3; memset(flags,0,sizeof(flags));
    for(unsigned k=0;k<sizeof(patterns)/sizeof(patterns[0]);++k) {
      float init;memcpy(&init,&patterns[k],4);
      shared_guarded(NULL,NULL,flags,out,n,init,init);
      ref_shared_guarded(NULL,NULL,flags,ref,n,init,init);
      for(unsigned j=0;j<2;++j) {
        uint32_t actual,expected;memcpy(&actual,&out[j],4);memcpy(&expected,&ref[j],4);
        if(expected!=patterns[k]) {fprintf(stderr,"reference changed initializer bits\n");return 1;}
        if(actual!=expected) {fprintf(stderr,"skipped initializer copy mismatch: %08x vs %08x\n",expected,actual);return 1;}
        ++checks;
      }
      float value=selected_contribution(a,flags,n,init);
      float reference=ref_selected_contribution(a,flags,n,init);
      uint32_t actual,expected;memcpy(&actual,&value,4);memcpy(&expected,&reference,4);
      if(expected!=patterns[k] || actual!=expected) {fprintf(stderr,"selected initializer copy mismatch\n");return 1;}
      ++checks;
      value=conditional_minmax(NULL,flags,n,init);
      reference=ref_conditional_minmax(NULL,flags,n,init);
      memcpy(&actual,&value,4);memcpy(&expected,&reference,4);
      if(expected!=patterns[k] || actual!=expected) {fprintf(stderr,"minnum initializer copy mismatch\n");return 1;}
      ++checks;
      value=conditional_minmax_ninf(NULL,flags,n,init);
      reference=ref_conditional_minmax_ninf(NULL,flags,n,init);
      memcpy(&actual,&value,4);memcpy(&expected,&reference,4);
      if(expected!=patterns[k] || actual!=expected) {fprintf(stderr,"ninf minnum initializer copy mismatch\n");return 1;}
      ++checks;
    }
  }
  // Exact end-of-page input bounds, including short and tail vector loads.
  // Scratch uses malloc-compatible alignment plus checked padding canaries.
  for(unsigned k=0;k<sizeof(counts)/sizeof(counts[0]);++k) {
    unsigned n=counts[k];
    float *ga=fission_guarded_input(n*sizeof(float));
    float *gb=fission_guarded_input(n*sizeof(float));
    double *gda=fission_guarded_input(n*sizeof(double));
    double *gdb=fission_guarded_input(n*sizeof(double));
    uint8_t *gf=fission_guarded_input(n);
    uint8_t *gx=fission_guarded_input(n);
    for(unsigned i=0;i<n;++i) {ga[i]=gda[i]=(int)(i%17)-8;gb[i]=gdb[i]=i%5;gf[i]=(i%3)!=0;gx[i]=(uint8_t)i;}
    CMP(readonly_sum,ga,n,3.0f);
    CMP(reassoc_chain,ga,gb,n,3.0f);
    CMP(double_chain,gda,gdb,n,3.0);
    CMP(reassoc_fmuladd_product,ga,gb,n,3.0f);
    CMP(selected_contribution,ga,gf,n,3.0f);
    shared_guarded(ga,gb,gf,out,n,1.0f,2.0f);ref_shared_guarded(ga,gb,gf,ref,n,1.0f,2.0f);
    for(unsigned j=0;j<2;++j) check(ref[j],out[j],"guarded shared_guarded",n);
    signed_unsigned_widening(gx,iw,n,0xfffffff0u,17);ref_signed_unsigned_widening(gx,iwref,n,0xfffffff0u,17);
    for(unsigned j=0;j<2;++j) check(iwref[j],iw[j],"guarded widening",n);
    mixed_widening(ga,dw,n,1.0f,2.0);ref_mixed_widening(ga,dwref,n,1.0f,2.0);
    for(unsigned j=0;j<2;++j) check(dwref[j],dw[j],"guarded mixed_widening",n);
    __wrap_free(ga);__wrap_free(gb);__wrap_free(gda);__wrap_free(gdb);__wrap_free(gf);__wrap_free(gx);
  }
  fission_check_allocations();
  printf("passed %u RVV/reference comparisons; seed=7729\n",checks);
  return 0;
}
