#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#include <unistd.h>

enum { WK68_VID = 0x258A, WK68_PID = 0x010C, REPORT_ID = 0x06, REPORT_LEN = 520 };

typedef struct {
    IOHIDManagerRef manager;
    IOHIDDeviceRef device;
} WK68Connection;

static CFNumberRef Number(int value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
}

static int IntProperty(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    int result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result);
    }
    return result;
}

static IOReturn WK68Open(WK68Connection *connection) {
    memset(connection, 0, sizeof(*connection));
    connection->manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFNumberRef vid = Number(WK68_VID), pid = Number(WK68_PID);
    const void *keys[] = {CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey)};
    const void *values[] = {vid, pid};
    CFDictionaryRef matching = CFDictionaryCreate(
        kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
    );
    IOHIDManagerSetDeviceMatching(connection->manager, matching);
    CFRelease(matching); CFRelease(vid); CFRelease(pid);

    IOReturn result = IOHIDManagerOpen(connection->manager, kIOHIDOptionsTypeNone);
    if (result != kIOReturnSuccess) return result;
    CFSetRef devices = IOHIDManagerCopyDevices(connection->manager);
    if (!devices) return kIOReturnNotFound;
    CFIndex count = CFSetGetCount(devices);
    const void **items = calloc((size_t)count, sizeof(void *));
    CFSetGetValues(devices, items);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDDeviceRef candidate = (IOHIDDeviceRef)items[i];
        if (IntProperty(candidate, CFSTR(kIOHIDMaxFeatureReportSizeKey)) >= REPORT_LEN) {
            connection->device = (IOHIDDeviceRef)CFRetain(candidate);
            break;
        }
    }
    free(items); CFRelease(devices);
    if (!connection->device) return kIOReturnNotFound;
    return IOHIDDeviceOpen(connection->device, kIOHIDOptionsTypeNone);
}

static void WK68Close(WK68Connection *connection) {
    if (connection->device) {
        IOHIDDeviceClose(connection->device, kIOHIDOptionsTypeNone);
        CFRelease(connection->device);
    }
    if (connection->manager) {
        IOHIDManagerClose(connection->manager, kIOHIDOptionsTypeNone);
        CFRelease(connection->manager);
    }
    memset(connection, 0, sizeof(*connection));
}

static IOReturn SetFeature(IOHIDDeviceRef device, const uint8_t *bytes) {
    return IOHIDDeviceSetReport(
        device, kIOHIDReportTypeFeature, REPORT_ID, bytes, REPORT_LEN
    );
}

static IOReturn GetFeature(IOHIDDeviceRef device, uint8_t *bytes, CFIndex *length) {
    memset(bytes, 0, REPORT_LEN);
    *length = REPORT_LEN;
    return IOHIDDeviceGetReport(
        device, kIOHIDReportTypeFeature, REPORT_ID, bytes, length
    );
}

static IOReturn QueryModel(IOHIDDeviceRef device, uint8_t *modelA, uint8_t *modelB) {
    uint8_t request[REPORT_LEN] = {0}, response[REPORT_LEN] = {0};
    request[0] = 0x06; request[1] = 0x82; request[2] = 0x01;
    request[4] = 0x01; request[6] = 0x06;
    IOReturn result = SetFeature(device, request);
    if (result != kIOReturnSuccess) return result;
    const uint8_t expected[] = {0x06,0x82,0x01,0x00,0x01,0x00,0x06};
    CFIndex length=0;
    for (int attempt=0; attempt<3; attempt++) {
        usleep((useconds_t)(15000 + attempt*20000));
        result = GetFeature(device, response, &length);
        if (result == kIOReturnSuccess && length >= 14 && !memcmp(response,expected,sizeof(expected))) break;
    }
    if (result != kIOReturnSuccess) return result;
    if (length < 14 || memcmp(response, expected, sizeof(expected))) return kIOReturnBadArgument;
    *modelA = response[12]; *modelB = response[13];
    return kIOReturnSuccess;
}

static IOReturn ReadConfig(IOHIDDeviceRef device, uint8_t *config, CFIndex *length) {
    uint8_t request[REPORT_LEN] = {0};
    request[0] = 0x06; request[1] = 0x84; request[4] = 0x01; request[6] = 0x80;
    IOReturn result=kIOReturnError;
    for (int attempt=0; attempt<4; attempt++) {
        result=SetFeature(device,request);
        if (result == kIOReturnSuccess) {
            usleep((useconds_t)(25000 + attempt*25000));
            result=GetFeature(device,config,length);
            if (result == kIOReturnSuccess && *length >= 136 && config[0] == 0x06 &&
                config[1] == 0x84 && config[134] == 0x5A && config[135] == 0xA5) {
                *length=136;
                return kIOReturnSuccess;
            }
        }
        usleep(30000);
    }
    return result == kIOReturnSuccess ? kIOReturnBadArgument : result;
}

static IOReturn WriteConfig(IOHIDDeviceRef device, const uint8_t *config, CFIndex length) {
    if (length < 136 || config[134] != 0x5A || config[135] != 0xA5) {
        return kIOReturnBadArgument;
    }
    uint8_t request[REPORT_LEN] = {0};
    memcpy(request, config, (size_t)MIN(length, REPORT_LEN));
    request[0] = 0x06; request[1] = 0x04; request[4] = 0x01; request[6] = 0x80;
    return SetFeature(device, request);
}

static IOReturn WriteStaticColor(IOHIDDeviceRef device, uint8_t red, uint8_t green, uint8_t blue) {
    uint8_t request[REPORT_LEN] = {0};
    request[0] = 0x06; request[1] = 0x0A; request[7] = 0x02;
    // In static mode, the WK68 firmware uses the first stored RGB entry globally.
    request[29] = red; request[30] = green; request[31] = blue;
    request[514] = 0x5A; request[515] = 0xA5;
    return SetFeature(device, request);
}

static IOReturn WritePerKeyColors(IOHIDDeviceRef device, const uint8_t colors[96][3]) {
    uint8_t request[REPORT_LEN] = {0};
    request[0] = 0x06; request[1] = 0x06; request[4] = 0x01;
    request[6] = 0x7A; request[7] = 0x01;
    for (int led = 0; led < 96; led++) {
        request[8 + led] = colors[led][0];
        request[134 + led] = colors[led][1];
        request[260 + led] = colors[led][2];
    }
    return SetFeature(device, request);
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property NSTextField *status;
@property NSButton *permissionButton;
@property NSPopUpButton *effect;
@property NSSlider *brightness;
@property NSTextField *brightnessValue;
@property NSSlider *speed;
@property NSTextField *speedValue;
@property NSPopUpButton *sideLight;
@property NSPopUpButton *sideColor;
@property NSSlider *sideBrightness;
@property NSTextField *sideBrightnessValue;
@property NSSlider *sideSpeed;
@property NSTextField *sideSpeedValue;
@property NSButton *sideMulticolor;
@property NSColorWell *colorWell;
@property BOOL colorDirty;
@property NSColorWell *paintColorWell;
@property NSMutableArray<NSButton *> *keyButtons;
@property BOOL customDirty;
@property BOOL deviceReady;
@end

@implementation AppDelegate

{
    uint8_t _keyColors[96][3];
    uint8_t _savedBottom[5];
    BOOL _hasSavedBottom;
}

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size bold:(BOOL)bold {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.stringValue = text; field.editable = NO; field.selectable = NO;
    field.bordered = NO; field.drawsBackground = NO;
    field.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    return field;
}

- (void)addKey:(NSString *)title led:(NSInteger)led x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width to:(NSView *)view {
    NSButton *button=[[NSButton alloc] initWithFrame:NSMakeRect(x,y,width,34)];
    button.title=title; button.font=[NSFont systemFontOfSize:10]; button.bezelStyle=NSBezelStyleRegularSquare;
    button.buttonType=NSButtonTypeToggle;
    button.tag=led; button.target=self; button.action=@selector(paintKey:);
    button.wantsLayer=YES; button.layer.cornerRadius=4;
    button.layer.backgroundColor=NSColor.controlBackgroundColor.CGColor;
    [view addSubview:button]; [self.keyButtons addObject:button];
}

- (void)addKeyboardTo:(NSView *)view {
    self.keyButtons=[NSMutableArray array];
    NSArray *rows=@[
      @[@[@"Esc",@1,@1.0],@[@"1",@7,@1.0],@[@"2",@13,@1.0],@[@"3",@19,@1.0],@[@"4",@25,@1.0],@[@"5",@31,@1.0],@[@"6",@37,@1.0],@[@"7",@43,@1.0],@[@"8",@49,@1.0],@[@"9",@55,@1.0],@[@"0",@61,@1.0],@[@"-",@67,@1.0],@[@"=",@73,@1.0],@[@"⌫",@79,@1.7]],
      @[@[@"Tab",@2,@1.35],@[@"Q",@8,@1.0],@[@"W",@14,@1.0],@[@"E",@20,@1.0],@[@"R",@26,@1.0],@[@"T",@32,@1.0],@[@"Y",@38,@1.0],@[@"U",@44,@1.0],@[@"I",@50,@1.0],@[@"O",@56,@1.0],@[@"P",@62,@1.0],@[@"[",@68,@1.0],@[@"]",@74,@1.0],@[@"\\",@80,@1.35],@[@"Del",@92,@1.0]],
      @[@[@"Caps",@3,@1.6],@[@"A",@9,@1.0],@[@"S",@15,@1.0],@[@"D",@21,@1.0],@[@"F",@27,@1.0],@[@"G",@33,@1.0],@[@"H",@39,@1.0],@[@"J",@45,@1.0],@[@"K",@51,@1.0],@[@"L",@57,@1.0],@[@";",@63,@1.0],@[@"'",@69,@1.0],@[@"Return",@81,@1.8],@[@"PgUp",@93,@1.0]],
      @[@[@"Shift",@4,@2.0],@[@"Z",@10,@1.0],@[@"X",@16,@1.0],@[@"C",@22,@1.0],@[@"V",@28,@1.0],@[@"B",@34,@1.0],@[@"N",@40,@1.0],@[@"M",@46,@1.0],@[@",",@52,@1.0],@[@".",@58,@1.0],@[@"/",@64,@1.0],@[@"Shift",@82,@1.55],@[@"↑",@88,@1.0],@[@"PgDn",@94,@1.0]],
      @[@[@"Ctrl",@5,@1.2],@[@"⌘",@11,@1.2],@[@"Alt",@17,@1.2],@[@"Space",@35,@5.0],@[@"Alt",@53,@1.2],@[@"Fn",@59,@1.2],@[@"←",@83,@1.0],@[@"↓",@89,@1.0],@[@"→",@95,@1.0]]
    ];
    CGFloat ys[]={365,325,285,245,205};
    for (NSInteger row=0; row<rows.count; row++) {
        CGFloat x=30;
        for (NSArray *item in rows[row]) {
            CGFloat width=42.0*[item[2] doubleValue];
            [self addKey:item[0] led:[item[1] integerValue] x:x y:ys[row] width:width to:view];
            x += width+4;
        }
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    memset(_keyColors,0,sizeof(_keyColors));
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,850,780)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"WK68 Control";
    [self.window center];
    NSView *view = self.window.contentView;

    [view addSubview:[self label:@"WEIKAV WK68" frame:NSMakeRect(28,732,300,32) size:24 bold:YES]];
    [view addSubview:[self label:@"Full lighting control · wired USB · changes apply automatically" frame:NSMakeRect(29,708,520,22) size:13 bold:NO]];
    self.status = [self label:@"Checking keyboard…" frame:NSMakeRect(29,678,760,22) size:13 bold:YES];
    [view addSubview:self.status];
    self.permissionButton=[[NSButton alloc] initWithFrame:NSMakeRect(650,670,170,32)];
    self.permissionButton.title=@"Fix Input Permission"; self.permissionButton.hidden=YES;
    self.permissionButton.target=self; self.permissionButton.action=@selector(fixPermission:); [view addSubview:self.permissionButton];

    [view addSubview:[self label:@"Key effect" frame:NSMakeRect(30,634,100,22) size:13 bold:YES]];
    self.effect = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(140,629,300,30) pullsDown:NO];
    NSArray *effects = @[
        @[@"Off",@0], @[@"Fixed On",@1], @[@"Respire",@2], @[@"Rainbow",@3],
        @[@"Flash Away",@4], @[@"Raindrops",@5], @[@"Rainbow Wheel",@6],
        @[@"Ripples Shining",@7], @[@"Stars Twinkle",@8], @[@"Shadow Disappear",@9],
        @[@"Retro Snake",@10], @[@"Neon Stream",@11], @[@"Reaction",@12],
        @[@"Sine Wave",@13], @[@"Retinue Scanning",@14], @[@"Rotating Windmill",@15],
        @[@"Colorful Waterfall",@16], @[@"Blossoming",@17], @[@"Rotating Storm",@18],
        @[@"Custom Per-Key",@21]
    ];
    for (NSArray *item in effects) {
        [self.effect addItemWithTitle:item[0]];
        self.effect.lastItem.tag = [item[1] integerValue];
    }
    self.effect.target=self; self.effect.action=@selector(controlChanged:);
    [view addSubview:self.effect];

    [view addSubview:[self label:@"Key brightness" frame:NSMakeRect(470,634,90,22) size:13 bold:YES]];
    self.brightness = [[NSSlider alloc] initWithFrame:NSMakeRect(570,630,205,26)];
    self.brightness.minValue=1; self.brightness.maxValue=4; self.brightness.numberOfTickMarks=4;
    self.brightness.allowsTickMarkValuesOnly=YES; self.brightness.target=self; self.brightness.action=@selector(updateValues:);
    [view addSubview:self.brightness];
    self.brightnessValue=[self label:@"4 / 4" frame:NSMakeRect(790,634,55,22) size:13 bold:NO];
    [view addSubview:self.brightnessValue];

    [view addSubview:[self label:@"Key speed" frame:NSMakeRect(470,586,90,22) size:13 bold:YES]];
    self.speed = [[NSSlider alloc] initWithFrame:NSMakeRect(570,582,205,26)];
    self.speed.minValue=0; self.speed.maxValue=4; self.speed.numberOfTickMarks=5;
    self.speed.allowsTickMarkValuesOnly=YES; self.speed.target=self; self.speed.action=@selector(updateValues:);
    [view addSubview:self.speed];
    self.speedValue=[self label:@"0 / 4" frame:NSMakeRect(790,586,55,22) size:13 bold:NO];
    [view addSubview:self.speedValue];

    [view addSubview:[self label:@"Bottom mode" frame:NSMakeRect(30,586,100,22) size:13 bold:YES]];
    self.sideLight = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(140,581,200,30) pullsDown:NO];
    for (NSString *title in @[@"Off", @"Rainbow", @"Mixed breathing", @"Static", @"Breathing"]) {
        [self.sideLight addItemWithTitle:title];
    }
    self.sideLight.target=self; self.sideLight.action=@selector(controlChanged:);
    [view addSubview:self.sideLight];

    self.sideMulticolor=[[NSButton alloc] initWithFrame:NSMakeRect(350,584,110,24)];
    self.sideMulticolor.buttonType=NSButtonTypeSwitch; self.sideMulticolor.title=@"Multicolor";
    self.sideMulticolor.target=self; self.sideMulticolor.action=@selector(controlChanged:);
    [view addSubview:self.sideMulticolor];

    [view addSubview:[self label:@"Bottom color" frame:NSMakeRect(30,538,90,22) size:13 bold:YES]];
    self.sideColor=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(120,533,140,30) pullsDown:NO];
    for (NSString *title in @[@"Red",@"Green",@"Blue",@"Yellow",@"Cyan",@"Magenta",@"White"]) [self.sideColor addItemWithTitle:title];
    self.sideColor.target=self; self.sideColor.action=@selector(controlChanged:); [view addSubview:self.sideColor];

    [view addSubview:[self label:@"Brightness" frame:NSMakeRect(275,538,75,22) size:13 bold:YES]];
    self.sideBrightness=[[NSSlider alloc] initWithFrame:NSMakeRect(350,534,115,26)];
    self.sideBrightness.minValue=0; self.sideBrightness.maxValue=4; self.sideBrightness.numberOfTickMarks=5;
    self.sideBrightness.allowsTickMarkValuesOnly=YES; self.sideBrightness.target=self; self.sideBrightness.action=@selector(updateValues:);
    [view addSubview:self.sideBrightness];
    self.sideBrightnessValue=[self label:@"4 / 4" frame:NSMakeRect(470,538,45,22) size:12 bold:NO]; [view addSubview:self.sideBrightnessValue];

    [view addSubview:[self label:@"Speed" frame:NSMakeRect(520,538,48,22) size:13 bold:YES]];
    self.sideSpeed=[[NSSlider alloc] initWithFrame:NSMakeRect(570,534,115,26)];
    self.sideSpeed.minValue=0; self.sideSpeed.maxValue=4; self.sideSpeed.numberOfTickMarks=5;
    self.sideSpeed.allowsTickMarkValuesOnly=YES; self.sideSpeed.target=self; self.sideSpeed.action=@selector(updateValues:);
    [view addSubview:self.sideSpeed];
    self.sideSpeedValue=[self label:@"0 / 4" frame:NSMakeRect(690,538,45,22) size:12 bold:NO]; [view addSubview:self.sideSpeedValue];
    NSButton *restoreBottom=[[NSButton alloc] initWithFrame:NSMakeRect(742,531,80,32)];
    restoreBottom.title=@"Restore"; restoreBottom.toolTip=@"Restore the bottom-light settings captured when the app opened";
    restoreBottom.target=self; restoreBottom.action=@selector(restoreBottom:); [view addSubview:restoreBottom];

    [view addSubview:[self label:@"Universal color" frame:NSMakeRect(30,478,110,22) size:13 bold:YES]];
    self.colorWell = [[NSColorWell alloc] initWithFrame:NSMakeRect(140,474,76,30)];
    self.colorWell.color = NSColor.whiteColor;
    self.colorWell.target = self; self.colorWell.action = @selector(colorChanged:);
    [view addSubview:self.colorWell];
    [view addSubview:[self label:@"sets every key and selects Fixed On" frame:NSMakeRect(230,478,240,22) size:11 bold:NO]];

    [view addSubview:[self label:@"Per-key paint" frame:NSMakeRect(470,478,90,22) size:13 bold:YES]];
    self.paintColorWell=[[NSColorWell alloc] initWithFrame:NSMakeRect(560,474,76,30)];
    self.paintColorWell.color=NSColor.systemBlueColor; [view addSubview:self.paintColorWell];
    NSButton *fill=[[NSButton alloc] initWithFrame:NSMakeRect(650,472,80,32)];
    fill.title=@"Fill All"; fill.target=self; fill.action=@selector(fillCustom:); [view addSubview:fill];
    NSButton *clear=[[NSButton alloc] initWithFrame:NSMakeRect(735,472,80,32)];
    clear.title=@"Clear"; clear.target=self; clear.action=@selector(clearCustom:); [view addSubview:clear];

    NSBox *line=[[NSBox alloc] initWithFrame:NSMakeRect(28,450,794,1)]; line.boxType=NSBoxSeparator; [view addSubview:line];
    [view addSubview:[self label:@"Custom per-key editor" frame:NSMakeRect(30,420,250,24) size:16 bold:YES]];
    [view addSubview:[self label:@"Choose a paint color, then click keys. Edits are batched briefly and applied automatically." frame:NSMakeRect(220,422,590,20) size:11 bold:NO]];
    [self addKeyboardTo:view];

    NSButton *refresh = [[NSButton alloc] initWithFrame:NSMakeRect(720,724,100,34)];
    refresh.title=@"Refresh"; refresh.bezelStyle=NSBezelStyleRounded; refresh.target=self; refresh.action=@selector(refresh:);
    [view addSubview:refresh];
    [view addSubview:[self label:@"WK68 profile 01 CA · 66-key map from Weikav’s official driver · unknown config bytes preserved" frame:NSMakeRect(30,3,760,18) size:10 bold:NO]];

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self refresh:nil];
}

- (void)updateValues:(id)sender {
    self.brightnessValue.stringValue=[NSString stringWithFormat:@"%ld / 4",self.brightness.integerValue];
    self.speedValue.stringValue=[NSString stringWithFormat:@"%ld / 4",self.speed.integerValue];
    self.sideBrightnessValue.stringValue=[NSString stringWithFormat:@"%ld / 4",self.sideBrightness.integerValue];
    self.sideSpeedValue.stringValue=[NSString stringWithFormat:@"%ld / 4",self.sideSpeed.integerValue];
    if (sender && self.deviceReady) [self scheduleApply];
}

- (void)controlChanged:(id)sender {
    if (self.deviceReady) [self scheduleApply];
}

- (void)restoreBottom:(id)sender {
    if (!_hasSavedBottom) return;
    [self.sideLight selectItemAtIndex:MIN(4,_savedBottom[0])];
    self.sideSpeed.integerValue=MIN(4,_savedBottom[3]);
    self.sideBrightness.integerValue=MIN(4,_savedBottom[2]);
    [self.sideColor selectItemAtIndex:MIN(6,_savedBottom[1])];
    self.sideMulticolor.state=_savedBottom[4] ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateValues:nil];
    if (self.deviceReady) [self scheduleApply];
}

- (void)colorChanged:(id)sender {
    NSInteger staticIndex=[self.effect indexOfItemWithTag:1];
    if (staticIndex >= 0) [self.effect selectItemAtIndex:staticIndex];
    self.colorDirty=YES;
    if (self.deviceReady) [self scheduleApply];
}

- (void)selectCustomEffect {
    NSInteger customIndex=[self.effect indexOfItemWithTag:21];
    if (customIndex >= 0) [self.effect selectItemAtIndex:customIndex];
    self.customDirty=YES;
}

- (void)setButton:(NSButton *)button color:(NSColor *)color {
    NSColor *rgb=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSInteger led=button.tag;
    _keyColors[led][0]=(uint8_t)lrint(rgb.redComponent*255.0);
    _keyColors[led][1]=(uint8_t)lrint(rgb.greenComponent*255.0);
    _keyColors[led][2]=(uint8_t)lrint(rgb.blueComponent*255.0);
    button.layer.backgroundColor=rgb.CGColor;
    CGFloat luminance=0.2126*rgb.redComponent+0.7152*rgb.greenComponent+0.0722*rgb.blueComponent;
    button.contentTintColor=luminance > 0.55 ? NSColor.blackColor : NSColor.whiteColor;
}

- (void)paintKey:(NSButton *)sender {
    NSColor *color=(sender.state == NSControlStateValueOn) ? self.paintColorWell.color : NSColor.blackColor;
    [self setButton:sender color:color];
    [self selectCustomEffect];
    if (self.deviceReady) [self scheduleApply];
}

- (void)fillCustom:(id)sender {
    for (NSButton *button in self.keyButtons) {
        button.state=NSControlStateValueOn;
        [self setButton:button color:self.paintColorWell.color];
    }
    [self selectCustomEffect];
    if (self.deviceReady) [self scheduleApply];
}

- (void)clearCustom:(id)sender {
    for (NSButton *button in self.keyButtons) {
        button.state=NSControlStateValueOff;
        [self setButton:button color:NSColor.blackColor];
    }
    [self selectCustomEffect];
    if (self.deviceReady) [self scheduleApply];
}

- (void)scheduleApply {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applySettings) object:nil];
    self.status.stringValue=@"Applying…"; self.status.textColor=NSColor.secondaryLabelColor;
    [self performSelector:@selector(applySettings) withObject:nil afterDelay:0.18];
}

- (void)showError:(NSString *)message result:(IOReturn)result {
    self.deviceReady=NO;
    if (result == kIOReturnNotPermitted) {
        self.status.stringValue=@"Input Monitoring needs approval for this final build";
        self.status.textColor=NSColor.systemOrangeColor;
        self.permissionButton.hidden=NO;
    } else {
        self.status.stringValue=[NSString stringWithFormat:@"%@: 0x%08x",message,result];
        self.status.textColor=NSColor.systemRedColor;
        self.permissionButton.hidden=YES;
    }
}

- (void)fixPermission:(id)sender {
    IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
    NSURL *url=[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"];
    [[NSWorkspace sharedWorkspace] openURL:url];
    self.status.stringValue=@"Enable WK68 Control, then return here and click Refresh";
}

- (void)refresh:(id)sender {
    WK68Connection connection; IOReturn result=WK68Open(&connection);
    if (result != kIOReturnSuccess) { [self showError:@"Keyboard unavailable" result:result]; WK68Close(&connection); return; }
    uint8_t a=0,b=0; result=QueryModel(connection.device,&a,&b);
    if (result != kIOReturnSuccess || a != 0x01 || b != 0xCA) {
        [self showError:@"Unexpected keyboard model; writes disabled" result:result ?: kIOReturnUnsupported];
        WK68Close(&connection); return;
    }
    uint8_t config[REPORT_LEN]; CFIndex length;
    result=ReadConfig(connection.device,config,&length); WK68Close(&connection);
    if (result != kIOReturnSuccess) { [self showError:@"Could not safely read config" result:result]; return; }

    NSInteger effectID=config[18];
    NSInteger index=[self.effect indexOfItemWithTag:effectID];
    if (index >= 0) [self.effect selectItemAtIndex:index];
    NSInteger offset=64+2*effectID;
    NSInteger bright=(offset < length-2) ? config[offset] : 4;
    NSInteger speedValue=(offset+1 < length-2) ? ((config[offset+1]>>4)&0x0F) : 0;
    self.brightness.integerValue=MAX(1,MIN(4,bright));
    self.speed.integerValue=MIN(4,speedValue);
    [self.sideLight selectItemAtIndex:MIN(4,config[26])];
    self.sideSpeed.integerValue=MIN(4,config[29]);
    self.sideBrightness.integerValue=MIN(4,config[28]);
    [self.sideColor selectItemAtIndex:MIN(6,config[27])];
    self.sideMulticolor.state=config[30] ? NSControlStateValueOn : NSControlStateValueOff;
    if (!_hasSavedBottom) {
        memcpy(_savedBottom,&config[26],sizeof(_savedBottom));
        _hasSavedBottom=YES;
    }
    [self updateValues:nil];
    self.status.stringValue=@"Connected · model 01 CA · configuration verified";
    self.status.textColor=NSColor.systemGreenColor; self.permissionButton.hidden=YES; self.deviceReady=YES;
}

- (void)applySettings {
    WK68Connection connection; IOReturn result=WK68Open(&connection);
    if (result != kIOReturnSuccess) { [self showError:@"Keyboard unavailable" result:result]; WK68Close(&connection); return; }
    uint8_t a=0,b=0; result=QueryModel(connection.device,&a,&b);
    if (result != kIOReturnSuccess || a != 0x01 || b != 0xCA) {
        [self showError:@"Model safety check failed" result:result ?: kIOReturnUnsupported]; WK68Close(&connection); return;
    }
    NSInteger effectID=self.effect.selectedItem.tag;
    BOOL shouldWriteColor=self.colorDirty && effectID == 1;
    BOOL shouldWriteCustom=self.customDirty && effectID == 21;
    if (shouldWriteColor) {
        NSColor *rgb=[self.colorWell.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        uint8_t red=(uint8_t)lrint(rgb.redComponent*255.0);
        uint8_t green=(uint8_t)lrint(rgb.greenComponent*255.0);
        uint8_t blue=(uint8_t)lrint(rgb.blueComponent*255.0);
        result=WriteStaticColor(connection.device,red,green,blue);
        if (result != kIOReturnSuccess) { [self showError:@"Color write failed" result:result]; WK68Close(&connection); return; }
    }
    if (shouldWriteCustom) {
        result=WritePerKeyColors(connection.device,_keyColors);
        if (result != kIOReturnSuccess) { [self showError:@"Per-key color write failed" result:result]; WK68Close(&connection); return; }
    }
    if (shouldWriteColor || shouldWriteCustom) usleep(50000);
    uint8_t config[REPORT_LEN]; CFIndex length;
    result=ReadConfig(connection.device,config,&length);
    if (result != kIOReturnSuccess) { [self showError:@"Config safety check failed" result:result]; WK68Close(&connection); return; }
    config[17]=(effectID == 21) ? 1 : 0;
    config[18]=(uint8_t)effectID;
    config[26]=(uint8_t)self.sideLight.indexOfSelectedItem;
    config[27]=(uint8_t)self.sideColor.indexOfSelectedItem;
    config[28]=(uint8_t)self.sideBrightness.integerValue;
    config[29]=(uint8_t)self.sideSpeed.integerValue;
    config[30]=(self.sideMulticolor.state == NSControlStateValueOn) ? 1 : 0;
    NSInteger offset=64+2*effectID;
    if (offset+1 >= length-2) { [self showError:@"Effect is outside safe config range" result:kIOReturnBadArgument]; WK68Close(&connection); return; }
    config[offset]=(uint8_t)self.brightness.integerValue;
    config[offset+1]=(config[offset+1]&0x0F)|((uint8_t)self.speed.integerValue<<4);
    result=WriteConfig(connection.device,config,length); WK68Close(&connection);
    if (result != kIOReturnSuccess) { [self showError:@"Apply failed" result:result]; return; }
    if (shouldWriteColor) self.colorDirty=NO;
    if (shouldWriteCustom) self.customDirty=NO;
    self.status.stringValue=@"Applied successfully"; self.status.textColor=NSColor.systemGreenColor;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app=[NSApplication sharedApplication];
        AppDelegate *delegate=[AppDelegate new]; app.delegate=delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
