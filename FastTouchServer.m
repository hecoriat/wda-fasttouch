// ===== FastTouch (appended to WebDriverAgentRunner/UITestingUITests.m by the CI build) =====
// A raw TCP server inside WebDriverAgent that injects touches straight into XCTest's
// event synthesizer, skipping WDA's per-action application lookups (~350 ms each).
//
// Protocol, one line per gesture, coordinates in PORTRAIT screen points:
//   G <hold_ms> <end_pause_ms> <x0> <y0> [<dt_ms> <x> <y>]...\n
//     finger down at (x0,y0), stay <hold_ms>, move through each point taking <dt_ms>,
//     stay <end_pause_ms>, lift.
//   P\n   ping
// Reply per line: "ok <ms>\n" (synthesizer time) or "err <message>\n".
//
// Private XCTest classes are reached through the runtime only, so nothing here can clash
// with declarations in WebDriverAgent's own private headers.

#import <UIKit/UIKit.h>
#import <objc/message.h>

// WDA builds with -Werror; casting objc_msgSend to a typed function pointer is the
// standard way to call it, so silence the strict cast warning for this code.
#pragma clang diagnostic ignored "-Wunknown-warning-option"
#pragma clang diagnostic ignored "-Wcast-function-type-strict"
#pragma clang diagnostic ignored "-Wcast-function-type"
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

static const uint16_t FTPort = 8200;

static NSString *FTPerform(NSString *line)
{
  NSMutableArray<NSString *> *p = [NSMutableArray array];
  for (NSString *s in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
    if (s.length) [p addObject:s];
  }
  if (p.count == 0) return @"err empty";
  if ([p[0] isEqualToString:@"P"]) return @"ok 0";
  if (![p[0] isEqualToString:@"G"] || p.count < 5 || (p.count - 5) % 3 != 0) return @"err bad command";

  Class pathClass = NSClassFromString(@"XCPointerEventPath");
  Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
  if (!pathClass || !recordClass) return @"err XCTest event classes not found";

  double hold = p[1].doubleValue / 1000.0, endPause = p[2].doubleValue / 1000.0;
  CGPoint start = CGPointMake(p[3].doubleValue, p[4].doubleValue);

  id path = ((id (*)(id, SEL))objc_msgSend)(pathClass, NSSelectorFromString(@"alloc"));
  path = ((id (*)(id, SEL, CGPoint, double))objc_msgSend)(
      path, NSSelectorFromString(@"initForTouchAtPoint:offset:"), start, 0.0);
  SEL moveSel = NSSelectorFromString(@"moveToPoint:atOffset:");
  double t = hold;
  for (NSUInteger i = 5; i + 2 < p.count; i += 3) {
    t += p[i].doubleValue / 1000.0;
    CGPoint pt = CGPointMake(p[i + 1].doubleValue, p[i + 2].doubleValue);
    ((void (*)(id, SEL, CGPoint, double))objc_msgSend)(path, moveSel, pt, t);
  }
  ((void (*)(id, SEL, double))objc_msgSend)(path, NSSelectorFromString(@"liftUpAtOffset:"),
                                            MAX(t + endPause, 0.01));

  // Portrait + native coordinates: no need to ask the app for its orientation.
  id record = ((id (*)(id, SEL))objc_msgSend)(recordClass, NSSelectorFromString(@"alloc"));
  record = ((id (*)(id, SEL, NSString *, NSInteger))objc_msgSend)(
      record, NSSelectorFromString(@"initWithName:interfaceOrientation:"), @"ft",
      (NSInteger)UIInterfaceOrientationPortrait);
  ((void (*)(id, SEL, id))objc_msgSend)(record, NSSelectorFromString(@"addPointerEventPath:"), path);

  id device = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"XCUIDevice"), NSSelectorFromString(@"sharedDevice"));
  SEL synthSel = NSSelectorFromString(@"eventSynthesizer");
  if (![device respondsToSelector:synthSel]) return @"err no eventSynthesizer";
  id synth = ((id (*)(id, SEL))objc_msgSend)(device, synthSel);

  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block NSString *reply = nil;
  CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
  void (^completion)(BOOL, NSError *) = ^(BOOL ok, NSError *error) {
    double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    reply = error ? [NSString stringWithFormat:@"err %@", error.localizedDescription]
                  : [NSString stringWithFormat:@"ok %.0f", ms];
    dispatch_semaphore_signal(done);
  };
  ((id (*)(id, SEL, id, id))objc_msgSend)(synth, NSSelectorFromString(@"synthesizeEvent:completion:"),
                                          record, completion);
  dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
  return reply ?: @"err timeout";
}

static void FTServeClient(int fd)
{
  int one = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  NSMutableData *buf = [NSMutableData data];
  NSData *newline = [NSData dataWithBytes:"\n" length:1];
  char chunk[4096];
  ssize_t n;
  while ((n = recv(fd, chunk, sizeof chunk, 0)) > 0) {
    [buf appendBytes:chunk length:(NSUInteger)n];
    while (true) {
      NSRange nl = [buf rangeOfData:newline options:0 range:NSMakeRange(0, buf.length)];
      if (nl.location == NSNotFound) break;
      @autoreleasepool {
        NSString *line = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, nl.location)]
                                               encoding:NSUTF8StringEncoding];
        [buf replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
        NSString *reply = [FTPerform(line ?: @"") stringByAppendingString:@"\n"];
        const char *r = reply.UTF8String;
        send(fd, r, strlen(r), 0);
      }
    }
  }
  close(fd);
}

__attribute__((constructor)) static void FTStartServer(void)
{
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(FTPort);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(srv, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(srv, 4) != 0) {
      NSLog(@"FastTouch: cannot listen on %d", FTPort);
      return;
    }
    NSLog(@"FastTouch: listening on %d", FTPort);
    while (true) {
      int fd = accept(srv, NULL, NULL);
      if (fd >= 0) FTServeClient(fd);   // one client at a time keeps gestures ordered
    }
  });
}
