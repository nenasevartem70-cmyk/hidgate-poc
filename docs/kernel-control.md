# Kernel control status — iOS 18.7.2 / A12

Last updated: **2026-10-31**

Target: iPhone XR (`iPhone11,8`), iOS 18.7.2 (22H124), A12 / T8020.
Goal: kernel read/write, KASLR defeat, PAC/PPL bypass, jailbreak.

## Verdict

**No kernel read/write yet.** What we do have is a reproducible kernel UAF in
`AppleJPEGDriver` and a controlled same-type reclaim of the freed request.
The direct "PC control" path from the public PoC is PAC-protected on A12, so
the next gate is a **double-free / write primitive**, not a fake vtable.

## The ladder

| Level | State | Evidence |
|---|---|---|
| 0. Crash | **PASS** | IOHID `x16=0x0020000000000000`, `far=0x...38`; AppleJPEG `far=0x308` |
| 1. Reproducible UAF | **PASS** | AppleJPEG `finish_io_gated` reads a freed `JpegRequest`; `x5/x6=0xfeedface...` |
| 2. Controlled free | **PASS** | `sel1` sync returns `kIOReturnTimeout` (`0xe00002d6`) after 10.001 s |
| 3. Same-type reclaim | **PASS** | 10 async requests on the same connection immediately after the timeout; kernel survives |
| 4. Persistent stale node | **PASS (UAF)** | Close during sync reproduces the `far=0x308` read without Camera |
| 5. Write / read primitive | **NOT YET** | No arbitrary kernel read/write or controlled free of a second object |
| 6. PAC / PPL bypass | **NOT YET** | `autda` + `blraa` on the `request->task` call are enforced |
| 7. Kernel r/w + jailbreak | **NOT YET** | Requires levels 5–6 |

## Evidence

### 1. AppleJPEG UAF panic

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
fffffff008df3410:  ldr x12, [x8]
fffffff008df3414:  ldr x12, [x12, #8]
fffffff008df3418:  ldrb w12, [x12, #0x308]   <-- fault
```

Call chain: `finish_io_gated` (`0x8df65e0`) → queue helper (`0x8df33ec`) →
stale `JpegRequest`. The panicking thread is `kernel_task`, not the app, so
the UAF is deferred.

Full analysis:
[`applejpeg-panic-2026-10-30.md`](applejpeg-panic-2026-10-30.md).

### 2. Controlled timeout

After an 8000-request mass prime, a true synchronous decode (`asyncToken = 0`,
`flags = 0`) returns:

```
cycle round=0 sync kr=0xe00002d6 dt=10.001s
```

`0xe00002d6` is `kIOReturnTimeout`. This is the driver's 10 s wait
(`w2 = 0x2710`) expiring and freeing the request.

### 3. Same-type reclaim

Immediately after the timeout, ten async decodes are submitted on the same
connection. The first allocation reuses the just-freed `JpegRequest` slot.
The kernel survives; the stale queue node no longer points at poison:

```
cycle round=0 TIMEOUT -> same-conn reclaim
cycle round=0 reclaim submitted=10
jpegreclaim done (no panic)
```

### 4. Power-state wedge

Closing the connection immediately after the reclaim leaves in-flight
requests that never release the driver's power-management state:

```
AppleJPEGDriver::setPowerState(0xffffffdef7cb1880, 1 -> 0)
  timed out after 10210 ms @IOServicePM.cpp:5577
```

This is a repeatable kernel hang, but it is **not** the queue-walk UAF and it
does not provide control. It masks the stale node because the power watchdog
fires first.

### 5. Persistent UAF trigger

`jpegclose` closes the victim userclient while a sync decode is in flight.
`terminatePhase1` marks the client inactive early; the timeout free skips the
dequeue, and a fresh sync probe walks the stale node:

```
jpegclose + probe
pc  = 0xfffffff014d23418   (0xfffffff008df3418 unslid)
lr  = 0xfffffff014d26638   (0xfffffff008df6638 unslid)
x5  = 0
x6  = 0x00000007839956d4
x12 = 0
far = 0x308
```

This is the **same read UAF**, now reproducible without Camera. It confirms
the inactive free path, but the reclaim did not replace the stale object
(`x12` is zero), so it is still not a write/double-free primitive.

## Why direct PC control is blocked

The public PoC points at this call in `finish_io_gated`:

```asm
fffffff008df6a38:  ldr x0, [x19]          ; request->task
fffffff008df6a3c:  ldr x16, [x0]          ; task->vtable
fffffff008df6a48:  autda x16, x17         ; data PAC, modifier = task address
fffffff008df6a4c:  ldr x8, [x16, #0x28]!
fffffff008df6a5c:  blraa x8, x17          ; authenticated call
```

`request->task` is set by the driver from the caller's `task_t`; a
same-type `JpegRequest` reclaim cannot change it. Pointing it at a fake
object requires a valid signed vtable pointer for that object's address,
which needs either a PAC oracle or a kernel read. Neither exists yet.

## Next gates

1. **Leave the node stale on purpose.** Close the userclient while a sync
   decode is in flight (`terminatePhase1` sets `isInactive` early), so the
   timeout free skips the dequeue. Reclaim on a fresh connection, then probe.
   Build: `jpegclose`.
2. **Keep the reclaim request from completing.** If the reclaim request
   completes, its normal `queue_remove` can clean the stale node. Use an
   in-flight request that never reaches completion before the walk. T9 does
   this with an early + late storm of 4032×3024 reclaim requests and frees
   one connection at a time while probing.
3. **Turn the second free into a write.** Look for a path that releases the
   request's `IOSurface`/`IOUserClient` references twice, or that writes to a
   freed request field we control.
4. **Audit the other AppleJPEG selectors in parallel.** `sel3` (encode),
   `sel4`/`sel5` (0x1000), `sel6`/`sel7` (0xDA0 async), and `sel8`/`sel9`
   (privileged) may expose a direct user pointer or a write path. See
   [`applejpeg-methods.md`](applejpeg-methods.md).
5. **Only then** revisit PAC: a kernel read or a signed-pointer leak is
   required before the `blraa` path can be used.

## What would count as control

A test is a control primitive only if at least one of these is observed:

- a controlled value in a fault register (`x12=0x4141...`, `far=0x4141...`);
- an arbitrary kernel read returning attacker-chosen data;
- an arbitrary kernel write to an attacker-chosen address;
- a double-free that can be converted into an allocation overlap;
- a PAC-signed pointer leak or a signing oracle.

A panic alone, including the `setPowerState` timeout, is **not** control.

## Direct links

- AppleJPEG selector audit: [`applejpeg-methods.md`](applejpeg-methods.md)
- Jailbreak project built on this research: https://github.com/nenasevartem70-cmyk/hidra
- Apple security content, iOS 26.4 / iPadOS 26.4 (CVE-2026-20687):
  https://support.apple.com/en-us/126792
- Apple security content, iOS 18.7.7 / iPadOS 18.7.7:
  https://support.apple.com/en-us/126793
- CVE record: https://www.cve.org/CVERecord?id=CVE-2026-20687
- NVD: https://nvd.nist.gov/vuln/detail/CVE-2026-20687
- Public PoC: https://github.com/0xjohnnydev/CVE-2026-20687-AppleJPEGDriver-UAF
- IOHID CVE record: https://www.cve.org/CVERecord?id=CVE-2026-28992
- IOHID NVD: https://nvd.nist.gov/vuln/detail/CVE-2026-28992
- IOHID public PoC:
  https://github.com/0xjohnnydev/CVE-2026-28992-IOHIDFamily-FastPathUserClient-Race-Conditions
