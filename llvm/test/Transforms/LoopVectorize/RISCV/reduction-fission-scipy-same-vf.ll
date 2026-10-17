; REQUIRES: asserts
; RUN: opt -verify-each -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
; RUN:   -mtriple=riscv64 -mattr=+v,+f,+d,+zvl128b \
; RUN:   -tail-folding-policy=must-fold-tail \
; RUN:   -enable-vplan-reduction-fission -debug-only=vplan-reduction-fission \
; RUN:   -S %s -o %t 2>&1 | FileCheck %s --check-prefix=SELECT
; RUN: FileCheck %s --check-prefix=IR < %t
; RUN: llc -verify-machineinstrs -mtriple=riscv64 -mattr=+v,+f,+d,+zvl128b %t -o /dev/null
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v,+f,+d,+zvl128b \
; RUN:   -tail-folding-policy=must-fold-tail -S %s \
; RUN:   | FileCheck %s --check-prefix=OFF
;
; SciPy/VDT sincos reduction shape with a constant bound. The larger producer
; VF is not pressure-safe, but equal-VF fission still reduces pressure.
; No forced VF or lowered analysis thresholds are used.
;
; SELECT: candidate: reductions=5 scratch-bytes=16384
; SELECT-SAME: baseline-vf=vscale x 2 producer-vf=vscale x 2 accumulator-vf=vscale x 2
;
; IR-LABEL: define {{.*}}void @kernel(
; IR-COUNT-2: alloca [1024 x double]
; IR: vector.fission.producer.body:
; IR: @llvm.fabs.nxv2f64
; IR-COUNT-2: store <vscale x 2 x double>
; IR: vector.fission.accumulator.body:
; IR-COUNT-2: load <vscale x 2 x double>
; IR: @llvm.vector.reduce.fadd.nxv2f64
;
; OFF-LABEL: define {{.*}}void @kernel(
; OFF-NOT: fission
; OFF: ret void

target datalayout = "e-m:e-p:64:64-i64:64-i128:128-n32:64-S128"
target triple = "riscv64-unknown-unknown-elf"

define dso_local void @kernel(ptr noundef readonly captures(none) %0, ptr noundef readonly captures(none) %1, i64 noundef %2, double noundef nofpclass(nan inf) %3, ptr noundef readnone captures(none) %4, ptr noundef readnone captures(none) %5, ptr noundef readnone captures(none) %6, ptr noundef readnone captures(none) %7, ptr noundef readnone captures(none) %8, ptr noundef writeonly captures(none) %9) local_unnamed_addr #0 {
  br label %16

11:                                               ; preds = %16
  store double %81, ptr %9, align 8
  %12 = getelementptr inbounds nuw i8, ptr %9, i64 8
  store double %83, ptr %12, align 8
  %13 = getelementptr inbounds nuw i8, ptr %9, i64 16
  store double %85, ptr %13, align 8
  %14 = getelementptr inbounds nuw i8, ptr %9, i64 24
  store double %87, ptr %14, align 8
  %15 = getelementptr inbounds nuw i8, ptr %9, i64 32
  store double %89, ptr %15, align 8
  ret void

16:                                               ; preds = %10, %16
  %17 = phi i64 [ 0, %10 ], [ %90, %16 ]
  %18 = phi double [ 0.000000e+00, %10 ], [ %89, %16 ]
  %19 = phi double [ 0.000000e+00, %10 ], [ %87, %16 ]
  %20 = phi double [ 0.000000e+00, %10 ], [ %85, %16 ]
  %21 = phi double [ 0.000000e+00, %10 ], [ %83, %16 ]
  %22 = phi double [ 0.000000e+00, %10 ], [ %81, %16 ]
  %23 = getelementptr inbounds nuw double, ptr %0, i64 %17
  %24 = load double, ptr %23, align 8
  %25 = fmul fast double %24, %3
  %26 = tail call fast double @llvm.fabs.f64(double nofpclass(nan inf) %25)
  %27 = fmul fast double %26, 0x3FF45F306DC9C883
  %28 = fptosi double %27 to i32
  %29 = add nsw i32 %28, 1
  %30 = and i32 %29, -2
  %31 = sitofp i32 %30 to double
  %32 = fmul fast double %31, 0x3FE921FB54442D18
  %33 = fsub fast double %26, %32
  %34 = and i32 %29, 4
  %35 = add nsw i32 %30, -2
  %36 = and i32 %35, 4
  %37 = and i32 %35, 2
  %38 = fmul fast double %33, %33
  %39 = fmul fast double %38, %33
  %40 = fmul fast double %38, 0x3DE5D8FD1FD19CCD
  %41 = fadd fast double %40, 0xBE5AE5E5A9291F5D
  %42 = fmul fast double %41, %38
  %43 = fadd fast double %42, 0x3EC71DE3567D48A1
  %44 = fmul fast double %43, %38
  %45 = fadd fast double %44, 0xBF2A01A019BFDF03
  %46 = fmul fast double %45, %38
  %47 = fadd fast double %46, 0x3F8111111110F7D0
  %48 = fmul fast double %47, %38
  %49 = fadd fast double %48, 0xBFC5555555555548
  %50 = fmul fast double %39, %49
  %51 = fadd fast double %50, %33
  %52 = fmul fast double %38, 0x3DA8FA49A0861A9B
  %53 = fsub fast double 0x3E21EE9D7B4E3F05, %52
  %54 = fmul fast double %53, %38
  %55 = fadd fast double %54, 0xBE927E4F7EAC4BC6
  %56 = fmul fast double %55, %38
  %57 = fadd fast double %56, 0x3EFA01A019C844F5
  %58 = fmul fast double %57, %38
  %59 = fadd fast double %58, 0xBF56C16C16C14F91
  %60 = fmul fast double %59, %38
  %61 = fadd fast double %60, 0x3FA555555555554B
  %62 = fmul fast double %61, %38
  %63 = fadd fast double %62, -5.000000e-01
  %64 = fmul fast double %63, %38
  %65 = fadd fast double %64, 1.000000e+00
  %66 = icmp eq i32 %37, 0
  %67 = select i1 %66, double %65, double %51
  %68 = select i1 %66, double %51, double %65
  %69 = icmp eq i32 %36, 0
  %70 = fneg fast double %68
  %71 = select nsz i1 %69, double %70, double %68
  %72 = icmp eq i32 %34, 0
  %73 = fneg fast double %67
  %74 = select nsz i1 %72, double %67, double %73
  %75 = fcmp fast olt double %25, 0.000000e+00
  %76 = fneg fast double %74
  %77 = select nsz i1 %75, double %76, double %74
  %78 = getelementptr inbounds nuw double, ptr %1, i64 %17
  %79 = load double, ptr %78, align 8
  %80 = fmul fast double %71, %79
  %81 = fadd fast double %80, %22
  %82 = fmul fast double %77, %79
  %83 = fadd fast double %82, %21
  %84 = fmul fast double %71, %71
  %85 = fadd fast double %84, %20
  %86 = fmul fast double %77, %77
  %87 = fadd fast double %86, %19
  %88 = fmul fast double %77, %71
  %89 = fadd fast double %88, %18
  %90 = add nuw nsw i64 %17, 1
  %91 = icmp eq i64 %90, 1024
  br i1 %91, label %11, label %16
}

declare double @llvm.fabs.f64(double) #1

attributes #0 = { vscale_range(2,1024) }
attributes #1 = { nounwind speculatable willreturn memory(none) }
