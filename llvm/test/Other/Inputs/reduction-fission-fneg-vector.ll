; Original scalar IR used unchanged at admission and as the executable reference.
; Synthetic VF4 controls live in the runnable test/driver, never corpus settings.
; Two streams: double then float, C=65/9/1 => 780/108/12 padded bytes.
; Each participant stores/loads 12 scratch bytes. No rereads or duplication.
; noalias is an explicit fixture contract; inherited alias tests stay intact.
; Direct negation stores include exact signed zero and quiet/signaling NaN bits.
; Only subsequent ordered fadd results permit NaN classification.

define void @neg_full(ptr noalias readonly %a, ptr noalias readonly %fp,
                      ptr noalias %out, ptr noalias %dout, ptr noalias %fout,
                      i64 %n, double %start) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
preheader:
  br label %loop
loop:
  %iv = phi i64 [0, %preheader], [%next, %loop]
  %rd = phi double [%start, %preheader], [%ud, %loop]
  %rf = phi float [%fstart, %preheader], [%uf, %loop]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %dc = fneg double %dx, !dbg !12
  %rawf = bitcast i32 %x to float
  %fc = fneg float %rawf, !dbg !13
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %op = getelementptr float, ptr %out, i64 %iv
  store float %fc, ptr %op, align 4
  %dop = getelementptr double, ptr %dout, i64 %iv
  store double %dc, ptr %dop, align 8
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !11
producer.exit:
  %out.rd = phi double [%ud, %loop]
  %out.rf = phi float [%uf, %loop]
  br label %exit
exit:
  %final.rd = phi double [%start, %entry], [%out.rd, %producer.exit]
  %final.rf = phi float [%fstart, %entry], [%out.rf, %producer.exit]
  %result = getelementptr double, ptr %dout, i64 65
  store double %final.rd, ptr %result, align 8
  store float %final.rf, ptr %fout, align 4
  ret void
}

; The analogous compact producer retains both negations and both direct stores
; in the active arm. P=0 can use an invalid fp address, and must forward starts.
; Loop::getStartLoc uses the preheader/header, not the separate latch's !dbg.
; Keep the original loop location available for Selected/Rejected/stage remarks.
define void @neg_compact(ptr noalias readonly %a, ptr noalias readonly %fp,
                         ptr noalias %out, ptr noalias %dout, ptr noalias %fout,
                         i64 %n, double %start) !dbg !20 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %inner.enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %inner.enter, label %preheader, label %exit
preheader:
  br label %loop, !dbg !21
loop:
  %iv = phi i64 [0, %preheader], [%next, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %rf = phi float [%fstart, %preheader], [%mf, %latch]
  %p = getelementptr i32, ptr %a, i64 %iv
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !21
left:
  %dp = getelementptr double, ptr %fp, i64 %iv
  %dx = load double, ptr %dp, align 8
  %dc = fneg double %dx, !dbg !22
  %rawf = bitcast i32 %x to float
  %fc = fneg float %rawf, !dbg !23
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %op = getelementptr float, ptr %out, i64 %iv
  store float %fc, ptr %op, align 4
  %dop = getelementptr double, ptr %dout, i64 %iv
  store double %dc, ptr %dop, align 8
  br label %latch
right:
  br label %latch
latch:
  %md = phi double [%ud, %left], [%rd, %right]
  %mf = phi float [%uf, %left], [%rf, %right]
  %next = add nuw i64 %iv, 1
  %done = icmp eq i64 %next, %n
  br i1 %done, label %producer.exit, label %loop, !dbg !21
producer.exit:
  %out.rd = phi double [%md, %latch]
  %out.rf = phi float [%mf, %latch]
  br label %exit
exit:
  %final.rd = phi double [%start, %entry], [%out.rd, %producer.exit]
  %final.rf = phi float [%fstart, %entry], [%out.rf, %producer.exit]
  %result = getelementptr double, ptr %dout, i64 65
  store double %final.rd, ptr %result, align 8
  store float %final.rf, ptr %fout, align 4
  ret void
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "fneg-vector.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!5 = !DISubroutineType(types: !6)
!6 = !{}
!10 = distinct !DISubprogram(name: "neg_full", scope: !1, file: !1, line: 10, type: !5, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 12, column: 3, scope: !10)
!12 = !DILocation(line: 13, column: 5, scope: !10)
!13 = !DILocation(line: 14, column: 5, scope: !10)
!20 = distinct !DISubprogram(name: "neg_compact", scope: !1, file: !1, line: 20, type: !5, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 22, column: 3, scope: !20)
!22 = !DILocation(line: 23, column: 5, scope: !20)
!23 = !DILocation(line: 24, column: 5, scope: !20)
