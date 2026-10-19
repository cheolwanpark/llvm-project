; RUN: opt -passes="scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>" -verify-each -disable-output %s
define i32 @narrow_max() {
entry:
  br label %preheader
preheader:
  br label %loop
loop:
  %iv = phi i8 [0, %preheader], [%next, %loop]
  %r = phi i32 [17, %preheader], [%u, %loop]
  %c = zext i8 %iv to i32
  %u = add i32 %r, %c
  %next = add nuw i8 %iv, 1
  %done = icmp eq i8 %next, -1
  br i1 %done, label %exit, label %loop
exit:
  %result = phi i32 [%u, %loop]
  ret i32 %result
}
