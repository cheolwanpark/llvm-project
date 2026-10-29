//===- VPlanBackendFeedback.cpp - In-process candidate lowering
//------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "VPlanBackendProbe.h"
#include "VPlanBackendProbePruning.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/Analysis/VPlanCostProfile.h"
#include "llvm/Bitcode/BitcodeReader.h"
#include "llvm/Bitcode/BitcodeWriter.h"
#include "llvm/IR/DiagnosticInfo.h"
#include "llvm/IR/DiagnosticPrinter.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/OptBisect.h"
#include "llvm/IR/PassTimingInfo.h"
#include "llvm/IR/PrintPasses.h"
#include "llvm/IR/Verifier.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/DebugCounter.h"
#include "llvm/Support/TimeProfiler.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Transforms/Utils/Cloning.h"
#include "llvm/Transforms/Vectorize/LoopVectorize.h"
#include <condition_variable>
#include <mutex>

using namespace llvm;

VPlanBackendFeedback::Batch VPlanBackendProbePool::run(
    unsigned Count, function_ref<VPlanBackendProbeResult(unsigned)> Probe,
    function_ref<void(unsigned, const VPlanBackendProbeResult &)> Completed) {
  SmallVector<std::optional<VPlanBackendProbeResult>, 0> Slots(Count);
  auto Run = [&](unsigned I) {
    VPlanCostProfileScope NativeScope(false);
    Slots[I].emplace(Probe(I));
  };
  if (LLVM_ENABLE_THREADS && Count > 1 && Threads > 1) {
    if (!Pool)
      Pool = std::make_unique<DefaultThreadPool>(hardware_concurrency(Threads));
    std::mutex Mutex;
    std::condition_variable CV;
    SmallVector<unsigned> Ready;
    ThreadPoolTaskGroup Group(*Pool);
    unsigned Next = 0, Active = 0;
    auto Fill = [&] {
      while (Next < Count && Active < Threads) {
        unsigned I = Next++;
        ++Active;
        Group.async([&, I] {
          Run(I);
          {
            std::lock_guard<std::mutex> Lock(Mutex);
            Ready.push_back(I);
          }
          CV.notify_one();
        });
      }
    };
    Fill();
    while (Active) {
      SmallVector<unsigned> Finished;
      {
        std::unique_lock<std::mutex> Lock(Mutex);
        CV.wait(Lock, [&] { return !Ready.empty(); });
        Finished.swap(Ready);
      }
      for (unsigned I : Finished) {
        --Active;
        if (Completed)
          Completed(I, *Slots[I]);
      }
      Fill();
    }
    Group.wait();
  } else {
    for (unsigned I = 0; I != Count; ++I) {
      Run(I);
      if (Completed)
        Completed(I, *Slots[I]);
    }
  }
  VPlanBackendFeedback::Batch Results;
  Results.reserve(Count);
  for (auto &Slot : Slots)
    Results.push_back(std::move(*Slot));
  return Results;
}

namespace {
cl::opt<unsigned> ProbeThreads(
    "vplan-backend-probe-threads", cl::Hidden, cl::init(1),
    cl::desc("Maximum concurrent VPlan backend probes (default 1)"),
    cl::callback([](const unsigned &N) {
      if (!N)
        reportFatalUsageError("vplan-backend-probe-threads must be positive");
    }));

/// These settings have process-global state or direct output. Retain their
/// existing execution order instead of changing options or LLVM
/// instrumentation.
std::string serialReason(const Function &F) {
  if (!LLVM_ENABLE_THREADS)
    return "LLVM was built without threads";
  if (vplanBackendFeedbackTimingEnabled())
    return "-vplan-backend-time uses process CPU timers";
  if (DebugFlag || legacy::debugPassSpecified())
    return "LLVM debug output is enabled";
  if (shouldPrintBeforeSomePass() || shouldPrintAfterSomePass() ||
      PrintChanged != ChangePrinter::None)
    return "pass IR printing is enabled";
  if (TimePassesIsEnabled || timeTraceProfilerEnabled())
    return "pass timing or time tracing is enabled";
  if (F.getContext().getOptPassGate().isEnabled())
    return "an optimization pass gate is enabled";
  const auto &Context = F.getContext();
  if (Context.getLLVMRemarkStreamer() || Context.getMainRemarkStreamer() ||
      Context.getDiagHandlerPtr()->isAnyRemarkEnabled())
    return "optimization remarks are enabled";
  for (auto [Name, Counter] : DebugCounter::instance())
    if (DebugCounter::isCounterSet(*Counter))
      return "debug counters are enabled";
  // Some diagnostic switches have no public value accessor. Inspect only their
  // presence; never change a registered option. Keep the fork's cost reports
  // out of this list: they are passive and emitted by the original thread.
  auto &Options = cl::getRegisteredOptions();
  auto ReportEnabled = [&](StringRef Name) {
    auto *Option = Options.lookup(Name);
    return Option && static_cast<cl::opt<bool> *>(Option)->getValue();
  };
  if (ReportEnabled("print-vplans") || ReportEnabled("print-detailed-vplans")) {
    auto *ForcedEpilogue = Options.lookup("epilogue-vectorization-force-VF");
    if (ForcedEpilogue && static_cast<cl::opt<ElementCount> *>(ForcedEpilogue)
                              ->getValue()
                              .isVector())
      return "forced-epilogue cost reporting requires serial preparation";
  }
  for (const auto &Entry : Options) {
    StringRef Name = Entry.first;
    if (Name == "print-vplans" || Name == "print-detailed-vplans")
      continue;
    if (Entry.second->getNumOccurrences() &&
        (Name.starts_with("view-") || Name.contains("print") ||
         Name.starts_with("debug-") || Name.starts_with("dot-") ||
         Name.contains("dump") || Name == "misched-detail-resource-booking" ||
         Name == "misched-dcpl" ||
         (Name.starts_with("regalloc-") &&
          (Name.ends_with("training-log") ||
           Name.ends_with("interactive-channel-base")))))
      return ("-" + Name + " requires serial diagnostics").str();
  }
  return {};
}

/// All target settings used below are copied on the calling thread. Workers
/// never read the live TargetMachine or its mutable subtarget/options caches.
struct ProbeTarget {
  const Target &TheTarget;
  Triple TargetTriple;
  std::string CPU, Features;
  TargetOptions Options;
  Reloc::Model Relocation;
  CodeModel::Model CodeModel;
  CodeGenOptLevel OptLevel;

  explicit ProbeTarget(const TargetMachine &TM)
      : TheTarget(TM.getTarget()), TargetTriple(TM.getTargetTriple()),
        CPU(TM.getTargetCPU()), Features(TM.getTargetFeatureString()),
        Options(TM.Options), Relocation(TM.getRelocationModel()),
        CodeModel(TM.getCodeModel()), OptLevel(TM.getOptLevel()) {}
};

Error checkInput(const TargetMachine *TM, const Function &F) {
  if (!TM)
    return createStringError("backend feedback requires a TargetMachine");
  if (!TM->getTargetTriple().isRISCV())
    return createStringError(
        "backend feedback observer currently supports RISC-V");
  if (F.getParent()->getProfileSummary(/*IsCS=*/false) ||
      F.getParent()->getProfileSummary(/*IsCS=*/true) || TM->getPGOOption())
    return createStringError(
        "profile-dependent backend probes are unsupported");
  if (F.hasOptNone())
    return createStringError("backend feedback does not support optnone");
  return Error::success();
}

std::unique_ptr<Module> cloneInput(const Function &F, ValueToValueMapTy &VMap) {
  return CloneModule(
      *F.getParent(), VMap,
      [&](const GlobalValue *GV) {
        return GV == &F || isa<GlobalVariable>(GV);
      },
      /*PreserveUseListOrder=*/true);
}

struct ProbePipeline {
  PipelineTuningOptions Tuning;
  void (*BuildSuffix)(PassBuilder &, OptimizationLevel, FunctionPassManager &);
};

Expected<VPlanBackendResult>
runProbe(Module &M, Function &F, BasicBlock &Header,
         const VPlanBackendCandidate &Candidate, const ProbeTarget &Target,
         const ProbePipeline &Pipeline,
         IntrusiveRefCntPtr<vfs::FileSystem> FileSystem,
         VPlanFeedbackTimer &Timer, raw_ostream &Diagnostics) {
  if (ScopedPassCancellation::check())
    return createStringError("backend probe cancelled");
  std::unique_ptr<TargetMachine> TM(Target.TheTarget.createTargetMachine(
      Target.TargetTriple, Target.CPU, Target.Features, Target.Options,
      Target.Relocation, Target.CodeModel, Target.OptLevel));
  if (!TM)
    return createStringError("cannot create candidate TargetMachine");
  PassBuilder PB(TM.get(), Pipeline.Tuning, std::nullopt, nullptr,
                 std::move(FileSystem));
  LoopAnalysisManager LAM;
  FunctionAnalysisManager FAM;
  CGSCCAnalysisManager CGAM;
  ModuleAnalysisManager MAM;
  PB.registerModuleAnalyses(MAM);
  PB.registerCGSCCAnalyses(CGAM);
  PB.registerFunctionAnalyses(FAM);
  PB.registerLoopAnalyses(LAM);
  PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);
  Timer.mark("target_and_analyses");

  VPlanBackendProbe Probe{Candidate, &Header};
  LoopVectorizePass LV(LoopVectorizeOptions(Candidate.InterleaveOnlyWhenForced,
                                            Candidate.VectorizeOnlyWhenForced));
  LV.setBackendProbe(Probe);
  FunctionPassManager Materialize;
  Materialize.addPass(std::move(LV));
  Materialize.run(F, FAM);
  Timer.mark("candidate_materialization");
  if (!Probe.Emitted)
    return createStringError(
        Probe.Error.empty() ? "candidate was not materialized" : Probe.Error);

  if (ScopedPassCancellation::check())
    return createStringError("backend probe cancelled");
  auto DumpPruningIR = [&](StringRef Stage) {
    if (PruningDumpIR) {
      Diagnostics << "VPLAN-BACKEND-PRUNING-IR: " << Candidate.ID << " "
                  << Stage << '\n';
      // Include intrinsic declarations and metadata definitions so a captured
      // stage can be verified or lowered independently during the experiment.
      M.print(Diagnostics, nullptr);
      Diagnostics << "VPLAN-BACKEND-PRUNING-IR-END\n";
    }
  };
  ProbeIRSize BeforePruning, AfterPruning;
  if (PruningTrace)
    BeforePruning = getProbeIRSize(F, FAM);
  DumpPruningIR("before");
  PruningResult Pruning =
      Candidate.Observation.Kind == VPlanBackendObservationKind::MIRBody
          ? PruningResult{0, "mir-observation"}
      : PruneLoopRegions ? pruneLoopRegions(F, FAM)
                         : PruningResult{0, "disabled"};
  unsigned Removed = Pruning.Removed;
  if (Removed) {
    FAM.invalidate(F, PreservedAnalyses::none());
    if (verifyFunction(F, &Diagnostics))
      return createStringError("invalid pruned candidate function");
  }
  DumpPruningIR("after");
  if (PruningTrace)
    AfterPruning = getProbeIRSize(F, FAM);
  Timer.mark("probe_pruning");

  if (ScopedPassCancellation::check())
    return createStringError("backend probe cancelled");
  // This is the same explicit post-LV continuation for both execution modes.
  auto Level = Target.OptLevel == CodeGenOptLevel::Aggressive
                   ? OptimizationLevel::O3
                   : OptimizationLevel::O2;
  FunctionPassManager Cleanup;
  Pipeline.BuildSuffix(PB, Level, Cleanup);
  Cleanup.run(F, FAM);
  DumpPruningIR("suffix");
  if (PruningTrace) {
    ProbeIRSize SuffixSize = getProbeIRSize(F, FAM);
    Diagnostics << "VPLAN-BACKEND-PRUNING: "
                << json::Value(json::Object{
                       {"candidate", Candidate.ID},
                       {"function", F.getName()},
                       {"enabled", bool(PruneLoopRegions)},
                       {"reason", Pruning.Reason},
                       {"applied", Removed != 0},
                       {"before", BeforePruning.Instructions},
                       {"before_blocks", BeforePruning.Blocks},
                       {"before_loop", BeforePruning.LoopInstructions},
                       {"before_loop_blocks", BeforePruning.LoopBlocks},
                       {"removed", Removed},
                       {"after", AfterPruning.Instructions},
                       {"after_blocks", AfterPruning.Blocks},
                       {"after_loop", AfterPruning.LoopInstructions},
                       {"after_loop_blocks", AfterPruning.LoopBlocks},
                       {"suffix", SuffixSize.Instructions},
                       {"suffix_blocks", SuffixSize.Blocks},
                       {"suffix_loop", SuffixSize.LoopInstructions},
                       {"suffix_loop_blocks", SuffixSize.LoopBlocks}})
                << '\n';
  }
  Timer.mark("ir_suffix");
  if (ScopedPassCancellation::check())
    return createStringError("backend probe cancelled");
  finalizeVPlanBackendIterationMapping(F, FAM);
  if (verifyModule(M, &Diagnostics))
    return createStringError("invalid candidate module");
  Timer.mark("iteration_mapping_and_verification");
  auto Result =
      TM->getVPlanBackendFeedback(M, Timer.Enabled, Candidate.Observation);
  Timer.mark("backend_total");
  if (!Result)
    return Result.takeError();
  if (Result->Candidate != Candidate.ID || Result->VF != Candidate.VF ||
      Result->IC != Candidate.IC || Result->IsEpilogue != Candidate.IsEpilogue)
    return createStringError("backend observation identity mismatch");
  return Result;
}

/// Single-query compatibility path: retain the live context, diagnostic
/// handler, VFS and phase timing, including short-circuiting before the next
/// candidate.
Expected<VPlanBackendResult>
runSerial(const Function &F, const BasicBlock &Header,
          const VPlanBackendCandidate &Candidate, TargetMachine *LiveTarget,
          const ProbePipeline &Pipeline,
          IntrusiveRefCntPtr<vfs::FileSystem> FileSystem) {
  VPlanFeedbackTimer Timer(vplanBackendFeedbackTimingEnabled());
  TimeRecord Start = Timer.Last;
  auto Run = [&]() -> Expected<VPlanBackendResult> {
    if (auto E = checkInput(LiveTarget, F))
      return std::move(E);
    ValueToValueMapTy VMap;
    auto Clone = cloneInput(F, VMap);
    Timer.mark("clone");
    ProbeTarget Target(*LiveTarget);
    return runProbe(*Clone, *cast<Function>(VMap.lookup(&F)),
                    *cast<BasicBlock>(VMap.lookup(&Header)), Candidate, Target,
                    Pipeline, FileSystem, Timer, errs());
  };
  auto Result = Run();
  Timer.mark("return_and_cleanup");
  if (Timer.Enabled) {
    auto Total = TimeRecord::getCurrentTime(false) - Start;
    if (Result)
      Timer.Phases.insert(Timer.Phases.end(), Result->Timings.begin(),
                          Result->Timings.end());
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
}

class ProbeDiagnostics final : public DiagnosticHandler {
  raw_ostream &OS;

public:
  explicit ProbeDiagnostics(raw_ostream &OS) : OS(OS) {}
  bool handleDiagnostics(const DiagnosticInfo &DI) override {
    HasErrors |= DI.getSeverity() == DS_Error;
    OS << LLVMContext::getDiagnosticMessagePrefix(DI.getSeverity()) << ": ";
    DiagnosticPrinterRawOStream Printer(OS);
    DI.print(Printer);
    OS << '\n';
    return true;
  }
};

struct ProbeSnapshot {
  SmallVector<char, 0> Bitcode;
  std::string ModuleIdentifier;
  unsigned FunctionIndex, HeaderIndex;
  bool DiscardNames, ODRTypes;

  ProbeSnapshot(const Function &F, const BasicBlock &Header)
      : ModuleIdentifier(F.getParent()->getModuleIdentifier()),
        DiscardNames(F.getContext().shouldDiscardValueNames()),
        ODRTypes(F.getContext().isODRUniquingDebugTypes()) {
    ValueToValueMapTy VMap;
    auto Clone = cloneInput(F, VMap);
    auto *CloneF = cast<Function>(VMap.lookup(&F));
    FunctionIndex = std::distance(Clone->begin(), CloneF->getIterator());
    HeaderIndex = std::distance(
        CloneF->begin(), cast<BasicBlock>(VMap.lookup(&Header))->getIterator());
    raw_svector_ostream OS(Bitcode);
    WriteBitcodeToFile(*Clone, OS, /*ShouldPreserveUseListOrder=*/true);
  }

  VPlanBackendProbeResult run(const VPlanBackendCandidate &Candidate,
                              const ProbeTarget &Target,
                              const ProbePipeline &Pipeline) const {
    std::string Diagnostics;
    raw_string_ostream OS(Diagnostics);
    auto Run = [&]() -> Expected<VPlanBackendResult> {
      LLVMContext Context;
      Context.setDiscardValueNames(DiscardNames);
      if (ODRTypes)
        Context.enableDebugTypeODRUniquing();
      Context.setDiagnosticHandler(std::make_unique<ProbeDiagnostics>(OS),
                                   /*RespectFilters=*/true);
      auto M = parseBitcodeFile(
          MemoryBufferRef(StringRef(Bitcode.data(), Bitcode.size()),
                          "vplan-backend-probe"),
          Context);
      if (!M)
        return M.takeError();
      (*M)->setModuleIdentifier(ModuleIdentifier);
      if (FunctionIndex >= (*M)->size())
        return createStringError("backend snapshot function identity mismatch");
      auto *F = &*std::next((*M)->begin(), FunctionIndex);
      if (HeaderIndex >= F->size())
        return createStringError("backend snapshot header identity mismatch");
      auto &Header = *std::next(F->begin(), HeaderIndex);
      VPlanFeedbackTimer Timer(false);
      // This profile-free, function-local pipeline uses no VFS inputs. Do not
      // share the original frontend's filesystem or diagnostic callbacks.
      auto Result = runProbe(**M, *F, Header, Candidate, Target, Pipeline,
                             nullptr, Timer, OS);
      if (Context.getDiagHandlerPtr()->HasErrors) {
        if (!Result)
          consumeError(Result.takeError());
        return createStringError("backend probe emitted an error diagnostic");
      }
      return Result;
    };
    auto Result = Run();
    return {std::move(Result), std::move(Diagnostics)};
  }
};

// Both ownership paths finish destroying their private IR before publication.
VPlanBackendProbeResult
runControlledProbe(const VPlanBackendCandidate &C,
                   function_ref<VPlanBackendProbeResult()> Run) {
  ScopedPassCancellation Scope(C.Control ? &C.Control->Cancellation : nullptr);
  auto R = [&]() -> VPlanBackendProbeResult {
    if (ScopedPassCancellation::check())
      return {createStringError("backend probe cancelled")};
    if (C.Control)
      C.Control->Started = true;
    return Run();
  }();
  R.Cancelled = C.Control && C.Control->Cancellation.Observed;
  return R;
}

class FeedbackProvider {
  TargetMachine *Target;
  ProbePipeline Pipeline;
  IntrusiveRefCntPtr<vfs::FileSystem> FileSystem;
  unsigned Threads;
  VPlanBackendProbePool Pool;
  unsigned SerialMainQueries = 0;
  bool Warned = false;

public:
  FeedbackProvider(TargetMachine *Target, ProbePipeline Pipeline,
                   IntrusiveRefCntPtr<vfs::FileSystem> FileSystem)
      : Target(Target), Pipeline(Pipeline), FileSystem(std::move(FileSystem)),
        Threads(ProbeThreads), Pool(Threads) {}

  void beginInvocation() { SerialMainQueries = 0; }

  bool canBatch(const Function &F) const {
    return Threads > 1 && serialReason(F).empty();
  }

  Expected<VPlanBackendFeedback::Batch>
  query(const Function &F, const BasicBlock &Header,
        ArrayRef<VPlanBackendCandidate> Candidates) {
    VPlanCostProfileScope NativeScope(false);
    std::string Reason = Threads > 1 ? serialReason(F) : std::string();
    if (!Reason.empty() && !Warned) {
      for (const auto &C : Candidates)
        SerialMainQueries += !C.IsEpilogue;
      // No warning for an empty/gated loop or a single main query. The original
      // thread emits this once, when serial execution actually prevents
      // overlap.
      if (SerialMainQueries > 1) {
        errs() << "warning: -vplan-backend-probe-threads=" << Threads
               << ": using serial backend probes because " << Reason << '\n';
        Warned = true;
      }
    }
    auto Completed = [&](unsigned I, const VPlanBackendProbeResult &R) {
      const auto &C = Candidates[I];
      if (C.Control && C.Control->Completed)
        C.Control->Completed(R);
    };
    if (Candidates.size() < 2 || Threads == 1 || !Reason.empty()) {
      VPlanBackendFeedback::Batch Results;
      for (unsigned I = 0; I < Candidates.size(); ++I) {
        const auto &C = Candidates[I];
        Results.push_back(
            runControlledProbe(C, [&]() -> VPlanBackendProbeResult {
              return {runSerial(F, Header, C, Target, Pipeline, FileSystem)};
            }));
        Completed(I, Results.back());
      }
      return Results;
    }
    if (auto E = checkInput(Target, F))
      return std::move(E);
    ProbeTarget Settings(*Target);
    ProbeSnapshot Snapshot(F, Header);
    return Pool.run(
        Candidates.size(),
        [&](unsigned I) {
          return runControlledProbe(Candidates[I], [&] {
            return Snapshot.run(Candidates[I], Settings, Pipeline);
          });
        },
        Completed);
  }
};
} // namespace

void PassBuilder::registerVPlanBackendFeedbackAnalysis(
    FunctionAnalysisManager &FAM) {
  // The service owns the lazy pool and outlives this PassBuilder. Each local
  // probe PassBuilder registers its own unused service, never a nested pool.
  ProbePipeline Pipeline{PTO, [](PassBuilder &PB, OptimizationLevel Level,
                                 FunctionPassManager &FPM) {
                           PB.addVectorPasses(Level, FPM,
                                              ThinOrFullLTOPhase::None,
                                              /*AddVectorizer=*/false);
                         }};
  auto Provider = std::make_shared<FeedbackProvider>(TM, Pipeline, FS);
  FAM.registerPass([Provider, TM = TM] {
    return VPlanBackendFeedbackAnalysis(
        [Provider](const Function &F, const BasicBlock &Header,
                   ArrayRef<VPlanBackendCandidate> Candidates) {
          return Provider->query(F, Header, Candidates);
        },
        [Provider](const Function &F) { return Provider->canBatch(F); },
        [TM](const Function &F) {
          return TM ? TM->getTargetMIRInfo(F) : nullptr;
        },
        [Provider] { Provider->beginInvocation(); });
  });
}
