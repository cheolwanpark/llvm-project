// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVGenericMIRInfo.h"
#include "RISCVInstrInfo.h"
#include "RISCVSubtarget.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/Support/InstructionCost.h"
#include "llvm/Support/MathExtras.h"
#define GET_COMPUTE_FEATURES
#include "RISCVGenInstrInfo.inc"
using namespace llvm;
namespace {
enum class Kind {
  Unsupported,
  Basic,
  Nominal,
  Zero,
  Ignore,
  Asm,
  CAS,
  Config,
  Whole,
  Indexed,
  Strided,
  Memory,
  MaskMemory,
  Vector,
  Wide,
  Gather,
  Ordered,
  Reduction,
  Matrix,
  TileMemory
};
struct Rule {
  Kind K;
  unsigned A = 1, Fields = 1;
  const char *Evidence = "native";
};
Rule classify(unsigned Opcode) {
  switch (Opcode) {
#include "RISCVGenericMIRRules.inc"
  default:
    return {Kind::Unsupported};
  }
}
} // namespace
RISCVGenericMIRInfo::RISCVGenericMIRInfo(const RISCVSubtarget &ST)
    : VLEN(ST.getRealMinVLen()), DLen(ST.getDLenFactor()), XLen(ST.getXLen()),
      Features(RISCV_MC::computeAvailableFeatures(ST.getFeatureBits())),
      CPU(ST.getTuneCPU()) {
  // Snapshot native scalable helpers; no target or IR pointers escape.
  for (unsigned I = 0; I != 7; ++I) {
    MVT VT = MVT::getVectorVT(MVT::i8, 1u << I, true);
    GroupCosts[I] = ST.getTargetLowering()->getLMULCost(VT).getValue();
    GatherCosts[I] = ST.getTargetLowering()->getVRGatherVVCost(VT).getValue();
  }
  for (unsigned F = 2; F != 9; ++F)
    OptimizedSegment[F] = ST.hasOptimizedSegmentLoadStore(F);
}
Expected<MIRInstructionCost>
RISCVGenericMIRInfo::getInstructionCost(const VPlanMIRInstruction &MI) const {
  Rule R = classify(MI.BaseOpcodeID);
  auto result = [&](StringRef RuleID, int64_t C, StringRef Evidence = {}) {
    MIRInstructionCost Cost{RuleID.str(), false, C, 1};
    Cost.Evidence = Evidence.empty() ? R.Evidence : Evidence.str();
    if (R.K == Kind::Reduction || R.K == Kind::Ordered ||
        R.K == Kind::Strided || R.K == Kind::Indexed || R.K == Kind::Memory ||
        R.K == Kind::MaskMemory)
      Cost.CountSource = "nominal-capacity";
    Cost.PriceGroup8 = MI.LMUL8;
    return Cost;
  };
  auto fail = [&]() -> Expected<MIRInstructionCost> {
    return createStringError("unsupported or invalid MIR instruction: " +
                             MI.Opcode);
  };
  if (R.K == Kind::Ignore)
    return result("policy-ignored", 0, "policy-ignored");
  if (MI.BaseOpcodeID >= RISCV::INSTRUCTION_LIST_END)
    return fail();
  auto RequiredFeatures = RISCV_MC::computeRequiredFeatures(MI.BaseOpcodeID);
  if ((RequiredFeatures & Features) != RequiredFeatures)
    return fail();
  if (R.K == Kind::Asm) {
    if (!MI.InlineAsmArguments)
      return fail();
    return result("ASM-OPAQUE", uint64_t(*MI.InlineAsmArguments) + 1, "policy");
  }
  if (R.K == Kind::Zero)
    return result("pseudo-nominal-no-compute", 0, "policy");
  if (R.K == Kind::Nominal)
    return result("pseudo-nominal-compute", 1, "policy");
  if (R.K == Kind::Basic)
    return result(MI.Call ? "CALL" : "S-BASIC",
                  MI.Call ? std::max(10u, R.A) : R.A);
  if (R.K == Kind::CAS)
    return result("AT-CAS", 3 * divideCeil(R.A, XLen), "policy");
  if (R.K == Kind::Config)
    return result("CFG-VSET", DLen);
  if (R.K == Kind::Whole) {
    if (MI.RegisterGroups8.empty() ||
        llvm::any_of(MI.RegisterGroups8,
                     [&](unsigned G) { return G != R.A * 8; }))
      return fail();
    auto Cost = result("REG-WHOLE", GroupCosts[Log2_32(R.A * 8)], "analogy");
    Cost.PriceGroup8 = R.A * 8;
    return Cost;
  }
  if (R.K == Kind::Unsupported)
    return fail();
  unsigned G = MI.LMUL8, S = MI.SEW;
  if (!VLEN || !isPowerOf2_32(G) || G > 64)
    return fail();
  auto C = [&](unsigned Group) { return GroupCosts[Log2_32(Group)]; };
  if (R.K == Kind::MaskMemory) {
    // Mask pseudos encode the corresponding e8 LMUL (AllMasks in
    // RISCVInstrInfoVPseudos.td), not a data type with SEW=1.
    if (S != 1 || uint64_t(VLEN) * G % 64)
      return fail();
    uint64_t Bits = uint64_t(VLEN) * G / 64;
    if (!Bits || Bits > VLEN)
      return fail();
    return result("MEM-MASK",
                  std::max(uint64_t(1),
                           divideCeil(divideCeil(Bits, uint64_t(8)) * DLen * 8,
                                      uint64_t(VLEN))),
                  "analogy");
  }
  if (S != 8 && S != 16 && S != 32 && S != 64)
    return fail();
  if (G * 8 < S || uint64_t(VLEN) * G % (8 * S))
    return fail();
  uint64_t N = uint64_t(VLEN) * G / (8 * S);
  if (!N)
    return fail();
  // Check the non-uniform geometries which an opcode's ISA predicate alone
  // cannot express. The pseudo's LMUL/SEW describe the execution type.
  switch (MI.BaseOpcodeID) {
  case RISCV::VAESDF_VS:
  case RISCV::VAESDF_VV:
  case RISCV::VAESDM_VS:
  case RISCV::VAESDM_VV:
  case RISCV::VAESEF_VS:
  case RISCV::VAESEF_VV:
  case RISCV::VAESEM_VS:
  case RISCV::VAESEM_VV:
  case RISCV::VAESKF1_VI:
  case RISCV::VAESKF2_VI:
  case RISCV::VAESZ_VS:
  case RISCV::VSM4K_VI:
  case RISCV::VSM4R_VS:
  case RISCV::VSM4R_VV:
  case RISCV::VGHSH_VV:
  case RISCV::VGMUL_VV:
    if (S != 32 || N < 4)
      return fail();
    break;
  case RISCV::VSM3C_VI:
  case RISCV::VSM3ME_VV:
    if (S != 32 || N < 8)
      return fail();
    break;
  case RISCV::VSHA2CH_VV:
  case RISCV::VSHA2CL_VV:
  case RISCV::VSHA2MS_VV:
    if ((S != 32 && S != 64) || N < 4 ||
        (S == 64 && !Features[RISCV_MC::Feature_HasStdExtZvknhbBit]))
      return fail();
    break;
  case RISCV::VDOT4ASU_VV:
  case RISCV::VDOT4ASU_VX:
  case RISCV::VDOT4AUS_VX:
  case RISCV::VDOT4AU_VV:
  case RISCV::VDOT4AU_VX:
  case RISCV::VDOT4A_VV:
  case RISCV::VDOT4A_VX:
    if (S != 32)
      return fail();
    break;
  case RISCV::VNCLIPU_WI:
  case RISCV::VNCLIPU_WV:
  case RISCV::VNCLIPU_WX:
  case RISCV::VNCLIP_WI:
  case RISCV::VNCLIP_WV:
  case RISCV::VNCLIP_WX:
  case RISCV::VFNCVT_F_F_W:
  case RISCV::VFNCVT_F_XU_W:
  case RISCV::VFNCVT_F_X_W:
  case RISCV::VFNCVT_ROD_F_F_W:
  case RISCV::VFNCVT_RTZ_XU_F_W:
  case RISCV::VFNCVT_RTZ_X_F_W:
  case RISCV::VFNCVT_XU_F_W:
  case RISCV::VFNCVT_X_F_W:
  case RISCV::VNSRA_WI:
  case RISCV::VNSRA_WV:
  case RISCV::VNSRA_WX:
  case RISCV::VNSRL_WI:
  case RISCV::VNSRL_WV:
  case RISCV::VNSRL_WX:
    if (S > 32 || G > 32)
      return fail();
    break;
  case RISCV::VSEXT_VF2:
  case RISCV::VZEXT_VF2:
    if (S < 16 || G < 2)
      return fail();
    break;
  case RISCV::VSEXT_VF4:
  case RISCV::VZEXT_VF4:
    if (S < 32 || G < 4)
      return fail();
    break;
  case RISCV::VSEXT_VF8:
  case RISCV::VZEXT_VF8:
    if (S < 64 || G < 8)
      return fail();
    break;
  default:
    break;
  }
  if (R.K == Kind::Matrix || R.K == Kind::TileMemory) {
    if (G < 8 || VLEN % S)
      return fail();
    uint64_t L = VLEN / S;
    uint64_t Low = UINT64_MAX, High = 0;
    for (unsigned Lambda = 1; Lambda <= 64; Lambda *= 2) {
      if (MI.MatrixLambda && Lambda != MI.MatrixLambda)
        continue;
      uint64_t Square = uint64_t(Lambda) * Lambda;
      if (Square > L || L % Square || L / Square > 16)
        continue;
      uint64_t Rows = L / Lambda;
      uint64_t K = uint64_t(Lambda) * R.A * (G / 8);
      // Each output row occupies 1/lambda registers. Small row fragments
      // still require one native vector operation; never pack rows together.
      uint64_t RowCost = Lambda <= DLen ? DLen / Lambda : 1;
      uint64_t Price = R.K == Kind::TileMemory ? N : K * Rows * RowCost;
      Low = std::min(Low, Price);
      High = std::max(High, Price);
    }
    if (Low == UINT64_MAX || High > uint64_t(INT64_MAX) / 2)
      return fail();
    auto Cost = result(R.K == Kind::Matrix ? "MATRIX-ANALOG" : "MEM-TILE",
                       Low + High, "analogy");
    Cost.Denominator = 2;
    Cost.CountSource = MI.MatrixLambda
                           ? "nominal-capacity;explicit-lambda"
                           : "nominal-capacity;lambda-cost-midrange";
    Cost.PriceGroup8 = 0; // Output geometry is not the input LMUL.
    return Cost;
  }
  if (R.K == Kind::Memory || R.K == Kind::Strided || R.K == Kind::Indexed) {
    unsigned E = R.K == Kind::Indexed ? S : R.A;
    if (G * R.Fields > 64 || uint64_t(VLEN) * G % (8 * E))
      return fail();
    N = uint64_t(VLEN) * G / (8 * E);
    if (!N)
      return fail();
    if (R.K == Kind::Indexed &&
        (!isPowerOf2_32(MI.IndexEMUL8) || MI.IndexEMUL8 > 64 ||
         MI.IndexEEW != R.A || MI.IndexEMUL8 * S != G * R.A))
      return fail();
    if (R.K != Kind::Memory)
      return result("MEM-ELEMENT", R.Fields * N);
    if (R.Fields == 1)
      return result("MEM-UNIT", C(G));
    if (!MI.MemoryAlignment)
      return fail();
    if (OptimizedSegment[R.Fields] && MI.MemoryAlignment >= E / 8 &&
        !MI.AddressSpace)
      return result("MEM-SEG-OPT",
                    std::max(1u, divideCeil(R.Fields * G * DLen, 8u)) +
                        R.Fields * C(G),
                    "analogy");
    return result("MEM-SEG", R.Fields * N);
  }
  switch (R.K) {
  case Kind::Vector:
    return result("V-OP", R.A * C(G));
  case Kind::Wide: {
    if (G > 32 || S > 32)
      return fail();
    auto Cost = result("V-WIDE", R.A * C(2 * G), "analogy");
    Cost.PriceGroup8 = 2 * G;
    return Cost;
  }
  case Kind::Gather:
    if (MI.BaseOpcodeID == RISCV::VRGATHEREI16_VV &&
        (G * 16 % S || !isPowerOf2_32(G * 16 / S) || G * 16 / S > 64))
      return fail();
    return result("P-GATHER", GatherCosts[Log2_32(G)]);
  case Kind::Ordered:
    return result("R-ORDER", N);
  case Kind::Reduction:
    return result("R-TREE", Log2_64_Ceil(N));
  default:
    return fail();
  }
}
