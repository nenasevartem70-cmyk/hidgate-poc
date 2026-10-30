# Experiment log — CVE-2026-28992 on iOS 18.7.2 / A12

This is the working log for the crash-to-control experiments. Everything here
was run on the spare iPhone XR (`iPhone11,8`, iOS 18.7.2, A12). The full panic
logs are kept private; only redacted fields are published.

## Summary

| Build | Idea | Result |
|---|---|---|
| `hidgate4` | Baseline: enumerate `IOHIDEventService`, gate 16 connections, AOP probe storm | Kernel data abort, `x16=0x0020000000000000`, `far=0x0020000000000038` |
| `hidgate5` | Add generic heap spray: `setxattr` + IOSurface `CFData` | Same fault; spray missed |
| `hidgate6` | Add targeted spray: big gate XML dictionaries + fast-path client churn | Same fault; targeted spray missed |
| `hidgate7` | Split into phase A (open/close) and phase B (AOP probe); name threads | Panic in **phase A**, thread `UAF-close`; AOP not involved |
| `hidgate8` | Insert a new type-2 client + big XML between `sel1` and `sel0` in the same thread | Same fault in `UAF-close-idx-inject`; in-thread client injection missed |
| `hidgate9` | `sel1` → `mach_port_destroy` → `IOServiceOpen` + gate in the same thread | No panic for 30,019 successful reopens; then provider exhausted and the loop spun errors (inconclusive) |
| `hidgate10` | Backoff after destroy, raw IOSurface/CFData between destroy and open | Pending |

## Key findings

1. The crash is a **kernel data abort** on a virtual call through a corrupted
   object pointer:
   ```
   ldr x8, [x16, #0x38]!
   x16 = 0x0020000000000000
   far = 0x0020000000000038
   ```
   The backtrace contains `IOHIDFamily` and `AppleSPU`.

2. The UAF is triggered in the **close/open path**, not by the AOP probe storm.
   In `hidgate7`, the panicked thread was `UAF-close` during phase A.

3. The first faulting virtual call is consistent with `OSDynamicCast` on a
   stale `IOService`/provider object while IOHIDFamily iterates a client
   dictionary during open/teardown.

4. Generic heap spray (`setxattr`, IOSurface `CFData`), targeted gate
   dictionaries, and extra fast-path clients did **not** reclaim the object.
   The slot is either in a different `kalloc_type`/zone or the free/use window
   is too short for a background thread to hit.

5. `mach_port_destroy` followed by `IOServiceOpen` suppressed the panic for
   30k successful reopens, but the provider then stopped accepting opens and
   the loop produced billions of errors. This needs a backoff/re-scan test
   (`hidgate10`) before drawing conclusions.

## Next steps

1. Run `hidgate10` with backoff and raw in-thread IOSurface allocation.
2. If the fault changes to `0x4141...`, the slot is reclaimable with
   controlled data; move to fake vtable/ROP.
3. If the fault stays `0x0020...`, stop blind spraying and identify the exact
   object/zone from the IOHIDFamily/AppleSPU kext.
4. If the panic disappears but the test is valid, determine whether the object
   was reclaimed by a legitimate client or the vulnerable path was avoided.

## Safety

The PoC intentionally panics the kernel and reboots the device. Run it only on
a spare device you own. Do not run it on a primary phone.
