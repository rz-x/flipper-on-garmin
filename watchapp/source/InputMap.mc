using Toybox.Lang;
using Toybox.WatchUi;

// Maps the Descent Mk2's five physical buttons onto the Flipper's six inputs
// (UP/DOWN/LEFT/RIGHT/OK/BACK) plus long-press.
//
// Physical (fenix/Descent 5-button layout):
//   KEY_LIGHT (left-top)      -> BACKLIGHT LATCH
//   KEY_UP    (left-middle)   -> UP    / LEFT   (depending on axis)
//   KEY_DOWN  (left-bottom)   -> DOWN  / RIGHT  (depending on axis)
//   KEY_ENTER (right-top)     -> OK    (Garmin default position for "select")
//   KEY_ESC   (right-bottom)  -> BACK  (Garmin default position for "back")
//
// Six directions from two direction buttons: a DOUBLE TAP of ENTER toggles the axis, the same way
// Garmin's own map view switches what up/down do. The view draws arrow hints next to the
// physical buttons showing the current axis, so it stays obvious which way you'll move.
//
//   AXIS_VERTICAL   (default): UP -> UP,   DOWN -> DOWN
//   AXIS_HORIZONTAL          : UP -> LEFT, DOWN -> RIGHT
//
// ENTER/ESC never change meaning - they match the watch's own conventions.
// Hold ESC ~1.5 s to leave the app; a short ESC is a plain BACK sent to the Flipper.
module InputMap {
    const LONG_PRESS_MS = 400;   // >= this held → Flipper LONG, else SHORT
    const EXIT_HOLD_MS  = 1500;  // hold BACK this long to leave the app (Flipper convention)
    // Double-tap ENTER flips the direction axis. It has to be a double tap of SHORT presses:
    // Garmin claims button HOLDS as system hotkeys (hold ENTER opens Wallet, hold LIGHT opens
    // controls) and takes them before the app sees them, even though the app consumes the key
    // events. Short presses are the only gestures reliably delivered to a Connect IQ app.
    const DOUBLE_TAP_MS = 350;   // second ENTER within this window = axis toggle, not OK

    enum {
        AXIS_VERTICAL = 0,       // UP/DOWN buttons move up/down
        AXIS_HORIZONTAL = 1      // UP/DOWN buttons move left/right
    }

    // Resolve a physical key on the given axis into a Flipper key, or null if unmapped
    // (the axis-toggle key itself returns null - it never reaches the Flipper).
    function toFlipperKey(ciqKey as Lang.Number, axis as Lang.Number) as Lang.Number or Null {
        var horizontal = (axis == AXIS_HORIZONTAL);
        switch (ciqKey) {
            case WatchUi.KEY_UP:    return horizontal ? Protocol.KEY_LEFT  : Protocol.KEY_UP;
            case WatchUi.KEY_DOWN:  return horizontal ? Protocol.KEY_RIGHT : Protocol.KEY_DOWN;
            case WatchUi.KEY_ENTER: return Protocol.KEY_OK;
            case WatchUi.KEY_ESC:   return Protocol.KEY_BACK;
        }
        return null;
    }

    // The LIGHT key toggles the axis rather than acting as a held modifier: a hold-modifier
    // needs two hands, a toggle does not. Note LIGHT is not guaranteed to reach the app - the
    // system may claim it for the backlight - which is why holding ENTER also flips the axis.
    function isBacklightKey(ciqKey as Lang.Number) as Lang.Boolean {
        return ciqKey == WatchUi.KEY_LIGHT;
    }

    function axisLabel(axis as Lang.Number) as Lang.String {
        return (axis == AXIS_HORIZONTAL) ? "< >" : "^ v";
    }
}
