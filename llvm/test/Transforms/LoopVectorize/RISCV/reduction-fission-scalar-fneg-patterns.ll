; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -scalar-fission-chunk-capacity=3 -S %s | FileCheck %s --check-prefix=SCALAR-MIGRATION
; RUN: opt -passes='scalar-fission,scalar-fission,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -scalar-fission-chunk-capacity=1 -S %s -o %t.scalar.ll
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.scalar.ll -o /dev/null
; SCALAR-MIGRATION checks characterize the independent scalar pass; semantic
; SCALAR-MIGRATION-LABEL: define {{.*}} @shared_negations(
; SCALAR-MIGRATION: scalar.fission.chunk:
; SCALAR-MIGRATION: }
; Dependent contribution arithmetic preserves positive feature coverage under
; the final producer depth policy. Checks exercise scalar fission and ordinary LV.
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
  %dn.depth.mul = fmul double %d, 5.000000e-01
  %dn.depth.bias = fadd double %dn.depth.mul, 1.250000e+00
  %dn = fneg nsz double %dn.depth.bias, !dbg !11
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
