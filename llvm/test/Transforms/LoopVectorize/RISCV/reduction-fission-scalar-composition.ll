; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=112 -pass-remarks=vplan-reduction-fission -S %s -o %t 2>%t.remarks
; RUN: FileCheck %s --check-prefix=SCALAR < %t
; RUN: FileCheck %s --check-prefix=REMARK < %t.remarks
; RUN: opt -passes='loop-vectorize,loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v -force-vector-width=1 -force-vector-interleave=0 -force-target-max-scalar-interleave=1 -scalable-vectorization=off -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=16 -vplan-reduction-fission-allow-fp-reordering -S %s | FileCheck %s --check-prefix=ONE
;
; Stores, exact sign negation and ordered subtraction compose with simultaneous
; retained state, compact chunks and separate current/next final exports. The
; two original pointers may overlap: all accesses stay in the producer order.
; The executable checker runs these exact originals, not source rewrites.

declare i32 @scalar_helper(i32) nounwind willreturn speculatable memory(none)

; REMARK: scalar-composition.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 9, scratch bytes 112, producer live-outs 6, chunked schedule, trip bound 65
; REMARK-SAME: producer state carries 2
; ONE-LABEL: define void @compose_neg(
; ONE: alloca [1 x i32]
; ONE: alloca [1 x double]
; ONE: scalar.fission.consumer.guard:
; SCALAR-LABEL: define void @compose_neg(
; SCALAR: alloca [9 x i32]
; SCALAR: alloca [9 x double]
; SCALAR: %prev.chunk.carry = phi i32
; SCALAR: %older.chunk.carry = phi i32
; SCALAR: store i32 %state.next, ptr %wp
; SCALAR: %dc = fneg double %dx, !dbg
; SCALAR: store double %dc, ptr %dp
; SCALAR: scalar.fission.consumer.guard:
; SCALAR-DAG: %prev.chunk.backedge = phi i32 [ %state.next, %latch ]
; SCALAR-DAG: %older.chunk.backedge = phi i32 [ %prev, %latch ]
; SCALAR-DAG: %prev.fission.export = phi i32 [ %prev, %latch ]
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %u0.consume = add i32 %r0.consume,
; SCALAR: %ud.consume = fadd double %rd.consume, {{.*}}, !dbg
; SCALAR: %rd.result = phi double [ %rd.chunk.carry, %scalar.fission.consumer.guard ],
; SCALAR: ret void
define void @compose_neg(ptr %a, ptr %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %state.next = add i32 %x, %older
  %wp = getelementptr i32, ptr %out, i64 %iv
  store i32 %state.next, ptr %wp, align 4
  %nonzero.x = icmp ne i32 %x, 0
  %state.bit = and i32 %prev, 1
  %state.odd = icmp ne i32 %state.bit, 0
  %state.mode = icmp eq i64 %rows, 2
  %state.choose = and i1 %nonzero.x, %state.odd
  %choose = select i1 %state.mode, i1 %state.choose, i1 %nonzero.x
  br i1 %choose, label %left, label %right
left:
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %as.double = uitofp i32 %prev to double
  %dc = fneg double %dx, !dbg !20
  store double %dc, ptr %dp, align 8
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc, !dbg !22
  br label %latch
right:
  br label %latch
latch:
  %m0 = phi i32 [%r0, %right], [%u0, %left]
  %m1 = phi i32 [%r1, %right], [%u1, %left]
  %md = phi double [%rd, %right], [%ud, %left]
  %last.dc = phi double [%start, %right], [%dc, %left]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !11
producer.exit:
  %out.r0 = phi i32 [%m0, %latch]
  %out.r1 = phi i32 [%m1, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.state.next = phi i32 [%state.next, %latch]
  %out.rd = phi double [%md, %latch]
  %out.last.dc = phi double [%last.dc, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.p0 = getelementptr i32, ptr %out, i64 0
  store i32 %out.r0, ptr %out.p0, align 4
  %out.p1 = getelementptr i32, ptr %out, i64 1
  store i32 %out.r1, ptr %out.p1, align 4
  %out.p2 = getelementptr i32, ptr %out, i64 2
  store i32 %out.prev, ptr %out.p2, align 4
  %out.p3 = getelementptr i32, ptr %out, i64 3
  store i32 %out.older, ptr %out.p3, align 4
  %out.p4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.state.next, ptr %out.p4, align 4
  %dout.p0 = getelementptr double, ptr %dout, i64 0
  store double %out.rd, ptr %dout.p0, align 8
  %dout.p1 = getelementptr double, ptr %dout, i64 1
  store double %out.last.dc, ptr %dout.p1, align 8
  %indices.p0 = getelementptr i64, ptr %indices, i64 0
  store i64 %out.iv, ptr %indices.p0, align 8
  %indices.p1 = getelementptr i64, ptr %indices, i64 1
  store i64 %out.next, ptr %indices.p1, align 8
  ret void
bypass:
  ret void
}

; REMARK: scalar-composition.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 9, scratch bytes 112, producer live-outs 6, chunked schedule, trip bound 65
; REMARK-SAME: producer state carries 2
; ONE-LABEL: define void @compose_sub(
; ONE: alloca [1 x i32]
; ONE: alloca [1 x double]
; ONE: scalar.fission.consumer.guard:
; SCALAR-LABEL: define void @compose_sub(
; SCALAR: alloca [9 x i32]
; SCALAR: alloca [9 x double]
; SCALAR: %prev.chunk.carry = phi i32
; SCALAR: %older.chunk.carry = phi i32
; SCALAR: store i32 %state.next, ptr %wp
; SCALAR: %dc = fneg double %dx, !dbg
; SCALAR: store double %dc, ptr %dp
; SCALAR: scalar.fission.consumer.guard:
; SCALAR-DAG: %prev.chunk.backedge = phi i32 [ %state.next, %latch ]
; SCALAR-DAG: %older.chunk.backedge = phi i32 [ %prev, %latch ]
; SCALAR-DAG: %prev.fission.export = phi i32 [ %prev, %latch ]
; SCALAR: %fission.empty = icmp eq i64 %fission.participating.count, 0
; SCALAR: scalar.fission.consumer.body:
; SCALAR: %u0.consume = sub i32 %r0.consume,
; SCALAR: %ud.consume = fsub double %rd.consume, {{.*}}, !dbg
; SCALAR: %rd.result = phi double [ %rd.chunk.carry, %scalar.fission.consumer.guard ],
; SCALAR: ret void
define void @compose_sub(ptr %a, ptr %fp, ptr %out, ptr %indices,
                      ptr %dout, ptr %fout, i64 %rows, i64 %n, double %start) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  br i1 %inner.enter, label %preheader, label %bypass
preheader:
  br label %loop, !dbg !13
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %prev = phi i32 [23, %preheader], [%state.next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %older = phi i32 [-11, %preheader], [%prev, %latch]
  %r1 = phi i32 [-7, %preheader], [%m1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %state.next = add i32 %x, %older
  %wp = getelementptr i32, ptr %out, i64 %iv
  store i32 %state.next, ptr %wp, align 4
  %nonzero.x = icmp ne i32 %x, 0
  %state.bit = and i32 %prev, 1
  %state.odd = icmp ne i32 %state.bit, 0
  %state.mode = icmp eq i64 %rows, 2
  %state.choose = and i1 %nonzero.x, %state.odd
  %choose = select i1 %state.mode, i1 %state.choose, i1 %nonzero.x
  br i1 %nonzero.x, label %gate0, label %right
gate0:
  %skip = icmp eq i32 %x, 2
  br i1 %skip, label %right1, label %gate1
gate1:
  br i1 %choose, label %left, label %right2
left:
  %raw = xor i32 %prev, %state.next
  %c = call i32 @scalar_helper(i32 %raw)
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %as.double = uitofp i32 %prev to double
  %dc = fneg double %dx, !dbg !21
  store double %dc, ptr %dp, align 8
  %u0 = sub i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fsub double %rd, %dc, !dbg !23
  br label %latch
right:
  br label %latch
right1:
  br label %latch
right2:
  br label %latch
latch:
  %m0 = phi i32 [%r0, %right2], [%r0, %right1], [%r0, %right], [%u0, %left]
  %m1 = phi i32 [%r1, %right2], [%r1, %right1], [%r1, %right], [%u1, %left]
  %md = phi double [%rd, %right2], [%rd, %right1], [%rd, %right], [%ud, %left]
  %last.dc = phi double [%start, %right2], [%start, %right1], [%start, %right], [%dc, %left]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !13
producer.exit:
  %out.r0 = phi i32 [%m0, %latch]
  %out.r1 = phi i32 [%m1, %latch]
  %out.prev = phi i32 [%prev, %latch]
  %out.older = phi i32 [%older, %latch]
  %out.state.next = phi i32 [%state.next, %latch]
  %out.rd = phi double [%md, %latch]
  %out.last.dc = phi double [%last.dc, %latch]
  %out.iv = phi i64 [%iv, %latch]
  %out.next = phi i64 [%next, %latch]
  %out.p0 = getelementptr i32, ptr %out, i64 0
  store i32 %out.r0, ptr %out.p0, align 4
  %out.p1 = getelementptr i32, ptr %out, i64 1
  store i32 %out.r1, ptr %out.p1, align 4
  %out.p2 = getelementptr i32, ptr %out, i64 2
  store i32 %out.prev, ptr %out.p2, align 4
  %out.p3 = getelementptr i32, ptr %out, i64 3
  store i32 %out.older, ptr %out.p3, align 4
  %out.p4 = getelementptr i32, ptr %out, i64 4
  store i32 %out.state.next, ptr %out.p4, align 4
  %dout.p0 = getelementptr double, ptr %dout, i64 0
  store double %out.rd, ptr %dout.p0, align 8
  %dout.p1 = getelementptr double, ptr %dout, i64 1
  store double %out.last.dc, ptr %dout.p1, align 8
  %indices.p0 = getelementptr i64, ptr %indices, i64 0
  store i64 %out.iv, ptr %indices.p0, align 8
  %indices.p1 = getelementptr i64, ptr %indices, i64 1
  store i64 %out.next, ptr %indices.p1, align 8
  ret void
bypass:
  ret void
}
!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!3, !4}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "reduction fission", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-composition.c", directory: "/")
!2 = !DISubroutineType(types: !5)
!3 = !{i32 2, !"Dwarf Version", i32 4}
!4 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !{}
!10 = distinct !DISubprogram(name: "compose_neg", scope: !1, file: !1, line: 11, type: !2, scopeLine: 11, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "compose_sub", scope: !1, file: !1, line: 21, type: !2, scopeLine: 21, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 22, column: 3, scope: !12)
!20 = !DILocation(line: 13, column: 5, scope: !10)
!21 = !DILocation(line: 23, column: 5, scope: !12)
!22 = !DILocation(line: 14, column: 5, scope: !10)
!23 = !DILocation(line: 24, column: 5, scope: !12)
