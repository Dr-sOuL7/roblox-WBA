# Harness Runner (headless, CI-friendly)

Runs the **actual game simulation modules** (`TickManager`, `PhysicsController`,
`BeyController`, `SpinEvaluator`, `SimulationHarness`, …) outside Roblox, under the
standalone [Luau CLI](https://github.com/luau-lang/luau/releases), using a thin
shim for the handful of Roblox APIs the headless path touches.

This is **developer/CI tooling**. Nothing in this directory ships into the place file
(`default.project.json` does not map it).

## Usage

```bash
# Get the Luau CLI (Linux):
curl -sL -o /tmp/luau.zip https://github.com/luau-lang/luau/releases/latest/download/luau-ubuntu.zip
unzip -o /tmp/luau.zip -d /tmp

# Full Phase 1 validation suite (exits non-zero on NO-GO → CI gate):
python3 tools/harness-runner/build_runner.py --luau /tmp/luau --run suite 1000 200

# Single batch:
python3 tools/harness-runner/build_runner.py --luau /tmp/luau --run batch 300 Aggressive Evasive
```

The same suite runs inside Studio against real Roblox APIs:
`_G.RunValidationSuite()` from the command bar (see `Main.server.lua`).

## How it works

`build_runner.py` concatenates `shim.lua` + each module source from `src/`
(wrapped as a registered loader, read at build time — no copies to drift) +
`driver.lua` into one Luau chunk.

Excluded modules: `TelemetryLogger`, `ReplayRecorder`, `DebugStatePublisher`.
They only register Replication-phase handlers, and the Replication phase never
executes under `TickManager.Step(true)` — identical to live headless behaviour.

## Fidelity caveats

* **PRNG:** the shim's `Random` is xorshift32, not Roblox's. Batches are exactly
  reproducible *within this runner* (fixed `baseSeed`), but not numerically
  identical to a Studio run of the same seeds.
* **Floats:** shim `Vector3` uses doubles; Roblox stores float32 components.
* Consequence: treat runner results as **statistical validation** (distributions,
  rates, bands). A Studio `_G.RunValidationSuite()` re-run should land within
  sampling noise of the runner's numbers, not match them digit-for-digit.
