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

### Confirmed: deferred kernel UAF

`jpegprobe` opened the userclient (`kr=0`), accepted the `0x58` struct
(`sel1 sync444 kr=0`, `sel1 async64 kr=0`), submitted five async 2048×2048
decodes, and closed. Opening Camera then produced a panic inside
`AppleJPEGDriver 7.6.9`:

```
pc  = 0xfffffff01157f418   (0xfffffff008df3418 unslid)
lr  = 0xfffffff011582638   (0xfffffff008df6638 unslid)
x5  = 0xfeedfacefeedfacf
x6  = 0xfeedfacefeedfacf
x12 = 0
far = 0x308
```

Faulting instruction:

```asm
ldrb w12, [x12, #0x308]
```

Call chain: `finish_io_gated` (0x8df65e0) → queue helper (0x8df33ec) →
stale `JpegRequest` read. The panicking thread was `kernel_task` tid 289,
not the app, confirming the deferred completion path. Full analysis:
[`applejpeg-panic-2026-10-30.md`](applejpeg-panic-2026-10-30.md).

### Reclaim race, first run

`jpegreclaim` ran four reclaimer threads: **2962 connections / 14,809 async
requests / 0 open failures**. The three "sync" rounds returned instantly:

```
sync round=0 kr=0 dt=0.000s
sync round=1 kr=0 dt=0.001s
sync round=2 kr=0 dt=0.000s
```

Cause: the trigger input still carried a non-zero async token, so the driver
treated the call as asynchronous and returned immediately. The reclaimer
itself worked; it was simply never aligned with a timeout. Fixed build uses
`asyncToken = 0`, `flags = 0` for the sync trigger, keeps the reclaimer alive
for 45 s before Camera, and requests a background task so the storm continues
for ~30 s after the app is backgrounded.

### Reclaim race, second run (Camera trigger)

The fixed build kept four reclaimer threads alive across the Camera open.
The device still panicked with the **same fault**:

```
pc  = 0xfffffff013ffb418   (0xfffffff008df3418 unslid)
lr  = 0xfffffff013ffe638   (0xfffffff008df6638 unslid)
x5  = 0x121
x6  = 0
x12 = 0
far = 0x308
```

The stale request was not replaced: `x12` is still zero, so the queue walk
hit the original freed object, not a reclaimer request. The reclaimer touched
a different allocation/timing window than the Camera-timeout request.

Next build changes the strategy: after a sync decode returns
`kIOReturnTimeout`, submit the reclaimer allocation **on the same connection
and in the same thread**, immediately after the free, instead of relying on
background threads. This removes the scheduler race between the free and the
next allocation.

## Next steps

1. Run the same-thread `jpegreclaim` and confirm `cycle round=... sync
   kr=0xe00002d6` (`kIOReturnTimeout`, `dt ~= 10 s`).
2. Observe whether the panic disappears, changes registers, or turns into a
   double-free/write fault.
3. If the sync trigger still returns instantly, switch to an in-app camera
   picker/AVCapture trigger so the reclaimer stays alive during the real
   Camera decode.
4. If the UAF becomes a controlled reuse, target the request fields before
   the PAC-protected `*(*(request+0)+40)()` call.
5. If direct PC control is blocked by PAC, look for a write/double-free
   primitive in the same path.

## Safety

The PoC intentionally panics the kernel and reboots the device. Run it only on
a spare device you own. Do not run it on a primary phone.
