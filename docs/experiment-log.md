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

## 2026-10-30 — control closure and AppleJPEG pivot

### IOHID fast path: `copyEvent` is closed on this provider

`copyprobe3` found the correct `sel2` ABI:

| Input | Result |
|---|---|
| `outc=0` | `0xe00002be` (`kIOReturnNoResources`) |
| `outc=1/2` | `0xe00002c2` (`kIOReturnBadArgument`) |

`SharedMemorySize` in the gate dictionary is accepted (`gate=0x0`). The
`NoResources` result means the handler is reached but the fast-path event
queue is empty.

`copyprobe4` then hammered `sel2` for 30 seconds while the device was shaken:
**245,808 attempts, `ok=0`, every call `0xe00002be`.** The SPU provider never
delivers a fast-path event to this client. `copyEvent` cannot be used to race
the free.

Conclusion: on the only reachable provider, CVE-2026-28992 is **crash-only**.
The freed object is provider-side; userland sprays (generic, targeted, OOL,
SPU client) do not reclaim it.

### AppleJPEGDriver: new control lead

Pivot to **CVE-2026-20687** (`AppleJPEGDriver` decoder timeout UAF, Apple
impact: *write kernel memory*). Static check of the 18.7.2 kext
(`com.apple.driver.AppleJPEGDriver`, version 7.6.9) confirms the vulnerable
machinery is present:

- `startDecoder`, `startEncoder`, `startDecoderExt`, `startDecoder2024`;
- `queue_io_gated`, `finish_io_gated`, `clientClosedGated`;
- `AppleJPEGDriver: %s(): TIMEOUT %dms`;
- the `0x58`-byte `AppleJPEGDriverIOStruct` field layout used by the public
  PoC.

The public PoC triggers the bug by submitting async decodes, closing the
connection, and then opening Camera to force a sync decode timeout. The freed
`JpegRequest` (0x440) keeps its queue node at `request+0x78`; the next queue
walk dereferences `request+0x80`.

`jpegprobe` was built to verify reachability from the app sandbox:
open type 0, selector sanity checks, 64×64 decode, then five 2048×2048 async
decodes and an immediate close. See
[`applejpeg-cve-2026-20687.md`](applejpeg-cve-2026-20687.md).

## Next steps

1. Run `jpegprobe` and check whether `IOServiceOpen("AppleJPEGDriver", 0)`
   succeeds from the sideloaded app.
2. If `sel1` accepts the `0x58` struct, confirm the async prime and the
   Camera-triggered panic; capture the `AppleJPEGDriver` backtrace.
3. If the UAF is confirmed, reclaim `JpegRequest` with controlled data and
   target the `*(*(request+0)+40)()` virtual call.
4. If the service is blocked, pivot to another reachable 18.7.2 kernel CVE.

## Safety

The PoC intentionally panics the kernel and reboots the device. Run it only on
a spare device you own. Do not run it on a primary phone.
