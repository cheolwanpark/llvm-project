; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -pass-remarks=scalar-fission -pass-remarks-output=%t.yaml -disable-output %s
; RUN: FileCheck %s < %t.yaml
;
; %coordinate moves with its private suffix. %symmetry remains in the original
; control and is read by both stages. Follow all retained dependencies rather
; than looking only at the load's immediate users or counting every cloned load.
; CHECK: Name: Selected
; CHECK: OriginalLoadInstructionBytes: '17'
; CHECK: AdditionalLoadInstructionBytesUpperBound: '1'
; CHECK: DuplicatedOriginalLoadInstructionBytes: '1'
; CHECK: MovedOriginalLoadInstructionBytes: '8'
; CHECK: ConsumerOriginalLoadInstructionBytes: '9'

define double @reads(ptr %a, ptr %coordinates, ptr %symmetries, i64 %n) {
entry:
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%next, %latch]
  %s = phi double [0.0, %entry], [%sn, %latch]
  %t = phi double [1.0, %entry], [%tn, %latch]
  %p = getelementptr double, ptr %a, i64 %i
  %x = load double, ptr %p
  %square = fmul double %x, %x
  %biased = fadd double %square, 1.25
  %f = fmul double %biased, 0.5
  %sp = getelementptr i8, ptr %symmetries, i64 %i
  %symmetry = load i8, ptr %sp
  %take = icmp eq i8 %symmetry, 0
  br i1 %take, label %then, label %latch
then:
  %cp = getelementptr double, ptr %coordinates, i64 %i
  %coordinate = load double, ptr %cp
  %g = fmul double %f, %coordinate
  %u = fadd double %s, %f
  %v = fsub double %t, %g
  br label %latch
latch:
  %sn = phi double [%s, %loop], [%u, %then]
  %tn = phi double [%t, %loop], [%v, %then]
  %next = add nuw i64 %i, 1
  %more = icmp ult i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %r = phi double [%sn, %latch]
  %q = phi double [%tn, %latch]
  %total = fadd double %r, %q
  ret double %total
}
