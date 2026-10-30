# AppleJPEGDriver panic analysis — CVE-2026-20687 on iOS 18.7.2 / A12

Confirmed deferred kernel UAF after `jpegprobe` primed AppleJPEGDriver and
Camera was opened. This is the first confirmed kernel UAF in the project that
is not the IOHID/AppleSPU crash.

Device-specific identifiers are omitted; the raw `.ips` stays private.

## Environment

```
Product:        iPhone11,8 (iPhone XR, A12 / T8020)
OS:             iPhone OS 18.7.2 (22H124)
Kernel:         xnu-11417.140.69.702.20~1/RELEASE_ARM64_T8020
Kext:           com.apple.driver.AppleJPEGDriver 7.6.9
Kext load base: 0xfffffff01157aec0
Kernel slide:   0x000000000878c000
Text exec slide:0x0000000009590000
```

## Panic

```
panic(cpu 2 caller 0xfffffff010d79eb0): Kernel data abort
pc  = 0xfffffff01157f418
lr  = 0xfffffff011582638
x5  = 0xfeedfacefeedfacf
x6  = 0xfeedfacefeedfacf
x12 = 0x0000000000000000
x16 = 0x000000103158a7e0
far = 0x0000000000000308
esr = 0xffffffdc96000005
```

Unslid (kext slide `0x878c000`):

```
pc  = 0xfffffff008df3418
lr  = 0xfffffff008df6638
```

Backtrace, kext frames:

```
pc  0xfffffff008df3418   helper at 0xfffffff008df33ec
lr  0xfffffff008df6638   finish_io_gated at 0xfffffff008df65e0
lr  0xfffffff008df624c   caller of finish_io_gated
```

Kernel extensions in backtrace:

```
com.apple.driver.AppleJPEGDriver(7.6.9)
  @0xfffffff01157aec0 -> 0xfffffff0115a4033
```

## Faulting instruction

```
fffffff008df3410:  ldr x12, [x8]
fffffff008df3414:  ldr x12, [x12, #8]
fffffff008df3418:  ldrb w12, [x12, #0x308]   <-- fault, far = 0x308
```

`x12` is zero, so the stale queue entry led to a NULL object and the
`+0x308` read faulted. `x5`/`x6` still contain the zone poison
`0xfeedfacefeedfacf`, confirming the object came from a freed allocation.

## What it means

The fault is in the queue-walk helper used by `finish_io_gated`:

1. `finish_io_gated` calls the helper at `0xfffffff008df33ec`.
2. The helper walks the per-codec request vector and dereferences a stale
   `JpegRequest` queue entry.
3. `request->IOUserClient` (or the next node's link) is zero after the free,
   so `ldrb [x12, #0x308]` aborts at `0x308`.

This is exactly the CVE-2026-20687 model: the timeout path frees a request
without removing its embedded queue node; a later completion walks the stale
node.

The panicking thread is `kernel_task` tid 289, not the app. The app
`hidgate4` (pid 935) was still alive. The UAF is therefore **deferred**: the
app primes the driver, then a kernel completion thread hits the stale object.

## Open question for control

The same `finish_io_gated` path contains a PAC-protected virtual call:

```
fffffff008df6a38:  ldr x0, [x19]        ; request->task
fffffff008df6a3c:  ldr x16, [x0]        ; task->vtable
fffffff008df6a48:  autda x16, x17       ; data PAC
fffffff008df6a4c:  ldr x8, [x16, #0x28]!
fffffff008df6a5c:  blraa x8, x17        ; authenticated call
```

The public PoC calls this the `*(*(req+0)+40)()` PC-control point. On A12 /
arm64e the call is PAC-authenticated, so a naive fake `task_t` will not pass
`autda`/`blraa`. The reclaim experiment must establish whether the stale
request can be turned into a double-free or a controlled write before that
call, rather than assuming direct PC control.

## Next experiment

`jpegreclaim`: prime the driver, force a sync decode and check for
`kIOReturnTimeout` (`0xe00002d6`), then race a same-type `JpegRequest`
reclaimer into the freed slot. Observe whether the panic:

- disappears (reclaim succeeded with a live request),
- changes `far`/registers (controlled reuse), or
- turns into a double-free/write fault in the driver.
