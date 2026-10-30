# AppleJPEGDriver selector audit

The decoder UAF reclaim loop is stuck: the stale queue node keeps pointing at
freed poison (`x5/x6=0xfeedface...`, `x12=0`, `far=0x308`) even after
same-type storms. Instead of another reclaim variation, audit the **other
userclient methods** for a direct read/write primitive.

## Dispatch table

The public PoC describes the `AppleJPEGDriverUserClient` dispatch table
(IOUserClient2022, 10 entries):

| Selector | Method | Struct in/out | Notes |
|---|---|---|---|
| 0 | `getTarget` | none | scalar output |
| 1 | `decode` | 0x58 / 0x58 | the path used so far |
| 2 | `query` | none | scalar output |
| 3 | `encode` | 0x58 / 0x58 | JPEG encode path |
| 4 | unknown | 0x1000 / 0x1000 | large struct |
| 5 | unknown | 0x1000 / 0x1000 | large struct |
| 6 | async decode | 0xDA0 / 0xDA0 | `allowAsync=1` |
| 7 | async encode | 0xDA0 / 0xDA0 | `allowAsync=1` |
| 8 | privileged | 4 / 0 | entitlement gate |
| 9 | privileged | none | entitlement gate |

The 0xDA0 and 0x1000 structs are the interesting ones: they are large enough
to contain **user pointers**, async references, notification ports, or
buffer descriptors. A user pointer that the driver dereferences or writes in
kernel context is a direct primitive.

## Probe

`experiments/applejpeg/jpegmethods.m` opens type 0 and calls:

- `sel0`, `sel2`, `sel9`, `sel10` with no args;
- `sel1` sync + async with the valid 0x58 struct;
- `sel3` encode with the 0x58 struct (source/dest swapped);
- `sel4`/`sel5` with zeroed 0x1000 input/output buffers;
- `sel6`/`sel7` with a 0xDA0 buffer whose first 0x58 bytes are a valid decode
  request and the rest zero;
- `sel8` with a 4-byte input.

Every call logs `kr` and `outSize`. The last log line before a panic tells us
which selector is dangerous.

## First probe result (2026-10-31)

`jpegmethods` on the XR:

```
open type0 kr=0
sel0 getTarget kr=0xe00002c2
sel2 query kr=0xe00002c2
sel1 decode sync kr=0 outSize=88
sel1 decode async kr=0 outSize=88
sel3 encode sync kr=0xe00002bc outSize=88
sel4 0x1000 struct kr=0xe00002bc outSize=4096
sel5 0x1000 struct kr=0xe00002cc outSize=4096
sel6 async decode 0xDA0 kr=0xe00002bc outSize=3488
sel7 async encode 0xDA0 kr=0xe00002bc outSize=3488
sel8 privileged 4 bytes kr=0xe00002c2
sel9 privileged no args kr=0xe00002bc
sel10 out of range kr=0xe00002c2
jpegmethods done (no panic)
```

The important part: `sel4/5/6/7` are **reachable**. They return the full
output size (`4096` / `3488`), so the handler ran and rejected our input,
rather than returning `kIOReturnUnsupported`. The next probe adds a
notification port, proper encode surfaces (BGRA source, raw JPEG dest), and
tries the 0x58 decode header at offsets `0`, `0x10`, `0x58`, `0x100` inside
the 0xDA0/0x1000 structs.

`jpegmethods2` also drains the notification port after every call. If the
driver sends async completion messages, their `msgh_id`/payload may be the
first kernel-side data we can read.

## What to look for

| Observation | Meaning |
|---|---|
| `sel6 kr=0` | async 0xDA0 path is reachable; reverse its layout |
| `sel4/5 kr=0` | 0x1000 path is reachable; reverse its layout |
| `sel3 kr=0` | encode path works; test for an encoder-side UAF/write |
| `sel8/9 kr=0xe00002c1` | `kIOReturnNotPrivileged`; entitlement gate |
| panic at a selector | that selector is the next target; log identifies it |

## Static analysis plan

For each accessible selector:

1. Locate the method in the 18.7.2 kext:
   - `startEncoder` / `startEncoderExt` / `startEncoder2024`;
   - `startDecoderExt` / `startDecoder2024`.
2. Map the struct fields to request writes/reads:
   - which fields become kernel pointers;
   - which fields are copied to `IOSurface`/`DART` setup;
   - which fields are written back to userland (`copyout`).
3. Look for a field that is dereferenced or written without validation.

The goal is a **write/read primitive**, not another read UAF. A user pointer
that reaches `memcpy`/`IOMemoryDescriptor`/DART setup is the shortest path.

## Build

`jpegmethods` reuses bundle ID `com.example.hidgate4` and writes
`jpegmethods.log` in the app's Documents folder.
