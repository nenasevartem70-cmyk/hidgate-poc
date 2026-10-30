# Experiments

Research variants of the crash PoC. They are kept for reproducibility and
diffing, not as stable tools.

| File | Purpose |
|---|---|
| `hidgate5_generic_spray.m` | `setxattr` + IOSurface `CFData` spray |
| `hidgate6_targeted_spray.m` | big gate-XML dictionaries + fast-path client churn |
| `hidgate7_phases.m` | phase A (close/open) vs phase B (AOP); named threads |
| `hidgate8_inthread_inject.m` | new type-2 client + big XML between `sel1` and `sel0` |
| `hidgate9_destroy_reopen.m` | `sel1` → `mach_port_destroy` → `IOServiceOpen` + gate |
| `hidgate10_backoff_raw.m` | backoff after destroy + raw IOSurface/CFData between destroy and open |

These variants assume a single `PoC/Info.plist`-style app wrapper. They all
panic the kernel by design; run them only on a spare device.

The main `PoC/main.m` remains the stable baseline (`hidgate4`).
