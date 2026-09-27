using Toybox.Lang;

// Minimal decoder for the inbound PB.Main envelope. We only need a handful of fields;
// everything else is skipped by wire type so unknown/future fields never break parsing.
//
// PB.Main: command_id=1 (varint), command_status=2 (varint enum), has_next=3 (varint bool),
//          system_ping_response=6 (len), gui_screen_frame=22 (len).
// ScreenFrame: data=1 (len bytes) = the 1024-byte packed framebuffer, orientation=2 (varint).
module PBMain {

    // Decode one PB.Main body (no length prefix - FrameReader has already stripped it).
    // Returns a Dictionary:
    //   :commandId  Number
    //   :status     Number (PB_CommandStatus; 0 == OK)
    //   :hasNext    Boolean
    //   :isPong     Boolean
    //   :frame      ByteArray or null   (framebuffer bytes from gui_screen_frame.data)
    //   :orientation Number or null
    function decode(body as Lang.ByteArray) as Lang.Dictionary {
        var out = { :commandId => 0, :status => 0, :hasNext => false,
                    :isPong => false, :frame => null, :orientation => null };
        var n = body.size();
        var i = 0;
        while (i < n) {
            var t = Protocol.tryDecodeVarint(body, i, n);
            if (t == null) { break; }
            var key = t[0];
            i = t[1];
            var field = key >> 3;
            var wire = key & 0x07;

            if (wire == Protocol.WIRE_VARINT) {
                var v = Protocol.tryDecodeVarint(body, i, n);
                if (v == null) { break; }
                var val = v[0];
                i = v[1];
                if (field == 1) { out[:commandId] = val; }
                else if (field == 2) { out[:status] = val; }
                else if (field == 3) { out[:hasNext] = (val != 0); }
            } else if (wire == Protocol.WIRE_LEN) {
                var l = Protocol.tryDecodeVarint(body, i, n);
                if (l == null) { break; }
                var len = l[0];
                var start = l[1];
                var end = start + len;
                if (end > n) { break; }
                if (field == Protocol.MAIN_GUI_SCREEN_FRAME) {
                    decodeScreenFrame(body.slice(start, end), out);
                } else if (field == Protocol.MAIN_SYSTEM_PING_RESPONSE) {
                    out[:isPong] = true;
                }
                i = end;
            } else if (wire == 5) {          // 32-bit
                i += 4;
            } else if (wire == 1) {          // 64-bit
                i += 8;
            } else {
                break;                        // groups / unknown wire type: stop safely
            }
        }
        return out;
    }

    function decodeScreenFrame(sf as Lang.ByteArray, out as Lang.Dictionary) as Void {
        var n = sf.size();
        var i = 0;
        while (i < n) {
            var t = Protocol.tryDecodeVarint(sf, i, n);
            if (t == null) { break; }
            var field = t[0] >> 3;
            var wire = t[0] & 0x07;
            i = t[1];
            if (wire == Protocol.WIRE_LEN) {
                var l = Protocol.tryDecodeVarint(sf, i, n);
                if (l == null) { break; }
                var end = l[1] + l[0];
                if (end > n) { break; }
                if (field == 1) { out[:frame] = sf.slice(l[1], end); } // ScreenFrame.data
                i = end;
            } else if (wire == Protocol.WIRE_VARINT) {
                var v = Protocol.tryDecodeVarint(sf, i, n);
                if (v == null) { break; }
                if (field == 2) { out[:orientation] = v[0]; }
                i = v[1];
            } else {
                break;
            }
        }
    }
}
