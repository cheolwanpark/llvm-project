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

TEST(TargetCostSheets, SaturnAndK1Prices) {
  SaturnCostSheet Saturn;
  SpacemitK1CostSheet K1;
  auto Check = [&](const RISCVCostSheet &Sheet, VPlanMIRInstruction Q,
                   int64_t Expected) {
    auto C = Sheet.getInstructionCost(Q);
    ASSERT_TRUE(bool(C)) << (C ? "" : toString(C.takeError()));
    EXPECT_EQ(C->Numerator, Expected) << Q.BaseOpcode;
    EXPECT_EQ(C->Denominator, 1);
    EXPECT_FALSE(C->Unknown);
  };
  Check(Saturn, op("VADD_VV", 16, 32), 2);
  Check(K1, op("VADD_VV", 16, 32), 4);
  Check(Saturn, op("VFMACC_VV", 8, 32), 1);
  Check(K1, op("VFMACC_VV", 8, 32), 2);
  // Integer extension prefixes deliberately use the ordinary SIMD service.
  Check(Saturn, op("VSEXT_VF2", 8, 32), 1);
  Check(K1, op("VZEXT_VF2", 16, 32), 4);
  Check(Saturn, op("VDIV_VV", 8, 32), 4);
  auto Load = op("VLE32_V", 8, 32);
  Load.Load = true;
  Check(Saturn, Load, 1);
  Check(K1, Load, 2);
  Load.BaseOpcode = "VLSE32_V";
  Check(Saturn, Load, 8);
  Check(K1, Load, 8);
  // The native-relative MIR sheet uses the element/field estimate for both
  // segment forms, and memory EEW can differ from the current SEW.
  for (StringRef Opcode : {"VLSEG3E64_V", "VSSEG3E64_V", "VLSSEG3E64_V",
                           "VSSSEG3E64_V", "VLSEG3E32_V", "VSSEG3E32_V",
                           "VLSSEG3E32_V", "VSSSEG3E32_V"}) {
    auto Segment = op(Opcode, 16, 64);
    Segment.Load = Opcode.starts_with("VL");
    Segment.Store = !Segment.Load;
    Check(Saturn, Segment, Opcode.contains("E32") ? 48 : 24);
  }
  for (unsigned G : {1u, 2u, 4u, 8u}) {
    auto Whole = op("VL" + std::to_string(G) + "RE8_V", G * 8);
    Whole.Load = Whole.Spill = true;
    Whole.RegisterGroups8 = {G * 8};
    Check(Saturn, Whole, G);
    Check(K1, Whole, 2 * G);
    EXPECT_EQ(Saturn.spillCost(true, true, {G, 1}), G);
    EXPECT_EQ(K1.spillCost(true, true, {G, 1}), 2 * G);
  }
  EXPECT_EQ(K1.spillCost(true, false, {2, 2}) +
                K1.spillCost(true, false, {4, 1}),
            12);
  EXPECT_EQ(K1.spillCost(true, false, {6, 3}), 12);
  EXPECT_FALSE(K1.spillCost(true, false, {5, 2}).isValid());
  // Scalar pricing counts transferred registers, independently of accesses.
  EXPECT_EQ(K1.spillCost(false, true, {4, 1}), 4);
  EXPECT_EQ(K1.spillCost(false, false, {4, 1}), 4);
  EXPECT_FALSE(K1.spillCost(false, false, {uint64_t(INT64_MAX), 1}).isValid());
  auto Invalid = Saturn.getInstructionCost(op("VADD_VV", 3, 32));
  EXPECT_FALSE(bool(Invalid));
  if (!Invalid)
    consumeError(Invalid.takeError());
  SaturnMIRInfo SM;
  SpacemitK1MIRInfo KM;
  EXPECT_EQ(SM.getModelName(), Saturn.getModelName());
  EXPECT_EQ(KM.getModelName(), K1.getModelName());
  auto SC = SM.getInstructionCost(op("VADD_VV", 16, 32));
  ASSERT_TRUE(bool(SC));
  EXPECT_EQ(SC->Numerator, 2);
}

TEST(SaturnCostSheet, NativeRelativeFamiliesAndSpills) {
  SaturnCostSheet Sheet;
  auto Check = [&](VPlanMIRInstruction Q, int64_t Expected) {
    auto C = Sheet.getInstructionCost(Q);
    ASSERT_TRUE(bool(C)) << (C ? "" : toString(C.takeError()));
    EXPECT_FALSE(C->Unknown);
    EXPECT_EQ(C->Numerator, Expected) << Q.BaseOpcode;
    EXPECT_EQ(C->Denominator, 1);
  };
  for (unsigned G : {1u, 2u, 4u, 8u, 16u, 32u}) {
    unsigned L = std::max(1u, G / 8);
    for (StringRef Opcode : {"VFMACC_VV", "VFMACC_VF", "VFNMSUB_VV",
                             "VFWMACC_VV"})
      Check(op(Opcode, G, 32), L);
    Check(op("VFADD_VV", G, 32), 2 * L);
    Check(op("VFDIV_VV", G, 32), 2 * L);
    Check(op("VDIV_VV", G, 32), 4 * L);
  }
  Check(op("VREDSUM_VS", 8, 32), 3);
  Check(op("VFREDUSUM_VS", 8, 32), 3);
  Check(op("VFREDOSUM_VS", 8, 32), 8);
  Check(op("FADD_D"), 2);
  Check(op("FSQRT_D"), 2);
  Check(op("DIV"), 4);
  for (bool Vector : {false, true})
    for (bool Load : {false, true}) {
      EXPECT_EQ(Sheet.spillCost(Vector, Load, {4, 1}), 4);
      EXPECT_EQ(Sheet.spillCost(Vector, Load, {4, 4}), 4);
      EXPECT_FALSE(Sheet.spillCost(Vector, Load, {4, 0}).isValid());
    }
  auto Unknown = Sheet.getInstructionCost(op("UNSUPPORTED", 8, 32));
  ASSERT_TRUE(bool(Unknown));
  EXPECT_TRUE(Unknown->Unknown);
  EXPECT_EQ(Unknown->Numerator, 1);
}

TEST(SpacemitK1CostSheet, StructuralWorkAndGeometry) {
  SpacemitK1CostSheet Sheet;
  auto Check = [&](VPlanMIRInstruction Q, int64_t Expected) {
    auto C = Sheet.getInstructionCost(Q);
    ASSERT_TRUE(bool(C)) << (C ? "" : toString(C.takeError()));
    EXPECT_FALSE(C->Unknown);
    EXPECT_EQ(C->Numerator, Expected) << Q.BaseOpcode;
    EXPECT_EQ(C->Denominator, 1);
    EXPECT_NE(C->Rule.find("assumed-structural-"), std::string::npos);
  };
  unsigned G = 1;
  for (unsigned Expected : {1, 1, 1, 2, 4, 8, 16}) {
    for (StringRef Name : {"VADD_VV", "VMUL_VX", "VSLIDEUP_VI"})
      Check(op(Name, G, 8), Expected);
    G *= 2;
  }
  Check(op("DIVW"), 34);
  Check(op("DIV"), 66);
  Check(op("REMU"), 66);
  Check(op("FDIV_H"), 15);
  Check(op("FSQRT_S"), 28);
  Check(op("FSQRT_D"), 57);
  Check(op("VDIV_VV", 8, 64), 132);
  Check(op("VREMU_VX", 1, 8), 10);
  EXPECT_EQ(Sheet.spillCost(true, true, {0, 0}), 0);
  EXPECT_FALSE(
      Sheet.spillCost(true, false, {uint64_t(INT64_MAX), uint64_t(INT64_MAX)})
          .isValid());
  Check(op("VWADD_VV", 1, 8), 1);
  Check(op("VWADD_VV", 4, 8), 2);
  Check(op("VFREDOSUM_VS", 8, 32), 8);
  Check(op("VFREDUSUM_VS", 8, 32), 4);
  Check(op("VFWREDUSUM_VS", 8, 32), 5);
  Check(op("VREDSUM_VS", 1, 32), 1);
  Check(op("VRGATHER_VX", 8, 32), 3);
  Check(op("VRGATHER_VV", 8, 32), 4);
  Check(op("VRGATHEREI16_VV", 8, 8), 8);
  Check(op("VCOMPRESS_VM", 8, 32), 16);
  Check(op("VIOTA_M", 8, 32), 16);
  Check(op("VMAND_MM", 8, 1), 2);
  Check(op("VMV_X_S", 64, 32), 1);
  auto Q = op("VLSEG3E64_V", 16, 64);
  Q.Load = true;
  Check(Q, 24);
  Q.BaseOpcode = "VLSSEG3E64_V";
  Check(Q, 24);
  Q.BaseOpcode = "VLSEG3E32_V";
  Check(Q, 24);
  Q.BaseOpcode = "VLSSEG3E32_V";
  Check(Q, 48);
  Q = op("VLOXEI16_V", 8, 32);
  Q.Load = true;
  Q.IndexEEW = 16;
  Q.IndexEMUL8 = 4;
  Check(Q, 9);
  Q.BaseOpcode = "VLUXEI16_V";
  Check(Q, 9);
  Q = op("VADD_VV", 8, 32);
  Q.Opcode = "PseudoVADD_VV_M1_MASK";
  Check(Q, 2);
  for (auto Bad : {op("VRGATHEREI16_VV", 64, 8), op("VRGATHEREI16_VV", 1, 64),
                   op("VZEXT_VF8", 8, 32), op("VWADD_VV", 8, 64)}) {
    auto C = Sheet.getInstructionCost(Bad);
    EXPECT_FALSE(bool(C));
    if (!C)
      consumeError(C.takeError());
  }
  EXPECT_EQ(Sheet.getRevision(), "k1-structural-service-v1");
}

TEST(SpacemitK1CostSheet, ExplicitIterativeFormsAndUnknownOpcodes) {
  SpacemitK1CostSheet Sheet;
  for (unsigned G : {1u, 2u, 4u, 8u, 16u, 32u, 64u})
    for (unsigned SEW : {16u, 32u, 64u})
      for (StringRef Name : {"VFDIV_VF", "VFRDIV_VF", "VFDIV_VV", "VFSQRT_V"}) {
        if (32 * G < SEW)
          continue;
        auto Cost = Sheet.getInstructionCost(op(Name, G, SEW));
        ASSERT_TRUE(bool(Cost));
        unsigned Unit = SEW == 16 ? 15 : SEW == 32 ? 28 : 57;
        EXPECT_EQ(Cost->Numerator, Unit * std::max(1u, G / 4));
        EXPECT_FALSE(Cost->Unknown);
      }
  for (StringRef Name : {"VSLIDE_UNREVIEWED", "VFRED_UNKNOWN", "VFDIV_UNKNOWN"}) {
    auto Cost = Sheet.getInstructionCost(op(Name, 8, 32));
    ASSERT_TRUE(bool(Cost));
    EXPECT_TRUE(Cost->Unknown);
    EXPECT_EQ(Cost->Numerator, 1);
  }
  auto Invalid = Sheet.getInstructionCost(op("VFWREDOSUM_VS", 8, 64));
  EXPECT_FALSE(bool(Invalid));
  if (!Invalid)
    consumeError(Invalid.takeError());
}
