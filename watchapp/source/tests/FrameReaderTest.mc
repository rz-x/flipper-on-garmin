using Toybox.Test;
using Toybox.Lang;

// Collector used as the FrameReader callback target in tests.
(:test)
class FrameCollector {
    var frames = null;
    function initialize() { frames = []; }
    function onFrame(body as Lang.ByteArray) as Void { frames.add(body); }
}

// Build a length-delimited frame carrying an arbitrary body payload.
(:test)
function wrap(payload as Lang.ByteArray) as Lang.ByteArray {
    var pre = [] as Lang.Array;
    Protocol.encodeVarint(pre, payload.size());
    var ba = new [pre.size() + payload.size()]b;
    var k = 0;
    for (var i = 0; i < pre.size(); i++) { ba[k] = pre[i]; k++; }
    for (var i = 0; i < payload.size(); i++) { ba[k] = payload[i]; k++; }
    return ba;
}

(:test)
function testWholeFrameOneFeed(logger as Test.Logger) as Lang.Boolean {
    var c = new FrameCollector();
    var r = new FrameReader(c.method(:onFrame));
    var frame = wrap([0xAA, 0xBB, 0xCC]b);
    r.feed(frame);
    Test.assertEqual(c.frames.size(), 1);
    Test.assertEqual(c.frames[0].size(), 3);
    Test.assertEqual(c.frames[0][1], 0xBB);
    return true;
}

(:test)
function testByteByByte(logger as Test.Logger) as Lang.Boolean {
    // Feeding one byte at a time must still yield exactly one frame at the end.
    var c = new FrameCollector();
    var r = new FrameReader(c.method(:onFrame));
    var frame = wrap([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]b);
    for (var i = 0; i < frame.size(); i++) {
        r.feed(frame.slice(i, i + 1));
    }
    Test.assertEqual(c.frames.size(), 1);
    Test.assertEqual(c.frames[0].size(), 10);
    return true;
}

(:test)
function testTwoFramesConcatenated(logger as Test.Logger) as Lang.Boolean {
    var c = new FrameCollector();
    var r = new FrameReader(c.method(:onFrame));
    var a = wrap([0x11]b);
    var b = wrap([0x22, 0x33]b);
    var both = new [a.size() + b.size()]b;
    var k = 0;
    for (var i = 0; i < a.size(); i++) { both[k] = a[i]; k++; }
    for (var i = 0; i < b.size(); i++) { both[k] = b[i]; k++; }
    r.feed(both);
    Test.assertEqual(c.frames.size(), 2);
    Test.assertEqual(c.frames[0][0], 0x11);
    Test.assertEqual(c.frames[1][1], 0x33);
    return true;
}

(:test)
function testMultiByteLengthPrefixSplit(logger as Test.Logger) as Lang.Boolean {
    // A 200-byte body needs a 2-byte varint length prefix (0xC8 0x01). Split the feed
    // *between* the two prefix bytes to exercise partial-varint buffering.
    var payload = new [200]b;
    for (var i = 0; i < 200; i++) { payload[i] = i & 0xFF; }
    var frame = wrap(payload);
    Test.assert(frame[0] == 0xC8 && frame[1] == 0x01); // sanity: 2-byte prefix

    var c = new FrameCollector();
    var r = new FrameReader(c.method(:onFrame));
    r.feed(frame.slice(0, 1));          // only first prefix byte
    Test.assertEqual(c.frames.size(), 0);
    r.feed(frame.slice(1, 30));         // second prefix byte + partial body
    Test.assertEqual(c.frames.size(), 0);
    r.feed(frame.slice(30, frame.size()));
    Test.assertEqual(c.frames.size(), 1);
    Test.assertEqual(c.frames[0].size(), 200);
    Test.assertEqual(c.frames[0][199], 199 & 0xFF);
    return true;
}

(:test)
function testResetClearsPartial(logger as Test.Logger) as Lang.Boolean {
    var c = new FrameCollector();
    var r = new FrameReader(c.method(:onFrame));
    r.feed([0x05, 0x01, 0x02]b);        // claims len 5, only 2 body bytes present
    Test.assertEqual(c.frames.size(), 0);
    r.reset();
    r.feed(wrap([0x42]b));              // fresh frame after reset parses cleanly
    Test.assertEqual(c.frames.size(), 1);
    Test.assertEqual(c.frames[0][0], 0x42);
    return true;
}
