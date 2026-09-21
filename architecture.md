# EdgeMIPS Architecture

## Goal

EdgeMIPS starts from a compact 32-bit MIPS-like five-stage pipeline and adds one workload-specific architectural feature: a packed INT8 dot-product instruction for edge-AI-style arithmetic.

## Pipeline

```text
IF -> ID -> EX -> MEM -> WB
          |     |
          |     +--> Forwarding from EX/MEM and MEM/WB
          +--------> Load-use hazard detection / one-cycle stall
```

Branches are resolved in EX. A taken branch redirects the PC and flushes the younger IF/ID instruction.

## Custom instruction

`DP4 rd, rs, rt`

Treats each 32-bit source register as four signed INT8 values:

```text
rs = {a3,a2,a1,a0}
rt = {b3,b2,b1,b0}

rd = a0*b0 + a1*b1 + a2*b2 + a3*b3
```

The operation is useful as a small building block for quantized edge-AI, DSP, and sensor-processing kernels while keeping the CPU architecture simple.

## Why forwarding and hazard detection matter

The original educational version relied on manually inserted filler instructions between dependent instructions. EdgeMIPS removes that software workaround. The forwarding network resolves ALU dependencies directly, while a load-use dependency receives one pipeline bubble.

## Performance counters

The core exposes:

- `cycle_count`
- `instruction_count`
- `stall_count`
- `dp4_count`

These make architectural experiments measurable without adding a large debug subsystem.
