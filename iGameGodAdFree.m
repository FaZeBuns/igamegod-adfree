/*
 * iGameGod-AdFree by Buns
 * For iGameGod version 0.6.7 only.
 * Blocks interstitial / StartApp ads. Not affiliated with iOSGods.
 */
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>

#define IGOD_LOG_PREFIX "[iGameGod-AdFree]"

#ifndef IGOD_ADFREE_DEBUG
#define IGOD_ADFREE_DEBUG 0
#endif

typedef void (*MSHookMessageEx_t)(Class, SEL, IMP, IMP *);

static MSHookMessageEx_t IGOD_MSHookMessageEx;
static BOOL g_baseHooksDone = NO;

static IMP orig_presentVC;
static IMP orig_wkLoadRequest;
static IMP orig_adWinMakeKey, orig_adWinSetHidden;

static void igod_log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"%@ %@", @IGOD_LOG_PREFIX, msg);
#if IGOD_ADFREE_DEBUG
    FILE *f = fopen("/var/mobile/Documents/igamegodadfree.log", "a");
    if (f) {
        fprintf(f, "%s\n", msg.UTF8String);
        fclose(f);
    }
#endif
}

static BOOL classIsAdUI(Class cls) {
    if (!cls) return NO;
    NSString *cn = NSStringFromClass(cls);
    static NSSet *exact;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exact = [NSSet setWithArray:@[
            @"_TtC13WebAdProvider28InterstitialAdViewController",
            @"_TtC13WebAdProvider8AdWindow",
            @"_TtC13WebAdProvider27WebInterstitialAdController",
            @"_TtC13WebAdProvider27WebAdInterstitialController",
            @"_TtC13WebAdProvider9AdWebView",
            @"_TtC6AppAds24InterstitialAdController",
            @"_TtC16StartAppProvider32StartAppInterstitialAdController",
            @"STAAdViewController",
            @"STASplashViewController",
            @"STAMRAIDAdViewController",
            @"STAClosableAdViewController",
        ]];
    });
    if ([exact containsObject:cn]) return YES;
    NSString *l = cn.lowercaseString;
    if ([cn hasPrefix:@"STA"] &&
        ([l containsString:@"adview"] || [l containsString:@"splash"] || [l containsString:@"mraid"]))
        return YES;
    return NO;
}

static BOOL objectIsAdUI(id obj) {
    return obj && classIsAdUI([obj class]);
}

static void tryCloseAdObject(id obj) {
    if (!obj) return;
    SEL closeSels[] = {
        sel_registerName("closeAd"),
        sel_registerName("closeAd:"),
        sel_registerName("closeAdWithAnimation:"),
        sel_registerName("dismiss"),
        NULL
    };
    for (int i = 0; closeSels[i]; i++) {
        SEL s = closeSels[i];
        if ([obj respondsToSelector:s]) {
            igod_log(@"closeAd %@ %@", NSStringFromClass([obj class]), NSStringFromSelector(s));
            if (s == sel_registerName("closeAdWithAnimation:"))
                ((void (*)(id, SEL, BOOL))objc_msgSend)(obj, s, NO);
            else if (s == sel_registerName("closeAd:"))
                ((void (*)(id, SEL, id))objc_msgSend)(obj, s, nil);
            else
                ((void (*)(id, SEL))objc_msgSend)(obj, s);
            return;
        }
    }
    if ([obj isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)obj;
        if (vc.presentingViewController)
            [vc.presentingViewController dismissViewControllerAnimated:NO completion:nil];
    }
}

static void notifyAdFinished(id obj) {
    id delegate = nil;
    @try {
        if ([obj respondsToSelector:@selector(delegate)])
            delegate = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(delegate));
    } @catch (__unused NSException *e) {}
    if (!delegate) {
        @try { delegate = [obj valueForKey:@"delegate"]; } @catch (__unused NSException *e) {}
    }
    SEL doneSels[] = {
        sel_registerName("didCloseAd"),
        sel_registerName("didCloseAd:"),
        sel_registerName("adDidFinish"),
        sel_registerName("adDidFinish:"),
        sel_registerName("onDismiss"),
        NULL
    };
    for (int i = 0; doneSels[i]; i++) {
        SEL s = doneSels[i];
        if (delegate && [delegate respondsToSelector:s]) {
            igod_log(@"notify delegate %@ %@", NSStringFromClass([delegate class]), NSStringFromSelector(s));
            if (s == sel_registerName("didCloseAd:") || s == sel_registerName("adDidFinish:"))
                ((void (*)(id, SEL, id))objc_msgSend)(delegate, s, obj);
            else
                ((void (*)(id, SEL))objc_msgSend)(delegate, s);
            return;
        }
    }
}

static void finishBlockedAd(id obj) {
    tryCloseAdObject(obj);
    notifyAdFinished(obj);
}

static BOOL urlLooksLikeAd(NSString *url) {
    if (!url.length) return NO;
    NSString *l = url.lowercaseString;
    static NSArray *needles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        needles = @[
            @"startapp", @"doubleclick", @"googlesyndication", @"googleadservices",
            @"adservice", @"adnxs", @"taboola", @"outbrain", @"mopub", @"applovin",
            @"unityads", @"ironsrc", @"chartboost", @"vungle", @"facebook.com/ads",
        ];
    });
    for (NSString *n in needles)
        if ([l containsString:n]) return YES;
    return NO;
}

static void hookInstance(Class cls, const char *selName, IMP repl, IMP *orig) {
    if (!cls || !IGOD_MSHookMessageEx) return;
    SEL sel = sel_registerName(selName);
    if (!class_getInstanceMethod(cls, sel)) return;
    IGOD_MSHookMessageEx(cls, sel, repl, orig);
}

static void IGOD_presentVC(id self, SEL _cmd, UIViewController *vc, BOOL anim, void (^comp)(void)) {
    if (objectIsAdUI(vc)) {
        igod_log(@"block present %@", NSStringFromClass([vc class]));
        finishBlockedAd(vc);
        if (comp) comp();
        return;
    }
    ((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))orig_presentVC)(self, _cmd, vc, anim, comp);
}

static void IGOD_adVC_viewWillAppear(id self, SEL _cmd, BOOL anim) {
    igod_log(@"ad vc appear %@", NSStringFromClass([self class]));
    finishBlockedAd(self);
}

static void IGOD_adWin_makeKey(id self, SEL _cmd) {
    igod_log(@"block AdWindow makeKey");
    ((void (*)(id, SEL, BOOL))orig_adWinSetHidden)(self, @selector(setHidden:), YES);
}

static void IGOD_adWin_setHidden(id self, SEL _cmd, BOOL hidden) {
    if (!hidden) hidden = YES;
    ((void (*)(id, SEL, BOOL))orig_adWinSetHidden)(self, _cmd, hidden);
}

static void IGOD_block_show(id self, SEL _cmd) {
    igod_log(@"block %@ %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd));
    finishBlockedAd(self);
}

static id IGOD_wkLoadRequest(id self, SEL _cmd, NSURLRequest *req) {
    NSString *url = req.URL.absoluteString;
    if (objectIsAdUI(self) || urlLooksLikeAd(url)) {
        igod_log(@"block WK ad url %@", url ?: @"");
        finishBlockedAd(self);
        return nil;
    }
    return ((id (*)(id, SEL, NSURLRequest *))orig_wkLoadRequest)(self, _cmd, req);
}

static void hookAdClasses(void) {
    if (!IGOD_MSHookMessageEx) return;

    const char *swiftVCs[] = {
        "_TtC13WebAdProvider28InterstitialAdViewController",
        "_TtC13WebAdProvider27WebInterstitialAdController",
        "_TtC13WebAdProvider27WebAdInterstitialController",
        "_TtC6AppAds24InterstitialAdController",
        "_TtC16StartAppProvider32StartAppInterstitialAdController",
        NULL
    };
    for (int i = 0; swiftVCs[i]; i++) {
        Class cls = objc_getClass(swiftVCs[i]);
        if (!cls) continue;
        IMP d = NULL;
        hookInstance(cls, "viewWillAppear:", (IMP)IGOD_adVC_viewWillAppear, &d);
    }

    Class adWin = objc_getClass("_TtC13WebAdProvider8AdWindow");
    if (adWin) {
        hookInstance(adWin, "makeKeyAndVisible", (IMP)IGOD_adWin_makeKey, &orig_adWinMakeKey);
        hookInstance(adWin, "setHidden:", (IMP)IGOD_adWin_setHidden, &orig_adWinSetHidden);
    }

    const char *staClasses[] = {
        "STAStartAppAd", "STAEventAdManager", "STAAdViewController",
        "STASplashViewController", "STAMRAIDAdViewController", NULL
    };
    const char *staSels[] = {
        "showAd", "showAd:", "showAdWithAdTag:", "showSplashAd", "showSplashAdIfNeeded",
        "showInterstitialSplashAdWithDelegate:withPreferences:",
        "presentAdViewController", "presentAdViewControllerIfReady", NULL
    };
    for (int c = 0; staClasses[c]; c++) {
        Class cls = objc_getClass(staClasses[c]);
        if (!cls) continue;
        for (int s = 0; staSels[s]; s++) {
            IMP d = NULL;
            hookInstance(cls, staSels[s], (IMP)IGOD_block_show, &d);
        }
    }
}

static void IGOD_installBaseHooks(void) {
    if (g_baseHooksDone) return;
    g_baseHooksDone = YES;

    void *sub = dlopen("/var/jb/usr/lib/libsubstrate.dylib", RTLD_NOW);
    if (!sub) sub = dlopen("/usr/lib/libsubstrate.dylib", RTLD_NOW);
    IGOD_MSHookMessageEx = (MSHookMessageEx_t)dlsym(sub, "MSHookMessageEx");
    if (!IGOD_MSHookMessageEx) {
        igod_log(@"MSHookMessageEx missing");
        return;
    }

    Class uvc = objc_getClass("UIViewController");
    hookInstance(uvc, "presentViewController:animated:completion:", (IMP)IGOD_presentVC, &orig_presentVC);

    Class wk = objc_getClass("WKWebView");
    hookInstance(wk, "loadRequest:", (IMP)IGOD_wkLoadRequest, &orig_wkLoadRequest);

    igod_log(@"base hooks bundle=%@", [NSBundle mainBundle].bundleIdentifier);
}

static void image_added(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (!dladdr((const void *)mh, &info) || !info.dli_fname) return;
    if (strstr(info.dli_fname, "iGameGod.framework/iGameGod") == NULL) return;
    igod_log(@"iGameGod.framework loaded — arming ad hooks");
    IGOD_installBaseHooks();
    hookAdClasses();
}

__attribute__((constructor)) static void IGOD_ctor(void) {
#if IGOD_ADFREE_DEBUG
    FILE *f = fopen("/var/mobile/Documents/igamegodadfree.log", "w");
    if (f) {
        fprintf(f, "iGameGod-AdFree ctor bundle=%s\n", [[[NSBundle mainBundle] bundleIdentifier] UTF8String]);
        fclose(f);
    }
#endif
    _dyld_register_func_for_add_image(image_added);
    IGOD_installBaseHooks();
    hookAdClasses();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        hookAdClasses();
    });
}
