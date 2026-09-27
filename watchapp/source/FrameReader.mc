using Toybox.Lang;

// Reassembles length-delimited PB.Main frames from the byte stream delivered by the TX
// indication. Each frame on the wire is: varint(bodyLen) + body[bodyLen]. BLE hands us
// arbitrary ~20-byte chunks, so a single frame spans many feed() calls and a chunk may
// carry a partial length prefix, several whole frames, or a frame boundary mid-varint.
//
// This is the top bug source in the project. It is written to be exercised
// with adversarial chunk boundaries in FrameReaderTest.
class FrameReader {
    // Guard against a corrupt/mis-synced stream claiming an absurd body length. A real
    // PB.Main here is a ping (tiny) or a screen frame (~1030B). 8 KiB is generous headroom.
    const MAX_BODY = 8192;

    var _buf = null;        // ByteArray accumulator of not-yet-consumed bytes
    var _onFrame = null;    // Method(ByteArray) invoked once per complete PB.Main body

    function initialize(onFrame as Lang.Method) {
        _buf = []b;
        _onFrame = onFrame;
    }

    // Discard buffered bytes (e.g. on reconnect) so a half-frame never bleeds into a new session.
    function reset() as Void {
        _buf = []b;
    }

    // Append a received chunk and emit every complete frame now available.
    function feed(chunk as Lang.ByteArray) as Void {
        _buf.addAll(chunk);
        drain();
    }

    function drain() as Void {
        while (true) {
            var n = _buf.size();
            if (n == 0) { return; }

            var v = Protocol.tryDecodeVarint(_buf, 0, n);
            if (v == null) { return; }              // length prefix not fully arrived yet

            var bodyLen = v[0];
            var headerLen = v[1];                    // bytes consumed by the varint

            if (bodyLen < 0 || bodyLen > MAX_BODY) {
                // Stream desync: drop everything rather than allocate/parse garbage.
                _buf = []b;
                return;
            }

            var total = headerLen + bodyLen;
            if (n < total) { return; }               // body still incomplete

            var body = _buf.slice(headerLen, total);
            _buf = _buf.slice(total, n);             // keep the remainder (may hold more frames)

            if (_onFrame != null) { _onFrame.invoke(body); }
        }
    }
}
