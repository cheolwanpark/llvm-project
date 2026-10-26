//===- VPlanBackendFeedback.cpp - In-process candidate lowering ------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/Analysis/VPlanCostProfile.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Verifier.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Timer.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Transforms/Scalar/InstSimplifyPass.h"
#include "llvm/Transforms/Scalar/LoopSink.h"
#include "llvm/Transforms/Scalar/SimplifyCFG.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/Transforms/Vectorize/LoopVectorize.h"
#include "llvm/Transforms/Vectorize/VPlanRA.h"

using namespace llvm;

static cl::opt<bool> LateCleanup(
    "vplan-backend-feedback-late-cleanup", cl::Hidden, cl::init(false),
    cl::desc("Run LoopSink, InstSimplify and SimplifyCFG in backend probes"));
static cl::opt<bool> TimeFeedback(
    "time-vplan-backend-feedback", cl::Hidden,
    cl::desc("Print per-candidate query, late cleanup and backend timings"));

void PassBuilder::registerVPlanBackendFeedbackAnalysis(
    FunctionAnalysisManager &FAM) {
  // Capture configuration by value: the analysis can outlive this PassBuilder.
  FAM.registerPass([Target = TM, Tuning = PTO, FileSystem = FS] {
    return VPlanBackendFeedbackAnalysis(
        [Target, Tuning, FileSystem](
            const Function &F, const BasicBlock &Header,
            const VPlanBackendCandidate &Candidate) -> Expected<json::Object> {
          VPlanCostProfileScope NativeScope(false);
          TimeRecord QueryStart =
              TimeFeedback ? TimeRecord::getCurrentTime() : TimeRecord();
          TimeRecord LateTime, BackendTime;
          bool Collected = false;
          // This guard runs after clone/analysis/target teardown. Timing is
          // diagnostic output, not part of the backend observation contract.
          auto ReportTiming = scope_exit([&] {
            if (!TimeFeedback)
              return;
            TimeRecord Total = TimeRecord::getCurrentTime(false) - QueryStart;
            json::Object Timing{
                {"candidate", Candidate.ID},
                {"status", Collected ? "collected" : "unavailable"},
                {"late_cleanup", bool(LateCleanup)},
                {"query_wall_seconds", Total.getWallTime()},
                {"query_cpu_seconds", Total.getProcessTime()},
                {"late_cleanup_wall_seconds", LateTime.getWallTime()},
                {"late_cleanup_cpu_seconds", LateTime.getProcessTime()},
                {"backend_wall_seconds", BackendTime.getWallTime()},
                {"backend_cpu_seconds", BackendTime.getProcessTime()}};
            errs() << "VPLAN-BACKEND-FEEDBACK-TIMING: "
                   << json::Value(std::move(Timing)) << '\n';
          });
          if (!Target)
            return createStringError(
                "backend feedback requires a TargetMachine");
          if (!Target->getTargetTriple().isRISCV())
            return createStringError(
                "backend feedback observer currently supports RISC-V");
          if (vplanRAEnabled())
            return createStringError(
                "backend feedback cannot nest external RA replay");
          // Profile-dependent module analyses and instrumentation are not part
          // of this first function-local probe contract.
          if (F.getParent()->getProfileSummary(/*IsCS=*/false) ||
              F.getParent()->getProfileSummary(/*IsCS=*/true) ||
              Target->getPGOOption())
            return createStringError(
                "profile-dependent backend probes are unsupported");

          ValueToValueMapTy VMap;
          auto Clone = CloneModule(
              *F.getParent(), VMap,
              [&](const GlobalValue *GV) {
                return GV == &F || isa<GlobalVariable>(GV);
              },
              /*PreserveUseListOrder=*/true);
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

          VPlanBackendProbe Probe{Candidate, ProbeHeader};
          LoopVectorizePass LV(
              LoopVectorizeOptions(Candidate.InterleaveOnlyWhenForced,
                                   Candidate.VectorizeOnlyWhenForced));
          LV.setBackendProbe(Probe);
          FunctionPassManager Materialize;
          Materialize.addPass(std::move(LV));
          Materialize.run(*ProbeF, LocalFAM);
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
          if (LateCleanup) {
            // Use the same pass options as the normal post-vectorizer
            // continuation. This experiment isolates these three passes; it
            // does not reproduce intervening or later module/extension passes.
            FunctionPassManager Late;
            Late.addPass(LoopSinkPass());
            Late.addPass(InstSimplifyPass());
            Late.addPass(
                SimplifyCFGPass(SimplifyCFGOptions()
                                    .convertSwitchRangeToICmp(true)
                                    .convertSwitchToArithmetic(true)
                                    .speculateUnpredictables(true)
                                    .hoistLoadsStoresWithCondFaulting(true)));
            TimeRecord Start =
                TimeFeedback ? TimeRecord::getCurrentTime() : TimeRecord();
            Late.run(*ProbeF, LocalFAM);
            if (TimeFeedback)
              LateTime = TimeRecord::getCurrentTime(false) - Start;
          }
          finalizeVPlanRAIterationMapping(*ProbeF, LocalFAM);
          if (verifyModule(*Clone, &errs()))
            return createStringError("invalid candidate module");

          TimeRecord BackendStart =
              TimeFeedback ? TimeRecord::getCurrentTime() : TimeRecord();
          auto Result = ProbeTM->getVPlanBackendFeedback(*Clone);
          if (TimeFeedback)
            BackendTime = TimeRecord::getCurrentTime(false) - BackendStart;
          if (!Result)
            return Result.takeError();
          if (Result->getString("candidate") != Candidate.ID ||
              Result->getInteger("vf") != Candidate.VF.getKnownMinValue() ||
              Result->getBoolean("scalable") != Candidate.VF.isScalable())
            return createStringError("backend observation identity mismatch");
          (*Result)["ic"] = Candidate.IC;
          (*Result)["observation_role"] =
              Candidate.IsEpilogue ? "epilogue" : "main";
          (*Result)["middle_end"] = std::move(Probe.MiddleEnd);
          (*Result)["scalar_cost"] = std::move(Probe.ScalarCost);
          std::string Pipeline = Level == OptimizationLevel::O3
                                     ? "vector-suffix-O3"
                                     : "vector-suffix-O2";
          if (LateCleanup)
            Pipeline += "+late-cleanup";
          (*Result)["feedback_pipeline"] = std::move(Pipeline);
          Collected = true;
          return std::move(*Result);
        });
  });
}
