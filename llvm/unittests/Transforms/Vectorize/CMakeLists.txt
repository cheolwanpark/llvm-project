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
  VPlanTest.cpp
  VPlanCostReportTest.cpp
  VPlanRegisterUsageBoundsTest.cpp
  VPDomTreeTest.cpp
  VPPostDomFrontierTest.cpp
  VPlanHCFGTest.cpp
  VPlanPatternMatchTest.cpp
  VPlanVerifierTest.cpp
  )

# Exercises the production backend-score transport and vectorizer selection.
add_llvm_unittest(VPlanRATests PARTIAL_SOURCES_INTENDED VPlanRATest.cpp)
