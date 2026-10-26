//===- VPlanBackendFeedback.cpp - Candidate backend queries
//-----------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Vectorize/VPlanBackendFeedback.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

static cl::opt<bool> EnableFeedback(
    "enable-vplan-backend-feedback", cl::Hidden,
    cl::desc(
        "Observe backend facts for VPlan candidates without changing costs"));
static cl::opt<std::string> FeedbackOutput(
    "vplan-backend-feedback-output", cl::Hidden,
    cl::desc("Append candidate feedback as JSONL (diagnostic only)"));
static cl::opt<bool> PrintFeedback(
    "print-vplan-backend-feedback", cl::Hidden,
    cl::desc("Print received backend facts in LV before VF selection"));
static cl::opt<bool> ForceAllFeedback(
    "vplan-backend-feedback-force-all", cl::Hidden,
    cl::desc("Query every candidate, retaining the register-bound decision"));

AnalysisKey VPlanBackendFeedbackAnalysis::Key;

bool llvm::vplanBackendFeedbackEnabled() {
  return EnableFeedback || PrintFeedback;
}

bool llvm::vplanBackendFeedbackForceAll() { return ForceAllFeedback; }

void llvm::printVPlanBackendFeedback(const json::Object &Result) {
  if (PrintFeedback)
    errs() << "VPLAN-BACKEND-FEEDBACK: " << json::Value(json::Object(Result))
           << '\n';
  if (FeedbackOutput.empty())
    return;
  std::error_code EC;
  raw_fd_ostream OS(FeedbackOutput, EC, sys::fs::OF_Append | sys::fs::OF_Text);
  if (EC)
    reportFatalUsageError(Twine("cannot write VPlan backend feedback: ") +
                          EC.message());
  OS << json::Value(json::Object(Result)) << '\n';
  OS.close();
  if (OS.has_error())
    reportFatalUsageError("failed to write VPlan backend feedback");
}
