using Toybox.Lang;

// Flipper RPC wire layer - hand-rolled protobuf subset (no protobuf runtime exists for Monkey C).
//
// Frame = varint(length) + PB.Main payload. Field numbers verified against
// flipperzero-protobuf (flipper.proto / system.proto / gui.proto), pinned commit
// ea4f185 in the Momentum assets/protobuf submodule:
//
//   PB.Main:  command_id=1, command_status=2, has_next=3,
//             oneof content: empty=4, system_ping_request=5, system_ping_response=6,
//                            gui_start_screen_stream_request=20, gui_stop_screen_stream_request=21,
//                            gui_screen_frame=22, gui_send_input_event_request=23
//   PingRequest/PingResponse: bytes data=1
//   ScreenFrame: bytes data=1, orientation=2, bg_color=3, fg_color=4
//   SendInputEventRequest: InputKey key=1, InputType type=2
//   InputKey:  UP=0 DOWN=1 RIGHT=2 LEFT=3 OK=4 BACK=5
//   InputType: PRESS=0 RELEASE=1 SHORT=2 LONG=3 REPEAT=4
//
// Only the message subset the product needs is implemented. Every added message is
// hand-parsed surface - keep it minimal.
module Protocol {

    // ---- protobuf wire types ----
    const WIRE_VARINT = 0;
    const WIRE_LEN    = 2;

    // ---- PB.Main content field numbers ----
    const MAIN_SYSTEM_PING_REQUEST  = 5;
    const MAIN_SYSTEM_PING_RESPONSE = 6;
    const MAIN_GUI_START_STREAM     = 20;
    const MAIN_GUI_STOP_STREAM      = 21;
    const MAIN_GUI_SCREEN_FRAME     = 22;
    const MAIN_GUI_SEND_INPUT       = 23;

    // ---- InputKey / InputType ----
    const KEY_UP = 0; const KEY_DOWN = 1; const KEY_RIGHT = 2;
    const KEY_LEFT = 3; const KEY_OK = 4; const KEY_BACK = 5;
    const TYPE_PRESS = 0; const TYPE_RELEASE = 1; const TYPE_SHORT = 2;
    const TYPE_LONG = 3; const TYPE_REPEAT = 4;

    // Append a base-128 varint to a ByteArray-backed buffer (Array<Number> of 0..255).
    function encodeVarint(out as Lang.Array, value as Lang.Number) as Void {
        var v = value;
        while (v >= 0x80) {
            out.add((v & 0x7f) | 0x80);
            v = v >> 7;
        }
        out.add(v & 0x7f);
    }

    // Read a varint from bytes starting at offset. Returns [value, nextOffset].
    // Caller must guarantee the varint is fully present (see FrameReader for reassembly).
    function decodeVarint(bytes as Lang.ByteArray, offset as Lang.Number) as Lang.Array {
        var shift = 0;
        var result = 0;
        var i = offset;
        while (true) {
            var b = bytes[i];
            result = result | ((b & 0x7f) << shift);
            i++;
            if ((b & 0x80) == 0) { break; }
            shift += 7;
        }
        return [result, i];
    }

    // Tolerant varint decode for stream reassembly: reads from `offset` but never past
    // `limit`. Returns [value, nextOffset] when a complete varint is present, or null when
    // the bytes so far end mid-varint (need more data). Keeps FrameReader boundary-safe.
    function tryDecodeVarint(bytes as Lang.ByteArray, offset as Lang.Number, limit as Lang.Number) as Lang.Array or Null {
        var shift = 0;
        var result = 0;
        var i = offset;
        while (i < limit) {
            var b = bytes[i];
            result = result | ((b & 0x7f) << shift);
            i++;
            if ((b & 0x80) == 0) { return [result, i]; }
            shift += 7;
        }
        return null; // ran out of bytes before the terminating byte
    }

    // key = (fieldNumber << 3) | wireType
    function tag(fieldNumber as Lang.Number, wireType as Lang.Number) as Lang.Number {
        return (fieldNumber << 3) | wireType;
    }

    // Build a length-delimited PB.Main frame carrying a single empty-body message
    // (StartScreenStream / StopScreenStream have no fields).
    // Returns a ByteArray ready to write to the RX characteristic.
    function buildEmptyContent(contentField as Lang.Number) as Lang.ByteArray {
        var main = [] as Lang.Array;
        // content sub-message, length 0
        encodeVarint(main, tag(contentField, WIRE_LEN));
        encodeVarint(main, 0);
        return frame(main);
    }

    // System.PingRequest with optional data payload (default empty). Smallest round-trip.
    function buildPing(data as Lang.ByteArray or Null) as Lang.ByteArray {
        var ping = [] as Lang.Array;
        if (data != null && data.size() > 0) {
            encodeVarint(ping, tag(1, WIRE_LEN)); // PingRequest.data = 1
            encodeVarint(ping, data.size());
            for (var i = 0; i < data.size(); i++) { ping.add(data[i]); }
        }
        var main = [] as Lang.Array;
        encodeVarint(main, tag(MAIN_SYSTEM_PING_REQUEST, WIRE_LEN));
        encodeVarint(main, ping.size());
        for (var i = 0; i < ping.size(); i++) { main.add(ping[i]); }
        return frame(main);
    }

    // Gui.SendInputEventRequest { key, type }
    function buildInput(key as Lang.Number, type as Lang.Number) as Lang.ByteArray {
        var ev = [] as Lang.Array;
        if (key != 0) { encodeVarint(ev, tag(1, WIRE_VARINT)); encodeVarint(ev, key); }
        if (type != 0) { encodeVarint(ev, tag(2, WIRE_VARINT)); encodeVarint(ev, type); }
        // proto3: fields equal to default (0 == UP / PRESS) are omitted; the Flipper decodes
        // the missing field as 0, which is the intended value.
        var main = [] as Lang.Array;
        encodeVarint(main, tag(MAIN_GUI_SEND_INPUT, WIRE_LEN));
        encodeVarint(main, ev.size());
        for (var i = 0; i < ev.size(); i++) { main.add(ev[i]); }
        return frame(main);
    }

    // Prefix a built PB.Main body with its varint length and materialise a ByteArray.
    function frame(mainBody as Lang.Array) as Lang.ByteArray {
        var prefixed = [] as Lang.Array;
        encodeVarint(prefixed, mainBody.size());
        for (var i = 0; i < mainBody.size(); i++) { prefixed.add(mainBody[i]); }
        var ba = new [prefixed.size()]b;
        for (var i = 0; i < prefixed.size(); i++) { ba[i] = prefixed[i]; }
        return ba;
    }
}
