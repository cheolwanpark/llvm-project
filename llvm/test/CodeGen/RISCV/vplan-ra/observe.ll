; RUN: llc -mtriple=riscv64 -mattr=+v -vplan-ra-run-id=test -vplan-probe-candidate=kernel:0:0:s4 -vplan-ra-features-output=%t.json -stop-after=riscv-vplan-ra-observe %s -o %t.mir
; RUN: FileCheck %s --check-prefix=FEATURES < %t.json
; RUN: FileCheck %s --check-prefix=MIR < %t.mir
; RUN: llc -mtriple=riscv64 -mattr=+v %s -o %t.direct.s
; RUN: llc -mtriple=riscv64 -mattr=+v -vplan-ra-run-id=test -vplan-probe-candidate=kernel:0:0:s4 -vplan-ra-features-output=%t.full.json %s -o %t.observed.s
; RUN: diff %t.direct.s %t.observed.s

; FEATURES-DAG: "stage":"post-ra"
; FEATURES-DAG: "id":"kernel:0:0:s4"
; FEATURES-DAG: "features":{
; MIR: body: |
; MIR-NOT: %{{[0-9]+}}
; MIR: $v
; MIR-NOT: %{{[0-9]+}}

define void @kernel(ptr %a, ptr %b, i64 %x) #0 {
  %v = load <vscale x 4 x i32>, ptr %a, align 4
  %r = add <vscale x 4 x i32> %v, splat (i32 1)
  store <vscale x 4 x i32> %r, ptr %b, align 4
  store i64 %x, ptr %a, align 8
  ret void
}
attributes #0 = { "vplan.ra.candidate"="kernel:0:0:s4" }
