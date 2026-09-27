using Toybox.Test;
using Toybox.Lang;

// Phase-1 wire-layer tests. Run with a unit-test build:
//   monkeyc -f monkey.jungle -o bin/test.prg -y developer_key -d descentmk2 --unit-test
//   monkeydo bin/test.prg descentmk2 -t
// (:test) functions are only compiled into unit-test builds.

(:test)
function testVarintRoundTrip(logger as Test.Logger) as Lang.Boolean {
    var cases = [0, 1, 127, 128, 300, 16383, 16384, 2097151, 1048576];
    for (var i = 0; i < cases.size(); i++) {
        var out = [] as Lang.Array;
        Protocol.encodeVarint(out, cases[i]);
        var ba = new [out.size()]b;
        for (var j = 0; j < out.size(); j++) { ba[j] = out[j]; }
        var dec = Protocol.tryDecodeVarint(ba, 0, ba.size());
        Test.assert(dec != null);
        Test.assertEqualMessage(dec[0], cases[i], "varint value " + cases[i].toString());
        Test.assertEqualMessage(dec[1], ba.size(), "varint length " + cases[i].toString());
    }
    return true;
}

(:test)
function testTryVarintIncomplete(logger as Test.Logger) as Lang.Boolean {
    // 300 = 0xAC 0x02; giving only the first (continuation) byte must return null.
    var partial = [0xAC]b;
    Test.assert(Protocol.tryDecodeVarint(partial, 0, 1) == null);
    return true;
}

(:test)
function testBuildPingFrame(logger as Test.Logger) as Lang.Boolean {
    // Empty ping: PB.Main { system_ping_request(5) = {} }.
    // body = tag(5,LEN)=0x2A, len=0x00  -> [0x2A,0x00]; frame = varint(2)+body = [0x02,0x2A,0x00].
    var f = Protocol.buildPing(null);
    Test.assertEqual(f.size(), 3);
    Test.assertEqual(f[0], 0x02);
    Test.assertEqual(f[1], 0x2A);
    Test.assertEqual(f[2], 0x00);
    return true;
}

(:test)
function testBuildInputOkShort(logger as Test.Logger) as Lang.Boolean {
    // key=OK(4), type=SHORT(2): ev = [tag(1,VARINT)=0x08,0x04, tag(2,VARINT)=0x10,0x02]
    // main = [tag(23,LEN)=0xBA 0x01, len=0x04, ev...]; frame = varint(len)+main.
    var f = Protocol.buildInput(Protocol.KEY_OK, Protocol.TYPE_SHORT);
    // Decode it back through PBMain to prove the envelope is well-formed.
    var body = f.slice(1, f.size());               // strip the frame length prefix
    var m = PBMain.decode(body);
    Test.assertEqual(m[:status], 0);               // no status field -> default 0
    return true;
}

(:test)
function testBuildInputDefaultsOmitted(logger as Test.Logger) as Lang.Boolean {
    // key=UP(0), type=PRESS(0): proto3 omits both -> empty SendInputEventRequest body.
    var f = Protocol.buildInput(Protocol.KEY_UP, Protocol.TYPE_PRESS);
    var body = f.slice(1, f.size());
    // body = tag(23,LEN)=0xBA 0x01, len=0x00
    Test.assertEqual(body[body.size() - 1], 0x00); // inner length is zero
    return true;
}
