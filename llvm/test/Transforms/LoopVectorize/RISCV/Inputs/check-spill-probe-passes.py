import sys
text = open(sys.argv[1]).read()
assert 'RISC-V VPlan vector spill observer' in text, text
# These passes cannot execute in any probe, including candidates with spill=0.
for forbidden in ('Insert VSETVLI', 'Prologue/Epilogue Insertion',
                  'RISC-V Insert VSETVLI', 'RISC-V local cost observations',
                  'Stack Frame Layout Analysis'):
    assert forbidden not in text, forbidden
executions = [line for line in text.splitlines() if '# *** IR Dump After' in line]
observers = [i for i, line in enumerate(executions)
             if 'RISC-V VPlan vector spill observer' in line]
assert observers
for i in observers:
    preceding = executions[max(0, i - 5):i]
    assert any('Virtual Register Rewriter' in line for line in preceding), preceding
# Exactly one allocator per observer, with no later scalar allocator.
assert sum('Greedy Register Allocator' in line for line in executions) == len(observers)
