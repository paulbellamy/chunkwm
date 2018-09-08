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

#define internal static
#define DESKTOP_MODE_BSP      0
#define DESKTOP_MODE_MONOCLE  1
#define DESKTOP_MODE_FLOATING 2

#define UP    0
#define DOWN  1
#define LEFT  2
#define RIGHT 2

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
    overlay *Inside;
    overlay *Top;
    overlay *Bottom;
    overlay *Left;
    overlay *Right;
};

internal macos_application *Application;
internal mask *Mask;
internal overlay *Locator;
internal bool ResetBeforeMove;
internal bool ShowMask;
internal chunkwm_api API;

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
    Y -= H/2;
    Locator = CreateOverlay(X, Y, W, H, BorderWidth, BorderRadius, BorderColor, BackgroundColor);
}

internal void
ClearLocator()
{
    if (Locator) {
        // TODO: Do we need to clear it here? Thread safe?
        DestroyOverlay(Locator);
    }
}

internal CGRect
GetDisplayBounds() {
    CGRect DisplayBounds;
    CFStringRef DisplayRef = AXLibGetDisplayIdentifierForMainDisplay();
    if (DisplayRef) {
      DisplayBounds = AXLibGetDisplayBounds(DisplayRef);
      CFRelease(DisplayRef);
    }
    return DisplayBounds;
}

internal void
CreateMask(int X, int Y, int W, int H)
{
    int BorderWidth = CVarIntegerValue("ratter_mask_border_width");
    int BorderRadius = CVarIntegerValue("ratter_mask_border_radius");
    unsigned BorderColor = CVarUnsignedValue("ratter_mask_border_color");
    unsigned BackgroundColor = CVarUnsignedValue("ratter_mask_background_color");

    CGRect DisplayBounds = GetDisplayBounds();
    int DisplayWidth = DisplayBounds.size.width;
    int DisplayHeight = DisplayBounds.size.height;
    mask *m = (mask *) malloc(sizeof(mask));
    m->Inside = CreateOverlay(X, Y, W, H, BorderWidth, BorderRadius, BorderColor, 0);
    m->Top = CreateOverlay(0, 0, DisplayWidth, Y, 0, 0, 0, BackgroundColor);
    m->Bottom = CreateOverlay(0, Y+H, DisplayWidth, DisplayHeight - (Y+H), 0, 0, 0, BackgroundColor);
    m->Left = CreateOverlay(0, 0, X, DisplayHeight, 0, 0, 0, BackgroundColor);
    m->Right = CreateOverlay(X+W, 0, DisplayWidth - (X+W), DisplayHeight, 0, 0, 0, BackgroundColor);
    Mask = m;
}

internal void
DestroyMask(mask *Mask)
{
    if ([NSThread isMainThread]) {
        DestroyOverlay(Mask->Inside);
        DestroyOverlay(Mask->Top);
        DestroyOverlay(Mask->Bottom);
        DestroyOverlay(Mask->Left);
        DestroyOverlay(Mask->Right);
        free(Mask);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^(void)
        {
            DestroyOverlay(Mask->Inside);
            DestroyOverlay(Mask->Top);
            DestroyOverlay(Mask->Bottom);
            DestroyOverlay(Mask->Left);
            DestroyOverlay(Mask->Right);
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
    }
}

internal bool
MoveIsInProgress() {
    // If we have a mask, we're moving!
    return !!Mask;
}

internal void
ShowLocator()
{
    // TODO: Set timeout to clear it
    // TODO: Get the mouse coords here
    // CreateLocator(mousex, mousey);
}

internal void
SetMousePosition(int X, int Y) {
  // TODO: Implement this
}

internal void
Move(int Direction)
{
    // Find the screen dimensions
    CGRect DisplayBounds = GetDisplayBounds();
    // If reset is enabled, and we are not already moving, move the mouse to the middle
    if (ResetBeforeMove && !MoveIsInProgress()) SetMousePosition(DisplayBounds.size.width/2, DisplayBounds.size.height/2);
    // Find mouse current position
    // Expand appropriate mask side to half the distance
    // Move mouse to new position
    // Reset cancel timeout
}

internal void
CancelMove()
{
    ClearMask();
    // If we are dragging, reset position, and trigger a mouse-up
}

internal void
Click()
{
    if (MoveIsInProgress()) CancelMove();
    // If we are dragging, trigger a mouse-up, otherwise a click
}

internal void
RightClick()
{
    if (MoveIsInProgress()) CancelMove();
    // Trigger a right click
}

internal void
BeginDrag()
{
    // TODO: Figure out how this should work
    if (MoveIsInProgress()) CancelMove();
    // Trigger a mouse-down
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
    } else if (StringEquals(Payload->Command, "down")) {
        Move(DOWN);
    } else if (StringEquals(Payload->Command, "left")) {
        Move(LEFT);
    } else if (StringEquals(Payload->Command, "right")) {
        Move(RIGHT);
    } else if (StringEquals(Payload->Command, "cancel")) {
        CancelMove();
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
    BeginCVars(&API);

    CreateCVar("ratter_cancel_timeout", 1000);
    CreateCVar("ratter_reset", 0);
    CreateCVar("ratter_locator_width", 8);
    CreateCVar("ratter_locator_height", 8);
    CreateCVar("ratter_locator_border_width", 0);
    CreateCVar("ratter_locator_border_radius", 0);
    CreateCVar("ratter_locator_border_color", 0);
    CreateCVar("ratter_locator_backgound_color", 0xffd5c4a1);
    CreateCVar("ratter_locator_display_time", 500);
    CreateCVar("ratter_show_mask", 1);
    CreateCVar("ratter_mask_color", 0xffd5c4a1);

    ResetBeforeMove = CVarIntegerValue("ratter_reset");
    ShowMask = CVarIntegerValue("ratter_show_mask");
    return true;
}

PLUGIN_VOID_FUNC(PluginDeInit)
{
    if (MoveIsInProgress) {
        CancelMove();
    }
}

CHUNKWM_PLUGIN_VTABLE(PluginInit, PluginDeInit, PluginMain)
chunkwm_plugin_export Subscriptions[] = {};
CHUNKWM_PLUGIN_SUBSCRIBE(Subscriptions)
CHUNKWM_PLUGIN("Ratter", "0.1.0")
