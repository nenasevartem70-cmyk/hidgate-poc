#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <unistd.h>
#import <stdarg.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>
#import <time.h>

static UITextView *gLog = nil;

static NSString *docsPath(void)
{
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}
static NSString *logPath(void)
{
    return [docsPath() stringByAppendingPathComponent:@"copyprobe4.log"];
}
static void appendLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[copyprobe4] %@", s);
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
        @"SharedMemorySize": @(0x10000),
    };
    NSError *err = nil;
    return [NSPropertyListSerialization dataWithPropertyList:dict
        format:NSPropertyListXMLFormat_v1_0 options:0 error:&err];
}

static kern_return_t gateConn(io_connect_t conn, NSData *xml)
{
    uint64_t scalar = 0;
    return IOConnectCallMethod(conn, 0, &scalar, 1,
        xml.bytes, xml.length, NULL, NULL, NULL, NULL);
}

static void probeAll(void)
{
    appendLog(@"build=copyprobe4 pid=%d", getpid());
    NSData *xml = buildGateXML();

    io_iterator_t it = MACH_PORT_NULL;
    if (IOServiceGetMatchingServices(MACH_PORT_NULL,
            IOServiceMatching("IOHIDEventService"), &it) != KERN_SUCCESS) {
        appendLog(@"scan failed");
        return;
    }

    io_service_t svc = MACH_PORT_NULL;
    io_connect_t conn = MACH_PORT_NULL;
    while ((svc = IOIteratorNext(it)) != MACH_PORT_NULL) {
        conn = MACH_PORT_NULL;
        if (IOServiceOpen(svc, mach_task_self(), 2, &conn) == KERN_SUCCESS
                && conn != MACH_PORT_NULL) {
            if (gateConn(conn, xml) == KERN_SUCCESS) {
                appendLog(@"provider ok svc=%#x conn=%#x", svc, conn);
                break;
            }
            IOServiceClose(conn);
            conn = MACH_PORT_NULL;
        }
        IOObjectRelease(svc);
        svc = MACH_PORT_NULL;
    }
    IOObjectRelease(it);
    if (svc == MACH_PORT_NULL || conn == MACH_PORT_NULL) {
        appendLog(@"no provider");
        return;
    }

    int ok = 0;
    long attempts = 0;
    time_t start = time(NULL);
    while (time(NULL) - start < 30) {
        for (int a = 0; a < 4 && !ok; a++) {
            for (int b = 0; b < 4 && !ok; b++) {
                uint64_t in[2] = { (uint64_t)a, (uint64_t)b };
                uint32_t outCnt = 0;
                kern_return_t kr = IOConnectCallMethod(conn, 2,
                    in, 2, NULL, 0, NULL, &outCnt, NULL, NULL);
                attempts++;
                if (kr == KERN_SUCCESS) {
                    appendLog(@"COPY_OK a=%d b=%d attempts=%ld", a, b, attempts);
                    ok = 1;
                } else if ((attempts % 5000) == 0) {
                    appendLog(@"copy attempts=%ld a=%d b=%d kr=%#x", attempts, a, b, kr);
                }
            }
        }
        usleep(1000);
    }
    appendLog(@"copyprobe4 done ok=%d attempts=%ld", ok, attempts);
    IOServiceClose(conn);
    IOObjectRelease(svc);
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
        probeAll();
    });
    return YES;
}

@end

int main(int argc, char *argv[])
{
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
