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
kern_return_t IOConnectSetNotificationPort(io_connect_t connect, uint32_t type, mach_port_t port, uintptr_t reference);
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

static NSString *docsPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}
static NSString *logPath(void) {
    return [docsPath() stringByAppendingPathComponent:@"jpegmethods.log"];
}
static void appendLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[jpegmethods] %@", s);
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
    if (kr != KERN_SUCCESS || !iter) return 0;
    io_service_t svc = IOIteratorNext(iter);
    IOObjectRelease(iter);
    return svc;
}

static NSData *makeJPEG(uint32_t w, uint32_t h) {
    UIGraphicsBeginImageContext(CGSizeMake(w, h));
    [[UIColor redColor] setFill];
    UIRectFill(CGRectMake(0, 0, w, h));
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

static void callStruct(io_connect_t conn, uint32_t sel, const void *in, size_t inLen,
                       void *out, size_t outLen, NSString *label) {
    if (sel > 20) {
        appendLog(@"sel%u %@: invalid selector", sel, label);
        return;
    }
    size_t os = outLen;
    kern_return_t kr = IOConnectCallStructMethod(conn, sel, in, inLen, out, &os);
    appendLog(@"sel%u %@ kr=%#x outSize=%zu", sel, label, kr, os);
}

static IOSurfaceRef makeRawSurface(size_t len) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(len),
        (id)kIOSurfaceHeight: @1,
        (id)kIOSurfaceBytesPerElement: @1,
        (id)kIOSurfacePixelFormat: @0x20202020,
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

static void drainNotify(mach_port_t port, NSString *label) {
    if (port == MACH_PORT_NULL) return;
    uint8_t msg[0x400];
    for (int i = 0; i < 4; i++) {
        mach_msg_header_t *h = (mach_msg_header_t *)msg;
        kern_return_t kr = mach_msg(h, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                    0, sizeof(msg), port, 10, MACH_PORT_NULL);
        if (kr != MACH_MSG_SUCCESS) break;
        appendLog(@"notify %@ id=%u size=%u", label, h->msgh_id, h->msgh_size);
    }
}

static void probeMethods(void) {
    appendLog(@"build=jpegmethods2 pid=%d", getpid());

    io_service_t svc = findJPEGService();
    if (!svc) { appendLog(@"service not found"); return; }
    appendLog(@"service=%#x", svc);

    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    appendLog(@"open type0 kr=%#x conn=%#x", kr, conn);
    if (kr != KERN_SUCCESS || !conn) { IOObjectRelease(svc); return; }

    mach_port_t notify = MACH_PORT_NULL;
    kern_return_t npr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &notify);
    if (npr == KERN_SUCCESS) {
        mach_port_insert_right(mach_task_self(), notify, notify, MACH_MSG_TYPE_MAKE_SEND);
        kern_return_t nsr = IOConnectSetNotificationPort(conn, 0, notify, 0);
        appendLog(@"notify port=%#x alloc=%#x set=%#x", notify, npr, nsr);
    } else {
        appendLog(@"notify alloc failed %#x", npr);
    }

    const uint32_t W = 2048, H = 2048;
    NSData *jpegData = makeJPEG(W, H);
    IOSurfaceRef src = makeSourceSurface(jpegData);
    IOSurfaceRef dst = makeDestSurface(W, H);
    IOSurfaceRef encSrc = makeDestSurface(W, H);
    IOSurfaceRef encDst = makeRawSurface(4 * 1024 * 1024);
    appendLog(@"jpeg=%lu src=%p dst=%p encSrc=%p encDst=%p",
              (unsigned long)jpegData.length, src, dst, encSrc, encDst);
    if (!src || !dst || !encSrc || !encDst) {
        if (src) CFRelease(src);
        if (dst) CFRelease(dst);
        if (encSrc) CFRelease(encSrc);
        if (encDst) CFRelease(encDst);
        IOServiceClose(conn);
        IOObjectRelease(svc);
        return;
    }
    uint32_t srcID = IOSurfaceGetID(src);
    uint32_t dstID = IOSurfaceGetID(dst);
    uint32_t encSrcID = IOSurfaceGetID(encSrc);
    uint32_t encDstID = IOSurfaceGetID(encDst);
    appendLog(@"srcID=%u dstID=%u encSrcID=%u encDstID=%u", srcID, dstID, encSrcID, encDstID);

    AppleJPEGDriverIOStruct input;
    AppleJPEGDriverIOStruct output = {0};
    fillInput(&input, srcID, dstID, W, H, 0, 0);
    callStruct(conn, 1, &input, sizeof(input), &output, sizeof(output), @"decode sync");
    drainNotify(notify, @"sel1 sync");

    memset(&input, 0, sizeof(input));
    input.sourceID = encSrcID;
    input.destID = encDstID;
    input.field_04 = W * H * 4;
    input.field_0C = 4 * 1024 * 1024;
    input.width = W;
    input.height = H;
    input.outWidth = W;
    input.outHeight = H;
    input.subsampling = 3;
    callStruct(conn, 3, &input, sizeof(input), &output, sizeof(output), @"encode sync");
    drainNotify(notify, @"sel3");

    const int offsets[] = {0, 0x10, 0x58, 0x100};
    for (int oi = 0; oi < 4; oi++) {
        int off = offsets[oi];
        uint8_t *in = calloc(1, 0xDA0);
        uint8_t *out = calloc(1, 0xDA0);
        if (!in || !out) { free(in); free(out); continue; }
        fillInput((AppleJPEGDriverIOStruct *)(in + off), srcID, dstID, W, H, 0, 0x6161);
        NSString *label = [NSString stringWithFormat:@"async decode 0xDA0 off=%#x", off];
        callStruct(conn, 6, in, 0xDA0, out, 0xDA0, label);
        drainNotify(notify, label);
        memset(in, 0, 0xDA0);
        memset(out, 0, 0xDA0);
        fillInput((AppleJPEGDriverIOStruct *)(in + off), encSrcID, encDstID, W, H, 0, 0x7171);
        label = [NSString stringWithFormat:@"async encode 0xDA0 off=%#x", off];
        callStruct(conn, 7, in, 0xDA0, out, 0xDA0, label);
        drainNotify(notify, label);
        free(in);
        free(out);
    }

    for (int oi = 0; oi < 4; oi++) {
        int off = offsets[oi];
        uint8_t *in = calloc(1, 0x1000);
        uint8_t *out = calloc(1, 0x1000);
        if (!in || !out) { free(in); free(out); continue; }
        fillInput((AppleJPEGDriverIOStruct *)(in + off), srcID, dstID, W, H, 0, 0x6161);
        NSString *label = [NSString stringWithFormat:@"sel4 0x1000 off=%#x", off];
        callStruct(conn, 4, in, 0x1000, out, 0x1000, label);
        drainNotify(notify, label);
        memset(in, 0, 0x1000);
        memset(out, 0, 0x1000);
        fillInput((AppleJPEGDriverIOStruct *)(in + off), srcID, dstID, W, H, 0, 0x7171);
        label = [NSString stringWithFormat:@"sel5 0x1000 off=%#x", off];
        callStruct(conn, 5, in, 0x1000, out, 0x1000, label);
        drainNotify(notify, label);
        free(in);
        free(out);
    }

    uint32_t priv = 0;
    callStruct(conn, 8, &priv, sizeof(priv), NULL, 0, @"privileged 4 bytes");
    callStruct(conn, 9, NULL, 0, NULL, 0, @"privileged no args");
    callStruct(conn, 10, NULL, 0, NULL, 0, @"out of range");
    drainNotify(notify, @"end");

    IOServiceClose(conn);
    CFRelease(src);
    CFRelease(dst);
    CFRelease(encSrc);
    CFRelease(encDst);
    IOObjectRelease(svc);
    appendLog(@"jpegmethods2 done (no panic)");
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
        probeMethods();
    });
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
