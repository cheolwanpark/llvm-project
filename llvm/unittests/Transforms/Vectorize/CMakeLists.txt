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
  VPlanTest.cpp
  VPlanCostReportTest.cpp
  VPDomTreeTest.cpp
  VPPostDomFrontierTest.cpp
  VPlanHCFGTest.cpp
  VPlanPatternMatchTest.cpp
  VPlanVerifierTest.cpp
  )

# Supplies a synthetic research policy only in this standalone test binary.
add_llvm_unittest(VPlanRATests PARTIAL_SOURCES_INTENDED VPlanRATest.cpp)
