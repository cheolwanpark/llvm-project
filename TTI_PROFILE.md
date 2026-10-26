# Fixed RTL-correspondence TTI profile

This is the fixed correction from the reference worktree's experiment, not a
newly fitted profile. `XiangShanV2TTIImpl` contains all correction rules; the
common RISC-V TTI has native defaults at the dispatch points. The factory uses
the effective tuning CPU `xiangshan-kunminghu` and exact VLEN=128. Other CPU or
VLEN settings still support in-process vector spill substitution with native TTI.

`VPlanCostProfileScope` saves and restores thread-local state. The master flag
`-enable-vplan-backend-cost-model` opens it only for candidate body and spill
cost queries. Planning, scalar comparisons, clone optimization and codegen run
outside the scope. Only reciprocal-throughput queries change. No benchmark names
or measured cycles enter a rule. Master OFF and other cost kinds remain native.

L is the legalized type's `getLMULCost`, including its fractional-LMUL clamp and
DLen behavior. K is the legalization multiplier. E is the memory hook's element
or field count. These variables are not the candidate VF.

| Hook / operation | Native expression → correction | RTL service correspondence and limits |
|---|---|---|
| slide up/down VI/VX | L → L(L+1)/2+1 | triangular permutation work plus transfer; both immediate and scalar forms |
| gather VI | L → L²+1 | gather work plus transfer; VV/EI16 remain native |
| FP divide VV/VF/reverse VF | L → L×{8,10,15}, VF forms +1 | vfdiv SEW 16/32/64 service plus scalar transfer |
| FP sqrt | L → L×{7,10,17} | vfsqrt SEW 16/32/64 |
| signed integer divide/remainder VV | L×TCC_Expensive → L×{11,13,17,25} | vidiv SEW 8/16/32/64; IR unsigned division/remainder share this opcode hook; actual unsigned machine opcodes and VX are not added to the switch |
| narrowing VNSRL_WI | L → max(1,ceil(2×destination-bits/group-bits))+1 | widened source work and transfer; scalable group is 64 bits, fixed group is real VLEN |
| generic FP arithmetic | 2×opcode cost → opcode cost | remove generic FP multiplier; this wraps corrected divide as in the prior patch |
| uniform arithmetic operand | opcode cost → opcode cost+1 before K | one transfer when either operand's original hook facts say uniform; constant materialization unchanged |
| contiguous vector memory | Cost+BaseCost → Cost+BaseCost+K | extra transfer per legalized vector memory operation |
| strided vector memory | E×TCC_Basic → E×TCC_Basic+2 | element flows, two transfer tasks |
| gather/scatter | E×TCC_Basic → E×TCC_Basic+1 | element flows, one transfer task |
| segment/interleaved fast path | E×TCC_Basic → E×(8 load / 4 store)+1 | field/element traversal plus transfer; other fallback branches unchanged |

All formulas are transcribed from the previous experiment's patch. They preserve
that patch's hook boundaries, including limitations: generic uniform operands can
have their own constant materialization costs; L is legalized work rather than a
fractional physical group; widening/narrowing outside VNSRL_WI retains original
hook logic; signed/unsigned IR share the signed-opcode hook although direct unsigned machine-opcode queries are unchanged; reductions, scalar hooks, shuffle
fallbacks, masking, legalization and other memory fallbacks remain native.
Thus equality with a particular emitted MIR sequence is not guaranteed. The
separate external Python model continues to obtain its full MIR service
decomposition from `kunminghu_v2.py`; this in-process model only prices actual
vector spills through TTI.

Whole-register spill/reload uses the new `getSpillReloadCost` descriptor hook:
actual register groups 1/2/4/8 cost 2/3/5/9 under the active profile. Each emitted
instruction is priced independently, even when multiple instructions share a
segment spill slot. The default hook delegates to `getMemoryOpCost`.

The in-process body model is `tti-real-vector-spill-v1`:
`L - estimated-vector-spill + observed-vector-spill * Wtti / Wobs`.
Scalar estimated spills remain in L. This is the vector-only variant of the
reference Python `tti-real-spill` model; the external model is unchanged.

Tests are in `XiangShanV2TTITest.cpp`, `VPlanBackendCostModelTest.cpp` and the
RISC-V loop-vectorizer integration tests. See [BACKEND_FEEDBACK.md](BACKEND_FEEDBACK.md)
for activation, IC, epilogue, fallback and reproduction commands.
