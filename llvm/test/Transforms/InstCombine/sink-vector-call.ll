; RUN: opt -passes='instcombine,simplifycfg' -S %s | FileCheck %s
;
; Killing a vector before a call avoids carrying the whole vector across it.
; This is a sinking profitability decision, not a new semantic barrier.

declare void @cleanup(ptr)
declare float @llvm.vector.reduce.fadd.nxv16f32(float, <vscale x 16 x float>)
declare i32 @llvm.vector.reduce.add.v16i32(<16 x i32>)

; CHECK-LABEL: define float @scalable_reduction(
; CHECK: call fast float @llvm.vector.reduce.fadd
; CHECK-NEXT: call void @cleanup
; CHECK-NEXT: ret float
define float @scalable_reduction(ptr %p, <vscale x 16 x float> %v) {
entry:
  %r = call fast float @llvm.vector.reduce.fadd.nxv16f32(float 0.0, <vscale x 16 x float> %v)
  br label %clean
clean:
  call void @cleanup(ptr %p)
  br label %exit
exit:
  ret float %r
}

; CHECK-LABEL: define i32 @fixed_reduction(
; CHECK: call i32 @llvm.vector.reduce.add
; CHECK-NEXT: call void @cleanup
; CHECK-NEXT: ret i32
define i32 @fixed_reduction(ptr %p, <16 x i32> %v) {
entry:
  %r = call i32 @llvm.vector.reduce.add.v16i32(<16 x i32> %v)
  call void @cleanup(ptr %p)
  br label %exit
exit:
  ret i32 %r
}

; CHECK-LABEL: define i32 @extract_before_call(
; CHECK: extractelement
; CHECK-NEXT: call void @cleanup
; CHECK-NEXT: ret i32
define i32 @extract_before_call(ptr %p, <4 x i32> %v) {
entry:
  %r = extractelement <4 x i32> %v, i64 0
  br label %clean
clean:
  call void @cleanup(ptr %p)
  br label %exit
exit:
  ret i32 %r
}

; No call: still sink into the sole user's conditional block.
; CHECK-LABEL: define i32 @sink_without_call(
; CHECK: entry:
; CHECK-NEXT: br i1
; CHECK: used:
; CHECK-NEXT: %r = call i32 @llvm.vector.reduce.add
define i32 @sink_without_call(<16 x i32> %v, i1 %cond) {
entry:
  %r = call i32 @llvm.vector.reduce.add.v16i32(<16 x i32> %v)
  br i1 %cond, label %used, label %exit
used:
  call void @consume(i32 %r)
  br label %exit
exit:
  ret i32 0
}

declare void @consume(i32)

; A later vector use already keeps the vector live across cleanup.
; CHECK-LABEL: define i32 @vector_already_live(
; CHECK: call void @cleanup
; CHECK: call i32 @llvm.vector.reduce.add
define i32 @vector_already_live(ptr %p, <16 x i32> %v) {
entry:
  %r = call i32 @llvm.vector.reduce.add.v16i32(<16 x i32> %v)
  br label %clean
clean:
  call void @cleanup(ptr %p)
  br label %exit
exit:
  call void @consume_vector(<16 x i32> %v)
  ret i32 %r
}

declare void @consume_vector(<16 x i32>)

; Independent later loops should carry a scalar, not the consumed vector.
; CHECK-LABEL: define i32 @later_loop(
; CHECK: entry:
; CHECK-NEXT: %r = call i32 @llvm.vector.reduce.add
; CHECK-NEXT: br label %loop
define i32 @later_loop(ptr %p, <16 x i32> %v, i64 %n) {
entry:
  %r = call i32 @llvm.vector.reduce.add.v16i32(<16 x i32> %v)
  br label %loop
loop:
  %i = phi i64 [0, %entry], [%inc, %loop]
  %address = getelementptr i32, ptr %p, i64 %i
  store i32 1, ptr %address
  %inc = add i64 %i, 1
  %done = icmp eq i64 %inc, %n
  br i1 %done, label %exit, label %loop
exit:
  ret i32 %r
}

; Shared constants have no live register state to preserve across a call.
; Their uses can also belong to another function's dominator tree.
; CHECK-LABEL: define i32 @shared_constant_a(
; CHECK: call void @cleanup
; CHECK: ret i32
define i32 @shared_constant_a(ptr %p, i64 %index) {
entry:
  %r = extractelement <4 x i32> <i32 17, i32 11, i32 -7, i32 42>, i64 %index
  br label %clean
clean:
  call void @cleanup(ptr %p)
  br label %exit
exit:
  ret i32 %r
}

; CHECK-LABEL: define i32 @shared_constant_b(
; CHECK: call void @cleanup
; CHECK: ret i32
define i32 @shared_constant_b(ptr %p, i64 %index) {
entry:
  %r = extractelement <4 x i32> <i32 17, i32 11, i32 -7, i32 42>, i64 %index
  br label %clean
clean:
  call void @cleanup(ptr %p)
  br label %exit
exit:
  ret i32 %r
}
