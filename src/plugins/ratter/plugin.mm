#import <Cocoa/Cocoa.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "../../api/plugin_api.h"
#include "../../common/accessibility/display.h"
#include "../../common/accessibility/application.h"
#include "../../common/accessibility/window.h"
#include "../../common/accessibility/element.h"
#include "../../common/border/border.h"
#include "../../common/config/tokenize.h"
#include "../../common/config/cvar.h"
#include "../../common/misc/assert.h"

#include "../../common/accessibility/display.mm"
#include "../../common/accessibility/window.cpp"
#include "../../common/accessibility/element.cpp"
#include "../../common/config/tokenize.cpp"
#include "../../common/config/cvar.cpp"
#include "../../common/border/border.mm"

extern chunkwm_log *c_log;
chunkwm_log *c_log;

#define internal static
#define DESKTOP_MODE_BSP      0
#define DESKTOP_MODE_MONOCLE  1
#define DESKTOP_MODE_FLOATING 2

#define UP    0
#define RIGHT 1
#define DOWN  2
#define LEFT  3

// an overlay draws a rectangle in the view
struct overlay
{
    int BorderWidth;
    int BorderRadius;
    unsigned BorderColor;
    unsigned BackgroundColor;

    NSWindow *Handle;
    OverlayView *View;
};

// a mask is the opposite of an overlay. Everything *outside* the rectangle is covered.
struct mask
{
    int Top;
    int Right;
    int Bottom;
    int Left;
    overlay *InsideOverlay;
    overlay *TopOverlay;
    overlay *RightOverlay;
    overlay *BottomOverlay;
    overlay *LeftOverlay;
};

@interface TimerManager : NSObject {
}
- (void)ClearLocator;
- (void)ResetLocatorCancelTimer;
- (void)ClearLocatorCancelTimer;
- (void)FinishMove;
- (void)ResetMoveCancelTimer;
- (void)ClearMoveCancelTimer;
@end

internal NSTimer *LocatorCancelTimer;
internal NSTimer *MoveCancelTimer;
internal TimerManager *timerManager;
internal bool ResetBeforeMove;
internal bool ShowMask;
internal chunkwm_api API;
internal mask *Mask;
internal overlay *Locator;

static void
InitOverlay(overlay *Overlay, int X, int Y, int W, int H)
{
    NSRect GraphicsRect = NSMakeRect(X, Y, W, H);
    Overlay->Handle = [[NSWindow alloc] initWithContentRect: GraphicsRect
                                       styleMask: NSWindowStyleMaskBorderless
                                       backing: NSBackingStoreBuffered
                                       defer: NO];
    Overlay->View = [[[OverlayView alloc] initWithFrame:GraphicsRect] autorelease];

    Overlay->View->Width = Overlay->BorderWidth;
    Overlay->View->Radius = Overlay->BorderRadius;
    Overlay->View->Color = Overlay->BorderColor;

    NSColor *BackgroundColor = ColorFromHex(Overlay->BackgroundColor);
    [Overlay->Handle setContentView:Overlay->View];
    [Overlay->Handle setIgnoresMouseEvents:YES];
    [Overlay->Handle setHasShadow:NO];
    [Overlay->Handle setOpaque:NO];
    [Overlay->Handle setBackgroundColor: BackgroundColor];
    [Overlay->Handle setCollectionBehavior:NSWindowCollectionBehaviorDefault];
    [Overlay->Handle setAnimationBehavior:NSWindowAnimationBehaviorNone];
    [Overlay->Handle setLevel:NSFloatingWindowLevel];
    [Overlay->Handle makeKeyAndOrderFront:nil];
    [Overlay->Handle setReleasedWhenClosed:YES];

    [Overlay->View display];
}

internal overlay *
CreateOverlay(int X, int Y, int W, int H, int BorderWidth, int BorderRadius, unsigned int BorderColor, unsigned int BackgroundColor)
{
    overlay *Overlay = (overlay *) malloc(sizeof(overlay));

    Overlay->BorderWidth = BorderWidth;
    Overlay->BorderRadius = BorderRadius;
    Overlay->BorderColor = BorderColor;
    Overlay->BackgroundColor = BackgroundColor;

    if ([NSThread isMainThread]) {
        NSAutoreleasePool *Pool = [[NSAutoreleasePool alloc] init];
        InitOverlay(Overlay, X, Y, W, H);
        [Pool release];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^(void)
        {
            NSAutoreleasePool *Pool = [[NSAutoreleasePool alloc] init];
            InitOverlay(Overlay, X, Y, W, H);
            [Pool release];
        });
    }

    return Overlay;
}

internal void
UpdateOverlayRect(overlay *Overlay, int X, int Y, int W, int H)
{
    if ([NSThread isMainThread]) {
        NSAutoreleasePool *Pool = [[NSAutoreleasePool alloc] init];
        [Overlay->Handle setFrame:NSMakeRect(X, Y, W, H) display:YES animate:NO];
        [Pool release];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^(void)
        {
            NSAutoreleasePool *Pool = [[NSAutoreleasePool alloc] init];
            [Overlay->Handle setFrame:NSMakeRect(X, Y, W, H) display:YES animate:NO];
            [Pool release];
        });
    }
}

internal void
DestroyOverlay(overlay *Overlay)
{
    if ([NSThread isMainThread]) {
        NSAutoreleasePool *Pool = [[NSAutoreleasePool alloc] init];
        [Overlay->Handle orderOut:nil];
        [Overlay->Handle close];
        [Pool release];
        free(Overlay);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^(void)
        {
            NSAutoreleasePool *Pool = [[NSAutoreleasePool alloc] init];
            [Overlay->Handle orderOut:nil];
            [Overlay->Handle close];
            [Pool release];
            free(Overlay);
        });
    }
}

internal CGRect
GetDisplayBounds()
{
    CGRect DisplayBounds;
    // TODO: Main display is always the big one afaict, so this will not be good enough.
    CFStringRef DisplayRef = AXLibGetDisplayIdentifierForMainDisplay();
    if (DisplayRef) {
        DisplayBounds = AXLibGetDisplayBounds(DisplayRef);
        CFRelease(DisplayRef);
    }
    return DisplayBounds;
}

internal void
CreateLocator(int X, int Y)
{
    int W = CVarIntegerValue("ratter_locator_width");
    int H = CVarIntegerValue("ratter_locator_height");
    int BorderWidth = CVarIntegerValue("ratter_locator_border_width");
    int BorderRadius = CVarIntegerValue("ratter_locator_border_radius");
    unsigned BorderColor = CVarUnsignedValue("ratter_locator_border_color");
    unsigned BackgroundColor = CVarUnsignedValue("ratter_locator_backgound_color");
    X -= W/2;
    Y = GetDisplayBounds().size.height - Y; // Flip the Y axis so it is from top-left.
    Y -= H/2;
    Locator = CreateOverlay(X, Y, W, H, BorderWidth, BorderRadius, BorderColor, BackgroundColor);
}

// Returns the CGDirectDisplayID
// TODO: Some sort of error handling if it is an unknown display
internal CGDirectDisplayID
CGDirectDisplayIDForPoint(int X, int Y)
{
    CGDirectDisplayID displayIDs[1];
    unsigned resultCount;
    CGGetDisplaysWithPoint(CGPointMake(X, Y), 1, displayIDs, &resultCount);
    return displayIDs[0];
}

internal void
CreateMask(int Top, int Right, int Bottom, int Left)
{
    int BorderWidth = CVarIntegerValue("ratter_mask_border_width");
    int BorderRadius = CVarIntegerValue("ratter_mask_border_radius");
    unsigned BorderColor = CVarUnsignedValue("ratter_mask_border_color");
    unsigned BackgroundColor = CVarUnsignedValue("ratter_mask_background_color");

    CGRect DisplayBounds = GetDisplayBounds();
    int DisplayWidth = DisplayBounds.size.width;
    int DisplayHeight = DisplayBounds.size.height;
    mask *m = (mask *) malloc(sizeof(mask));
    m->Top = Top;
    m->Right = Right;
    m->Bottom = Bottom;
    m->Left = Left;
    m->InsideOverlay = CreateOverlay(Left, Bottom, DisplayWidth-Right, DisplayHeight-Top, BorderWidth, BorderRadius, BorderColor, 0);
    m->TopOverlay = CreateOverlay(0, DisplayHeight-Top, DisplayWidth, Top, 0, 0, 0, BackgroundColor);
    m->RightOverlay = CreateOverlay(DisplayWidth-Right, 0, Right, DisplayHeight, 0, 0, 0, BackgroundColor);
    m->BottomOverlay = CreateOverlay(0, 0, DisplayWidth, Bottom, 0, 0, 0, BackgroundColor);
    m->LeftOverlay = CreateOverlay(0, 0, Left, DisplayHeight, 0, 0, 0, BackgroundColor);
    Mask = m;
}

internal void
UpdateMask(mask *Mask, int Top, int Right, int Bottom, int Left)
{
    CGRect DisplayBounds = GetDisplayBounds();
    int DisplayWidth = DisplayBounds.size.width;
    int DisplayHeight = DisplayBounds.size.height;

    if (Top != Mask->Top) {
        Mask->Top = Top;
        UpdateOverlayRect(Mask->TopOverlay, 0, DisplayHeight-Top, DisplayWidth, Top);
    }
    if (Right != Mask->Right) {
        Mask->Right = Right;
        UpdateOverlayRect(Mask->RightOverlay, DisplayWidth - Right, 0, Right, DisplayHeight);
    }
    if (Bottom != Mask->Bottom) {
        Mask->Bottom = Bottom;
        UpdateOverlayRect(Mask->BottomOverlay, 0, 0, DisplayWidth, Bottom);
    }
    if (Left != Mask->Left) {
        Mask->Left = Left;
        UpdateOverlayRect(Mask->LeftOverlay, 0, 0, Left, DisplayHeight);
    }
    UpdateOverlayRect(Mask->InsideOverlay, Top, Left, DisplayWidth-(Left+Right), DisplayHeight-(Top+Bottom));
}


internal void
DestroyMask(mask *Mask)
{
    if ([NSThread isMainThread]) {
        DestroyOverlay(Mask->InsideOverlay);
        DestroyOverlay(Mask->TopOverlay);
        DestroyOverlay(Mask->RightOverlay);
        DestroyOverlay(Mask->BottomOverlay);
        DestroyOverlay(Mask->LeftOverlay);
        free(Mask);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^(void)
        {
            DestroyOverlay(Mask->InsideOverlay);
            DestroyOverlay(Mask->TopOverlay);
            DestroyOverlay(Mask->RightOverlay);
            DestroyOverlay(Mask->BottomOverlay);
            DestroyOverlay(Mask->LeftOverlay);
            free(Mask);
        });
    }
}

internal inline void
ClearMask()
{
    if (Mask) {
        // TODO: Do we need to clear it here? Thread safe?
        DestroyMask(Mask);
        Mask = nil;
    }
}

internal bool
MoveIsInProgress()
{
    // If we have a mask, we're moving!
    return !!Mask;
}

internal NSPoint
GetMousePosition()
{
  // TODO: This needs to take into account cursor size (or where the click
  // would actually happen). It seems to move around the bottom-left ofthe
  // mouse for some reason.
  return AXLibGetCursorPos();
}

internal void
ShowLocator()
{
    [timerManager ClearLocator];
    [timerManager ResetLocatorCancelTimer];
    NSPoint mouse = GetMousePosition();
    CreateLocator(mouse.x, mouse.y);
}

internal void
SetMousePosition(int X, int Y, bool triggerEvents)
{
    NSPoint Position = NSMakePoint(X, Y);
    if (triggerEvents) {
        CGDisplayMoveCursorToPoint(CGDirectDisplayIDForPoint(X, Y), Position);
    } else {
        CGWarpMouseCursorPosition(Position);
    }
}

internal void
PostMouseEvent(CGPoint mouseCursorPosition, bool left, bool right)
{
    /*
    CGEventRef event = CGEventCreateMouseEvent(NULL, mouseType, mouseCursorPosition, mouseButton);
    CGEventPost(mouseCursorPosition, event);
    CFRelease(event);
    */
    // TODO: This is deprecated, use Events instead
    CGPostMouseEvent(mouseCursorPosition, true, 2, left, right);
}


internal void
BeginMove()
{
    // If we're already moving, noop
    if (MoveIsInProgress()) return;
    CGRect DisplayBounds = GetDisplayBounds();
    // If reset is enabled, and we are not already moving, move the mouse to the middle
    if (ResetBeforeMove) SetMousePosition(DisplayBounds.size.width/2, DisplayBounds.size.height/2, false);
    // Create the mask, at the edges of the screen
    CreateMask(0, 0, 0, 0);
}

@implementation TimerManager
- (void)ClearLocator
{
    [self ClearLocatorCancelTimer];
    if (Locator) {
        // TODO: Do we need to clear it here? Thread safe?
        DestroyOverlay(Locator);
        Locator = nil;
    }
}

- (void)ResetLocatorCancelTimer
{
    if (LocatorCancelTimer) {
        [LocatorCancelTimer invalidate];
    }

    int TimeoutMS = CVarIntegerValue("ratter_locator_display_time");
    if (TimeoutMS == -1) {
        return;
    }
    NSTimeInterval interval = TimeoutMS / 1000.0;

    LocatorCancelTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                           target:self
                           selector:@selector(ClearLocator)
                           userInfo:nil
                           repeats:NO];
}

- (void)ClearLocatorCancelTimer
{
    if (LocatorCancelTimer) {
      [LocatorCancelTimer invalidate];
      LocatorCancelTimer = nil;
    }
}

- (void)FinishMove
{
    [self ClearMoveCancelTimer];
    [self ClearLocator];
    ClearMask();
    // Move the mouse to it's current position to trigger movement events
    NSPoint mouse = GetMousePosition();
    SetMousePosition(mouse.x, mouse.y, true);
}

- (void)ResetMoveCancelTimer
{
    // TODO: Timers don't seem to be firing
    if (MoveCancelTimer) {
      [MoveCancelTimer invalidate];
    }

    int TimeoutMS = CVarIntegerValue("ratter_cancel_timeout");
    if (TimeoutMS == -1) {
        return;
    }
    NSTimeInterval interval = TimeoutMS / 1000.0;

    MoveCancelTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                        target:self
                        selector:@selector(FinishMove)
                        userInfo:nil
                        repeats:NO];
}

- (void)ClearMoveCancelTimer
{
    if (MoveCancelTimer) {
      [MoveCancelTimer invalidate];
      MoveCancelTimer = nil;
    }
}
@end

internal void
Move(int Direction)
{
    BeginMove();
    // Find the screen dimensions
    CGRect DisplayBounds = GetDisplayBounds();
    // Find mouse current position
    NSPoint mouse = GetMousePosition();
    // Calculate new mouse position (center of mask), and expand appropriate
    // mask side to where the mouse is
    // TODO: These seem to overlap a bit when we get close to single-pixel scale.
    int mouseX = mouse.x;
    int mouseY = mouse.y;
    switch (Direction) {
    case UP:
        UpdateMask(Mask, Mask->Top, Mask->Right, DisplayBounds.size.height - mouseY, Mask->Left);
        mouseY = mouseY - ((mouseY - Mask->Top) / 2);
        break;
    case RIGHT:
        UpdateMask(Mask, Mask->Top, Mask->Right, Mask->Bottom, mouseX);
        mouseX = mouseX + (((DisplayBounds.size.width - Mask->Right) - mouseX) / 2);
        break;
    case DOWN:
        UpdateMask(Mask, mouseY, Mask->Right, Mask->Bottom, Mask->Left);
        mouseY = mouseY + (((DisplayBounds.size.height - Mask->Bottom) - mouseY) / 2);
        break;
    case LEFT:
        UpdateMask(Mask, Mask->Top, DisplayBounds.size.width - mouseX, Mask->Bottom, Mask->Left);
        mouseX = mouseX - ((mouseX - Mask->Left) / 2);
        break;
    }

    // Move mouse to new position
    SetMousePosition(mouseX, mouseY, false);

    // Reset cancel timeout
    [timerManager ResetMoveCancelTimer];
}

internal void
Click()
{
    if (MoveIsInProgress()) [timerManager FinishMove];
    CGPoint mouse = GetMousePosition();
    PostMouseEvent(mouse, true, false);
    PostMouseEvent(mouse, false, false);
}

internal void
RightClick()
{
    if (MoveIsInProgress()) [timerManager FinishMove];
    CGPoint mouse = GetMousePosition();
    PostMouseEvent(mouse, false, true);
    PostMouseEvent(mouse, false, false);
}

internal void
BeginDrag()
{
    // TODO: Figure out how to do this
    if (MoveIsInProgress()) [timerManager FinishMove];
}

internal inline bool
StringEquals(const char *A, const char *B)
{
    return (strcmp(A, B) == 0);
}

internal void
CommandHandler(void *Data)
{
    chunkwm_payload *Payload = (chunkwm_payload *) Data;
    if (StringEquals(Payload->Command, "locate")) {
        ShowLocator();
    } else if (StringEquals(Payload->Command, "up")) {
        Move(UP);
    } else if (StringEquals(Payload->Command, "right")) {
        Move(RIGHT);
    } else if (StringEquals(Payload->Command, "down")) {
        Move(DOWN);
    } else if (StringEquals(Payload->Command, "left")) {
        Move(LEFT);
    } else if (StringEquals(Payload->Command, "cancel")) {
        [timerManager FinishMove];
    } else if (StringEquals(Payload->Command, "click")) {
        Click();
    } else if (StringEquals(Payload->Command, "rightclick")) {
        RightClick();
    } else if (StringEquals(Payload->Command, "begindrag")) {
        BeginDrag();
    }
}

PLUGIN_MAIN_FUNC(PluginMain)
{
    if (StringEquals(Node, "chunkwm_daemon_command")) {
        CommandHandler(Data);
        return true;
    }

    return false;
}

PLUGIN_BOOL_FUNC(PluginInit)
{
    API = ChunkwmAPI;
    c_log = API.Log;
    BeginCVars(&API);
    timerManager = [TimerManager alloc];

    CreateCVar("ratter_cancel_timeout", 500);
    CreateCVar("ratter_locator_backgound_color", 0xbb4799b7);
    CreateCVar("ratter_locator_border_color", 0);
    CreateCVar("ratter_locator_border_radius", 16);
    CreateCVar("ratter_locator_border_width", 0);
    CreateCVar("ratter_locator_display_time", 500);
    CreateCVar("ratter_locator_height", 16);
    CreateCVar("ratter_locator_width", 16);
    CreateCVar("ratter_mask_background_color", 0xbb4799b7);
    CreateCVar("ratter_mask_border_color", 0);
    CreateCVar("ratter_mask_border_radius", 0);
    CreateCVar("ratter_mask_border_width", 0);
    CreateCVar("ratter_reset", 0);
    CreateCVar("ratter_show_mask", 1);

    ResetBeforeMove = CVarIntegerValue("ratter_reset");
    ShowMask = CVarIntegerValue("ratter_show_mask");
    return true;
}

PLUGIN_VOID_FUNC(PluginDeInit)
{
    if (MoveIsInProgress()) {
        [timerManager FinishMove];
    }
}

CHUNKWM_PLUGIN_VTABLE(PluginInit, PluginDeInit, PluginMain)
chunkwm_plugin_export Subscriptions[] = {};
CHUNKWM_PLUGIN_SUBSCRIBE(Subscriptions)
CHUNKWM_PLUGIN("Ratter", "0.1.0")
