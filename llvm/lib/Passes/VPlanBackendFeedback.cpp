//===- VPlanBackendFeedback.cpp - In-process candidate lowering ------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
#include "llvm/Analysis/VPlanCostProfile.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/Timer.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/Transforms/Vectorize/LoopVectorize.h"

using namespace llvm;

void PassBuilder::registerVPlanBackendFeedbackAnalysis(
    FunctionAnalysisManager &FAM) {
  // Capture configuration by value: the analysis can outlive this PassBuilder.
  FAM.registerPass([Target = TM, Tuning = PTO, FileSystem = FS] {
    return VPlanBackendFeedbackAnalysis([Target, Tuning,
                                         FileSystem](const Function &F,
                                                     const BasicBlock &Header,
                                                     const VPlanBackendCandidate
                                                         &Candidate)
                                            -> Expected<VPlanBackendResult> {
      VPlanCostProfileScope NativeScope(false);
      const bool TimeFeedback = vplanBackendFeedbackTimingEnabled();
      VPlanFeedbackTimer Timer(TimeFeedback);
      TimeRecord QueryStart = Timer.Last;
      std::vector<VPlanFeedbackTiming> BackendPhases;
      auto Run = [&]() -> Expected<VPlanBackendResult> {
        if (!Target)
          return createStringError("backend feedback requires a TargetMachine");
        if (!Target->getTargetTriple().isRISCV())
          return createStringError(
              "backend feedback observer currently supports RISC-V");
        // Profile-dependent module analyses and instrumentation are not part
        // of this first function-local probe contract.
        if (F.getParent()->getProfileSummary(/*IsCS=*/false) ||
            F.getParent()->getProfileSummary(/*IsCS=*/true) ||
            Target->getPGOOption())
          return createStringError(
              "profile-dependent backend probes are unsupported");

        if (F.hasOptNone())
          return createStringError("backend feedback does not support optnone");
        ValueToValueMapTy VMap;
        auto Clone = CloneModule(
            *F.getParent(), VMap,
            [&](const GlobalValue *GV) {
              return GV == &F || isa<GlobalVariable>(GV);
            },
            /*PreserveUseListOrder=*/true);
        Timer.mark("clone");
        auto *ProbeF = cast<Function>(VMap.lookup(&F));
        auto *ProbeHeader = cast<BasicBlock>(VMap.lookup(&Header));
        // Avoid mutation of the live target's subtarget cache and options.
        std::unique_ptr<TargetMachine> ProbeTM(
            Target->getTarget().createTargetMachine(
                Target->getTargetTriple(), Target->getTargetCPU(),
                Target->getTargetFeatureString(), Target->Options,
                Target->getRelocationModel(), Target->getCodeModel(),
                Target->getOptLevel()));
        if (!ProbeTM)
          return createStringError("cannot create candidate TargetMachine");

        PassBuilder PB(ProbeTM.get(), Tuning, std::nullopt, nullptr,
                       FileSystem);
        LoopAnalysisManager LAM;
        FunctionAnalysisManager LocalFAM;
        CGSCCAnalysisManager CGAM;
        ModuleAnalysisManager MAM;
        PB.registerModuleAnalyses(MAM);
        PB.registerCGSCCAnalyses(CGAM);
        PB.registerFunctionAnalyses(LocalFAM);
        PB.registerLoopAnalyses(LAM);
        PB.crossRegisterProxies(LAM, LocalFAM, CGAM, MAM);

        Timer.mark("target_and_analyses");
        VPlanBackendProbe Probe{Candidate, ProbeHeader};
        LoopVectorizePass LV(
            LoopVectorizeOptions(Candidate.InterleaveOnlyWhenForced,
                                 Candidate.VectorizeOnlyWhenForced));
        LV.setBackendProbe(Probe);
        FunctionPassManager Materialize;
        Materialize.addPass(std::move(LV));
        Materialize.run(*ProbeF, LocalFAM);
        Timer.mark("candidate_materialization");
        if (!Probe.Emitted)
          return createStringError(Probe.Error.empty()
                                       ? "candidate was not materialized"
                                       : Probe.Error);

        // Reuse the normal post-LV vector pipeline. This is an explicit probe
        // continuation, not a promise to reproduce arbitrary later module,
        // LTO, instrumentation or user-added passes.
        auto Level = Target->getOptLevel() == CodeGenOptLevel::Aggressive
                         ? OptimizationLevel::O3
                         : OptimizationLevel::O2;
        FunctionPassManager Cleanup;
        PB.addVectorPasses(Level, Cleanup, ThinOrFullLTOPhase::None,
                           /*AddVectorizer=*/false);
        Cleanup.run(*ProbeF, LocalFAM);
        Timer.mark("ir_suffix");
        finalizeVPlanBackendIterationMapping(*ProbeF, LocalFAM);
        if (verifyModule(*Clone, &errs()))
          return createStringError("invalid candidate module");

        Timer.mark("iteration_mapping_and_verification");
        auto Result = ProbeTM->getVPlanBackendFeedback(*Clone, TimeFeedback);
        Timer.mark("backend_total");
        if (!Result)
          return Result.takeError();
        BackendPhases = std::move(Result->Timings);
        if (Result->Candidate != Candidate.ID || Result->VF != Candidate.VF ||
            Result->IC != Candidate.IC ||
            Result->IsEpilogue != Candidate.IsEpilogue)
          return createStringError("backend observation identity mismatch");
        return Result;
      };
      auto Result = Run();
      Timer.mark("return_and_cleanup");
      if (TimeFeedback) {
        auto Total = TimeRecord::getCurrentTime(false) - QueryStart;
        Timer.Phases.insert(Timer.Phases.end(), BackendPhases.begin(),
                            BackendPhases.end());
        json::Object Timing{{"candidate", Candidate.ID},
                            {"status", Result ? "collected" : "unavailable"},
                            {"query_wall_seconds", Total.getWallTime()},
                            {"query_cpu_seconds", Total.getProcessTime()}};
        for (const auto &P : Timer.Phases) {
          Timing[P.Phase + "_wall_seconds"] = P.Wall;
          Timing[P.Phase + "_cpu_seconds"] = P.CPU;
        }
        errs() << "VPLAN-BACKEND-FEEDBACK-TIMING: "
               << json::Value(std::move(Timing)) << '\n';
        if (Result)
          Result->Timings = std::move(Timer.Phases);
      }
      return Result;
    });
  });
}
