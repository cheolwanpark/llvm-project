; RUN: opt -mtriple=riscv64 -mattr=+v -passes='default<O2>' -vplan-candidates-output=%t.json -vplan-ra-run-id=test -S %s | FileCheck %s
;
; optnone preserves the synthetic induction witnesses until the final mapping
; pass. Width is already measured in scalar elements at the target vscale.
; Folding vscale must not multiply it again. Unknown mismatches, overflow and
; nonintegral ratios must retain an unproven mapping.

declare i64 @llvm.vscale.i64()

; CHECK-DAG: attributes #[[A0:[0-9]+]] = {{.*}}"vplan.ra.candidate"="folded:0:0:s4" "vplan.ra.iteration-mapping"="1" "vplan.ra.width"="8"
define void @folded(ptr %p, i64 %n) #0 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !2
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, 2
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !0
exit:
  ret void
}
attributes #0 = { noinline optnone vscale_range(2,2) "vplan.ra.candidate"="folded:0:0:s4" "vplan.ra.width"="8" }
!0 = distinct !{!0, !1}
!1 = !{!"llvm.loop.vplan.candidate", !"folded:0:0:s4"}
!2 = !{i64 1, i1 true}

; CHECK-DAG: attributes #[[A1:[0-9]+]] = {{.*}}"vplan.ra.candidate"="folded_unrolled:0:0:s4" "vplan.ra.iteration-mapping"="1" "vplan.ra.width"="32"
define void @folded_unrolled(ptr %p, i64 %n) #1 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !5
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, 8
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !3
exit:
  ret void
}
attributes #1 = { noinline optnone vscale_range(2,2) "vplan.ra.candidate"="folded_unrolled:0:0:s4" "vplan.ra.width"="8" }
!3 = distinct !{!3, !4}
!4 = !{!"llvm.loop.vplan.candidate", !"folded_unrolled:0:0:s4"}
!5 = !{i64 1, i1 true}

; CHECK-DAG: attributes #[[A2:[0-9]+]] = {{.*}}"vplan.ra.candidate"="fixed:0:0:s4" "vplan.ra.iteration-mapping"="1" "vplan.ra.width"="24"
define void @fixed(ptr %p, i64 %n) #2 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !8
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, 6
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !6
exit:
  ret void
}
attributes #2 = { noinline optnone  "vplan.ra.candidate"="fixed:0:0:s4" "vplan.ra.width"="8" }
!6 = distinct !{!6, !7}
!7 = !{!"llvm.loop.vplan.candidate", !"fixed:0:0:s4"}
!8 = !{i64 2, i1 false}

; CHECK-DAG: attributes #[[A3:[0-9]+]] = {{.*}}"vplan.ra.candidate"="scalable:0:0:s4" "vplan.ra.iteration-mapping"="1" "vplan.ra.width"="24"
define void @scalable(ptr %p, i64 %n) #3 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !11
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, %step
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !9
exit:
  ret void
}
attributes #3 = { noinline optnone  "vplan.ra.candidate"="scalable:0:0:s4" "vplan.ra.width"="8" }
!9 = distinct !{!9, !10}
!10 = !{!"llvm.loop.vplan.candidate", !"scalable:0:0:s4"}
!11 = !{i64 2, i1 true}

; CHECK-DAG: attributes #[[A4:[0-9]+]] = {{.*}}"vplan.ra.candidate"="reverse_folded:0:0:s4" "vplan.ra.iteration-mapping"="1" "vplan.ra.width"="48"
define void @reverse_folded(ptr %p, i64 %n) #4 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !14
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, %step
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !12
exit:
  ret void
}
attributes #4 = { noinline optnone vscale_range(2,2) "vplan.ra.candidate"="reverse_folded:0:0:s4" "vplan.ra.width"="8" }
!12 = distinct !{!12, !13}
!13 = !{!"llvm.loop.vplan.candidate", !"reverse_folded:0:0:s4"}
!14 = !{i64 2, i1 false}

; CHECK-DAG: attributes #[[A5:[0-9]+]] = {{.*}}"vplan.ra.candidate"="variable:0:0:s4" "vplan.ra.iteration-mapping"="0" "vplan.ra.width"="8"
define void @variable(ptr %p, i64 %n) #5 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !17
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, 2
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !15
exit:
  ret void
}
attributes #5 = { noinline optnone vscale_range(2,4) "vplan.ra.candidate"="variable:0:0:s4" "vplan.ra.width"="8" }
!15 = distinct !{!15, !16}
!16 = !{!"llvm.loop.vplan.candidate", !"variable:0:0:s4"}
!17 = !{i64 1, i1 true}

; CHECK-DAG: attributes #[[A6:[0-9]+]] = {{.*}}"vplan.ra.candidate"="unknown:0:0:s4" "vplan.ra.iteration-mapping"="0" "vplan.ra.width"="8"
define void @unknown(ptr %p, i64 %n) #6 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !20
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, 2
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !18
exit:
  ret void
}
attributes #6 = { noinline optnone  "vplan.ra.candidate"="unknown:0:0:s4" "vplan.ra.width"="8" }
!18 = distinct !{!18, !19}
!19 = !{!"llvm.loop.vplan.candidate", !"unknown:0:0:s4"}
!20 = !{i64 1, i1 true}

; CHECK-DAG: attributes #[[A7:[0-9]+]] = {{.*}}"vplan.ra.candidate"="nonintegral:0:0:s4" "vplan.ra.iteration-mapping"="0" "vplan.ra.width"="8"
define void @nonintegral(ptr %p, i64 %n) #7 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !23
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, 6
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !21
exit:
  ret void
}
attributes #7 = { noinline optnone vscale_range(2,2) "vplan.ra.candidate"="nonintegral:0:0:s4" "vplan.ra.width"="8" }
!21 = distinct !{!21, !22}
!22 = !{!"llvm.loop.vplan.candidate", !"nonintegral:0:0:s4"}
!23 = !{i64 2, i1 true}

; CHECK-DAG: attributes #[[A8:[0-9]+]] = {{.*}}"vplan.ra.candidate"="overflow:0:0:s4" "vplan.ra.iteration-mapping"="0" "vplan.ra.width"="8"
define void @overflow(ptr %p, i64 %n) #8 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !26
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, 2
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !24
exit:
  ret void
}
attributes #8 = { noinline optnone vscale_range(4,4) "vplan.ra.candidate"="overflow:0:0:s4" "vplan.ra.width"="8" }
!24 = distinct !{!24, !25}
!25 = !{!"llvm.loop.vplan.candidate", !"overflow:0:0:s4"}
!26 = !{i64 9223372036854775807, i1 true}

; CHECK-DAG: attributes #[[A9:[0-9]+]] = {{.*}}"vplan.ra.candidate"="width_overflow:0:0:s4" "vplan.ra.iteration-mapping"="0" "vplan.ra.width"="4294967295"
define void @width_overflow(ptr %p, i64 %n) #9 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !29
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, 4
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !27
exit:
  ret void
}
attributes #9 = { noinline optnone vscale_range(2,2) "vplan.ra.candidate"="width_overflow:0:0:s4" "vplan.ra.width"="4294967295" }
!27 = distinct !{!27, !28}
!28 = !{!"llvm.loop.vplan.candidate", !"width_overflow:0:0:s4"}
!29 = !{i64 1, i1 true}

; CHECK-DAG: attributes #[[A10:[0-9]+]] = {{.*}}"vplan.ra.candidate"="zero:0:0:s4" "vplan.ra.iteration-mapping"="0" "vplan.ra.width"="8"
define void @zero(ptr %p, i64 %n) #10 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !32
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, 2
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !30
exit:
  ret void
}
attributes #10 = { noinline optnone vscale_range(2,2) "vplan.ra.candidate"="zero:0:0:s4" "vplan.ra.width"="8" }
!30 = distinct !{!30, !31}
!31 = !{!"llvm.loop.vplan.candidate", !"zero:0:0:s4"}
!32 = !{i64 0, i1 true}

; CHECK-DAG: attributes #[[A11:[0-9]+]] = {{.*}}"vplan.ra.candidate"="negative_step:0:0:s4" "vplan.ra.iteration-mapping"="0" "vplan.ra.width"="8"
define void @negative_step(ptr %p, i64 %n) #11 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !35
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, -2
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !33
exit:
  ret void
}
attributes #11 = { noinline optnone vscale_range(2,2) "vplan.ra.candidate"="negative_step:0:0:s4" "vplan.ra.width"="8" }
!33 = distinct !{!33, !34}
!34 = !{!"llvm.loop.vplan.candidate", !"negative_step:0:0:s4"}
!35 = !{i64 1, i1 true}

; CHECK-DAG: attributes #[[A12:[0-9]+]] = {{.*}}"vplan.ra.candidate"="before_folding:0:0:s4" "vplan.ra.iteration-mapping"="1" "vplan.ra.width"="8"
define void @before_folding(ptr %p, i64 %n) #12 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !38
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, %vs
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !36
exit:
  ret void
}
attributes #12 = { noinline optnone vscale_range(2,2) "vplan.ra.candidate"="before_folding:0:0:s4" "vplan.ra.width"="8" }
!36 = distinct !{!36, !37}
!37 = !{!"llvm.loop.vplan.candidate", !"before_folding:0:0:s4"}
!38 = !{i64 1, i1 true}

; CHECK-DAG: attributes #[[A13:[0-9]+]] = {{.*}}"vplan.ra.candidate"="folded_four:0:0:s4" "vplan.ra.iteration-mapping"="1" "vplan.ra.width"="8"
define void @folded_four(ptr %p, i64 %n) #13 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !41
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, 4
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !39
exit:
  ret void
}
attributes #13 = { noinline optnone vscale_range(4,4) "vplan.ra.candidate"="folded_four:0:0:s4" "vplan.ra.width"="8" }
!39 = distinct !{!39, !40}
!40 = !{!"llvm.loop.vplan.candidate", !"folded_four:0:0:s4"}
!41 = !{i64 1, i1 true}

; CHECK-DAG: attributes #[[A14:[0-9]+]] = {{.*}}"vplan.ra.candidate"="missing_witness:0:0:s4" "vplan.ra.iteration-mapping"="0" "vplan.ra.width"="8"
define void @missing_witness(ptr %p, i64 %n) #14 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop]
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, 2
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !42
exit:
  ret void
}
attributes #14 = { noinline optnone vscale_range(2,2) "vplan.ra.candidate"="missing_witness:0:0:s4" "vplan.ra.width"="8" }
!42 = distinct !{!42, !43}
!43 = !{!"llvm.loop.vplan.candidate", !"missing_witness:0:0:s4"}
!44 = !{i64 1, i1 true}

; CHECK-DAG: attributes #[[A15:[0-9]+]] = {{.*}}"vplan.ra.candidate"="wrong_loop:0:0:s4" "vplan.ra.iteration-mapping"="0" "vplan.ra.width"="8"
define void @wrong_loop(ptr %p, i64 %n) #15 {
entry:
  %vs = call i64 @llvm.vscale.i64()
  %step = mul i64 %vs, 6
  br label %loop
loop:
  %iv = phi i64 [0, %entry], [%next, %loop], !vplan.ra.induction !47
  store volatile i64 %iv, ptr %p
  %next = add i64 %iv, 2
  %done = icmp eq i64 %next, %n
  br i1 %done, label %exit, label %loop, !llvm.loop !45
exit:
  ret void
}
attributes #15 = { noinline optnone vscale_range(2,2) "vplan.ra.candidate"="wrong_loop:0:0:s4" "vplan.ra.width"="8" }
!45 = distinct !{!45, !46}
!46 = !{!"llvm.loop.vplan.candidate", !"different:0:0:s4"}
!47 = !{i64 1, i1 true}
