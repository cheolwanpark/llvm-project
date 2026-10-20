; RUN: %python %S/Inputs/frontier-budget.py > %t.ll
; RUN: opt -passes='scalar-fission,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -pass-remarks-missed=scalar-fission -S %t.ll -o %t.out 2> %t.err
; RUN: FileCheck %s < %t.out
; RUN: FileCheck %s --check-prefix=REASON < %t.err
; CHECK-LABEL: define i32 @budget(
; CHECK-NOT: scalar.fission
; CHECK: ret i32
; REASON: scalar fission rejected: analysis-budget
; REASON-SAME: analysis budget remaining 0
