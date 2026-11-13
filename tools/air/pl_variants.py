#!/usr/bin/env python3
"""pl_variants.py pipelines.desc OUT.txt : list every specialized CoreAnimation function of a pipelinelib with its
base function and function-constant values, one per line:  <published name> <base function> name=value ...
(the output is derived from the OS image: keep it on the device, do not commit it)"""
import re, struct, sys
d = open(sys.argv[1], 'rb').read()
def table(base):
    n, = struct.unpack_from('<I', d, base)
    offs = struct.unpack_from('<%dI' % n, d, base + 4)
    return [d[base + offs[i]: base + (offs[i + 1] if i + 1 < n else offs[i] + 4096)] for i in range(n)]
hdr = struct.unpack_from('<14I', d, 0)
names = [re.search(rb'com\.apple\.[\x21-\x7e]+', e).group().decode() for e in table(hdr[2])]
rec = re.compile(rb'\x03\x01\x04\x10\x00\x00\x00\x02\x04(.)\x00\x00\x00\x03(.)', re.S)
out, kinds = [], set()
for pub, e in zip(names, table(hdr[6])):
    base = re.search(rb'[a-z][a-z0-9_]+', e[32:]).group().decode()
    kv, pos = [], 0
    while True:
        m = rec.search(e, pos)
        if not m: break
        t, L = m.group(1)[0], m.group(2)[0]
        v = int.from_bytes(e[m.end():m.end() + L], 'little')
        nm_end = e.index(b'\0', m.end() + L)
        kv.append('%s=%d' % (e[m.end() + L:nm_end].decode(), v)); kinds.add((t, L)); pos = nm_end
    out.append('%s %s %s' % (pub, base, ' '.join(kv)))
open(sys.argv[2], 'w').write('\n'.join(out) + '\n')
print(len(out), 'variants; (type,len) kinds:', sorted(kinds), file=sys.stderr)
