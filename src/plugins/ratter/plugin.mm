#import <Carbon/Carbon.h>
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
#define RIGHT 3

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
    int X;
    int Y;
    int W;
    int H;
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
    m->X = X;
    m->Y = Y;
    m->W = W;
    m->H = H;
    m->Inside = CreateOverlay(X, Y, W, H, BorderWidth, BorderRadius, BorderColor, 0);
    m->Top = CreateOverlay(0, 0, DisplayWidth, Y, 0, 0, 0, BackgroundColor);
    m->Bottom = CreateOverlay(0, Y+H, DisplayWidth, DisplayHeight - (Y+H), 0, 0, 0, BackgroundColor);
    m->Left = CreateOverlay(0, 0, X, DisplayHeight, 0, 0, 0, BackgroundColor);
    m->Right = CreateOverlay(X+W, 0, DisplayWidth - (X+W), DisplayHeight, 0, 0, 0, BackgroundColor);
    Mask = m;
}

internal void
UpdateMask(mask *Mask, int X, int Y, int W, int H)
{
    CGRect DisplayBounds = GetDisplayBounds();
    int DisplayWidth = DisplayBounds.size.width;
    int DisplayHeight = DisplayBounds.size.height;

    if (X != Mask->X) {
        Mask->X = X;
        UpdateOverlayRect(Mask->Left, 0, 0, X, DisplayHeight);
    }
    if (Y != Mask->Y) {
        Mask->Y = Y;
        UpdateOverlayRect(Mask->Top, 0, 0, DisplayWidth, Y);
    }
    if (W != Mask->W) {
        Mask->W = W;
        UpdateOverlayRect(Mask->Right, X+W, 0, DisplayWidth - (X+W), DisplayHeight);
    }
    if (H != Mask->H) {
        Mask->H = H;
        UpdateOverlayRect(Mask->Bottom, 0, Y+H, DisplayWidth, DisplayHeight - (Y+H));
    }
    UpdateOverlayRect(Mask->Inside, X, Y, W, H);
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
        Mask = nil;
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
SetMousePosition(int X, int Y, bool triggerEvents) {
  // TODO: Implement this
  CGPoint Position;
  Position.x = X;
  Position.y = Y;
  if (triggerEvents) {
      // TODO: This will always be the big display. We want to move it in the global space...
      CGMoveCursorToPoint(Position);
  } else {
      CGWarpMouseCursorPosition(Position);
  }
}

internal void
BeginMove() {
    // If we're already moving, noop
    if (MoveIsInProgress()) return;
    CGRect DisplayBounds = GetDisplayBounds();
    // If reset is enabled, and we are not already moving, move the mouse to the middle
    if (ResetBeforeMove) SetMousePosition(DisplayBounds.size.width/2, DisplayBounds.size.height/2, false);
    // Create the mask, at the edges of the screen
    CreateMask(0, 0, DisplayBounds.size.width, DisplayBounds.size.height);
}

internal void
Move(int Direction)
{
    BeginMove();
    // Find the screen dimensions
    CGRect DisplayBounds = GetDisplayBounds();
    // Find mouse current position
    NSPoint mouseLocation = [NSEvent mouseLocation];
    // Calculate new mouse position (center of mask), and expand appropriate
    // mask side to where the mouse is
    int newX = mouseLocation.x;
    int newY = mouseLocation.y;
    switch (Direction) {
    case UP:
        newY = Mask->Y + ((mouseLocation.y - Mask->Y) / 2);
        UpdateMask(Mask, Mask->X, Mask->Y, Mask->W, DisplayBounds.size.height - mouseLocation.y);
        break;
    case DOWN:
        newY = mouseLocation.y + ((Mask->Y + Mask->H - mouseLocation.y) / 2);
        UpdateMask(Mask, Mask->X, mouseLocation.y, Mask->W, Mask->H);
        break;
    case LEFT:
        newX = Mask->X + ((mouseLocation.x - Mask->X) / 2);
        UpdateMask(Mask, mouseLocation.x, Mask->Y, Mask->W, Mask->H);
        break;
    case RIGHT:
        newX = mouseLocation.x + ((Mask->X + Mask->W - mouseLocation.x) / 2);
        UpdateMask(Mask, Mask->X, Mask->Y, DisplayBounds.size.width - mouseLocation.x, Mask->H);
        break;
    }

    // Move mouse to new position
    SetMousePosition(newX, newY, false);

    // Reset cancel timeout
}

internal void
FinishMove()
{
    ClearMask();
    // Move the mouse to it's current position to trigger movement events
    // TODO: do we need to warp back to start then move it?
    NSPoint mouseLocation = [NSEvent mouseLocation];
    SetMousePosition(mouseLocation.x, mouseLocation.y, true);
    // If we are dragging, reset position, and trigger a mouse-up
}

internal void
Click()
{
    if (MoveIsInProgress()) FinishMove();
    // If we are dragging, trigger a mouse-up, otherwise a click
}

internal void
RightClick()
{
    if (MoveIsInProgress()) FinishMove();
    // Trigger a right click
}

internal void
BeginDrag()
{
    // TODO: Figure out how this should work
    if (MoveIsInProgress()) FinishMove();
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
        FinishMove();
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
    CreateCVar("ratter_locator_backgound_color", 0x330000ff);
    CreateCVar("ratter_locator_display_time", 500);
    CreateCVar("ratter_show_mask", 1);
    CreateCVar("ratter_mask_color", 0x330000ff);

    ResetBeforeMove = CVarIntegerValue("ratter_reset");
    ShowMask = CVarIntegerValue("ratter_show_mask");
    return true;
}

PLUGIN_VOID_FUNC(PluginDeInit)
{
    if (MoveIsInProgress()) {
        FinishMove();
    }
}

CHUNKWM_PLUGIN_VTABLE(PluginInit, PluginDeInit, PluginMain)
chunkwm_plugin_export Subscriptions[] = {};
CHUNKWM_PLUGIN_SUBSCRIBE(Subscriptions)
CHUNKWM_PLUGIN("Ratter", "0.1.0")
