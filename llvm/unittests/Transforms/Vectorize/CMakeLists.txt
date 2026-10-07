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
  VPlanTest.cpp
  VPlanCostReportTest.cpp
  VPDomTreeTest.cpp
  VPPostDomFrontierTest.cpp
  VPlanHCFGTest.cpp
  VPlanPatternMatchTest.cpp
  VPlanVerifierTest.cpp
  )
