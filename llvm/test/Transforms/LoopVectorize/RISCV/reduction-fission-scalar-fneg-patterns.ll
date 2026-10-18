; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 \
; RUN:   -force-target-max-scalar-interleave=1 -enable-vplan-reduction-fission \
; RUN:   -pass-remarks=vplan-reduction-fission -S %s -o %t 2> %t.remarks
; RUN: FileCheck %s --check-prefix=IR < %t
; RUN: FileCheck %s --check-prefix=SELECT < %t.remarks
;
; Analogous float/double streams each shared by two independent accumulators.
; Flags here are original IR promises, solely to check verbatim preservation.
; No flags are added to the executable comparison fixtures or corpus.
; Source locations distinguish negation, update and latch. The original final
; negated values dominate the exit and require no further scratch allocation.
; SELECT: scalar-fneg-patterns.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 780, producer live-outs 2
; SELECT: scalar-fneg-patterns.c:12:3: scalar-IR fission producer VF 1
; SELECT: scalar-fneg-patterns.c:12:3: scalar-IR fission consumer VF 1
; IR-LABEL: define void @shared_negations(
; IR-COUNT-1: alloca [65 x double]
; IR-NOT: alloca [65 x double]
; IR: loop:
; IR: %dn = fneg nsz double %d, !dbg ![[NEG:[0-9]+]]
; IR: %fn = fneg nsz float %f, !dbg ![[NEG]]
; IR: store double %dn,
; IR: store float %fn,
; IR: scalar.fission.consumer.body:
; IR: %du0.consume = fadd nsz double %d0.consume, %[[D:[-a-zA-Z0-9.]+]], !dbg ![[UP:[0-9]+]]
; IR: %du1.consume = fsub nsz double %d1.consume, %[[D]], !dbg ![[UP]]
; IR: %fu0.consume = fadd nsz float %f0.consume, %[[F:[-a-zA-Z0-9.]+]], !dbg ![[UP]]
; IR: %fu1.consume = fsub nsz float %f1.consume, %[[F]], !dbg ![[UP]]
; IR: ![[NEG]] = !DILocation(line: 13, column: 5,
; IR: ![[UP]] = !DILocation(line: 14, column: 5,
define void @shared_negations(ptr %a, ptr %b, ptr %out, i64 %n) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %bypass
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %d0 = phi double [2.0, %preheader], [%du0, %loop]
  %d1 = phi double [3.0, %preheader], [%du1, %loop]
  %f0 = phi float [4.0, %preheader], [%fu0, %loop]
  %f1 = phi float [5.0, %preheader], [%fu1, %loop]
  %dp = getelementptr double, ptr %a, i64 %iv
  %fp = getelementptr float, ptr %b, i64 %iv
  %d = load double, ptr %dp, align 8
  %f = load float, ptr %fp, align 4
  %dn = fneg nsz double %d, !dbg !11
  %fn = fneg nsz float %f, !dbg !11
  %du0 = fadd nsz double %d0, %dn, !dbg !12
  %du1 = fsub nsz double %d1, %dn, !dbg !12
  %fu0 = fadd nsz float %f0, %fn, !dbg !12
  %fu1 = fsub nsz float %f1, %fn, !dbg !12
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !dbg !13
exit:
  %od0 = phi double [%du0, %loop]
  %od1 = phi double [%du1, %loop]
  %of0 = phi float [%fu0, %loop]
  %of1 = phi float [%fu1, %loop]
  %lastd = phi double [%dn, %loop]
  %lastf = phi float [%fn, %loop]
  store double %od0, ptr %out
  %o1 = getelementptr i8, ptr %out, i64 8
  store double %od1, ptr %o1
  %o2 = getelementptr i8, ptr %out, i64 16
  store float %of0, ptr %o2
  %o3 = getelementptr i8, ptr %out, i64 20
  store float %of1, ptr %o3
  %o4 = getelementptr i8, ptr %out, i64 24
  store double %lastd, ptr %o4
  %o5 = getelementptr i8, ptr %out, i64 32
  store float %lastf, ptr %o5
  ret void
bypass:
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-fneg-patterns.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !DISubroutineType(types: !6)
!6 = !{}
!10 = distinct !DISubprogram(name: "shared_negations", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 13, column: 5, scope: !10)
!12 = !DILocation(line: 14, column: 5, scope: !10)
!13 = !DILocation(line: 12, column: 3, scope: !10)
