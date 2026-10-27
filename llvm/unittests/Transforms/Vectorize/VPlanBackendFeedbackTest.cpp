// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#include "../lib/Passes/VPlanBackendProbe.h"
#include "llvm/Analysis/VPlanCostProfile.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/Module.h"
#include "gtest/gtest.h"
#include <condition_variable>
#include <mutex>

using namespace llvm;

TEST(VPlanBackendFeedback, EmptySingletonAndMalformedBatch) {
  LLVMContext Context;
  Module M("test", Context);
  auto *F = Function::Create(FunctionType::get(Type::getVoidTy(Context), false),
                             GlobalValue::ExternalLinkage, "f", M);
  auto *Header = BasicBlock::Create(Context, "header", F);
  VPlanBackendCandidate C{"f:0", 0,     ElementCount::getFixed(4),
                          true,  false, false};
  unsigned Calls = 0;
  VPlanBackendFeedback Service([&](const Function &, const BasicBlock &,
                                   ArrayRef<VPlanBackendCandidate> Candidates)
                                   -> Expected<VPlanBackendFeedback::Batch> {
    ++Calls;
    VPlanBackendFeedback::Batch Results;
    for (const auto &Candidate : Candidates) {
      VPlanBackendResult R;
      R.Candidate = Candidate.ID;
      Results.emplace_back(std::move(R));
    }
    return Results;
  });
  auto Empty = Service.getBatch(*F, *Header, {});
  ASSERT_TRUE(bool(Empty));
  EXPECT_TRUE(Empty->empty());
  EXPECT_EQ(Calls, 0u);
  auto Single = Service.get(*F, *Header, C);
  ASSERT_TRUE(bool(Single));
  EXPECT_EQ(Single->Candidate, C.ID);
  EXPECT_EQ(Calls, 1u);

  VPlanBackendFeedback Malformed(
      [](const Function &, const BasicBlock &, ArrayRef<VPlanBackendCandidate>)
          -> Expected<VPlanBackendFeedback::Batch> {
        VPlanBackendFeedback::Batch Results;
        // A rejected batch must also safely destroy an unconsumed error slot.
        Results.emplace_back(createStringError("discarded candidate failure"));
        Results.emplace_back(createStringError("second discarded failure"));
        return Results;
      });
  auto Bad = Malformed.get(*F, *Header, C);
  ASSERT_FALSE(bool(Bad));
  EXPECT_EQ(toString(Bad.takeError()), "backend feedback batch size mismatch");
  VPlanBackendFeedback Missing;
  auto Unavailable = Missing.get(*F, *Header, C);
  ASSERT_FALSE(bool(Unavailable));
  EXPECT_EQ(toString(Unavailable.takeError()),
            "backend feedback provider unavailable");
}

TEST(VPlanBackendFeedback, PoolOverlapBoundOrderingAndReuse) {
  for (unsigned Threads : {1u, 2u, 4u}) {
    if (!LLVM_ENABLE_THREADS && Threads > 1)
      continue;
    VPlanBackendProbePool Pool(Threads);
    VPlanCostProfileScope CallerScope(true);
    for (unsigned Round = 0; Round != 3; ++Round) {
      std::mutex Mutex;
      std::condition_variable CV;
      unsigned Active = 0, Peak = 0, Arrived = 0, Generation = 0;
      SmallVector<unsigned> Completed;
      auto Results =
          Pool.run(Threads * 2, [&](unsigned I) -> VPlanBackendProbeResult {
            EXPECT_FALSE(VPlanCostProfileScope::active());
            std::unique_lock<std::mutex> Lock(Mutex);
            Peak = std::max(Peak, ++Active);
            unsigned MyGeneration = Generation;
            if (++Arrived == Threads) {
              Arrived = 0;
              ++Generation;
              CV.notify_all();
            } else {
              CV.wait(Lock, [&] { return Generation != MyGeneration; });
            }
            // Force out-of-order completion, independent of host speed.
            if (Threads > 1 && I == 0)
              CV.wait(Lock, [&] { return !Completed.empty(); });
            Completed.push_back(I);
            --Active;
            CV.notify_all();
            if (I == 1)
              return {createStringError("injected probe failure")};
            VPlanBackendResult R;
            R.Candidate = std::to_string(I);
            return {std::move(R)};
          });
      EXPECT_TRUE(VPlanCostProfileScope::active());
      EXPECT_EQ(Active, 0u);
      EXPECT_EQ(Peak, Threads);
      EXPECT_EQ(Completed.size(), Threads * 2);
      if (Threads > 1)
        EXPECT_NE(Completed.front(), 0u);
      ASSERT_EQ(Results.size(), Threads * 2);
      for (unsigned I = 0; I != Results.size(); ++I) {
        if (I == 1) {
          EXPECT_FALSE(Results[I].Observation);
          EXPECT_EQ(Results[I].Failure, "injected probe failure");
        } else {
          ASSERT_TRUE(Results[I].Observation);
          EXPECT_EQ(Results[I].Observation->Candidate, std::to_string(I));
        }
      }
    }
    unsigned Calls = 0;
    auto Empty = Pool.run(0, [&](unsigned) -> VPlanBackendProbeResult {
      ++Calls;
      return {createStringError("unreachable")};
    });
    EXPECT_TRUE(Empty.empty());
    EXPECT_EQ(Calls, 0u);
  }
}
