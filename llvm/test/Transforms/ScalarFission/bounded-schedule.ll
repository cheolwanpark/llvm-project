; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -S %s | FileCheck %s --check-prefix=FIT
; RUN: opt -passes=scalar-fission -verify-each -scalar-fission-chunk-capacity=8 -S %s | FileCheck %s --check-prefix=FIT
; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=CHUNKS
; RUN: opt -passes=scalar-fission -verify-each -scalar-fission-max-scratch-bytes=8 -S %s | FileCheck %s --check-prefix=BUDGET
; RUN: opt -passes='function(scalar-fission),default<O3>' -verify-each -S %s | FileCheck %s --check-prefix=FINAL
;
; A maximum is not an exact count: retain the original producer continuation
; and use the number actually completed for the consumer, including n=0/1.

; FIT-LABEL: define double @exact(
; FIT: alloca [8 x double]
; FIT-NOT: .chunk = phi
; FIT-NOT: fission.more
; FIT: scalar.fission.chunk.latch:
; FIT-NEXT: br label %exit{{$}}
; FIT: loop.consume:
; FIT: %s.consume = phi double [ %seed,
; FIT: icmp ult i64 %fission.consumer.next, %fission.consumer.count
; FIT: call void @llvm.lifetime.end
; FIT: ret double
; BUDGET-LABEL: define double @exact(
; BUDGET: alloca [1 x double]
; CHUNKS-LABEL: define double @exact(
; CHUNKS: alloca [3 x double]
; CHUNKS: fission.more = select i1
; CHUNKS: br i1 %more.produced, label %scalar.fission.chunk, label %exit
; BUDGET: fission.more = select i1
; BUDGET: br i1 %more.produced, label %scalar.fission.chunk, label %exit
; FINAL-LABEL: define double @exact(
; FINAL-NOT: fission.more
; FINAL-NOT: br i1 {{.*}}, label %scalar.fission.chunk,
; FINAL: ret double

define double @exact(ptr %a, i64 %n, double %seed) {
entry:
  br label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s = phi double [%seed, %ph], [%u, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %f = fmul double %x, %x
  %u = fadd double %s, %f
  %next = add nuw i64 %i, 1
  %more = icmp ult i64 %next, 8
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%u, %loop]
  ret double %r
}

; FIT-LABEL: define double @bounded(
; FIT: alloca [8 x double]
; FIT-NOT: .chunk = phi
; FIT-NOT: fission.more
; FIT: scalar.fission.chunk.latch:
; FIT-NEXT: br label %exit{{$}}
; FIT: loop.consume:
; FIT: %s.consume = phi double [ %seed,
; FIT: icmp ult i64 %fission.consumer.next, %fission.consumer.count
; FIT: call void @llvm.lifetime.end
; FIT: ret double
; BUDGET-LABEL: define double @bounded(
; BUDGET: alloca [1 x double]
; CHUNKS-LABEL: define double @bounded(
; CHUNKS: alloca [3 x double]
; CHUNKS: fission.more = select i1
; CHUNKS: br i1 %more.produced, label %scalar.fission.chunk, label %exit
; BUDGET: fission.more = select i1
; BUDGET: br i1 %more.produced, label %scalar.fission.chunk, label %exit
; FINAL-LABEL: define double @bounded(
; FINAL-NOT: fission.more
; FINAL-NOT: br i1 {{.*}}, label %scalar.fission.chunk,
; FINAL: ret double

define double @bounded(ptr %a, i64 %n, double %seed) {
entry:
  %small = icmp ult i64 %n, 8
  %limit = select i1 %small, i64 %n, i64 8
  %empty = icmp eq i64 %limit, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s = phi double [%seed, %ph], [%u, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %f = fmul double %x, %x
  %u = fadd double %s, %f
  %next = add nuw i64 %i, 1
  %more = icmp ult i64 %next, %limit
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%u, %loop]
  br label %done
done:
  %result = phi double [%seed, %entry], [%r, %exit]
  ret double %result
}

; FIT-LABEL: define double @one(
; FIT: alloca [1 x double]
; FIT-NOT: .chunk = phi
; FIT-NOT: fission.more
; FIT: scalar.fission.chunk.latch:
; FIT-NEXT: br label %exit{{$}}
; FIT: loop.consume:
; FIT: %s.consume = phi double [ %seed,
; FIT: icmp ult i64 %fission.consumer.next, %fission.consumer.count
; FIT: call void @llvm.lifetime.end
; FIT: ret double
; BUDGET-LABEL: define double @one(
; BUDGET: alloca [1 x double]
; FINAL-LABEL: define double @one(
; FINAL-NOT: fission.more
; FINAL-NOT: br i1 {{.*}}, label %scalar.fission.chunk,
; FINAL: ret double

define double @one(ptr %a, i64 %n, double %seed) {
entry:
  %small = icmp ult i64 %n, 1
  %limit = select i1 %small, i64 %n, i64 1
  %empty = icmp eq i64 %limit, 0
  br i1 %empty, label %done, label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s = phi double [%seed, %ph], [%u, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %f = fmul double %x, %x
  %u = fadd double %s, %f
  %next = add nuw i64 %i, 1
  %more = icmp ult i64 %next, %limit
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%u, %loop]
  br label %done
done:
  %result = phi double [%seed, %entry], [%r, %exit]
  ret double %result
}
