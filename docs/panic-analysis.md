# Panic analysis — iOS 18.7.2 / iPhone XR

Redacted analysis of the panic produced by `hidgate4` on the test device.
Device-specific identifiers (crash reporter key, boot session UUID, incident
ID, container UUIDs) are intentionally omitted.

## Environment

```
Product:        iPhone11,8 (iPhone XR, A12)
OS:             iPhone OS 18.7.2 (22H124)
Kernel:         Darwin 24.6.0
                xnu-11417.140.69.702.20~1/RELEASE_ARM64_T8020
Kernel slide:   0x1bc40000
Text exec slide:0x1ca3c000
```

## Panic

```
Panicked task ... pid ...: hidgate4
Panicked thread ... tid ...

Kernel data abort
pc  = 0xfffffff02405c388
lr  = 0xfffffff024f7bb84
x0  = 0xffffffdf68bdbe98
x16 = 0x0020000000000000
far = 0x0020000000000038
esr = 0x0000000096000004
```

`far` is exactly `x16 + 0x38`, and `esr` is a data abort. The faulting
instruction, after applying the kernel slide, is:

```asm
0xfffffff008424388:  ldr x8, [x16, #0x38]!
```

This is a pre-indexed load through `x16`. The preceding code loads `x16` from
the object pointer and authenticates it as a data pointer:

```asm
ldr  x16, [x0]
mov  x17, x0
movk x17, #0xcda1, lsl #48
autda x16, x17
ldr  x8, [x16, #0x38]!
...
blraa x8, x17
```

In other words, the kernel took an object at `x0`, read its first field
(vtable/data pointer), authenticated it, and then tried to use it. The
authenticated value was `0x0020000000000000` — not a valid kernel pointer.

## Backtrace

```
lr: 0xfffffff02405c388   <- faulting virtual call
lr: 0xfffffff024f7bb84   <- AppleSPU
lr: 0xfffffff024f55910   <- AppleSPU
lr: 0xfffffff0256544b4   <- IOHIDFamily
lr: 0xfffffff025653e24   <- IOHIDFamily
lr: 0xfffffff02413349c   <- kernel
lr: 0xfffffff02560c0dc   <- IOHIDFamily
lr: 0xfffffff024188584   <- kernel
lr: 0xfffffff02418883c   <- kernel
...
```

Kernel extensions in the backtrace:

```
com.apple.iokit.IOHIDFamily(2.0)
com.apple.driver.AppleSPU(1.0)
```

The IOHIDFamily frames map to its load range:

```
IOHIDFamily @ 0xfffffff025606830 -> 0xfffffff02566ac37
```

## Interpretation

This is not a NULL dereference or a simple assertion. The kernel is iterating
provider-side state and calling a virtual method through an object whose first
field has been replaced with an invalid value. That is consistent with a
use-after-free / stale object in the FastPath open/teardown path:

- `sel0` opens/gates a connection;
- `sel1`/teardown frees provider-facing state;
- the open path continues to walk that state and dispatches through the
  corrupted object pointer.

The `x16` value (`0x0020000000000000`) looks like allocator metadata or a
partially overwritten pointer rather than a controlled user value. This is why
the PoC currently produces a crash, not a controlled primitive.

## What would be needed next

To turn this into a kernel read/write primitive, the freed object would need to
be reclaimed with controlled data of the same size/zone, and the virtual call
at `+0x38` would need to reach a fake vtable/ROP target. That also requires a
runtime KASLR leak and a PAC-compatible control-flow target. None of that is
implemented here.

## Reproduction

The crash was produced by [`PoC/main.m`](../PoC/main.m). It is intentionally
aggressive and reboots the device. Do not run it on a primary phone.
