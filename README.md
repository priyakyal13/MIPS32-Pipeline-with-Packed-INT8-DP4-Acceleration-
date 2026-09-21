# EdgeMIPS

### A compact MIPS32 pipeline with a custom INT8 dot-product instruction for edge AI

EdgeMIPS upgrades a simple educational 5-stage MIPS32 processor into a small, measurable hardware platform for edge-AI-style arithmetic.

The project is intentionally **small enough to understand end-to-end** while demonstrating several real RTL concepts:

- 32-bit, 5-stage pipeline: IF / ID / EX / MEM / WB
- Forwarding for ALU data hazards
- Automatic one-cycle stall for load-use hazards
- BEQZ / BNEQZ branch handling with pipeline flush
- Custom `DP4` instruction: four signed INT8 multiplies + accumulation
- Simple hardware performance counters
- Self-checking simulation testbench

## Why DP4?

A dot product is a basic operation inside convolution, neural-network inference, DSP, and sensor-processing workloads. Instead of building a large accelerator, EdgeMIPS explores a smaller architectural idea: extend a normal CPU with one workload-specific instruction.

### Custom ISA extension

```text
DP4 rd, rs, rt
```

The 32-bit values in `rs` and `rt` are viewed as four signed 8-bit lanes:

```text
rs = [a3 a2 a1 a0]
rt = [b3 b2 b1 b0]

rd = a0*b0 + a1*b1 + a2*b2 + a3*b3
```

Example:

```text
rs = 0x04030201  ->  1, 2, 3, 4
rt = 0x08070605  ->  5, 6, 7, 8

DP4 = 1*5 + 2*6 + 3*7 + 4*8 = 70
```

## Architecture

```text
                  +----------------------+
                  |       MIPS32         |
                  |  IF ID EX MEM WB     |
                  +----------+-----------+
                             |
                +------------+------------+
                |                         |
         Forwarding unit            Hazard unit
                |                         |
                +------------+------------+
                             |
                    +--------v--------+
                    |   EX arithmetic  |
                    | ALU + DP4 unit  |
                    +--------+--------+
                             |
                    +--------v--------+
                    | Memory / Writeback|
                    +--------+--------+
                             |
                  Performance counters
```


## Supported instructions

Inherited from the original project plus the custom extension:

- `ADD`, `SUB`, `AND`, `OR`, `SLT`, `MUL`
- `LW`, `SW`
- `ADDI`, `SUBI`, `SLTI`
- `BEQZ`, `BNEQZ`
- `DP4` (custom)
- `HLT`

Instruction field layout remains intentionally close to the original project so the upgrade is easy to follow.

## Run the simulation

Requires Icarus Verilog and GTKWave.

### Command line

```bash
iverilog -g2012 -Wall -o sim_edge_mips rtl/dp4_unit.v rtl/edge_mips.v tb/tb_edge_mips.v
vvp sim_edge_mips
```

or simply:

```bash
./run.sh
```

### View waveforms

```bash
gtkwave edge_mips.vcd
```

### Makefile

```bash
make test
make wave
```

## What the testbench checks

1. Back-to-back ALU dependencies are handled using forwarding.
2. A `LW -> use` dependency inserts exactly one load-use stall.
3. `DP4` produces the expected packed INT8 dot product.
4. A scalar MUL/ADD dot product is compared against the `DP4` version using cycle and instruction counters.

The benchmark prints **measured** cycle/instruction counts at simulation time; no performance numbers are hard-coded into the README.

## Design philosophy

The goal is not to build a large CPU. The goal is to make one architectural idea obvious:

> **Keep a conventional pipeline, but add a tiny instruction that matches a real workload.**

That keeps the RTL approachable while creating a clear hardware/software co-design story.
