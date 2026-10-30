# Final tests — iOS 18.7.2 / A12

This is the reproducible test set for the two kernel bugs in this repository.
Run it only on the spare test device. Every AppleJPEG test can panic and
reboot the phone.

## Test environment

| Item | Value |
|---|---|
| Device | iPhone XR (`iPhone11,8`), A12 / T8020 |
| OS | iOS 18.7.2 (22H124) |
| Kernel | `xnu-11417.140.69.702.20~1` |
| AppleJPEGDriver | 7.6.9 |
| Bundle ID (all builds) | `com.example.hidgate4` |
| Installer | Sideloadly / AltStore / own signing |

All AppleJPEG builds reuse `com.example.hidgate4` so a free Sideloadly
account does not spend a new App ID. Only one build can be installed at a
time; installing the next one overwrites the previous app.

## Matrix

| ID | Build / source | Purpose | Expected result | State |
|---|---|---|---|---|
| T1 | `PoC/main.m` (`hidgate4`) | IOHID fast-path crash baseline | `x16=0x0020000000000000`, `far=0x...38` | **PASS** |
| T2 | `experiments/copyprobe4.m` | IOHID `copyEvent` reachability | 245,808 attempts, all `0xe00002be` | **PASS (closed)** |
| T3 | `experiments/applejpeg/jpegprobe.m` | AppleJPEG userclient + ABI | `open type0 kr=0`, `sel1 sync444 kr=0`, `sel1 async64 kr=0` | **PASS** |
| T4 | `jpegprobe.m` + Camera | Deferred AppleJPEG UAF | panic in `AppleJPEGDriver`, `far=0x308`, `x12=0` | **PASS** |
| T5 | `experiments/applejpeg/jpegreclaim.m` | Controlled 10 s timeout | `kr=0xe00002d6`, `dt=10.001s` | **PASS** |
| T6 | `jpegreclaim.m` | Same-type reclaim after timeout | 10 async submitted, no panic | **PASS** |
| T7 | `jpegreclaim.m` immediate close | Persistent stale / power wedge | `setPowerState(1 -> 0) timed out after 10210 ms` | **PASS (DoS)** |
| T8 | `experiments/applejpeg/jpegclose.m` | Close during sync (`isInactive`) | `far=0x308` without Camera | **PASS (UAF)** |
| T9 | `experiments/applejpeg/jpegclose6.m` | Early + late 2048/flags=0 reclaim storm around the inactive close | `x12 != 0`, new `far`, or double-free | **PENDING** |

### Revision note

`experiments/applejpeg/jpegreclaim.m` is the current source and includes the
immediate-close path used by T7. The 100 ms-delay revision used for T5/T6 is
commit `7420288`; T7 is the later immediate-close revision. Both use the same
mass prime and the same 10 s timeout trigger.

## T1 — IOHID crash baseline

Source: [`../PoC/main.m`](../PoC/main.m)

1. Build and install the baseline app.
2. Launch it and let it run for 30 s.
3. The kernel panics in the IOHID/AppleSPU path.

Pass criteria:

```
Kernel data abort
x16 = 0x0020000000000000
far = 0x0020000000000038
```

Evidence: [`panic-analysis.md`](panic-analysis.md).

## T2 — IOHID `copyEvent` is closed

Source: [`../experiments/copyprobe4.m`](../experiments/copyprobe4.m)

1. Install the probe.
2. Launch and shake the device for 30 s.
3. Read `copyprobe4.log` from the app's Documents folder.

Pass criteria:

```
copyprobe4 done ok=0 attempts=245808
```

Every `sel2` call returns `0xe00002be` (`kIOReturnNoResources`). The SPU
provider never delivers a fast-path event, so the IOHID free cannot be raced
from userland on this target.

## T3 — AppleJPEG reachability and ABI

Source: [`../experiments/applejpeg/jpegprobe.m`](../experiments/applejpeg/jpegprobe.m)

1. Install the probe.
2. Launch it.
3. Read `jpegprobe.log`.

Pass criteria:

```
open type0 kr=0 conn=0x...
sel1 zero kr=0xe00002cc outSize=88
sel1 sync444 kr=0 outSize=88
sel1 async64 kr=0 outSize=88
submitted=5
```

`sel1 zero` returning `kIOReturnCannotLock` (`0xe00002cc`) is expected: there
are no IOSurfaces in the zeroed struct. `sel0`/`sel2` returning
`kIOReturnBadArgument` (`0xe00002c2`) is also expected; those selectors need
arguments this probe does not supply.

## T4 — Deferred AppleJPEG UAF

1. Install `jpegprobe`.
2. Launch it and wait for `submitted=5` / `closed after async submit`.
3. Open **Camera** manually and wait 15–20 s.
4. The phone panics and reboots.

Pass criteria:

```
pc  = ... (AppleJPEGDriver)
x5/x6 = 0xfeedfacefeedfacf
x12 = 0
far = 0x308
```

Unslid faulting instruction:

```asm
fffffff008df3418:  ldrb w12, [x12, #0x308]
```

Full analysis: [`applejpeg-panic-2026-10-30.md`](applejpeg-panic-2026-10-30.md).

## T5 — Controlled 10 s timeout

Source: [`../experiments/applejpeg/jpegreclaim.m`](../experiments/applejpeg/jpegreclaim.m)

1. Install the build with the 8000-request mass prime.
2. Launch it and wait for the mass spray to finish.
3. Watch the `cycle` lines.

Pass criteria:

```
mass spray done conn=800 req=8000 fail=0
cycle round=N sync kr=0xe00002d6 dt=10.001s
```

`0xe00002d6` is `kIOReturnTimeout`.

## T6 — Same-type reclaim

1. Same build as T5.
2. When `cycle round=N TIMEOUT -> same-conn reclaim` appears, ten async
   decodes are submitted on the same connection.
3. The kernel must survive the subsequent queue walk.

Pass criteria:

```
cycle round=N TIMEOUT -> same-conn reclaim
cycle round=N reclaim submitted=10
jpegreclaim done (no panic)
```

This is the first controlled free/reclaim window. It is **not** kernel r/w.

## T7 — Immediate close and power wedge

1. Use the build that closes the connection immediately after the reclaim
   submission (`jpegstall4`).
2. Run the mass prime and the three timeout cycles.
3. Wait; the driver is asked to power down and the watchdog fires.

Observed:

```
AppleJPEGDriver::setPowerState(0x..., 1 -> 0)
  timed out after 10210 ms @IOServicePM.cpp:5577
```

This is a repeatable DoS/hang, not the queue-walk UAF.

## T8 — Close during sync

Source: [`../experiments/applejpeg/jpegclose.m`](../experiments/applejpeg/jpegclose.m)

1. Install `jpegclose`.
2. Launch it.
3. Wait for `victim sync`, `victim close`, `reclaim submitted`, `probe`.

### Observed result (2026-10-31 01:02:05)

The close-during-sync path reproduced the **same 0x308 UAF without Camera**:

```
pc  = 0xfffffff014d23418   (0xfffffff008df3418 unslid)
lr  = 0xfffffff014d26638   (0xfffffff008df6638 unslid)
x5  = 0
x6  = 0x00000007839956d4
x12 = 0
far = 0x308
```

Call chain is identical: `finish_io_gated` → queue helper → stale
`JpegRequest`. This is a reliable UAF trigger in our own app, but it is still
a **read** UAF; the reclaim did not replace the stale object (`x12` is zero).
It is not a double-free or write primitive.

Expected variants:

| Log | Meaning |
|---|---|
| `probe` panics at `far=0x308` | inactive free left the node; persistent UAF |
| `probe kr=0xe00002d6` | probe also timed out; node present but walk delayed |
| `probe kr=0` then power-state timeout | node present, power watchdog wins |
| no panic | inactive path also dequeues; need a non-completing request |

## T9 — Reclaim storm around the inactive close

Source: [`../experiments/applejpeg/jpegclose6.m`](../experiments/applejpeg/jpegclose6.m)

The T8 panic still shows `x12=0`: the probe hit a stale node, not a reclaimed
request. T9 changes the timing:

### Variant history

- `jpegclose3`: 4032×3024 reclaims with `flags=1` (progressive bit) on a
  baseline JPEG. It still panicked at `far=0x308`, `x12=0`. The 4032 pool may
  differ from the 2048 victim/mass-spray pool, and `flags=1` may fail
  validation before the node is queued.
- `jpegclose6`: **2048×2048, `flags=0`** (valid baseline) for both storms,
  6 connections × 5 requests each, appended, with the probe 50 ms after the
  storm. This matches the victim pool and keeps valid requests in flight.
- `jpegclose5`: same as `jpegclose6` but without the mass spray, to isolate
  the victim request. Observed control: `victim sync kr=0 dt=0.004–0.008s`,
  so the decode finished **before** the 100 ms close; no stale node and no
  panic. The mass spray is required to keep the victim decode in flight.

1. Mass prime 8000 requests.
2. Start an **early reclaim storm**: 6 connections × 3 async 4032×3024
   requests, held open. This covers the mass-spray stale slots.
3. Open the victim connection, start a sync decode, close the victim during
   the decode (the `isInactive` path).
4. Start a **second reclaim storm**: 6 connections × 3 async 4032×3024
   requests, appended to the early set.
5. Probe three times while the reclaim requests are in flight.
6. Free one reclaimer connection at a time and probe after each; if the stale
   node points into that request, the next walk is a use-after-free with a
   slot we control.

Expected log:

```
early reclaim start threads=6 reqs=3
early reclaim done conns=6
victim open kr=0
victim sync kr=... dt=...
victim close kr=...
reclaim storm start threads=6 reqs=3
reclaim storm done conns=12
probe round=0 kr=...
free reclaim[0] conn=...
probe-after-free[0] kr=...
```

Pass criteria for S4:

| Observation | Meaning |
|---|---|
| `x12 != 0` in a panic | stale node points at our reclaim request |
| `far != 0x308` | different object/offset, likely write or double-free |
| `kalloc`/`zone` in backtrace | double-free detected |
| no panic after freeing a reclaimer | node was cleaned; tune the in-flight window |

## How to collect logs

### App log

Every AppleJPEG app sets `UIFileSharingEnabled`. After a run:

1. Open **Files**.
2. **On My iPhone → [jpegprobe / jpegspray / jpegreclaim / jpegclose]**.
3. Copy the `.log` file.

### Panic log

After a reboot:

1. **Settings → Privacy & Security → Analytics & Improvements → Analytics Data**.
2. Open the newest `panic-full-*.ips`.
3. Share the file.

The useful fields are `panicString`, `pc`, `lr`, `x5`, `x6`, `x12`, `far`,
`Panicked task`, and `Kernel Extensions in backtrace`.

## Direct links

- Kernel control status: [`kernel-control.md`](kernel-control.md)
- AppleJPEG CVE notes: [`applejpeg-cve-2026-20687.md`](applejpeg-cve-2026-20687.md)
- AppleJPEG panic analysis: [`applejpeg-panic-2026-10-30.md`](applejpeg-panic-2026-10-30.md)
- Full experiment log: [`experiment-log.md`](experiment-log.md)
- AppleJPEG sources: [`../experiments/applejpeg/`](../experiments/applejpeg/)
- Apple security content (26.4): https://support.apple.com/en-us/126792
- Apple security content (18.7.7): https://support.apple.com/en-us/126793
- CVE-2026-20687: https://www.cve.org/CVERecord?id=CVE-2026-20687
- Public AppleJPEG PoC: https://github.com/0xjohnnydev/CVE-2026-20687-AppleJPEGDriver-UAF
- CVE-2026-28992: https://www.cve.org/CVERecord?id=CVE-2026-28992
- Public IOHID PoC:
  https://github.com/0xjohnnydev/CVE-2026-28992-IOHIDFamily-FastPathUserClient-Race-Conditions
