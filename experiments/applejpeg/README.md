# AppleJPEGDriver experiments (CVE-2026-20687)

Standalone iOS apps for the 18.7.2 / A12 AppleJPEGDriver UAF. All builds reuse
the bundle ID `com.example.hidgate4` so a free Sideloadly account does not
spend a new App ID.

| Source | Purpose |
|---|---|
| `jpegprobe.m` | Reachability + ABI probe. Opens `AppleJPEGDriver` type 0, checks selectors, does one sync/async decode, then five 2048×2048 async decodes and a close. |
| `jpegspray.m` | Aggressive prime: 8 threads × 125 iterations × 10 async decodes, then a sync trigger and Camera prompt. |
| `jpegreclaim.m` | Reclaim race: prime, then a sync decode expected to return `kIOReturnTimeout` (`0xe00002d6`), while four threads allocate same-type `JpegRequest`s to reuse the freed slot. |

## Build

The build environment is the same as the main PoC: clang with the iPhoneOS
16.5 SDK, `-target arm64-apple-ios15.0`, link `UIKit`, `Foundation`, `IOKit`,
`IOSurface`, and `libobjc`. The IPA packager is in
`../../scripts/` or the private build tree.

## Status

`jpegprobe` confirmed the userclient and the `0x58` decode ABI on the target.
Opening Camera after the prime produced a deferred kernel data abort in
`AppleJPEGDriver 7.6.9`:

```
pc  = 0xfffffff01157f418   (0xfffffff008df3418 unslid)
lr  = 0xfffffff011582638   (0xfffffff008df6638 unslid)
x5  = 0xfeedfacefeedfacf
x6  = 0xfeedfacefeedfacf
x12 = 0
far = 0x308
```

Faulting instruction: `ldrb w12, [x12, #0x308]` in the queue helper called by
`finish_io_gated`. Full analysis:
[`../../docs/applejpeg-panic-2026-10-30.md`](../../docs/applejpeg-panic-2026-10-30.md).

`jpegreclaim` is the next step: reclaim the freed `JpegRequest` with a live
same-type request and turn the read UAF into a double-free/write primitive.
