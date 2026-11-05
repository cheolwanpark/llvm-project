// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "llvm/IR/RelatedBlock.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Module.h"
#include "gtest/gtest.h"
using namespace llvm;
TEST(RelatedBlock, ScopedAncestryAndFunctionIsolation) {
  LLVMContext C;
  Module M("tracking", C);
  auto MakeFunction = [&]() {
    return Function::Create(FunctionType::get(Type::getVoidTy(C), false),
                            GlobalValue::ExternalLinkage, "f", M);
  };
  Function *F = MakeFunction(), *Other = MakeFunction();
  auto *Body = BasicBlock::Create(C, "body", F);
  auto *Outside = BasicBlock::Create(C, "outside", F);
  auto *Untracked = BasicBlock::Create(C, "other", Other);
  IRBuilder<> B(Body);
  auto *I = B.CreateAlloca(B.getInt32Ty());
  B.CreateRetVoid();
  EXPECT_EQ(Body->getRelatedBlock().State, RelatedBlockState::Disabled);
  {
    ScopedRelatedBlockTracking Scope(*F);
    auto *T = RelatedBlockTracking::get(F);
    T->seed({Body}, "candidate", "main", 4, false);
    EXPECT_EQ(Untracked->getRelatedBlock().State, RelatedBlockState::Disabled);
    EXPECT_TRUE(T->Region.intersects(Body->getRelatedBlock()));
    EXPECT_FALSE(T->Region.intersects(Outside->getRelatedBlock()));
    {
      ScopedRelatedBlockTracking OtherScope(*Other);
      RelatedBlockTracking::get(Other)->seed({Untracked}, "other", "main", 1, false);
      mergeRelatedBlocks(*Outside, *Untracked);
      EXPECT_FALSE(T->Region.intersects(Outside->getRelatedBlock()));
      EXPECT_EQ(Outside->getRelatedBlock().State, RelatedBlockState::Incomplete);
    }
    auto *Split = Body->splitBasicBlock(I->getIterator());
    EXPECT_TRUE(T->Region.intersects(Split->getRelatedBlock()));
    auto *Copy = I->clone();
    Copy->insertInto(Outside, Outside->end());
    EXPECT_TRUE(T->Region.intersects(Outside->getRelatedBlock()));
    I->removeFromParent();
    I->insertInto(Outside, Outside->end());
    // Deleted entries must not be reused as identities for a new block.
    Split->replaceAllUsesWith(Outside);
    Split->eraseFromParent();
    auto *New = BasicBlock::Create(C, "new", F);
    EXPECT_EQ(New->getRelatedBlock().State, RelatedBlockState::Incomplete);
    EXPECT_FALSE(T->Region.intersects(New->getRelatedBlock()));
  }
  EXPECT_EQ(Body->getRelatedBlock().State, RelatedBlockState::Disabled);
  ScopedRelatedBlockTracking Next(*F);
  auto *T = RelatedBlockTracking::get(F);
  T->seed({Outside}, "next", "main", 1, false);
  EXPECT_FALSE(T->Region.intersects(Body->getRelatedBlock()));
}
