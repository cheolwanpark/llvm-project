; RUN: opt -passes=simplifycfg -vplan-backend=false -disable-output %s
; RUN: opt -passes=simplifycfg -vplan-backend=true -disable-output %s
; RUN: opt -passes=simplifycfg -vplan-backend=true -use-default-tti -disable-output %s
;
; Opaque scalar support TUs keep the tuning CPU but deliberately disable RVV.
; TTI construction must not query real VLEN on these subtargets.
target triple = "riscv64-unknown-elf"

define void @xiangshan_scalar() #0 { ret void }
define void @saturn_scalar() #1 { ret void }
define void @k1_scalar() #2 { ret void }

attributes #0 = { "target-cpu"="generic-rv64" "tune-cpu"="xiangshan-kunminghu" "target-features"="-v,-zve32x,-zve32f,-zve64x,-zve64f,-zve64d" }
attributes #1 = { "target-cpu"="generic-rv64" "tune-cpu"="saturn-shuttle-v256d128" "target-features"="-v,-zve32x,-zve32f,-zve64x,-zve64f,-zve64d" }
attributes #2 = { "target-cpu"="generic-rv64" "tune-cpu"="spacemit-x60" "target-features"="-v,-zve32x,-zve32f,-zve64x,-zve64f,-zve64d" }
