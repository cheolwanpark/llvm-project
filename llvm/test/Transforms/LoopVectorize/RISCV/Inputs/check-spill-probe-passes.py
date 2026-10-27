import sys
text = open(sys.argv[1]).read()
assert 'RISC-V VPlan vector spill observer' in text, text
for forbidden in ('Prologue/Epilogue Insertion', 'RISC-V local cost observations',
                  'Stack Frame Layout Analysis', 'Machine Copy Propagation Pass',
                  'After Machine Loop Invariant Code Motion (machinelicm)'):
    assert forbidden not in text, forbidden
executions = [line for line in text.splitlines() if '# *** IR Dump After' in line]
observers = [i for i, line in enumerate(executions)
             if 'RISC-V VPlan vector spill observer' in line]
assert observers
start = 0
for i in observers:
    probe = executions[start:i]
    assert 'Stack Slot Coloring' in probe[-1], probe[-6:]
    assert sum('Virtual Register Rewriter' in line for line in probe) == 2, probe
    assert sum('Greedy Register Allocator' in line for line in probe) == 2, probe
    assert any('Insert VSETVLI' in line for line in probe), probe
    assert any('Dead register definitions' in line for line in probe), probe
    assert any('Register Allocation Pass Scoring' in line for line in probe), probe
    start = i + 1
