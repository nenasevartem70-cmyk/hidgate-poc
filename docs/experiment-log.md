# Experiment log — CVE-2026-28992 on iOS 18.7.2 / A12

This is the working log for the crash-to-control experiments. Everything here
was run on the spare iPhone XR (`iPhone11,8`, iOS 18.7.2, A12). The full panic
logs are kept private; only redacted fields are published.

- Current control ladder: [`kernel-control.md`](kernel-control.md)
- Reproducible test matrix: [`final-tests.md`](final-tests.md)
- AppleJPEG path: [`applejpeg-cve-2026-20687.md`](applejpeg-cve-2026-20687.md)

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

### The sync trigger is healthy

The `jpegreclaim` log from the second run:

```
prime submitted=5
prime closed
reclaimer start threads=4
sync round=0 kr=0 dt=0.094s
sync round=1 kr=0 dt=0.133s
sync round=2 kr=0 dt=0.238s
background task id=3
camera:// opened=0
```

Our own `sel1` sync decode completes in 0.1–0.2 s even after the 5-request
prime. The timeout that frees the stale request is specific to the **Camera
decode path**, not to a generic 2048×2048 sel1 decode. That is why the
same-thread reclaim had no timeout to act on.

New build adds a mass prime (8 threads × 50 iterations × 10 async requests)
before the true sync cycles. If the churn stalls the codec, the same-thread
sync returns `kIOReturnTimeout` and the very next allocation on that
connection reuses the freed slot. The build also logs reclaimer progress once
per second, so we can see whether the storm survives backgrounding.

### 7.2 s near-timeout

`jpegstall2` with a 4000-request mass prime produced:

```
mass spray done conn=400 req=4000 fail=0
cycle round=0 sync kr=0 dt=7.210s
cycle round=1 sync kr=0 dt=0.008s
cycle round=2 sync kr=0 dt=0.007s
reclaimer stop conn=4312 req=21560 fail=0
jpegreclaim done (no panic)
```

The first sync after the mass prime waited **7.21 s** — close to the driver's
10 s wait (`w2 = 0x2710`) but still completed. The next two syncs were fast,
so the stall is a one-shot queue-drain effect. There was no panic this run.

Next build doubles the mass prime to 8000 requests and starts the reclaimer
storm **before** the sync cycle. The goal is to push the first sync past 10 s,
get `kIOReturnTimeout`, and have the storm plus the same-connection allocation
already in flight when the request is freed.

### Timeout + same-thread reclaim, no panic

`jpegstall3` hit the real timeout:

```
cycle round=2 sync kr=0xe00002d6 dt=10.002s
cycle round=2 TIMEOUT -> same-conn reclaim
cycle round=2 reclaim submitted=10
cycle round=2 closed
storm conn=9266 req=46330 fail=0
jpegreclaim done (no panic)
```

This is the first run where the 10 s timeout freed a request and the very
next allocations were same-type `JpegRequest`s on the same connection, yet
the kernel survived. Two interpretations remain:

1. the freed slot was replaced by a live reclaimer request, so the stale
   queue node no longer pointed at poison;
2. the reclaimer requests completed and their normal `queue_remove` cleaned
   the stale node before the queue walk.

The next build closes the connection **immediately** after the reclaim
submission, so the reclaimer requests are still in flight and
`clientClosedGated` takes the inactive path (no dequeue). That should leave
the embedded node stale and tell us which interpretation is correct.

### Power-state wedge after immediate close

The immediate-close build eventually produced a different panic:

```
AppleJPEGDriver::setPowerState(0xffffffdef7cb1880, 1 -> 0)
  timed out after 10210 ms @IOServicePM.cpp:5577
```

This is **not** the `far=0x308` queue-walk UAF. It is a power-management
timeout: the driver was left with in-flight/leaked requests and could not
transition to the off state. The app had already logged
`jpegreclaim done (no panic)`; the watchdog fired later, when the driver was
asked to power down.

The wedge is a new, repeatable kernel-hang signal, but it also masks the UAF:
the power watchdog fires before the stale queue node is walked. The next build
closes the userclient **while the sync decode is in flight**, which is the
real `isInactive` path from the CVE, then reclaims on a fresh connection and
probes.

### Close during sync reproduces the UAF without Camera

`jpegclose` closes the victim userclient while a sync decode is in flight and
then probes the queue. The device panicked with the same read UAF:

```
pc  = 0xfffffff014d23418   (0xfffffff008df3418 unslid)
lr  = 0xfffffff014d26638   (0xfffffff008df6638 unslid)
x5  = 0
x6  = 0x00000007839956d4
x12 = 0
far = 0x308
```

This confirms the `isInactive` free path: the timeout free skipped the
dequeue, and the probe walked the stale node. It is a reliable UAF trigger in
our own app, without Camera. The reclaim still did not replace the stale
object (`x12` is zero), so S4 (write/double-free) is not closed.

A second `jpegclose` run with an early+late 4032×3024 `flags=1` reclaim storm
still produced the same `far=0x308`, `x12=0` fault. The likely causes are a
codec/pool mismatch (4032 vs the 2048 victim/mass-spray pool) and the
progressive flag on a baseline JPEG failing validation before the node is
queued. `jpegclose6` fixes both: 2048×2048, `flags=0`, early+late storms of
6 connections × 5 requests, probe 50 ms after the storm.

## Next steps

1. Run `jpegclose` variants: reclaim after the timeout free, not before it,
   and keep the reclaim requests in flight.
2. If the probe panics at `far=0x308`, the inactive free left the node and we
   can chain the reclaim into a persistent UAF.
3. If it survives, the node is being dequeued even on the inactive path; the
   next step is to keep the reclaimer request from completing at all.
4. Treat the `setPowerState` timeout as a separate DoS primitive, not as
   control.
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
