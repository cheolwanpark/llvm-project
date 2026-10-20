; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -S %s -o %t
; RUN: FileCheck %s < %t
; RUN: opt -passes=scalar-fission -pass-remarks-analysis=scalar-fission -disable-output %s 2>&1 | FileCheck %s --check-prefix=REMARK
; RUN: opt -passes='function(scalar-fission),default<O3>' -mtriple=riscv64 -mattr=+m,+a,+f,+d,+v -S %s -o %t.opt
; RUN: llc -mtriple=riscv64 -mattr=+m,+a,+f,+d,+v -verify-machineinstrs -stop-after=stack-coloring %t.opt -o - | FileCheck %s --check-prefix=COLOR
;
; Both sets of IR allocas remain. Machine stack coloring must merge the two
; nonoverlapping objects in each function. Repeated outer iterations restart
; lifetimes only after both consumers from the preceding iteration have ended.
; COLOR-LABEL: name: sequential
; COLOR: stack:
; COLOR: size: 1024,
; COLOR-NOT: size: 1024,
; COLOR: body:
; COLOR-LABEL: name: enclosing
; COLOR: stack:
; COLOR: size: 1024,
; COLOR-NOT: size: 1024,
; COLOR: body:
; REMARK: function scratch IR allocation bytes 2048
; REMARK: function scratch IR allocation bytes 2048

; CHECK-LABEL: define double @sequential(
; CHECK-COUNT-2: alloca [128 x double]
; CHECK-NOT: alloca
; CHECK: call void @llvm.lifetime.start
; CHECK-NOT: call void @llvm.lifetime
; CHECK: loop.consume:
; CHECK: load double
; CHECK: call void @llvm.lifetime.end
; CHECK: call void @llvm.lifetime.start
; CHECK-NOT: call void @llvm.lifetime
; CHECK: second.consume:
; CHECK: load double
; CHECK: call void @llvm.lifetime.end
; CHECK-NOT: call void @llvm.lifetime
; CHECK: ret double

define double @sequential(ptr %a, ptr %b, i64 %n, double %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %outer
outer:
  br label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s = phi double [%seed, %ph], [%u, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %square = fmul double %x, %x
  %biased = fadd double %square, 1.25
  %f = fmul double %biased, 0.5
  %u = fadd double %s, %f
  %next = add nuw i64 %i, 1
  %more = icmp ult i64 %next, 128
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%u, %loop]
  br label %second
second:
  %k = phi i64 [0, %exit], [%knext, %second]
  %t = phi double [%r, %exit], [%v, %second]
  %q = getelementptr double, ptr %b, i64 %k
  %y = load double, ptr %q
  %square.second = fmul double %y, %y
  %biased.second = fadd double %square.second, 1.25
  %g = fmul double %biased.second, 0.5
  %v = fadd double %t, %g
  %knext = add nuw i64 %k, 1
  %kmore = icmp ult i64 %knext, 128
  br i1 %kmore, label %second, label %after
after:
  %r2 = phi double [%v, %second]
  br label %done
done:
  %result = phi double [%seed, %entry], [%r2, %after]
  ret double %result
}

; CHECK-LABEL: define double @enclosing(
; CHECK-COUNT-2: alloca [128 x double]
; CHECK-NOT: alloca
; CHECK: call void @llvm.lifetime.start
; CHECK-NOT: call void @llvm.lifetime
; CHECK: loop.consume:
; CHECK: load double
; CHECK: call void @llvm.lifetime.end
; CHECK: call void @llvm.lifetime.start
; CHECK-NOT: call void @llvm.lifetime
; CHECK: second.consume:
; CHECK: load double
; CHECK: call void @llvm.lifetime.end
; CHECK-NOT: call void @llvm.lifetime
; CHECK: ret double

define double @enclosing(ptr %a, ptr %b, i64 %n, double %seed) {
entry:
  %empty = icmp eq i64 %n, 0
  br i1 %empty, label %done, label %outer
outer:
  %j = phi i64 [0, %entry], [%jnext, %after]
  %acc = phi double [%seed, %entry], [%r2, %after]
  br label %ph
ph:
  br label %loop
loop:
  %i = phi i64 [0, %ph], [%next, %loop]
  %s = phi double [%acc, %ph], [%u, %loop]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %square = fmul double %x, %x
  %biased = fadd double %square, 1.25
  %f = fmul double %biased, 0.5
  %u = fadd double %s, %f
  %next = add nuw i64 %i, 1
  %more = icmp ult i64 %next, 128
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%u, %loop]
  br label %second
second:
  %k = phi i64 [0, %exit], [%knext, %second]
  %t = phi double [%r, %exit], [%v, %second]
  %q = getelementptr double, ptr %b, i64 %k
  %y = load double, ptr %q
  %square.second = fmul double %y, %y
  %biased.second = fadd double %square.second, 1.25
  %g = fmul double %biased.second, 0.5
  %v = fadd double %t, %g
  %knext = add nuw i64 %k, 1
  %kmore = icmp ult i64 %knext, 128
  br i1 %kmore, label %second, label %after
after:
  %r2 = phi double [%v, %second]
  %jnext = add nuw i64 %j, 1
  %jmore = icmp ult i64 %jnext, %n
  br i1 %jmore, label %outer, label %outerexit, !llvm.loop !0
outerexit:
  %r3 = phi double [%r2, %after]
  br label %done
done:
  %result = phi double [%seed, %entry], [%r3, %outerexit]
  ret double %result
}

!0 = distinct !{!0, !1}
!1 = !{!"llvm.loop.scalar_fission.disable"}
