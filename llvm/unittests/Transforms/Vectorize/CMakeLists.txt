add_subdirectory(SandboxVectorizer)

set(LLVM_LINK_COMPONENTS
  Analysis
  Core
  Passes
  Vectorize
  AsmParser
  TargetParser
  )

add_llvm_unittest(VectorizeTests
  PARTIAL_SOURCES_INTENDED
  VPlanBackendCostModelTest.cpp
  VPlanBackendFeedbackTest.cpp
  VPlanTest.cpp
  VPlanCostReportTest.cpp
  VPlanRegisterUsageBoundsTest.cpp
  VPDomTreeTest.cpp
  VPPostDomFrontierTest.cpp
  VPlanHCFGTest.cpp
  VPlanPatternMatchTest.cpp
  VPlanVerifierTest.cpp
  )
