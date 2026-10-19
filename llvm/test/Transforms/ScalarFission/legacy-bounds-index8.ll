; RUN: opt -passes="scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>" -verify-each -disable-output %s
target datalayout = "e-p:64:64:64:8-i64:64-n32:64-S128"
define i1024 @row_cannot_fit() {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i8 [0, %preheader], [%next, %loop]
  %r = phi i1024 [17, %preheader], [%u, %loop]
  %c = zext i8 %iv to i1024
  %u = add i1024 %r, %c
  %next = add nuw i8 %iv, 1
  %done = icmp eq i8 %next, 2
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i1024 [%u, %loop]
  ret i1024 %result
}
