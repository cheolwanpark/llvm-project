// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "RISCVCostSheet.h"
#include "gtest/gtest.h"
using namespace llvm;
namespace {
// Direct instruction prices for the fixed Kunminghu profile.
VPlanMIRInstruction op(StringRef Name, unsigned Group = 0, unsigned SEW = 0) {
  VPlanMIRInstruction I;
  I.Opcode = I.BaseOpcode = Name.str();
  I.Vector = Group != 0;
  I.LMUL8 = Group;
  I.SEW = SEW;
  return I;
}
void expectCost(const VPlanMIRInstruction &I, unsigned Cost,
                bool Unknown = false) {
  auto C = XiangShanCostSheet().getInstructionCost(I);
  ASSERT_TRUE(bool(C)) << (C ? "" : toString(C.takeError()));
  EXPECT_EQ(C->Denominator, 1);
  EXPECT_EQ(C->Numerator, Cost) << I.BaseOpcode;
  EXPECT_EQ(C->Unknown, Unknown);
}
void expectInvalid(const VPlanMIRInstruction &I) {
  auto C = XiangShanCostSheet().getInstructionCost(I);
  EXPECT_FALSE(bool(C));
  if (!C)
    consumeError(C.takeError());
}
} // namespace
TEST(XiangShanCostSheet, ScalarAndConfiguration) {
  expectCost(op("ADD"), 1);
  auto Store = op("SD");
  Store.Store = true;
  expectCost(Store, 2);
  expectCost(op("DIVW"), 15);
  expectCost(op("DIV"), 23);
  expectCost(op("FDIV_S"), 9);
  expectCost(op("FSQRT_D"), 16);
  auto Config = op("PseudoVSETVLI");
  Config.Configuration = Config.Pseudo = true;
  expectCost(Config, 1);
  auto Copy = op("COPY");
  Copy.Pseudo = true;
  expectCost(Copy, 1, true);
  expectCost(op("UNREVIEWED"), 1, true);
}
TEST(XiangShanCostSheet, ArithmeticGeometry) {
  expectCost(op("VADD_VV", 32, 32), 4);
  expectCost(op("VADD_VX", 32, 32), 5);
  expectCost(op("VFADD_VF", 4, 32), 2);
  expectCost(op("VSLIDEUP_VX", 32, 32), 11);
  expectCost(op("VSLIDEDOWN_VX", 64, 32), 37);
  expectCost(op("VRGATHER_VV", 32, 32), 16);
  expectCost(op("VRGATHEREI16_VV", 16, 8), 8);
  expectCost(op("VCOMPRESS_VM", 32, 32), 13);
  expectCost(op("VFDIV_VV", 16, 32), 20);
  expectCost(op("VDIV_VV", 16, 8), 22);
  expectCost(op("VFSQRT_V", 16, 64), 34);
  expectCost(op("VFREDUSUM_VS", 4, 32), 2);
  expectCost(op("VFREDOSUM_VS", 16, 32), 8);
  expectCost(op("VWADD_VV", 16, 32), 4);
  expectCost(op("VMAND_MM", 8, 1), 1);
  expectInvalid(op("VFDIV_VF", 8, 8));
  expectInvalid(op("VWADD_VV", 64, 32));
  expectInvalid(op("VADD_VV", 3, 32));
  expectInvalid(op("VADD_VV", 1, 64));
  auto Missing = op("VADD_VV");
  Missing.Vector = true;
  expectInvalid(Missing);
}
TEST(XiangShanCostSheet, MemoryAndWholeRegisters) {
  auto Load = op("VLE32_V", 16, 32);
  Load.Load = true;
  expectCost(Load, 3);
  Load.BaseOpcode = "VLSE32_V";
  expectCost(Load, 10);
  Load.BaseOpcode = "VLSEG2E32_V";
  expectCost(Load, 129);
  auto Store = Load;
  Store.BaseOpcode = "VSSEG2E32_V";
  Store.Load = false;
  Store.Store = true;
  expectCost(Store, 65);
  Load.BaseOpcode = "VLOXEI16_V";
  Load.IndexEMUL8 = 8;
  Load.IndexEEW = 16;
  expectCost(Load, 33);
  Load.BaseOpcode = "VLUXEI16_V";
  expectCost(Load, 9);
  Load.IndexEMUL8 = 16;
  expectInvalid(Load);
  for (unsigned G : {1u, 2u, 4u, 8u}) {
    auto Whole = op("VL" + std::to_string(G) + "RE8_V", G * 8, 0);
    Whole.Load = Whole.Spill = true;
    Whole.RegisterGroups8 = {G * 8};
    expectCost(Whole, G + 1);
    Whole.BaseOpcode = "VS" + std::to_string(G) + "R_V";
    Whole.Load = false;
    Whole.Store = true;
    expectCost(Whole, G + 1);
    Whole.BaseOpcode = "COPY";
    Whole.Store = false;
    expectCost(Whole, G);
    Whole.RegisterGroups8.push_back(G == 1 ? 16 : 8);
    expectInvalid(Whole);
  }
}

TEST(RISCVCostSheet, GenericPricesAndGeometry) {
  RISCVCostSheet Sheet(256);
  auto Check = [&](VPlanMIRInstruction Q, int64_t Expected) {
    auto C = Sheet.getInstructionCost(Q);
    ASSERT_TRUE(bool(C)) << (C ? "" : toString(C.takeError()));
    EXPECT_EQ(C->Numerator, Expected);
    EXPECT_EQ(C->Denominator, 1);
  };
  Check(op("ADD"), 1);
  Check(op("DIV"), 4);
  Check(op("FDIV_D"), 2);
  Check(op("VADD_VV", 32, 32), 4);
  Check(op("VFDIV_VF", 32, 32), 8);
  Check(op("VDIVU_VV", 16, 32), 8);
  Check(op("VREDMAX_VS", 16, 32), 4);
  Check(op("VFREDOSUM_VS", 16, 32), 16);
  Check(op("VRGATHER_VV", 32, 32), 16);
  auto Load = op("VLSE32_V", 16, 32);
  Load.Load = true;
  Check(Load, 16);
  Load.BaseOpcode = "VLSEG2E32_V";
  Check(Load, 32);
  Load.BaseOpcode = "VLE32_V";
  Check(Load, 2);
  // Fractional LMUL valid for VLEN=256, even though invalid at VLEN=128.
  Check(op("VADD_VV", 1, 32), 1);
}
