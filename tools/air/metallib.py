import struct, sys, os
def parse(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'MTLB', d[:4]
    fl_off, fl_sz, pub_off, pub_sz, priv_off, priv_sz, bc_off, bc_sz = struct.unpack_from('<8Q', d, 0x18)
    n = struct.unpack_from('<I', d, fl_off)[0]
    p = fl_off + 4
    funcs = []
    for _ in range(n):
        esz = struct.unpack_from('<I', d, p)[0]
        q = p + 4; f = {}
        while True:
            tag = d[q:q+4]; q += 4
            if tag == b'ENDT': break
            ln = struct.unpack_from('<H', d, q)[0]; q += 2
            val = d[q:q+ln]; q += ln
            if tag == b'NAME': f['name'] = val.rstrip(b'\0').decode()
            elif tag == b'TYPE': f['type'] = val[0]
            elif tag == b'MDSZ': f['bcsize'] = struct.unpack_from('<Q', val)[0]
            elif tag == b'OFFT': f['pub'], f['priv'], f['bcoff'] = struct.unpack_from('<3Q', val)
            elif tag == b'VERS': f['vers'] = struct.unpack_from('<4H', val)
            else: f.setdefault('other', []).append(tag.decode('latin1'))
        funcs.append(f)
        p += esz
    return d, bc_off, funcs
if __name__ == '__main__':
    d, bc_off, funcs = parse(sys.argv[1])
    out = sys.argv[2] if len(sys.argv) > 2 else None
    types = {0:'vertex',1:'fragment',2:'kernel',3:'unqualified',4:'visible',5:'extern',6:'intersection'}
    from collections import Counter
    print(len(funcs), 'functions', Counter(types.get(f.get('type'), f.get('type')) for f in funcs))
    for f in funcs[:6]: print(f.get('name'), types.get(f.get('type')), f.get('bcsize'), f.get('vers'), f.get('other'))
    if out:
        os.makedirs(out, exist_ok=True)
        for f in funcs:
            b = d[bc_off + f['bcoff']: bc_off + f['bcoff'] + f['bcsize']]
            open(os.path.join(out, f['name'] + '.bc'), 'wb').write(b)
