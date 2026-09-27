using Toybox.Lang;

// Connection lifecycle. The state is always legible on screen - the UI must never show a
// stale frame as if it were live.
module ConnState {
    enum {
        IDLE = 0,
        STARTING = 1,
        SCANNING = 2,
        FOUND = 3,
        CONNECTING = 4,
        CONNECTED = 5,      // GATT up, not yet subscribed
        STREAMING = 6,      // subscribed + screen stream active (the live state)
        DEGRADED = 7,       // connected but RPC/ping not responding
        LOST = 8            // dropped; reconnect in progress
    }

    function label(s as Lang.Number) as Lang.String {
        switch (s) {
            case IDLE:       return "idle";
            case STARTING:   return "starting BLE";
            case SCANNING:   return "scanning BLE";
            case FOUND:      return "Flipper found";
            case CONNECTING: return "connecting BLE";
            case CONNECTED:  return "GATT connected";
            case STREAMING:  return "live";
            case DEGRADED:   return "BLE/RPC error";
            case LOST:       return "reconnecting";
        }
        return "?";
    }
}
