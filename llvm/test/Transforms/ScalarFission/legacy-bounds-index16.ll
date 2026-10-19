; RUN: opt -passes="scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>" -verify-each -disable-output %s
target datalayout = "e-p:64:64:64:16-i64:64-n32:64-S128"
define i32 @limited_index() {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i32 [0, %preheader], [%next, %loop]
  %r = phi i32 [17, %preheader], [%u, %loop]
  %u = add i32 %r, %iv
  %next = add nuw i32 %iv, 1
  %done = icmp eq i32 %next, 16385
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%u, %loop]
  ret i32 %result
}
