### Ratter ChunkWM Plugin

Ratter is a newer, OSX version of a 2006 program known as "mouser". It
helps you move your mouse around the screen via the keyboard. By
partitioning the screen into a binary tree, the movements can be very
efficient. A 1900x1200 screen means a maximum of 21 movements before
you reach an individual pixel. I expect the average to be around 8
moves to reach a typical hitbox anywhere on the screen.

It doesn't really need to be a chunkwm plugin, but that makes it
convenient for me to bootstrap the project. Short-term, the plan is to
use skhd to configure, catch, and forward the hotkeys (so I don't need
to deal with that). But long-term, probably provide a configuration UI
and use Carbon to catch them myself.

#### chunkwm-ratter configuration index

* [config settings](#config-settings)
  * [cancel timeout](#set-cancel-timeout)
  * [whether to reset mouse to center before moving](#set-whether-to-reset-mouse-to-center-before-moving)
  * [locator style](#set-locator-style)
  * [locator display time](#set-locator-display-time)
  * [show mask](#set-whether-to-mask-ruled-out-areas-of-screen)
  * [mask color](#set-mask-color)
* [runtime commands](#runtime-commands)
  * [show locator](#show-locator)
  * [move up](#move-up)
  * [move down](#move-down)
  * [move left](#move-left)
  * [move right](#move-right)
  * [cancel](#cancel)
  * [click](#click)
  * [right-click](#right-click)
  * [begin drag](#begin-drag)

#### config settings

##### set cancel timeout

    chunkc set ratter_cancel_timeout <millis>

##### set whether to reset mouse to center before moving

    chunkc set ratter_reset <option>
    <option>: 1 | 0

##### set locator style

    chunkc set ratter_locator_width <px>
    chunkc set ratter_locator_height <px>
    chunkc set ratter_locator_border_width <px>
    chunkc set ratter_locator_border_radius <px>
    chunkc set ratter_locator_border_color 0xAARRGGBB
    chunkc set ratter_locator_backgound_color 0xAARRGGBB

##### set locator display time

    chunkc set ratter_locator_display_time <millis>

##### set whether to mask ruled out areas of screen

    chunkc set ratter_show_mask <option>
    <option>: 1 | 0

##### set mask style

    chunkc set ratter_mask_border_width <px>
    chunkc set ratter_mask_border_radius <px>
    chunkc set ratter_mask_border_color 0xAARRGGBB
    chunkc set ratter_mask_background_color 0xAARRGGBB

#### runtime commands

##### show locator

    chunkc ratter::locate

##### move up

    chunkc ratter::up

##### move down

    chunkc ratter::down

##### move left

    chunkc ratter::left

##### move right

    chunkc ratter::right

##### cancel

    chunkc ratter::cancel

##### click

    chunkc ratter::click

##### right-click

    chunkc ratter::rightclick

##### begin drag

    chunkc ratter::begindrag
