; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each \
; RUN:   -mtriple=riscv64 -mattr=+v -enable-vplan-reduction-fission \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -S %s -o %t 2>%t.remarks
; RUN: FileCheck %s --implicit-check-not=scalar.fission < %t
; RUN: FileCheck %s --check-prefix=REASON < %t.remarks
; RUN: opt -passes=loop-vectorize -verify-each -mtriple=riscv64 -mattr=+v \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-allow-fp-reordering \
; RUN:   -S %s | FileCheck %s --implicit-check-not=scalar.fission
;
; A supported affine IV is insufficient to override any semantic restriction.
; Existing early-exit, internal-cycle, call/effect, ordered-FP and unsupported
; recurrence checks also remain in the mandatory scalar-fission suite.

declare i32 @scalar_helper(i32) memory(none) nounwind willreturn speculatable
declare i32 @unsafe(i32) memory(read) nounwind willreturn speculatable

; REASON: scalar-affine-reject.c:12:3: scalar-IR reduction fission rejected: {{non-constant-trip-count|scalar-scratch-limit}}
; CHECK-LABEL: define void @reject_affine_unproved(
; CHECK: ret void
define void @reject_affine_unproved(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !6 {
entry:
  %valid = icmp ule i64 %n, -1
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %limit = add nuw nsw i64 %n, 7
  br label %loop, !dbg !7
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %index = sub nuw nsw i64 %iv, 7
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !7
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 0.5
  br label %latch
negative:
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.0
  br label %latch
latch:
  %c = phi i32 [%pc, %positive], [%nc, %negative]
  %dc = phi double [%pd, %positive], [%nd, %negative]
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !7
exit:
  %v0 = phi i32 [17, %entry], [%u0, %latch]
  %v1 = phi i32 [-7, %entry], [%u1, %latch]
  %vd = phi double [%start, %entry], [%ud, %latch]
  %vf = phi float [%fstart, %entry], [%uf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; REASON: scalar-affine-reject.c:22:3: scalar-IR reduction fission rejected: scalar-unsupported-exit
; CHECK-LABEL: define void @reject_affine_variable_step(
; CHECK: ret void
define void @reject_affine_variable_step(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !8 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %limit = add nuw nsw i64 %n, 7
  br label %loop, !dbg !9
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %index = sub nuw nsw i64 %iv, 7
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !9
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 0.5
  br label %latch
negative:
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.0
  br label %latch
latch:
  %c = phi i32 [%pc, %positive], [%nc, %negative]
  %dc = phi double [%pd, %positive], [%nd, %negative]
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add i64 %iv, %begin
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !9
exit:
  %v0 = phi i32 [17, %entry], [%u0, %latch]
  %v1 = phi i32 [-7, %entry], [%u1, %latch]
  %vd = phi double [%start, %entry], [%ud, %latch]
  %vf = phi float [%fstart, %entry], [%uf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; REASON: scalar-affine-reject.c:32:3: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define void @reject_affine_feedback(
; CHECK: ret void
define void @reject_affine_feedback(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !10 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %limit = add nuw nsw i64 %n, 7
  br label %loop, !dbg !11
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %index = sub nuw nsw i64 %iv, 7
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %r0, 0
  br i1 %choose, label %left, label %right, !dbg !11
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 0.5
  br label %latch
negative:
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.0
  br label %latch
latch:
  %c = phi i32 [%pc, %positive], [%nc, %negative]
  %dc = phi double [%pd, %positive], [%nd, %negative]
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !11
exit:
  %v0 = phi i32 [17, %entry], [%u0, %latch]
  %v1 = phi i32 [-7, %entry], [%u1, %latch]
  %vd = phi double [%start, %entry], [%ud, %latch]
  %vf = phi float [%fstart, %entry], [%uf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; REASON: scalar-affine-reject.c:42:3: scalar-IR reduction fission rejected: scalar-unsupported-recurrence
; CHECK-LABEL: define void @reject_affine_contribution_feedback(
; CHECK: ret void
define void @reject_affine_contribution_feedback(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !12 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %limit = add nuw nsw i64 %n, 7
  br label %loop, !dbg !13
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %index = sub nuw nsw i64 %iv, 7
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !13
left:
  %q = sdiv i32 %r0, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 0.5
  br label %latch
negative:
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.0
  br label %latch
latch:
  %c = phi i32 [%pc, %positive], [%nc, %negative]
  %dc = phi double [%pd, %positive], [%nd, %negative]
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !13
exit:
  %v0 = phi i32 [17, %entry], [%u0, %latch]
  %v1 = phi i32 [-7, %entry], [%u1, %latch]
  %vd = phi double [%start, %entry], [%ud, %latch]
  %vf = phi float [%fstart, %entry], [%uf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; REASON: scalar-affine-reject.c:52:3: scalar-IR reduction fission rejected: scalar-unsafe-call
; CHECK-LABEL: define void @reject_affine_unsafe_call(
; CHECK: ret void
define void @reject_affine_unsafe_call(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !14 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %limit = add nuw nsw i64 %n, 7
  br label %loop, !dbg !15
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %index = sub nuw nsw i64 %iv, 7
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !15
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @unsafe(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 0.5
  br label %latch
negative:
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.0
  br label %latch
latch:
  %c = phi i32 [%pc, %positive], [%nc, %negative]
  %dc = phi double [%pd, %positive], [%nd, %negative]
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !15
exit:
  %v0 = phi i32 [17, %entry], [%u0, %latch]
  %v1 = phi i32 [-7, %entry], [%u1, %latch]
  %vd = phi double [%start, %entry], [%ud, %latch]
  %vf = phi float [%fstart, %entry], [%uf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; REASON: scalar-affine-reject.c:62:3: scalar-IR reduction fission rejected: scalar-unsupported-instruction
; CHECK-LABEL: define void @reject_affine_store(
; CHECK: ret void
define void @reject_affine_store(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !16 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %limit = add nuw nsw i64 %n, 7
  br label %loop, !dbg !17
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %index = sub nuw nsw i64 %iv, 7
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !17
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 0.5
  br label %latch
negative:
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.0
  br label %latch
latch:
  %c = phi i32 [%pc, %positive], [%nc, %negative]
  %dc = phi double [%pd, %positive], [%nd, %negative]
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  store i32 %c, ptr %out
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !17
exit:
  %v0 = phi i32 [17, %entry], [%u0, %latch]
  %v1 = phi i32 [-7, %entry], [%u1, %latch]
  %vd = phi double [%start, %entry], [%ud, %latch]
  %vf = phi float [%fstart, %entry], [%uf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; REASON: scalar-affine-reject.c:72:3: scalar-IR reduction fission rejected: scalar-unsupported-live-out
; CHECK-LABEL: define void @reject_affine_liveout(
; CHECK: ret void
define void @reject_affine_liveout(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !18 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %limit = add nuw nsw i64 %n, 7
  br label %loop, !dbg !19
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %index = sub nuw nsw i64 %iv, 7
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !19
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 0.5
  br label %latch
negative:
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.0
  br label %latch
latch:
  %c = phi i32 [%pc, %positive], [%nc, %negative]
  %dc = phi double [%pd, %positive], [%nd, %negative]
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !19
exit:
  %observed = phi i64 [%iv, %latch], [0, %entry]
  %v0 = phi i32 [17, %entry], [%u0, %latch]
  %v1 = phi i32 [-7, %entry], [%u1, %latch]
  %vd = phi double [%start, %entry], [%ud, %latch]
  %vf = phi float [%fstart, %entry], [%uf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  %obs32 = trunc i64 %observed to i32
  store i32 %obs32, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; REASON: scalar-affine-reject.c:82:3: scalar-IR reduction fission rejected: scalar-incompatible-participation
; CHECK-LABEL: define void @reject_affine_participation(
; CHECK: ret void
define void @reject_affine_participation(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !20 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %span = shl nuw nsw i64 %n, 1
  %limit = sub nuw nsw i64 137, %span
  br label %loop, !dbg !21
loop:
  %iv = phi i64 [137, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%m0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%md, %latch]
  %rf = phi float [%fstart, %preheader], [%mf, %latch]
  %distance = sub nuw nsw i64 137, %iv
  %index = lshr i64 %distance, 1
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %latch, !dbg !21
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %dp = getelementptr double, ptr %fp, i64 %index
  %dc = load double, ptr %dp, align 8
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %lc
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  br label %latch
latch:
  %m0 = phi i32 [%u0, %left], [%r0, %loop]
  %md = phi double [%ud, %left], [%rd, %loop]
  %mf = phi float [%uf, %left], [%rf, %loop]
  %u1 = add i32 1, %r1
  %next = sub nuw nsw i64 %iv, 2
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !21
exit:
  %v0 = phi i32 [17, %entry], [%m0, %latch]
  %v1 = phi i32 [-7, %entry], [%u1, %latch]
  %vd = phi double [%start, %entry], [%md, %latch]
  %vf = phi float [%fstart, %entry], [%mf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; REASON: scalar-affine-reject.c:92:3: scalar-IR reduction fission rejected: scalar-strict-fp
; CHECK-LABEL: define void @reject_affine_strictfp(
; CHECK: ret void
define void @reject_affine_strictfp(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) strictfp !dbg !22 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %limit = add nuw nsw i64 %n, 7
  br label %loop, !dbg !23
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %index = sub nuw nsw i64 %iv, 7
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !23
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 0.5
  br label %latch
negative:
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.0
  br label %latch
latch:
  %c = phi i32 [%pc, %positive], [%nc, %negative]
  %dc = phi double [%pd, %positive], [%nd, %negative]
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add nuw nsw i64 %iv, 1
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !23
exit:
  %v0 = phi i32 [17, %entry], [%u0, %latch]
  %v1 = phi i32 [-7, %entry], [%u1, %latch]
  %vd = phi double [%start, %entry], [%ud, %latch]
  %vf = phi float [%fstart, %entry], [%uf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; REASON: scalar-affine-reject.c:102:3: scalar-IR reduction fission rejected: scalar-unsupported-exit
; CHECK-LABEL: define void @reject_affine_zero_step(
; CHECK: ret void
define void @reject_affine_zero_step(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !24 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %limit = add nuw nsw i64 %n, 7
  br label %loop, !dbg !25
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %index = sub nuw nsw i64 %iv, 7
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !25
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 0.5
  br label %latch
negative:
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.0
  br label %latch
latch:
  %c = phi i32 [%pc, %positive], [%nc, %negative]
  %dc = phi double [%pd, %positive], [%nd, %negative]
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = add i64 %iv, 0
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !25
exit:
  %v0 = phi i32 [17, %entry], [%u0, %latch]
  %v1 = phi i32 [-7, %entry], [%u1, %latch]
  %vd = phi double [%start, %entry], [%ud, %latch]
  %vf = phi float [%fstart, %entry], [%uf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; REASON: scalar-affine-reject.c:112:3: scalar-IR reduction fission rejected: scalar-unsupported-exit
; CHECK-LABEL: define void @reject_affine_nonlinear(
; CHECK: ret void
define void @reject_affine_nonlinear(ptr readonly %a, ptr readonly %fp, ptr %out,
                            ptr %dout, ptr %fout, i64 %n, double %start, i64 %begin) !dbg !26 {
entry:
  %valid = icmp ule i64 %n, 65
  %nonzero = icmp ne i64 %n, 0
  %enter = and i1 %valid, %nonzero
  %fstart = fptrunc double %start to float
  br i1 %enter, label %preheader, label %exit
preheader:
  %limit = add nuw nsw i64 %n, 7
  br label %loop, !dbg !27
loop:
  %iv = phi i64 [7, %preheader], [%next, %latch]
  %r0 = phi i32 [17, %preheader], [%u0, %latch]
  %r1 = phi i32 [-7, %preheader], [%u1, %latch]
  %rd = phi double [%start, %preheader], [%ud, %latch]
  %rf = phi float [%fstart, %preheader], [%uf, %latch]
  %index = sub nuw nsw i64 %iv, 7
  %p = getelementptr i32, ptr %a, i64 %index
  %x = load i32, ptr %p, align 4
  %choose = icmp ne i32 %x, 0
  br i1 %choose, label %left, label %right, !dbg !27
left:
  %q = sdiv i32 840, %x
  %lc = call i32 @scalar_helper(i32 %q)
  %ld = sitofp i32 %q to double
  br label %first.merge
right:
  %dp = getelementptr double, ptr %fp, i64 %index
  %dx = load double, ptr %dp, align 8
  %rc = fmul double %dx, 3.0
  br label %first.merge
first.merge:
  %first.c = phi i32 [%lc, %left], [17, %right]
  %first.d = phi double [%ld, %left], [%rc, %right]
  %parity = and i64 %index, 1
  %second = icmp ne i64 %parity, 0
  br i1 %second, label %positive, label %negative
positive:
  %pc = add i32 %first.c, 23
  %pd = fmul double %first.d, 0.5
  br label %latch
negative:
  %nc = sub i32 %first.c, 9
  %nd = fmul double %first.d, -1.0
  br label %latch
latch:
  %c = phi i32 [%pc, %positive], [%nc, %negative]
  %dc = phi double [%pd, %positive], [%nd, %negative]
  %fc = fptrunc double %dc to float
  %u0 = add i32 %r0, %c
  %u1 = add i32 %c, %r1
  %ud = fadd double %rd, %dc
  %uf = fadd float %rf, %fc
  %next = mul i64 %iv, 2
  %done = icmp eq i64 %limit, %next
  br i1 %done, label %exit, label %loop, !dbg !27
exit:
  %v0 = phi i32 [17, %entry], [%u0, %latch]
  %v1 = phi i32 [-7, %entry], [%u1, %latch]
  %vd = phi double [%start, %entry], [%ud, %latch]
  %vf = phi float [%fstart, %entry], [%uf, %latch]
  %o1 = getelementptr i32, ptr %out, i64 1
  store i32 %v0, ptr %out
  store i32 %v1, ptr %o1
  store double %vd, ptr %dout
  store float %vf, ptr %fout
  ret void
}

; REASON: scalar-affine-reject.c:122:3: scalar-IR reduction fission rejected: scalar-unsupported-exit
; CHECK-LABEL: define i32 @reject_affine_pointer(
; CHECK: ret i32
define i32 @reject_affine_pointer(ptr %a, ptr %end) !dbg !28 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !29
loop:
  %iv = phi ptr [%a, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %x = load i32, ptr %a
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = getelementptr i32, ptr %iv, i64 1
  %done = icmp eq ptr %next, %end
  br i1 %done, label %exit, label %loop, !dbg !29
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

; REASON: scalar-affine-reject.c:132:3: scalar-IR reduction fission rejected: scalar-unsupported-exit
; CHECK-LABEL: define i32 @reject_affine_fp_control(
; CHECK: ret i32
define i32 @reject_affine_fp_control(ptr %a, ptr %end) !dbg !30 {
entry:
  br label %preheader
preheader:
  br label %loop, !dbg !31
loop:
  %iv = phi double [1.0, %preheader], [%next, %loop]
  %sum = phi i32 [17, %preheader], [%update, %loop]
  %x = load i32, ptr %a
  %c = call i32 @scalar_helper(i32 %x)
  %update = add i32 %sum, %c
  %next = fadd double %iv, 1.0
  %done = fcmp oge double %next, 10.0
  br i1 %done, label %exit, label %loop, !dbg !31
exit:
  %result = phi i32 [%update, %loop]
  ret i32 %result
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}
!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, producer: "test", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "scalar-affine-reject.c", directory: "/")
!2 = !{i32 2, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DISubroutineType(types: !5)
!5 = !{}
!6 = distinct !DISubprogram(name: "reject_affine_unproved", scope: !1, file: !1, line: 10, type: !4, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!7 = !DILocation(line: 12, column: 3, scope: !6)
!8 = distinct !DISubprogram(name: "reject_affine_variable_step", scope: !1, file: !1, line: 20, type: !4, scopeLine: 20, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!9 = !DILocation(line: 22, column: 3, scope: !8)
!10 = distinct !DISubprogram(name: "reject_affine_feedback", scope: !1, file: !1, line: 30, type: !4, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DILocation(line: 32, column: 3, scope: !10)
!12 = distinct !DISubprogram(name: "reject_affine_contribution_feedback", scope: !1, file: !1, line: 40, type: !4, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!13 = !DILocation(line: 42, column: 3, scope: !12)
!14 = distinct !DISubprogram(name: "reject_affine_unsafe_call", scope: !1, file: !1, line: 50, type: !4, scopeLine: 50, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!15 = !DILocation(line: 52, column: 3, scope: !14)
!16 = distinct !DISubprogram(name: "reject_affine_store", scope: !1, file: !1, line: 60, type: !4, scopeLine: 60, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!17 = !DILocation(line: 62, column: 3, scope: !16)
!18 = distinct !DISubprogram(name: "reject_affine_liveout", scope: !1, file: !1, line: 70, type: !4, scopeLine: 70, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!19 = !DILocation(line: 72, column: 3, scope: !18)
!20 = distinct !DISubprogram(name: "reject_affine_participation", scope: !1, file: !1, line: 80, type: !4, scopeLine: 80, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocation(line: 82, column: 3, scope: !20)
!22 = distinct !DISubprogram(name: "reject_affine_strictfp", scope: !1, file: !1, line: 90, type: !4, scopeLine: 90, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!23 = !DILocation(line: 92, column: 3, scope: !22)
!24 = distinct !DISubprogram(name: "reject_affine_zero_step", scope: !1, file: !1, line: 100, type: !4, scopeLine: 100, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!25 = !DILocation(line: 102, column: 3, scope: !24)
!26 = distinct !DISubprogram(name: "reject_affine_nonlinear", scope: !1, file: !1, line: 110, type: !4, scopeLine: 110, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!27 = !DILocation(line: 112, column: 3, scope: !26)
!28 = distinct !DISubprogram(name: "reject_affine_pointer", scope: !1, file: !1, line: 120, type: !4, scopeLine: 120, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!29 = !DILocation(line: 122, column: 3, scope: !28)
!30 = distinct !DISubprogram(name: "reject_affine_fp_control", scope: !1, file: !1, line: 130, type: !4, scopeLine: 130, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!31 = !DILocation(line: 132, column: 3, scope: !30)
