; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' \
; RUN:   -verify-each -mtriple=riscv64 -mattr=+v -force-vector-width=4 \
; RUN:   -force-vector-interleave=1 -scalable-vectorization=always -hints-allow-reordering=false \
; RUN:   -tail-folding-policy=dont-fold-tail -enable-epilogue-vectorization=false \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=780 \
; RUN:   -pass-remarks=vplan-reduction-fission -S %S/../../../Other/Inputs/reduction-fission-fneg-vector.ll \
; RUN:   -o %t.ll 2> %t.remarks
; RUN: FileCheck %s --check-prefix=IR < %t.ll
; RUN: FileCheck %s --check-prefix=SELECT < %t.remarks
; RUN: llc -mtriple=riscv64 -mattr=+v -verify-machineinstrs %t.ll -o /dev/null
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v \
; RUN:   -enable-vplan-reduction-fission -vplan-reduction-fission-max-scratch-bytes=11 \
; RUN:   -pass-remarks-missed=vplan-reduction-fission -disable-output \
; RUN:   %S/../../../Other/Inputs/reduction-fission-fneg-vector.ll 2>&1 | FileCheck %s --check-prefix=LIMIT
;
; Synthetic ordinary-LV VF4/IC1 controls apply only to this regression.
; Both original scalar fneg opcodes reach scalar admission, with no frontend
; canonicalization, flags, nsz, reassociation or errno assumptions. The full
; producer can vectorize; the analogous compact producer keeps its conditional
; work scalar while the ordered consumer vectorizes independently.
;
; The companion checker runs strict/reordered, once/twice LV and C=65/1/9,
; verifies actual probe modules, and rejects sign/participation/start/count
; mutations. The complete executable driver compares original and transformed
; IR to a sign-bit/ordered-add oracle. It requires actual vector entries where
; widths fit, scalar tails and exact scratch/count/bypass evidence. C=1 is a
; scalar boundary even if an unreachable vector body is emitted. EVL/VP is
; separately machine-verified RVV codegen; unsupported host execution is explicit.
;
; SELECT: fneg-vector.c:12:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 780, producer live-outs 0
; SELECT: fneg-vector.c:12:3: scalar-IR fission producer VF vscale x 4
; SELECT: fneg-vector.c:12:3: scalar-IR fission consumer VF vscale x 4
; SELECT: fneg-vector.c:22:3: split scalar-IR reduction loop; {{.*}}scratch capacity 65, scratch bytes 780, producer live-outs 0
; SELECT: fneg-vector.c:22:3: scalar-IR fission producer VF 1
; SELECT: fneg-vector.c:22:3: scalar-IR fission consumer VF vscale x 4
; LIMIT: fneg-vector.c:12:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; LIMIT: fneg-vector.c:22:3: scalar-IR reduction fission rejected: scalar-scratch-limit
; IR-LABEL: define void @neg_full(
; IR: alloca [65 x double]
; IR: alloca [65 x float]
; IR: fneg <vscale x 4 x double>
; IR: fneg <vscale x 4 x float>
; IR: scalar.fission.consumer.ph:
; IR: call double @llvm.vector.reduce.fadd.nxv4f64(double
; IR: call float @llvm.vector.reduce.fadd.nxv4f32(float
; IR: scalar.fission.consumer.body:
; IR: fadd double
; IR: fadd float
; IR-LABEL: define void @neg_compact(
; IR: left:
; IR: %dc = fneg double %dx
; IR: %fc = fneg float %rawf
; IR: right:
; IR-NOT: fneg
; IR-NOT: load double
; IR: latch:
; IR: %fission.empty = icmp eq i64
; IR: scalar.fission.consumer.ph:
; IR: call double @llvm.vector.reduce.fadd.nxv4f64(double
; IR: call float @llvm.vector.reduce.fadd.nxv4f32(float
