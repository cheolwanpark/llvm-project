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
  VPlanBackendPricingTest.cpp
  VPlanBackendExecutionTest.cpp
  VPlanTest.cpp
  VPDomTreeTest.cpp
  VPPostDomFrontierTest.cpp
  VPlanHCFGTest.cpp
  VPlanPatternMatchTest.cpp
  VPlanVerifierTest.cpp
  )
