using Toybox.Lang;
using Toybox.Graphics;

// Decodes and renders the Flipper's 128x64 monochrome framebuffer.
//
// Layout: the Flipper canvas is u8g2. The 1024-byte buffer is 8 pages of 128 columns.
//   byteIndex = x + page*128,  page = y >> 3,  bit = y & 7  (bit 0 = topmost row of the page)
//   pixel(x,y) set  <=>  (buf[x + (y>>3)*128] >> (y & 7)) & 1
//
// HARDWARE-VERIFY: a wrong page/bit order yields a plausible-looking
// but sheared image. Confirm against a Flipper screen with known geometry; if inverted or
// rotated, flip BIT_TOP_FIRST / the byteIndex formula here - this is the single place to change.
module Framebuffer {
    const WIDTH = 128;
    const HEIGHT = 64;
    const SIZE = 1024;             // WIDTH * HEIGHT / 8
    const BIT_TOP_FIRST = true;    // u8g2: bit 0 is the top pixel of the page

    function isSet(buf as Lang.ByteArray, x as Lang.Number, y as Lang.Number) as Lang.Boolean {
        var idx = x + (y >> 3) * WIDTH;
        if (idx < 0 || idx >= buf.size()) { return false; }
        var bit = BIT_TOP_FIRST ? (y & 7) : (7 - (y & 7));
        return ((buf[idx] >> bit) & 1) == 1;
    }

    // Largest integer scale that fits the source into (w x h), centered. Returns [scale, ox, oy].
    // Largest INTEGER scale that fits the screen box. On a round screen the image corners can
    // fall just outside the bezel (3 px per side on a 280 px Descent Mk2), but the Flipper never
    // draws in its extreme corners, and the user prefers the ~10% larger image to a smaller one
    // that clears the circle. Integer scale also keeps every pixel the same size.
    function fit(w as Lang.Number, h as Lang.Number) as Lang.Array {
        var sx = w / WIDTH;
        var sy = h / HEIGHT;
        var s = (sx < sy) ? sx : sy;
        if (s < 1) { s = 1; }
        var ox = (w - WIDTH * s) / 2;
        var oy = (h - HEIGHT * s) / 2;
        return [s, ox, oy];
    }

    function scaledWidth(s as Lang.Number) as Lang.Number { return WIDTH * s; }
    function scaledHeight(s as Lang.Number) as Lang.Number { return HEIGHT * s; }

    // Render the framebuffer scaled and centered on dc. Set pixels are drawn as fg on a bg
    // clear; horizontal runs within a row are batched into one rectangle to cut draw calls.
    // The per-pixel bit test is INLINED here (no isSet() method call): calling a method ~16k
    // times per frame is slow enough on the watch to trip the Connect IQ render watchdog, which
    // kills the app mid-draw (the "artifacts then Connect IQ screen" symptom).
    // Hard cap on rectangles PER PASS (per onUpdate call), not per frame. Measured the hard way:
    // a single pass carrying a whole frame at 2400 rectangles trips the render watchdog and kills
    // the app (CIQ_LOG, 2026-09-03, Framebuffer.draw <- onUpdate). 600 per pass is the value that
    // ran without a watchdog trip on a Descent Mk2 (watchdog budget 240 000). The Forerunner 255
    // family has HALF that budget (120 000, per its simulator.json), so the per-update cap is 300
    // with twice the slices: same 2400-rectangle frame capacity, half the work per update.
    const MAX_RECTS = 300;

    // Draw rows [yStart, yEnd) of the framebuffer. Each call erases its own band before painting
    // it, so a slice is never left blank waiting for a later update. `fullClear` additionally
    // wipes the whole Dc, needed only on the first frame after the status screen. The frame is split into slices across consecutive onUpdate calls so no
    // single call runs long enough to trip the render watchdog; the Garmin screen persists between
    // updates, so the slices compose into the full image. Only lit pixels are drawn - the
    // background comes from the clear on the first pass.
    function draw(dc as Graphics.Dc, buf as Lang.ByteArray,
                  fg as Graphics.ColorValue, bg as Graphics.ColorValue,
                  yStart as Lang.Number, yEnd as Lang.Number, fullClear as Lang.Boolean) as Lang.Boolean {
        var f = fit(dc.getWidth(), dc.getHeight());
        var s = f[0]; var ox = f[1]; var oy = f[2];
        var n = buf.size();
        var rects = 0;

        if (fullClear) {
            dc.setColor(bg, bg);
            dc.clear();
        }
        // Erase only the band we are about to paint. Clearing the WHOLE screen on the first slice
        // left the remaining slices blank until later updates painted them, which is exactly the
        // "top third steady, lower two thirds blink once a second" flicker. Erasing and repainting
        // one band inside a single update means no part of the image is ever momentarily blank.
        dc.setColor(bg, bg);
        dc.fillRectangle(ox, oy + yStart * s, WIDTH * s, (yEnd - yStart) * s);
        dc.setColor(fg, bg);

        for (var y = yStart; y < yEnd; y++) {
            var page = (y >> 3) * WIDTH;
            var bit = BIT_TOP_FIRST ? (y & 7) : (7 - (y & 7));
            var rowY = oy + y * s;
            var x = 0;
            while (x < WIDTH) {
                var idx = x + page;
                if (idx < n && ((buf[idx] >> bit) & 1) == 1) {
                    var runStart = x;
                    x++;
                    while (x < WIDTH) {
                        var i2 = x + page;
                        if (i2 < n && ((buf[i2] >> bit) & 1) == 1) { x++; } else { break; }
                    }
                    dc.fillRectangle(ox + runStart * s, rowY, (x - runStart) * s, s);
                    rects++;
                    if (rects >= MAX_RECTS) { return true; }
                } else {
                    x++;
                }
            }
        }
        return false;
    }
}
