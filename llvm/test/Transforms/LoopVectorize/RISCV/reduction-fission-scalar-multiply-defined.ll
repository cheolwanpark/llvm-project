; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off -S %s | FileCheck %s
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off -vplan-reduction-fission-allow-fp-reordering -vplan-reduction-fission-max-scratch-bytes=17 -S %s | FileCheck %s
;
; All entered executions are defined: the first factor is3, all later factors1.
; Positive seeds remain within signed i8; negative seeds carry only nsw.
; Original operations and source locations must survive scalar consumer cloning.
; The executable oracle compares these exact originals at C1/C8/C9/C65.
; CHECK-LABEL: define void @multiply_defined(
; CHECK: %state.next = mul i32 %state, %x
; CHECK: scalar.fission.consumer.body:
; CHECK: %u.a0.consume = mul nuw nsw i32 %a0.consume,
; CHECK: %u.a1.consume = mul nsw i32 {{%[-a-zA-Z$._0-9]+}}, %a1.consume
; CHECK: %u.x0.consume = mul nuw i64 %x0.consume,
; CHECK: %u.x1.consume = mul nsw i64 {{%[-a-zA-Z$._0-9]+}}, %x1.consume
; CHECK: %u.b0.consume = mul nuw nsw i8 %b0.consume,
; CHECK: %u.b1.consume = mul nsw i8 {{%[-a-zA-Z$._0-9]+}}, %b1.consume
; CHECK: ret void
define void @multiply_defined(ptr %a, ptr %mem, ptr %out, i64 %n, i32 %mode, i32 %seed) !dbg !40 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !41
loop:
  %iv = phi i64 [ 0, %preheader ], [ %next, %loop ]
  %state = phi i32 [ %seed, %preheader ], [ %state.next, %loop ]
  %a0 = phi i32 [ 5, %preheader ], [ %u.a0, %loop ]
  %a1 = phi i32 [ -7, %preheader ], [ %u.a1, %loop ]
  %o0 = phi i32 [ 324508639, %preheader ], [ %u.o0, %loop ]
  %o1 = phi i32 [ 610839776, %preheader ], [ %u.o1, %loop ]
  %x0 = phi i64 [ 1073741824, %preheader ], [ %u.x0, %loop ]
  %x1 = phi i64 [ -19, %preheader ], [ %u.x1, %loop ]
  %b0 = phi i8 [ 11, %preheader ], [ %u.b0, %loop ]
  %b1 = phi i8 [ -13, %preheader ], [ %u.b1, %loop ]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %factor.first = icmp eq i64 %iv, 0
  %c = select i1 %factor.first, i32 3, i32 1
  %bc = trunc i32 %c to i8
  %dc = zext i32 %c to i64
  %state.next = mul i32 %state, %x
  %wp = getelementptr i32, ptr %mem, i64 %iv
  store i32 %state.next, ptr %wp, align 4
  %u.a0 = mul nuw nsw i32 %a0, %c, !dbg !42
  %u.a1 = mul nsw i32 %c, %a1, !dbg !43
  %u.o0 = or i32 %o0, %c, !dbg !44
  %u.o1 = or i32 %c, %o1, !dbg !45
  %u.x0 = mul nuw i64 %x0, %dc, !dbg !46
  %u.x1 = mul nsw i64 %dc, %x1, !dbg !47
  %u.b0 = mul nuw nsw i8 %b0, %bc, !dbg !48
  %u.b1 = mul nsw i8 %bc, %b1, !dbg !49
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !41
producer.exit:
  %out.a0 = phi i32 [ %u.a0, %loop ]
  %out.a1 = phi i32 [ %u.a1, %loop ]
  %out.o0 = phi i32 [ %u.o0, %loop ]
  %out.o1 = phi i32 [ %u.o1, %loop ]
  %out.x0 = phi i64 [ %u.x0, %loop ]
  %out.x1 = phi i64 [ %u.x1, %loop ]
  %out.b0 = phi i8 [ %u.b0, %loop ]
  %out.b1 = phi i8 [ %u.b1, %loop ]
  %out.state = phi i32 [ %state, %loop ]
  %out.state.next = phi i32 [ %state.next, %loop ]
  %out.c = phi i32 [ %c, %loop ]
  %out.dc = phi i64 [ %dc, %loop ]
  %out.iv = phi i64 [ %iv, %loop ]
  %out.next = phi i64 [ %next, %loop ]
  %z.a0 = zext i32 %out.a0 to i64
  %op.0 = getelementptr i64, ptr %out, i64 0
  store i64 %z.a0, ptr %op.0, align 8
  %z.a1 = zext i32 %out.a1 to i64
  %op.1 = getelementptr i64, ptr %out, i64 1
  store i64 %z.a1, ptr %op.1, align 8
  %z.o0 = zext i32 %out.o0 to i64
  %op.2 = getelementptr i64, ptr %out, i64 2
  store i64 %z.o0, ptr %op.2, align 8
  %z.o1 = zext i32 %out.o1 to i64
  %op.3 = getelementptr i64, ptr %out, i64 3
  store i64 %z.o1, ptr %op.3, align 8
  %op.4 = getelementptr i64, ptr %out, i64 4
  store i64 %out.x0, ptr %op.4, align 8
  %op.5 = getelementptr i64, ptr %out, i64 5
  store i64 %out.x1, ptr %op.5, align 8
  %z.state = zext i32 %out.state to i64
  %op.6 = getelementptr i64, ptr %out, i64 6
  store i64 %z.state, ptr %op.6, align 8
  %z.state.next = zext i32 %out.state.next to i64
  %op.7 = getelementptr i64, ptr %out, i64 7
  store i64 %z.state.next, ptr %op.7, align 8
  %z.c = zext i32 %out.c to i64
  %op.8 = getelementptr i64, ptr %out, i64 8
  store i64 %z.c, ptr %op.8, align 8
  %op.9 = getelementptr i64, ptr %out, i64 9
  store i64 %out.dc, ptr %op.9, align 8
  %op.10 = getelementptr i64, ptr %out, i64 10
  store i64 %out.iv, ptr %op.10, align 8
  %op.11 = getelementptr i64, ptr %out, i64 11
  store i64 %out.next, ptr %op.11, align 8
  %z.b0 = zext i8 %out.b0 to i64
  %op.12 = getelementptr i64, ptr %out, i64 12
  store i64 %z.b0, ptr %op.12, align 8
  %z.b1 = zext i8 %out.b1 to i64
  %op.13 = getelementptr i64, ptr %out, i64 13
  store i64 %z.b1, ptr %op.13, align 8
  br label %exit
exit:
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-multiply-defined.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!40 = distinct !DISubprogram(name: "multiply_defined", scope: !1, file: !1, line: 70, type: !4, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!41 = !DILocation(line: 72, column: 3, scope: !40)
!42 = !DILocation(line: 73, column: 5, scope: !40)
!43 = !DILocation(line: 74, column: 5, scope: !40)
!44 = !DILocation(line: 75, column: 5, scope: !40)
!45 = !DILocation(line: 76, column: 5, scope: !40)
!46 = !DILocation(line: 77, column: 5, scope: !40)
!47 = !DILocation(line: 78, column: 5, scope: !40)
!48 = !DILocation(line: 79, column: 5, scope: !40)
!49 = !DILocation(line: 80, column: 5, scope: !40)
