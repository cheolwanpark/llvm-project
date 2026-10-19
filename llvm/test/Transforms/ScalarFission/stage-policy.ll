; RUN: opt -passes=scalar-fission -scalar-fission-producer-vf=1 -scalar-fission-consumer-vf=4 -scalar-fission-consumer-scalable -scalar-fission-consumer-interleave=2 -S %S/basic.ll | FileCheck %s
; RUN: opt -passes='default<O3>' -enable-scalar-fission -scalar-fission-early=false -debug-pass-manager -disable-output %S/basic.ll 2>&1 | FileCheck %s --check-prefix=LATE
; RUN: opt -passes='default<O3>' -enable-scalar-fission -scalar-fission-early=true -debug-pass-manager -disable-output %S/basic.ll 2>&1 | FileCheck %s --check-prefix=EARLY
; RUN: not opt -passes=scalar-fission -enable-scalar-reduction-fission=false -disable-output %S/basic.ll 2>&1 | FileCheck %s --check-prefix=MIGRATE
;
; CHECK-DAG: !{!"llvm.loop.vectorize.width", i32 1}
; CHECK-DAG: !{!"llvm.loop.vectorize.enable", i1 false}
; CHECK-DAG: !{!"llvm.loop.vectorize.width", i32 4}
; CHECK-DAG: !{!"llvm.loop.vectorize.scalable.enable", i1 true}
; CHECK-DAG: !{!"llvm.loop.interleave.count", i32 2}
; CHECK-DAG: !{!"llvm.loop.scalar_fission.producer"}
; CHECK-DAG: !{!"llvm.loop.scalar_fission.consumer"}
; LATE: Running pass: LoopFullUnrollPass
; LATE: Running pass: ScalarFissionPass
; LATE: Running pass: LoopVectorizePass
; EARLY: Running pass: ScalarFissionPass
; EARLY: Running pass: LoopFullUnrollPass
; EARLY: Running pass: LoopVectorizePass
; MIGRATE: VPlan-only fission was removed
