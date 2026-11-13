#!/usr/bin/env python3
"""smsp_merge.py OUT IN1 IN2 ... : concatenate shader packs; a later pack's shader replaces an earlier one with the same name."""
import struct, sys
def records(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'SMSP', path
    n, = struct.unpack_from('<I', d, 4); o = 8
    for _ in range(n):
        name = d[o:o + 64].split(b'\0')[0]
        size, = struct.unpack_from('<I', d, o + 68)
        cds, = struct.unpack_from('<I', d, o + 108)
        ln = 112 + ((size + 15) & ~15) + (((cds + 15) & ~15) if cds else 0)
        yield name, d[o:o + ln]; o += ln
out = {}
for p in sys.argv[2:]:
    for name, rec in records(p): out[name] = rec
with open(sys.argv[1], 'wb') as f:
    f.write(b'SMSP' + struct.pack('<I', len(out)))
    for rec in out.values(): f.write(rec)
print('%d shaders' % len(out))
