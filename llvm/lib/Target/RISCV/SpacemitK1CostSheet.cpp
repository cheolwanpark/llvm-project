// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVCostSheet.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/MathExtras.h"
#include <optional>
using namespace llvm;
namespace {
unsigned wholeGroup(const VPlanMIRInstruction &MI) {
  StringRef Op = MI.BaseOpcode;
  bool Move = Op.starts_with("VMV") && Op.size() > 3 &&
              Op[3] >= '1' && Op[3] <= '8';
  bool WholeLoad = Op.starts_with("VL") && Op.size() > 4 &&
                   Op[2] >= '1' && Op[2] <= '8' && Op.substr(3, 2) == "RE";
  bool WholeStore = Op.starts_with("VS") && Op.size() > 3 &&
                    Op[2] >= '1' && Op[2] <= '8' && Op[3] == 'R';
  if (Op == "COPY" || Move || WholeLoad || WholeStore)
    if (!MI.RegisterGroups8.empty())
      return MI.RegisterGroups8.front() / 8;
  return 0;
}
unsigned fields(StringRef Op) {
  auto P = Op.find("SEG");
  if (P == StringRef::npos || P + 3 >= Op.size())
    return 1;
  return unsigned(Op[P + 3] - '0');
}
// Exact ISA forms, classified independently of scheduler timing.
enum class Family {
  None,
  SIMD,
  Compress,
  Mask,
  IntegerIterative,
  FPIterative,
  ScalarTransfer,
  Wide,
  TreeReduction,
  OrderedReduction,
  Slide,
  WideOrderedReduction,
  WideTreeReduction,
  Iota,
  Gather16,
  UniformGather,
  Gather,
  Ext2,
  Ext4,
  Ext8
};
Family classify(StringRef Op) {
  return StringSwitch<Family>(Op)
      .Case("VAADDU_VV", Family::SIMD)
      .Case("VAADDU_VX", Family::SIMD)
      .Case("VAADD_VV", Family::SIMD)
      .Case("VAADD_VX", Family::SIMD)
      .Case("VADC_VIM", Family::SIMD)
      .Case("VADC_VVM", Family::SIMD)
      .Case("VADC_VXM", Family::SIMD)
      .Case("VADD_VI", Family::SIMD)
      .Case("VADD_VV", Family::SIMD)
      .Case("VADD_VX", Family::SIMD)
      .Case("VANDN_VV", Family::SIMD)
      .Case("VANDN_VX", Family::SIMD)
      .Case("VAND_VI", Family::SIMD)
      .Case("VAND_VV", Family::SIMD)
      .Case("VAND_VX", Family::SIMD)
      .Case("VASUBU_VV", Family::SIMD)
      .Case("VASUBU_VX", Family::SIMD)
      .Case("VASUB_VV", Family::SIMD)
      .Case("VASUB_VX", Family::SIMD)
      .Case("VBREV8_V", Family::SIMD)
      .Case("VBREV_V", Family::SIMD)
      .Case("VCLZ_V", Family::SIMD)
      .Case("VCPOP_V", Family::SIMD)
      .Case("VCTZ_V", Family::SIMD)
      .Case("VFADD_VF", Family::SIMD)
      .Case("VFADD_VV", Family::SIMD)
      .Case("VFCLASS_V", Family::SIMD)
      .Case("VFCVT_F_XU_V", Family::SIMD)
      .Case("VFCVT_F_X_V", Family::SIMD)
      .Case("VFCVT_RTZ_XU_F_V", Family::SIMD)
      .Case("VFCVT_RTZ_X_F_V", Family::SIMD)
      .Case("VFCVT_XU_F_V", Family::SIMD)
      .Case("VFCVT_X_F_V", Family::SIMD)
      .Case("VFMACC_VF", Family::SIMD)
      .Case("VFMACC_VV", Family::SIMD)
      .Case("VFMADD_VF", Family::SIMD)
      .Case("VFMADD_VV", Family::SIMD)
      .Case("VFMAX_VF", Family::SIMD)
      .Case("VFMAX_VV", Family::SIMD)
      .Case("VFMERGE_VFM", Family::SIMD)
      .Case("VFMIN_VF", Family::SIMD)
      .Case("VFMIN_VV", Family::SIMD)
      .Case("VFMSAC_VF", Family::SIMD)
      .Case("VFMSAC_VV", Family::SIMD)
      .Case("VFMSUB_VF", Family::SIMD)
      .Case("VFMSUB_VV", Family::SIMD)
      .Case("VFMUL_VF", Family::SIMD)
      .Case("VFMUL_VV", Family::SIMD)
      .Case("VFMV_V_F", Family::SIMD)
      .Case("VFNMACC_VF", Family::SIMD)
      .Case("VFNMACC_VV", Family::SIMD)
      .Case("VFNMADD_VF", Family::SIMD)
      .Case("VFNMADD_VV", Family::SIMD)
      .Case("VFNMSAC_VF", Family::SIMD)
      .Case("VFNMSAC_VV", Family::SIMD)
      .Case("VFNMSUB_VF", Family::SIMD)
      .Case("VFNMSUB_VV", Family::SIMD)
      .Case("VFREC7_V", Family::SIMD)
      .Case("VFRSQRT7_V", Family::SIMD)
      .Case("VFRSUB_VF", Family::SIMD)
      .Case("VFSGNJN_VF", Family::SIMD)
      .Case("VFSGNJN_VV", Family::SIMD)
      .Case("VFSGNJX_VF", Family::SIMD)
      .Case("VFSGNJX_VV", Family::SIMD)
      .Case("VFSGNJ_VF", Family::SIMD)
      .Case("VFSGNJ_VV", Family::SIMD)
      .Case("VFSUB_VF", Family::SIMD)
      .Case("VFSUB_VV", Family::SIMD)
      .Case("VID_V", Family::SIMD)
      .Case("VMACC_VV", Family::SIMD)
      .Case("VMACC_VX", Family::SIMD)
      .Case("VMADC_VI", Family::SIMD)
      .Case("VMADC_VIM", Family::SIMD)
      .Case("VMADC_VV", Family::SIMD)
      .Case("VMADC_VVM", Family::SIMD)
      .Case("VMADC_VX", Family::SIMD)
      .Case("VMADC_VXM", Family::SIMD)
      .Case("VMADD_VV", Family::SIMD)
      .Case("VMADD_VX", Family::SIMD)
      .Case("VMAXU_VV", Family::SIMD)
      .Case("VMAXU_VX", Family::SIMD)
      .Case("VMAX_VV", Family::SIMD)
      .Case("VMAX_VX", Family::SIMD)
      .Case("VMERGE_VIM", Family::SIMD)
      .Case("VMERGE_VVM", Family::SIMD)
      .Case("VMERGE_VXM", Family::SIMD)
      .Case("VMFEQ_VF", Family::SIMD)
      .Case("VMFEQ_VV", Family::SIMD)
      .Case("VMFGE_VF", Family::SIMD)
      .Case("VMFGT_VF", Family::SIMD)
      .Case("VMFLE_VF", Family::SIMD)
      .Case("VMFLE_VV", Family::SIMD)
      .Case("VMFLT_VF", Family::SIMD)
      .Case("VMFLT_VV", Family::SIMD)
      .Case("VMFNE_VF", Family::SIMD)
      .Case("VMFNE_VV", Family::SIMD)
      .Case("VMINU_VV", Family::SIMD)
      .Case("VMINU_VX", Family::SIMD)
      .Case("VMIN_VV", Family::SIMD)
      .Case("VMIN_VX", Family::SIMD)
      .Case("VMSBC_VV", Family::SIMD)
      .Case("VMSBC_VVM", Family::SIMD)
      .Case("VMSBC_VX", Family::SIMD)
      .Case("VMSBC_VXM", Family::SIMD)
      .Case("VMSEQ_VI", Family::SIMD)
      .Case("VMSEQ_VV", Family::SIMD)
      .Case("VMSEQ_VX", Family::SIMD)
      .Case("VMSGTU_VI", Family::SIMD)
      .Case("VMSGTU_VX", Family::SIMD)
      .Case("VMSGT_VI", Family::SIMD)
      .Case("VMSGT_VX", Family::SIMD)
      .Case("VMSLEU_VI", Family::SIMD)
      .Case("VMSLEU_VV", Family::SIMD)
      .Case("VMSLEU_VX", Family::SIMD)
      .Case("VMSLE_VI", Family::SIMD)
      .Case("VMSLE_VV", Family::SIMD)
      .Case("VMSLE_VX", Family::SIMD)
      .Case("VMSLTU_VV", Family::SIMD)
      .Case("VMSLTU_VX", Family::SIMD)
      .Case("VMSLT_VV", Family::SIMD)
      .Case("VMSLT_VX", Family::SIMD)
      .Case("VMSNE_VI", Family::SIMD)
      .Case("VMSNE_VV", Family::SIMD)
      .Case("VMSNE_VX", Family::SIMD)
      .Case("VMULHSU_VV", Family::SIMD)
      .Case("VMULHSU_VX", Family::SIMD)
      .Case("VMULHU_VV", Family::SIMD)
      .Case("VMULHU_VX", Family::SIMD)
      .Case("VMULH_VV", Family::SIMD)
      .Case("VMULH_VX", Family::SIMD)
      .Case("VMUL_VV", Family::SIMD)
      .Case("VMUL_VX", Family::SIMD)
      .Case("VMV1R_V", Family::SIMD)
      .Case("VMV2R_V", Family::SIMD)
      .Case("VMV4R_V", Family::SIMD)
      .Case("VMV8R_V", Family::SIMD)
      .Case("VMV_V_I", Family::SIMD)
      .Case("VMV_V_V", Family::SIMD)
      .Case("VMV_V_X", Family::SIMD)
      .Case("VNMSAC_VV", Family::SIMD)
      .Case("VNMSAC_VX", Family::SIMD)
      .Case("VNMSUB_VV", Family::SIMD)
      .Case("VNMSUB_VX", Family::SIMD)
      .Case("VOR_VI", Family::SIMD)
      .Case("VOR_VV", Family::SIMD)
      .Case("VOR_VX", Family::SIMD)
      .Case("VREV8_V", Family::SIMD)
      .Case("VROL_VV", Family::SIMD)
      .Case("VROL_VX", Family::SIMD)
      .Case("VROR_VI", Family::SIMD)
      .Case("VROR_VV", Family::SIMD)
      .Case("VROR_VX", Family::SIMD)
      .Case("VRSUB_VI", Family::SIMD)
      .Case("VRSUB_VX", Family::SIMD)
      .Case("VSADDU_VI", Family::SIMD)
      .Case("VSADDU_VV", Family::SIMD)
      .Case("VSADDU_VX", Family::SIMD)
      .Case("VSADD_VI", Family::SIMD)
      .Case("VSADD_VV", Family::SIMD)
      .Case("VSADD_VX", Family::SIMD)
      .Case("VSBC_VVM", Family::SIMD)
      .Case("VSBC_VXM", Family::SIMD)
      .Case("VSLL_VI", Family::SIMD)
      .Case("VSLL_VV", Family::SIMD)
      .Case("VSLL_VX", Family::SIMD)
      .Case("VSMUL_VV", Family::SIMD)
      .Case("VSMUL_VX", Family::SIMD)
      .Case("VSRA_VI", Family::SIMD)
      .Case("VSRA_VV", Family::SIMD)
      .Case("VSRA_VX", Family::SIMD)
      .Case("VSRL_VI", Family::SIMD)
      .Case("VSRL_VV", Family::SIMD)
      .Case("VSRL_VX", Family::SIMD)
      .Case("VSSRA_VI", Family::SIMD)
      .Case("VSSRA_VV", Family::SIMD)
      .Case("VSSRA_VX", Family::SIMD)
      .Case("VSSRL_VI", Family::SIMD)
      .Case("VSSRL_VV", Family::SIMD)
      .Case("VSSRL_VX", Family::SIMD)
      .Case("VSSUBU_VV", Family::SIMD)
      .Case("VSSUBU_VX", Family::SIMD)
      .Case("VSSUB_VV", Family::SIMD)
      .Case("VSSUB_VX", Family::SIMD)
      .Case("VSUB_VV", Family::SIMD)
      .Case("VSUB_VX", Family::SIMD)
      .Case("VXOR_VI", Family::SIMD)
      .Case("VXOR_VV", Family::SIMD)
      .Case("VXOR_VX", Family::SIMD)
      .Case("VCOMPRESS_VM", Family::Compress)
      .Case("VCPOP_M", Family::Mask)
      .Case("VFIRST_M", Family::Mask)
      .Case("VMANDN_MM", Family::Mask)
      .Case("VMAND_MM", Family::Mask)
      .Case("VMNAND_MM", Family::Mask)
      .Case("VMNOR_MM", Family::Mask)
      .Case("VMORN_MM", Family::Mask)
      .Case("VMOR_MM", Family::Mask)
      .Case("VMSBF_M", Family::Mask)
      .Case("VMSIF_M", Family::Mask)
      .Case("VMSOF_M", Family::Mask)
      .Case("VMXNOR_MM", Family::Mask)
      .Case("VMXOR_MM", Family::Mask)
      .Case("VDIVU_VV", Family::IntegerIterative)
      .Case("VDIVU_VX", Family::IntegerIterative)
      .Case("VDIV_VV", Family::IntegerIterative)
      .Case("VDIV_VX", Family::IntegerIterative)
      .Case("VREMU_VV", Family::IntegerIterative)
      .Case("VREMU_VX", Family::IntegerIterative)
      .Case("VREM_VV", Family::IntegerIterative)
      .Case("VREM_VX", Family::IntegerIterative)
      .Case("VFDIV_VF", Family::FPIterative)
      .Case("VFDIV_VV", Family::FPIterative)
      .Case("VFRDIV_VF", Family::FPIterative)
      .Case("VFSQRT_V", Family::FPIterative)
      .Case("VFMV_F_S", Family::ScalarTransfer)
      .Case("VFMV_S_F", Family::ScalarTransfer)
      .Case("VMV_S_X", Family::ScalarTransfer)
      .Case("VMV_X_S", Family::ScalarTransfer)
      .Case("VFNCVT_F_F_W", Family::Wide)
      .Case("VFNCVT_F_XU_W", Family::Wide)
      .Case("VFNCVT_F_X_W", Family::Wide)
      .Case("VFNCVT_ROD_F_F_W", Family::Wide)
      .Case("VFNCVT_RTZ_XU_F_W", Family::Wide)
      .Case("VFNCVT_RTZ_X_F_W", Family::Wide)
      .Case("VFNCVT_XU_F_W", Family::Wide)
      .Case("VFNCVT_X_F_W", Family::Wide)
      .Case("VFWADD_VF", Family::Wide)
      .Case("VFWADD_VV", Family::Wide)
      .Case("VFWADD_WF", Family::Wide)
      .Case("VFWADD_WV", Family::Wide)
      .Case("VFWCVT_F_F_V", Family::Wide)
      .Case("VFWCVT_F_XU_V", Family::Wide)
      .Case("VFWCVT_F_X_V", Family::Wide)
      .Case("VFWCVT_RTZ_XU_F_V", Family::Wide)
      .Case("VFWCVT_RTZ_X_F_V", Family::Wide)
      .Case("VFWCVT_XU_F_V", Family::Wide)
      .Case("VFWCVT_X_F_V", Family::Wide)
      .Case("VFWMACC_VF", Family::Wide)
      .Case("VFWMACC_VV", Family::Wide)
      .Case("VFWMSAC_VF", Family::Wide)
      .Case("VFWMSAC_VV", Family::Wide)
      .Case("VFWMUL_VF", Family::Wide)
      .Case("VFWMUL_VV", Family::Wide)
      .Case("VFWNMACC_VF", Family::Wide)
      .Case("VFWNMACC_VV", Family::Wide)
      .Case("VFWNMSAC_VF", Family::Wide)
      .Case("VFWNMSAC_VV", Family::Wide)
      .Case("VFWSUB_VF", Family::Wide)
      .Case("VFWSUB_VV", Family::Wide)
      .Case("VFWSUB_WF", Family::Wide)
      .Case("VFWSUB_WV", Family::Wide)
      .Case("VNCLIPU_WI", Family::Wide)
      .Case("VNCLIPU_WV", Family::Wide)
      .Case("VNCLIPU_WX", Family::Wide)
      .Case("VNCLIP_WI", Family::Wide)
      .Case("VNCLIP_WV", Family::Wide)
      .Case("VNCLIP_WX", Family::Wide)
      .Case("VNSRA_WI", Family::Wide)
      .Case("VNSRA_WV", Family::Wide)
      .Case("VNSRA_WX", Family::Wide)
      .Case("VNSRL_WI", Family::Wide)
      .Case("VNSRL_WV", Family::Wide)
      .Case("VNSRL_WX", Family::Wide)
      .Case("VWADDU_VV", Family::Wide)
      .Case("VWADDU_VX", Family::Wide)
      .Case("VWADDU_WV", Family::Wide)
      .Case("VWADDU_WX", Family::Wide)
      .Case("VWADD_VV", Family::Wide)
      .Case("VWADD_VX", Family::Wide)
      .Case("VWADD_WV", Family::Wide)
      .Case("VWADD_WX", Family::Wide)
      .Case("VWMACCSU_VV", Family::Wide)
      .Case("VWMACCSU_VX", Family::Wide)
      .Case("VWMACCUS_VX", Family::Wide)
      .Case("VWMACCU_VV", Family::Wide)
      .Case("VWMACCU_VX", Family::Wide)
      .Case("VWMACC_VV", Family::Wide)
      .Case("VWMACC_VX", Family::Wide)
      .Case("VWMULSU_VV", Family::Wide)
      .Case("VWMULSU_VX", Family::Wide)
      .Case("VWMULU_VV", Family::Wide)
      .Case("VWMULU_VX", Family::Wide)
      .Case("VWMUL_VV", Family::Wide)
      .Case("VWMUL_VX", Family::Wide)
      .Case("VWSLL_VI", Family::Wide)
      .Case("VWSLL_VV", Family::Wide)
      .Case("VWSLL_VX", Family::Wide)
      .Case("VWSUBU_VV", Family::Wide)
      .Case("VWSUBU_VX", Family::Wide)
      .Case("VWSUBU_WV", Family::Wide)
      .Case("VWSUBU_WX", Family::Wide)
      .Case("VWSUB_VV", Family::Wide)
      .Case("VWSUB_VX", Family::Wide)
      .Case("VWSUB_WV", Family::Wide)
      .Case("VWSUB_WX", Family::Wide)
      .Case("VFREDMAX_VS", Family::TreeReduction)
      .Case("VFREDMIN_VS", Family::TreeReduction)
      .Case("VFREDUSUM_VS", Family::TreeReduction)
      .Case("VREDAND_VS", Family::TreeReduction)
      .Case("VREDMAXU_VS", Family::TreeReduction)
      .Case("VREDMAX_VS", Family::TreeReduction)
      .Case("VREDMINU_VS", Family::TreeReduction)
      .Case("VREDMIN_VS", Family::TreeReduction)
      .Case("VREDOR_VS", Family::TreeReduction)
      .Case("VREDSUM_VS", Family::TreeReduction)
      .Case("VREDXOR_VS", Family::TreeReduction)
      .Case("VFREDOSUM_VS", Family::OrderedReduction)
      .Case("VFSLIDE1DOWN_VF", Family::Slide)
      .Case("VFSLIDE1UP_VF", Family::Slide)
      .Case("VSLIDE1DOWN_VX", Family::Slide)
      .Case("VSLIDE1UP_VX", Family::Slide)
      .Case("VSLIDEDOWN_VI", Family::Slide)
      .Case("VSLIDEDOWN_VX", Family::Slide)
      .Case("VSLIDEUP_VI", Family::Slide)
      .Case("VSLIDEUP_VX", Family::Slide)
      .Case("VFWREDOSUM_VS", Family::WideOrderedReduction)
      .Case("VFWREDUSUM_VS", Family::WideTreeReduction)
      .Case("VWREDSUMU_VS", Family::WideTreeReduction)
      .Case("VWREDSUM_VS", Family::WideTreeReduction)
      .Case("VIOTA_M", Family::Iota)
      .Case("VRGATHEREI16_VV", Family::Gather16)
      .Case("VRGATHER_VI", Family::UniformGather)
      .Case("VRGATHER_VX", Family::UniformGather)
      .Case("VRGATHER_VV", Family::Gather)
      .Case("VSEXT_VF2", Family::Ext2)
      .Case("VZEXT_VF2", Family::Ext2)
      .Case("VSEXT_VF4", Family::Ext4)
      .Case("VZEXT_VF4", Family::Ext4)
      .Case("VSEXT_VF8", Family::Ext8)
      .Case("VZEXT_VF8", Family::Ext8)
      .Default(Family::None);
}
uint64_t blocks(uint64_t Bits) {
  return std::max(uint64_t(1), divideCeil(Bits, uint64_t(128)));
}
unsigned fpSteps(unsigned Width) {
  return (Width == 16 ? 11 : Width == 32 ? 24 : 53) + 4;
}
} // namespace

Expected<MIRInstructionCost>
SpacemitK1CostSheet::getInstructionCost(const VPlanMIRInstruction &MI) const {
  // Reuse only support and geometry validation, never generic prices.
  auto Valid = RISCVCostSheet::getInstructionCost(MI);
  if (!Valid)
    return Valid.takeError();
  if (Valid->Unknown)
    return Valid;
  StringRef Op = MI.BaseOpcode;
  uint64_t Cost = 1;
  StringRef Rule = "scalar";
  if (!MI.Vector || MI.Configuration) {
    if (Op.starts_with("DIV") || Op.starts_with("REM")) {
      Cost = (Op.ends_with("W") ? 32 : 64) + 2;
      Rule = "integer-iterative";
    } else if (Op.starts_with("FDIV") || Op.starts_with("FSQRT")) {
      Cost = fpSteps(Op.ends_with("_H") ? 16 : Op.ends_with("_S") ? 32 : 64);
      Rule = "fp-iterative";
    }
  } else if (unsigned G = wholeGroup(MI)) {
    Cost = blocks(256 * G);
    Rule = "whole-register";
  } else {
    uint64_t Bits = uint64_t(32) * MI.LMUL8;
    unsigned W = MI.SEW;
    if (MI.Load || MI.Store) {
      unsigned F = fields(Op), EEW = 0;
      bool Indexed = Op.contains("XEI");
      bool Strided =
          (F == 1 && (Op.starts_with("VLSE") || Op.starts_with("VSSE"))) ||
          Op.starts_with("VLSSEG") || Op.starts_with("VSSSEG");
      StringRef Tail = Op.drop_until([](char C) { return C >= '0' && C <= '9'; });
      if (F > 1)
        Tail = Tail.drop_front().drop_until(
            [](char C) { return C >= '0' && C <= '9'; });
      Tail = Tail.take_while([](char C) { return C >= '0' && C <= '9'; });
      (void)Tail.getAsInteger(10, EEW);
      uint64_t N = Bits / (Indexed ? W : EEW);
      Cost = Indexed   ? blocks(N * MI.IndexEEW) + N
             : Strided ? N * F
                       : blocks(Bits * F) * (F > 1 ? 2 : 1);
      Rule = Indexed   ? "indexed"
             : Strided ? "strided"
             : F > 1   ? "segment"
                       : "contiguous";
    } else {
      uint64_t N = Bits / W;
      Family F = classify(Op);
      Cost = blocks(Bits);
      Rule = "simd";
      switch (F) {
      case Family::None:
        return createStringError("missing K1 structural opcode rule");
      case Family::SIMD:
        break;
      case Family::Wide:
        if (W >= 64)
          return createStringError("unsupported K1 wide precision");
        Cost = blocks(2 * Bits);
        Rule = "wide";
        break;
      case Family::Ext2:
      case Family::Ext4:
      case Family::Ext8: {
        unsigned Factor = F == Family::Ext2 ? 2 : F == Family::Ext4 ? 4 : 8;
        if (W / Factor < 8 || MI.LMUL8 < Factor)
          return createStringError("invalid K1 extension source geometry");
        Rule = "extension";
        break;
      }
      case Family::ScalarTransfer:
        Cost = 1;
        Rule = "scalar-transfer";
        break;
      case Family::Mask:
        Cost = blocks(256);
        Rule = "mask";
        break;
      case Family::Slide:
        Rule = "slide";
        break;
      case Family::UniformGather:
        Cost += 1;
        Rule = "uniform-gather";
        break;
      case Family::Gather:
      case Family::Gather16: {
        unsigned I = F == Family::Gather16 ? 16 : W;
        unsigned IndexG = MI.LMUL8 * I;
        if (IndexG % W || IndexG / W < 1 || IndexG / W > 64)
          return createStringError("invalid K1 gather index geometry");
        Cost *= blocks(N * std::max(W, I));
        Rule = "gather";
        break;
      }
      case Family::Compress:
        Cost = 2 * N;
        Rule = "compress";
        break;
      case Family::Iota:
        Cost = 2 * N;
        Rule = "iota";
        break;
      case Family::IntegerIterative:
        Cost *= W + 2;
        Rule = "integer-iterative";
        break;
      case Family::FPIterative:
        Cost *= fpSteps(W);
        Rule = "fp-iterative";
        break;
      case Family::WideTreeReduction:
      case Family::WideOrderedReduction:
        if (W >= 64)
          return createStringError(
              "unsupported K1 widening reduction precision");
        W *= 2;
        [[fallthrough]];
      case Family::TreeReduction:
      case Family::OrderedReduction: {
        bool Ordered =
            F == Family::OrderedReduction || F == Family::WideOrderedReduction;
        bool Wide =
            F == Family::WideTreeReduction || F == Family::WideOrderedReduction;
        Cost = Ordered ? N : 1; // Includes the seed, even for N=1.
        if (!Ordered)
          for (uint64_t Active = N / 2; Active; Active /= 2)
            Cost += blocks(Active * W);
        Rule = Ordered ? (Wide ? "wide-ordered-reduction" : "ordered-reduction")
                       : (Wide ? "wide-tree-reduction" : "tree-reduction");
        break;
      }
      }
    }
  }
  return MIRInstructionCost{("k1:assumed-structural-" + Rule).str(), false,
                            int64_t(Cost), 1};
}
InstructionCost SpacemitK1CostSheet::spillCost(
    bool Vector, bool IsLoad, TargetTransformInfo::SpillReloadUnits U) const {
  if (!U.isValid())
    return InstructionCost::getInvalid();
  if (!U.Accesses)
    return 0;
  if (!Vector) {
    if (U.Registers > uint64_t(INT64_MAX / 4))
      return InstructionCost::getInvalid();
    return int64_t(U.Registers);
  }
  if (U.Registers % U.Accesses)
    return InstructionCost::getInvalid();
  uint64_t G = U.Registers / U.Accesses;
  if (!isPowerOf2_64(G) || G > 8)
    return InstructionCost::getInvalid();
  uint64_t Unit = 2 * G;
  if (U.Accesses > uint64_t(INT64_MAX / 4) / Unit)
    return InstructionCost::getInvalid();
  return int64_t(U.Accesses * Unit);
}
