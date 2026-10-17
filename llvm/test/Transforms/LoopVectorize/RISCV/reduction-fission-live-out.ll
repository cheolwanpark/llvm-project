; RUN: sed 's/ret void/store i32 %x, ptr %out ret void/' %S/reduction-fission-general.ll > %t.ll
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
; RUN:   -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -S %t.ll -o %t.baseline
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
; RUN:   -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-force-producer-vf=16 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 -S %t.ll -o %t.fission
; RUN: diff %t.baseline %t.fission
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
; RUN:   -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false \
; RUN:   -S %t.ll -o %t.baseline
; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
; RUN:   -verify-each -mtriple=riscv64 -mattr=+v -force-vector-interleave=1 \
; RUN:   -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-min-chain-depth=4 \
; RUN:   -vplan-reduction-fission-force-producer-vf=16 \
; RUN:   -vplan-reduction-fission-force-accumulator-vf=2 -S %t.ll -o %t.fission
; RUN: diff %t.baseline %t.fission
;
; Fission exports reductions through vector/scalar result merges. A separate
; last-iteration load cannot use those merges. Reject before changing IR, both
; with EVL tail folding and with an ordinary scalar epilogue, so every original
; exit PHI retains its incoming value.
