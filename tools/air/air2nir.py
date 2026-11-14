"""AIR (Metal LLVM IR) -> Mesa nir_builder C code. v0: straight-line functions.
Push-constant ABI (bytes):  0..63  buffer[i] GPU VA (u64)       64..191 attr[L] {u64 va, u32 stride, u32 pad}
                           192..215 viewport scale.xyz, offset.xyz (f32)
                           216..223 function-constant "defined" mask (bit k)   256..511 function constant k at 256+4k
Texture i -> pan_res_handle(4, i), sampler i -> pan_res_handle(3, i), constexpr samplers -> sampler 15.
Varyings: global name -> VAR0+slot."""
import re, sys, json
sys.setrecursionlimit(100000)
import llvmlite.binding as llb
llb.initialize(); llb.initialize_native_target(); llb.initialize_native_asmprinter()

PUSH_BUF, PUSH_ATTR, PUSH_VP, PUSH_FCDEF, PUSH_FC = 0, 64, 192, 216, 256
INLINE_SAMPLER = 15
NULL_TEXTURE = 7                            # texture slot the runtime fills with a 1x1 transparent texture
NULL_TEXTURE_3D = 6                         # ... and a 1x1x1 3D one
PUSH_CDATA_VS, PUSH_CDATA_FS = 224, 232     # u64 GPU VA of this shader's constant-global blob
PUSH_DUMMY = 240                            # u64 GPU VA of a zeroed 4 KiB scratch page: target of predicated-off memory accesses
PUSH_CS_TG = 448                            # compute: u32 threads-per-threadgroup x, y, z (function constants 48+ unusable in kernels)
PUSH_CS_TEXSZ = 464                         # compute: texture i (0..3) size as u32 (width | height << 16)
CUR_KIND = [None]                           # stage of the function being translated
PUSH_CS_TEXW = 480                          # compute: written texture i (0, 1): {u64 va, u32 row stride, u32 format (0 RGBA8, 1 BGRA8)}

class Unsupported(Exception): pass

def split_top(s, sep=','):
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch in '<{[(': depth += 1
        if ch in '>}])': depth -= 1
        if ch == sep and depth == 0: out.append(cur.strip()); cur = ''
        else: cur += ch
    if cur.strip(): out.append(cur.strip())
    return out


def split_tv(x):
    """'<2 x float> <float 1.0, float 2.0>' -> ('<2 x float>', '<float 1.0, float 2.0>')"""
    x = x.strip()
    if x[0] in '<{[':
        depth = 0
        for i, ch in enumerate(x):
            if ch in '<{[(': depth += 1
            elif ch in '>}])':
                depth -= 1
                if depth == 0:
                    j = i + 1
                    while x[j:j+1] == '>': j += 1
                    t, v = x[:j].strip(), x[j:].strip()
                    while v.startswith('addrspace') or v.startswith('*'):
                        a, v = v.split(None, 1) if ' ' in v else (v, '')
                        t += ' ' + a
                    return t, v.strip()
    t, v = x.split(None, 1)
    while v.startswith('addrspace') or v == '*':
        a, v = v.split(None, 1) if ' ' in v else (v, '')
        t += ' ' + a
    return t, v.strip()


def ptr_of(part):
    """pointer operand text -> '%x' | '@g' | 'GEP:<normalized constant gep on a global>'"""
    if 'getelementptr' in part and '@' in part:
        g = part[part.index('getelementptr'):]
        return 'GEP:' + re.sub(r'\s+', ' ', g.replace('inbounds ', '')).strip()
    if 'bitcast' in part and '@' in part:
        return re.search(r'(@[\w.$]+)', part).group(1)
    return part.rsplit(' ', 1)[1]


def cfloat(x):
    import math
    if math.isnan(x): return 'NAN'
    if math.isinf(x): return 'INFINITY' if x > 0 else '-INFINITY'
    return repr(x)

class Types:
    def __init__(self, modtext):
        self.named = {}
        for m in re.finditer(r'^(%[\w."$:<>,\- ]+?) = type (.*)$', modtext, re.M):
            self.named[m.group(1).strip()] = m.group(2).strip()
    def norm(self, t):
        t = t.strip()
        t = re.sub(r'\s+addrspace\(\d+\)\*$', '*', t)
        return t
    def layout(self, t):
        """(size, align) in bytes"""
        t = t.strip()
        if t.endswith('*'): return 8, 8
        if t in self.named: return self.layout(self.named[t])
        if t in ('float', 'i32'): return 4, 4
        if t in ('half', 'i16'): return 2, 2
        if t in ('i8', 'i1'): return 1, 1
        if t in ('double', 'i64'): return 8, 8
        m = re.match(r'^<(\d+) x (.+)>$', t)
        if m:
            n = int(m.group(1)); es, _ = self.layout(m.group(2))
            sz = n * es; al = 1
            while al < sz: al *= 2
            return al, al          # vec3 padded like vec4
        m = re.match(r'^\[(\d+) x (.+)\]$', t)
        if m:
            es, ea = self.layout(m.group(2)); return int(m.group(1)) * es, ea
        m = re.match(r'^<?\{(.*)\}>?$', t)
        if m:
            packed = t.startswith('<{')
            off, al = 0, 1
            for e in split_top(m.group(1)):
                es, ea = self.layout(e)
                if not packed: off = (off + ea - 1) // ea * ea
                off += es; al = max(al, ea)
            return (off + al - 1) // al * al if not packed else off, al
        if t == 'opaque' or t.startswith('%struct._texture') or t.startswith('%struct._sampler'): return 8, 8
        raise Unsupported('layout ' + t)
    def member(self, t, idx):
        """(offset, member type) of element idx of aggregate t"""
        t = t.strip()
        if t in self.named: return self.member(self.named[t], idx)
        m = re.match(r'^\[(\d+) x (.+)\]$', t) or re.match(r'^<(\d+) x (.+)>$', t)
        if m:
            es, _ = self.layout(m.group(2)); return idx * es, m.group(2)
        m = re.match(r'^<?\{(.*)\}>?$', t)
        packed = t.startswith('<{')
        off = 0
        for i, e in enumerate(split_top(m.group(1))):
            es, ea = self.layout(e)
            if not packed: off = (off + ea - 1) // ea * ea
            if i == idx: return off, e
            off += es
        raise Unsupported('member')

def scal(t):
    """'<4 x float>' -> (4,'float'); 'float' -> (1,'float')"""
    m = re.match(r'^<(\d+) x (\w+)>$', t.strip())
    return (int(m.group(1)), m.group(2)) if m else (1, t.strip())
BITS = {'float': 32, 'half': 16, 'i32': 32, 'i16': 16, 'i8': 8, 'i1': 1, 'i64': 64, 'double': 64}


import struct as _st
def _num(t, v):
    v = v.strip()
    if v in ('undef', 'poison', 'zeroinitializer', 'null'): v = '0'
    if v == 'true': v = '1'
    if v == 'false': v = '0'
    if t in ('float', 'half', 'double'):
        if v.startswith('0xH'): return _st.unpack('<e', _st.pack('<H', int(v[3:], 16)))[0]
        if v.startswith('0x'): return _st.unpack('<d', _st.pack('<Q', int(v, 16)))[0]
        return float(v)
    return int(v)

def const_bytes(types, t, v):
    """initializer (type text, value text) -> little-endian bytes laid out like the GPU sees it"""
    t = t.strip(); v = v.strip()
    size, _ = types.layout(t)
    if v in ('zeroinitializer', 'undef', 'poison'): return bytes(size)
    if t in types.named: t = types.named[t]
    if t in ('float',): return _st.pack('<f', _num(t, v))
    if t in ('half',): return _st.pack('<e', _num(t, v))
    if t in ('double',): return _st.pack('<d', _num(t, v))
    m = re.match(r'^i(\d+)$', t)
    if m:
        bits = int(m.group(1)); nb = max(bits // 8, 1)
        return (_num(t, v) & ((1 << (8 * nb)) - 1)).to_bytes(nb, 'little')
    m = re.match(r'^<(\d+) x (.+)>$', t) or re.match(r'^\[(\d+) x (.+)\]$', t)
    if m:
        et = m.group(2); es, _ = types.layout(et)
        inner = v[1:-1]
        out = b''
        for el in split_top(inner):
            et2, ev = split_tv(el)
            out += const_bytes(types, et2, ev).ljust(es, b'\0')
        return out.ljust(size, b'\0')
    m = re.match(r'^<?\{(.*)\}>?$', t)
    if m:
        buf = bytearray(size)
        inner = v.strip('<>{} ')
        for i, el in enumerate(split_top(inner)):
            off, et = types.member(t, i)
            et2, ev = split_tv(el)
            bb = const_bytes(types, et2, ev); buf[off:off + len(bb)] = bb
        return bytes(buf)
    raise Unsupported('const init ' + t)

class Fn:
    def __init__(self, mod, f, md, parent=None):
        self.mod, self.f, self.md = mod, f, md
        self.vals = {}
        self.cur_pred = None
        self.up = parent
        if parent is None:
            self.lines, self.ctr, self.globals = [], [0], {}   # globals: module-level mutable globals -> SSA value
            self.types = Types(str(mod))
            self.funcs = {fn.name: fn for fn in mod.functions if not fn.is_declaration}
            self.depth = 0
            self.cdata = bytearray(); self.cdata_off = {}
            self.slots = {}
            self.gtypes = {}
            for g in re.finditer(r'^(@[\w.$]+) = [^=]*?\b(?:global|constant) (.*?)(?:, section "[^"]*")?(?:, align \d+)?$', str(mod), re.M):
                try: self.gtypes[g.group(1)] = split_tv(g.group(2))[0]
                except Exception: pass
            self.cglobals = {}
            for g in re.finditer(r'^(@[\w.$]+) = (?:internal |private )?(?:unnamed_addr )?(?:addrspace\(\d+\) )?constant (.*?)(?:, align \d+)?$', str(mod), re.M):
                gname, rest = g.group(1), g.group(2)
                if 'externally_initialized' in rest or 'MTL_FC' in gname: continue
                try:
                    ty_, val_ = split_tv(rest)
                    self.cglobals[gname] = (ty_, const_bytes(self.types, ty_, val_))
                except Exception:
                    pass
        else:
            self.lines, self.ctr, self.globals, self.types, self.funcs = parent.lines, parent.ctr, parent.globals, parent.types, parent.funcs
            self.cglobals = parent.cglobals
            self.cdata, self.cdata_off, self.stage = parent.cdata, parent.cdata_off, parent.stage
            self.slots = parent.slots
            self.gtypes = parent.gtypes
            self.depth = parent.depth + 1
        self.base_pred = None
        if parent is None: self.stage = md[0] if md else 'vertex'
    def tmp(self, expr):
        self.ctr[0] += 1; v = 'v%d' % self.ctr[0]
        self.lines.append('\tnir_def *%s = %s;' % (v, expr)); return v

    def run_body(self, base_pred=None):
        """translate this function's blocks; returns {member: value} of the (merged) return value"""
        blocks = list(self.f.blocks)
        self.base_pred = base_pred
        self.rets = []
        if len(blocks) == 1 and base_pred is None:
            self.single_ret = None
            for ins in blocks[0].instructions:
                self.ins(ins)
            return self.single_ret
        if self.base_pred is None and getattr(self, 'up', None) is not None: self.base_pred = 'nir_imm_true(b)'   # inlined multi-block helper at top level
        self.if_convert(blocks, merge_outputs=False)
        if not self.rets: return {}
        final = dict(self.rets[-1][1])
        for p2, mem in reversed(self.rets[:-1]):
            for i2 in final:
                if i2 in mem: final[i2] = self.tmp('nir_bcsel(b, %s, %s, %s)' % (p2, mem[i2], final[i2]))
        return final
    def const(self, ty, txt):
        n, s = scal(ty); bits = BITS[s]
        txt = txt.strip()
        if txt in ('undef', 'zeroinitializer', 'poison'):
            return 'nir_imm_zero(b, %d, %d)' % (n, bits)
        if n == 1: return self.scalar_const(s, txt)
        m = re.match(r'^<(.*)>$', txt)
        comps = [split_top(c)[0] for c in split_top(m.group(1))]
        cs = [self.scalar_const(s, c.split(' ', 1)[1]) for c in comps]
        return 'nir_vec%d(b, %s)' % (n, ', '.join(cs)) if n > 1 else cs[0]
    def scalar_const(self, s, v):
        v = v.strip()
        if v in ('undef', 'poison', 'zeroinitializer'): v = '0'
        if s in ('float', 'half', 'double'):
            if v.startswith('0xH'):
                import struct
                fv = struct.unpack('<e', struct.pack('<H', int(v[3:], 16)))[0]
            elif v.startswith('0x'):
                import struct
                fv = struct.unpack('<d', struct.pack('<Q', int(v, 16)))[0]
            else: fv = float(v)
            return 'nir_imm_floatN_t(b, %s, %d)' % (cfloat(fv), BITS[s])
        if v == 'true': v = '1'
        if v == 'false': v = '0'
        return 'nir_imm_intN_t(b, %s, %d)' % (int(v), max(BITS[s], 1) if s != 'i1' else 1)
    def cptr(self, txt):
        """'@g' or 'getelementptr (T, T* @g, i64 0, i64 1 ...)' on a constant global -> ('cptr', g, offset, type)"""
        m = re.search(r'(@[\w.$]+)', txt)
        if not m or m.group(1) not in self.cglobals: return None
        g = m.group(1); gty, _ = self.cglobals[g]
        if 'getelementptr' not in txt: return ('cptr', g, 0, gty)
        inner = txt[txt.index('(') + 1:txt.rindex(')')]
        parts = split_top(inner)
        cur = parts[0].strip(); off = 0
        for k, ix in enumerate(parts[2:]):
            iv = int(ix.split()[-1])
            if k == 0: off += iv * self.types.layout(cur)[0]
            else:
                o, cur = self.types.member(cur, iv); off += o
        return ('cptr', g, off, cur)

    def gaddr(self, txt):
        """'@g' or constant 'getelementptr (... @g, i64 0, i32 k ...)' on a mutable global -> ('gptr', g, off, type)"""
        m = re.search(r'(@[\w.$]+)', txt)
        if not m: return None
        g = m.group(1)
        if g not in self.gtypes: return None
        gty = self.gtypes[g]
        if 'getelementptr' not in txt: return ('gptr', g, 0, gty)
        inner = txt[txt.index('(', txt.index('getelementptr')) + 1:txt.rindex(')')]
        parts = split_top(inner)
        cur = parts[0].strip(); off = 0
        for k, ix in enumerate(parts[2:]):
            iv = int(ix.split()[-1])
            if k == 0: off += iv * self.types.layout(cur)[0]
            else:
                o, cur = self.types.member(cur, iv); off += o
        return ('gptr', g, off, cur)

    def materialize(self, p):
        """constant-global pointer -> real GPU pointer ('ptr', addr, type) into the shader's constant blob"""
        if p[0] != 'cptr': return p
        _, g, off, cur = p
        if g not in self.cdata_off:
            while len(self.cdata) % 16: self.cdata.append(0)
            self.cdata_off[g] = len(self.cdata)
            self.cdata += self.cglobals[g][1]
        base = self.tmp('nir_load_push_constant(b, 1, 64, nir_imm_int(b, 0), .base = %d, .range = 8)'
                        % (PUSH_CDATA_FS if self.stage == 'fragment' else PUSH_CDATA_VS))
        return ('ptr', self.tmp('nir_iadd_imm(b, %s, %d)' % (base, self.cdata_off[g] + off)), cur)

    def merge(self, c, a, b):
        """value = c ? a : b for any value kind (C vars, pointers, texture/sampler handles, globals)"""
        if isinstance(a, str) and isinstance(b, str):
            return self.tmp('nir_bcsel(b, %s, %s, %s)' % (c, a, b))
        if a == b: return a
        ka, kb = a[0], b[0]
        if ka in ('tex', 'texdyn', 'smp', 'smpdyn') and kb in ('tex', 'texdyn', 'smp', 'smpdyn'):
            kind = 'texdyn' if ka.startswith('tex') else 'smpdyn'
            e1 = a[1] if ka.endswith('dyn') else 'nir_imm_int(b, %d)' % a[1]
            e2 = b[1] if kb.endswith('dyn') else 'nir_imm_int(b, %d)' % b[1]
            return (kind, self.tmp('nir_bcsel(b, %s, %s, %s)' % (c, e1, e2)))
        if ka == 'gptr' and kb == 'gptr' and a[1] == b[1] and a[2] == b[2]: return a
        if ka == 'cptr': a = self.materialize(a); ka = 'ptr'
        if kb == 'cptr': b = self.materialize(b); kb = 'ptr'
        if ka == 'ptr' and kb == 'ptr':
            return ('ptr', self.tmp('nir_bcsel(b, %s, %s, %s)' % (c, a[1], b[1])), a[2])
        if ka in ('ptr', 'gptr', 'choice', 'slot') and kb in ('ptr', 'gptr', 'choice', 'slot'):
            return ('choice', c, a, b)          # resolved per access: load both sides, select
        raise Unsupported('merge %s/%s' % (ka, kb))

    def default_of(self, ty):
        if ty.endswith('*'):
            if 'sampler' in ty: return ('smp', INLINE_SAMPLER)
            if 'texture' in ty: return ('tex', NULL_TEXTURE)
            return ('ptr', self.tmp('nir_imm_int64(b, 0)'), re.sub(r'\s*addrspace\(\d+\)\*$', '', ty))
        return self.tmp(self.const(ty, 'zeroinitializer'))

    def load_via(self, p, ty, al):
        """load of type ty through any pointer kind"""
        if p[0] == 'choice':
            return self.merge(p[1], self.load_via(p[2], ty, al), self.load_via(p[3], ty, al))
        if p[0] == 'gptr':
            key = (p[1], p[2])
            if key not in self.globals: self.globals[key] = self.default_of(ty)
            return self.globals[key]
        if p[0] == 'cptr':
            return self.tmp(self.cload(p, ty))
        if p[0] == 'ptr':
            n, sc = scal(ty)
            return self.tmp('nir_load_global(b, %s, %s, %d, %d)' % (self.guard(p[1]), al or 4, n, BITS[sc]))
        if p[0] == 'slot':
            v_ = self.slots.get(p[1])
            return v_ if v_ is not None else self.default_of(ty)
        if p[0] in ('smp', 'tex', 'smpdyn', 'texdyn'):
            return p
        raise Unsupported('load via ' + p[0])

    def gep_via(self, p, srcty, idxs):
        """apply getelementptr indices [(type, value)] to any pointer kind"""
        if p[0] == 'choice':
            return ('choice', p[1], self.gep_via(p[2], srcty, idxs), self.gep_via(p[3], srcty, idxs))
        if p[0] in ('slot', 'smp', 'tex', 'smpdyn', 'texdyn'):
            return p
        if p[0] in ('gptr', 'cptr'):
            kind, g, off, cur = p
            for k, (ity, iv) in enumerate(idxs):
                if not iv.lstrip('-').isdigit(): raise Unsupported('dynamic index into global')
                if k == 0: off += int(iv) * self.types.layout(srcty)[0]; cur = srcty
                else:
                    o, cur = self.types.member(cur, int(iv)); off += o
            return (kind, g, off, cur)
        if p[0] != 'ptr': raise Unsupported('gep on ' + p[0])
        addr, cur = p[1], srcty
        off_c = 0; dyn = []
        for k, (ity, iv) in enumerate(idxs):
            if k == 0:
                es, _ = self.types.layout(cur)
            else:
                if not iv.lstrip('-').isdigit() and not cur.startswith('['):
                    raise Unsupported('dynamic struct index')
                if iv.lstrip('-').isdigit():
                    o, cur = self.types.member(cur, int(iv)); off_c += o; continue
                _, cur = self.types.member(cur, 0); es, _ = self.types.layout(cur)
            if iv.lstrip('-').isdigit(): off_c += int(iv) * es
            else: dyn.append((self.val(ity, iv), es))
        for dv, es in dyn:
            addr = self.tmp('nir_iadd(b, %s, nir_imul_imm(b, nir_i2i64(b, %s), %d))' % (addr, dv, es))
        if off_c: addr = self.tmp('nir_iadd_imm(b, %s, %d)' % (addr, off_c))
        return ('ptr', addr, cur)

    def guard(self, addr):
        """if-converted code executes every path: send memory accesses of inactive paths to a dummy page"""
        if self.cur_pred is None: return addr
        dummy = self.tmp('nir_load_push_constant(b, 1, 64, nir_imm_int(b, 0), .base = %d, .range = 8)' % PUSH_DUMMY)
        return self.tmp('nir_bcsel(b, %s, %s, %s)' % (self.cur_pred, addr, dummy))

    def pval(self, ty, txt):
        """pointer-typed operand -> ('ptr', addr, pointee) tuple"""
        txt = txt.strip()
        if txt == 'null':
            return ('ptr', self.tmp('nir_imm_int64(b, 0)'), re.sub(r'\s*addrspace\(\d+\)\*$', '', ty))
        if txt.startswith('%'):
            v = self.vals[txt]
            return v if v[0] in ('tex', 'texdyn', 'smp', 'smpdyn', 'gptr', 'slot') else self.materialize(v)
        cp = self.cptr(txt)
        if cp is None:
            gp = self.gaddr(txt)
            if gp is None: raise Unsupported('pointer operand ' + txt[:40])
            return gp
        return self.materialize(cp)

    def cload(self, p, ty):
        """load of type ty from constant pointer p -> C expression"""
        _, g, off, _ = p
        data = self.cglobals[g][1]
        n, sc = scal(ty); eb = BITS[sc] // 8 if sc != 'i1' else 1
        es = eb
        vals = []
        for i in range(n):
            chunk = data[off + i * es: off + i * es + eb]
            if sc == 'float': vals.append('nir_imm_float(b, %s)' % cfloat(_st.unpack('<f', chunk)[0]))
            elif sc == 'half': vals.append('nir_imm_float16(b, %s)' % cfloat(_st.unpack('<e', chunk)[0]))
            else: vals.append('nir_imm_intN_t(b, %d, %d)' % (int.from_bytes(chunk, 'little'), BITS[sc]))
        return vals[0] if n == 1 else 'nir_vec(b, (nir_def *[]){%s}, %d)' % (', '.join(vals), n)

    def val(self, ty, txt):
        txt = txt.strip()
        m = re.search(r'MTL_FC_INIT_(\d+)_', txt)
        if txt.startswith('@') and m:
            return ('fc', int(m.group(1)))
        if txt.startswith('%'):
            if txt not in self.vals: raise Unsupported('value ' + txt)
            return self.vals[txt]
        return self.tmp(self.const(ty, txt))

    def operands(self, s):
        """split 'T a, T b' operand list text into [(type, value)]"""
        out = []
        for o in split_top(s):
            o = re.sub(r'\b(nocapture|readonly|readnone|noalias|nonnull|noundef|inreg|zeroext|signext)\b', '', o).strip()
            o = re.sub(r'\s+', ' ', o)
            t, v = split_tv(o)
            if t.endswith('*') or 'addrspace' in t:
                m = re.match(r'^(.*\*)\s*(.*)$', o)
                if m: t, v = m.group(1).strip(), m.group(2).strip()
            if not v: raise Unsupported('operand ' + o)
            out.append((t, v))
        return out

    # ---------------- entry
    def build(self):
        kind, outs, args = self.md
        params = list(self.f.arguments)
        for i, p in enumerate(params):
            name = '%' + (p.name or str(i))
            a = args[i]; ty = str(p.type)
            if a['kind'] == 'vertex_input':
                n, s = scal(ty); L = a['loc']
                base = self.tmp('nir_load_push_constant(b, 1, 64, nir_imm_int(b, 0), .base = %d, .range = 8)' % (PUSH_ATTR + 16 * L))
                stride = self.tmp('nir_load_push_constant(b, 1, 32, nir_imm_int(b, 0), .base = %d, .range = 4)' % (PUSH_ATTR + 16 * L + 8))
                vid = self.tmp('nir_load_vertex_id(b)')
                addr = self.tmp('nir_iadd(b, %s, nir_u2u64(b, nir_imul(b, %s, %s)))' % (base, vid, stride))
                self.vals[name] = self.tmp('nir_load_global(b, %s, 4, %d, %d)' % (addr, n, BITS[s]))
            elif a['kind'] == 'buffer':
                self.vals[name] = ('ptr', self.tmp('nir_load_push_constant(b, 1, 64, nir_imm_int(b, 0), .base = %d, .range = 8)' % (PUSH_BUF + 8 * a['loc'])),
                                   re.sub(r'\s*addrspace\(\d+\)\*$', '', ty))
            elif a['kind'] == 'texture':
                self.vals[name] = ('tex', a['loc'])
            elif a['kind'] == 'sampler':
                self.vals[name] = ('smp', a['loc'])
            elif a['kind'] == 'position':
                self.vals[name] = self.tmp('nir_load_frag_coord(b)')
            elif a['kind'] in ('fragment_input',):
                n, s = scal(ty)
                self.vals[name] = self.tmp('nir_load_interpolated_input(b, %d, %d, nir_load_barycentric_pixel(b, 32, .interp_mode = INTERP_MODE_SMOOTH), nir_imm_int(b, 0), .base = %d, .io_semantics.location = VARYING_SLOT_VAR0 + %d, .io_semantics.num_slots = 1)'
                                           % (n, BITS[s], a['slot'] + 1, a['slot']))
            elif a['kind'] in ('vertex_id',):
                n, sc = scal(ty)
                v = self.tmp('nir_load_vertex_id(b)')
                self.vals[name] = self.tmp('nir_u2uN(b, %s, %d)' % (v, BITS[sc])) if BITS[sc] != 32 else v
            elif a['kind'] in ('instance_id',):
                n, sc = scal(ty)
                v = self.tmp('nir_load_instance_id(b)')
                self.vals[name] = self.tmp('nir_u2uN(b, %s, %d)' % (v, BITS[sc])) if BITS[sc] != 32 else v
            elif a['kind'] == 'rt_in':
                n, sc = scal(ty)
                self.vals[name] = self.tmp('nir_load_output(b, %d, %d, nir_imm_int(b, 0), .base = %d, .dest_type = nir_type_float | %d, .io_semantics.location = FRAG_RESULT_DATA0 + %d, .io_semantics.num_slots = 1, .io_semantics.fb_fetch_output = 1)'
                                           % (n, BITS[sc], a['idx'], BITS[sc], a['idx']))
            elif a['kind'] in ('gid', 'lid', 'wgid'):
                n, sc = scal(ty)
                lid = self.tmp('nir_load_local_invocation_id(b)'); wg = self.tmp('nir_load_workgroup_id(b)')
                if a['kind'] == 'gid':
                    tg = self.tmp('nir_load_push_constant(b, 3, 32, nir_imm_int(b, 0), .base = %d, .range = 12)' % PUSH_CS_TG)
                    v = self.tmp('nir_iadd(b, nir_imul(b, %s, %s), %s)' % (wg, tg, lid))
                else:
                    v = lid if a['kind'] == 'lid' else wg
                v = self.tmp('nir_channels(b, %s, %d)' % (v, (1 << n) - 1)) if n < 3 else v
                self.vals[name] = self.tmp('nir_u2uN(b, %s, %d)' % (v, BITS[sc])) if BITS[sc] != 32 else v
            elif a['kind'] == 'point_coord':
                self.vals[name] = self.tmp('nir_imm_zero(b, 2, 32)')
            elif a['kind'] == 'unused':
                pass
            else:
                raise Unsupported('arg kind ' + a['kind'])
        out = self.run_body()
        if out is not None: self.emit_outputs(out)
        return '\n'.join(self.lines)

    # ---------------- control flow -> predicated straight-line code (loops: predicated unrolling)
    LOOP_UNROLL = 4

    def if_convert(self, blocks, merge_outputs=False):
        nargs = len(list(self.f.arguments))
        labels = []
        for k, bb in enumerate(blocks):
            first = str(bb).lstrip('\n').split('\n', 1)[0]
            m = re.match(r'^([\w.\-]+):', first)
            labels.append('%' + m.group(1) if m else ('%' + str(nargs) if k == 0 else None))
        idx = {l: k for k, l in enumerate(labels)}
        terms = []
        for bb in blocks:
            terms.append(re.sub(r',\s*!\w+ !\d+', '', str(list(bb.instructions)[-1]).strip()))
        succ = [[idx[x] for x in re.findall(r'label (%[\w.\-]+)', t)] for t in terms]
        preds_of = [[] for _ in blocks]
        for k, ss in enumerate(succ):
            for s2 in ss: preds_of[s2].append(k)
        # back edges via DFS
        back, state = set(), [0] * len(blocks)
        def dfs(k):
            state[k] = 1
            for s2 in succ[k]:
                if state[s2] == 1: back.add((k, s2))
                elif state[s2] == 0: dfs(s2)
            state[k] = 2
        dfs(0)
        loops = {}     # header -> (latch, body set)
        for (L, H) in back:
            body = {H, L}; work = [L] if L != H else []
            while work:
                x = work.pop()
                for p2 in preds_of[x]:
                    if p2 not in body and (p2, x) not in back: body.add(p2); work.append(p2)
            if H in loops: raise Unsupported('loop with several latches')
            loops[H] = (L, body)
        for H, (L, body) in loops.items():
            for H2, (L2, body2) in loops.items():
                if H != H2 and body & body2: raise Unsupported('nested loops')
        # topological order of the DAG without back edges
        order, state = [], [0] * len(blocks)
        def topo(k):
            if state[k]: return
            state[k] = 1
            for s2 in succ[k]:
                if (k, s2) not in back: topo(s2)
            order.append(k)
        topo(0)
        order.reverse()
        self.labels, self.edge = labels, {}
        self.exitsnaps = {}       # (from, to) -> [(pred, vals snapshot)]  for edges leaving a loop
        self.loopblocks = set()
        for H, (L, body) in loops.items(): self.loopblocks |= body
        self.blk_pred = {0: self.base_pred if self.base_pred else self.tmp('nir_imm_true(b)')}
        self.rets = []
        done = set()
        for k in order:
            if k in done: continue
            if k in loops:
                L, body = loops[k]
                border = [x for x in order if x in body]
                outside_in = [e for e in self.edge if e[1] == k and e[0] not in body]
                for it in range(self.LOOP_UNROLL):
                    if it == 0:
                        p0 = None
                        for e in outside_in: p0 = self.edge[e] if p0 is None else self.tmp('nir_ior(b, %s, %s)' % (p0, self.edge[e]))
                        hp = p0 if p0 is not None else (self.base_pred or 'nir_imm_true(b)')   # loop header = entry block
                        self.loop_entry = ('first', outside_in)
                    else:
                        hp = latch_pred
                        self.loop_entry = ('latch', L, latch_vals)
                    for x in body:
                        self.blk_pred.pop(x, None)
                        for e in list(self.edge):
                            if e[0] in body and e[1] in body: pass
                    self.blk_pred[k] = hp
                    for x in border:
                        self.process_block(blocks, x, terms, idx, body, it)
                    latch_pred = self.edge.pop((L, k), 'nir_imm_false(b)')
                    latch_vals = dict(self.vals)
                done |= body
                self.loop_entry = None
                continue
            self.process_block(blocks, k, terms, idx, None, 0)

    def process_block(self, blocks, k, terms, idx, loopbody, it):
        if k not in self.blk_pred:
            ins_edges = [self.edge[e] for e in self.edge if e[1] == k]
            for e, snaps in self.exitsnaps.items():
                if e[1] == k:
                    for p2, _ in snaps: ins_edges.append(p2)
            if not ins_edges: return
            p = ins_edges[0]
            for e2 in ins_edges[1:]: p = self.tmp('nir_ior(b, %s, %s)' % (p, e2))
            self.blk_pred[k] = p
        P = self.blk_pred[k]
        self.cur_block, self.cur_pred = k, P
        for ins in list(blocks[k].instructions)[:-1]:
            self.ins(ins)
        t = terms[k]
        new_edges = []
        m = re.match(r'^br label (%[\w.\-]+)$', t)
        m2 = re.match(r'^br i1 (\S+), label (%[\w.\-]+), label (%[\w.\-]+)$', t)
        m3 = re.match(r'^switch (\w+) (\S+), label (%[\w.\-]+) \[(.*)\]$', t, re.S)
        if m:
            new_edges.append((idx[m.group(1)], P))
        elif m2:
            c = self.val('i1', m2.group(1))
            new_edges.append((idx[m2.group(2)], self.tmp('nir_iand(b, %s, %s)' % (P, c))))
            new_edges.append((idx[m2.group(3)], self.tmp('nir_iand(b, %s, nir_inot(b, %s))' % (P, c))))
        elif m3:
            ty, v, dflt, cases = m3.groups()
            V = self.val(ty, v)
            any_case = None
            for cv, cl in re.findall(r'\w+ (-?\d+), label (%[\w.\-]+)', cases):
                eq = self.tmp('nir_ieq_imm(b, %s, %s)' % (V, cv))
                any_case = eq if any_case is None else self.tmp('nir_ior(b, %s, %s)' % (any_case, eq))
                new_edges.append((idx[cl], self.tmp('nir_iand(b, %s, %s)' % (P, eq))))
            new_edges.append((idx[dflt], self.tmp('nir_iand(b, %s, nir_inot(b, %s))' % (P, any_case)) if any_case else P))
        elif t.startswith('ret'):
            self.ins_text_ret(t, P)
        elif t.startswith('unreachable'):
            pass
        else:
            raise Unsupported('terminator ' + t.split()[0])
        merged = {}
        for to, pe in new_edges:
            merged[to] = self.tmp('nir_ior(b, %s, %s)' % (merged[to], pe)) if to in merged else pe
        for to, pe in merged.items():
            if loopbody is not None and to not in loopbody:
                self.exitsnaps.setdefault((k, to), []).append((pe, dict(self.vals)))
            else:
                self.edge[(k, to)] = pe

    def ins_text_ret(self, t, P):
        m = re.match(r'^ret (.+) (\S+)$', t)
        if t == 'ret void' or not m: self.rets.append((P, {})); return
        ty, v = m.groups()
        self.rets.append((P, self.ret_members(ty, v)))

    def phi(self, rhs):
        body = rhs[len('phi '):]
        i0 = body.index('[')
        ty, rest = body[:i0].strip(), body[i0:]
        inc = []
        for part in split_top(rest):
            part = part.strip()[1:-1]
            v, lab = part.rsplit(',', 1)
            inc.append((v.strip(), lab.strip()))
        idx0 = {l: k for k, l in enumerate(self.labels)}
        le = getattr(self, 'loop_entry', None)
        lb = getattr(self, 'loopblocks', set())
        cur = self.cur_block
        exits = getattr(self, 'exitsnaps', {})
        if le is not None and le[0] == 'latch':
            for v, lab in inc:
                if idx0[lab] == le[1]:
                    if v.startswith('%'):
                        old = le[2].get(v)
                        if old is None: raise Unsupported('loop-carried value missing')
                        return old
                    return self.pval(ty, v) if '*' in ty else self.val(ty, v)
        # keep only incoming edges that exist in this pass (drops the not-yet-taken back edge of a loop header)
        cands = []
        for v, lab in inc:
            e = (idx0[lab], cur)
            if e in exits:
                for pe, vals in exits[e]:
                    cv = vals.get(v) if v.startswith('%') else (self.pval(ty, v) if '*' in ty else self.val(ty, v))
                    if cv is None: raise Unsupported('exit phi value')
                    cands.append((pe, cv))
                continue
            if e not in self.edge and idx0[lab] in lb and cur in lb: continue
            cv = self.pval(ty, v) if '*' in ty else self.val(ty, v)
            cands.append((self.edge.get(e, 'nir_imm_false(b)'), cv))
        if not cands: raise Unsupported('phi without incoming')
        res = cands[-1][1]
        for pe, cv in reversed(cands[:-1]):
            res = self.merge(pe, cv, res)
        return res

    def ins(self, ins):
        t = str(ins).strip()
        t = re.sub(r',\s*!\w+ !\d+', '', t)
        m = re.match(r'^(%[\w.]+) = (.*)$', t)
        dst, rhs = (m.group(1), m.group(2)) if m else (None, t)
        rhs = re.sub(r'\b(fast|nnan|ninf|nsz|arcp|contract|afn|reassoc|nuw|nsw|exact|inbounds|tail)\b\s*', '', rhs).strip()
        op = rhs.split()[0]
        R = None
        if op in ('fadd', 'fsub', 'fmul', 'fdiv', 'add', 'sub', 'mul', 'and', 'or', 'xor', 'shl', 'lshr', 'ashr', 'udiv', 'sdiv', 'urem', 'srem', 'frem'):
            parts = split_top(rhs.split(None, 1)[1])
            ty, a = split_tv(parts[0]); bb = parts[1]
            fn = {'fadd': 'fadd', 'fsub': 'fsub', 'fmul': 'fmul', 'fdiv': 'fdiv', 'add': 'iadd', 'sub': 'isub', 'mul': 'imul',
                  'and': 'iand', 'or': 'ior', 'xor': 'ixor', 'shl': 'ishl', 'lshr': 'ushr', 'ashr': 'ishr',
                  'udiv': 'udiv', 'sdiv': 'idiv', 'urem': 'umod', 'srem': 'irem', 'frem': 'fmod'}[op]
            R = self.tmp('nir_%s(b, %s, %s)' % (fn, self.val(ty, a), self.val(ty, bb)))
        elif op == 'fneg':
            ty, a = split_tv(rhs.split(None, 1)[1]); R = self.tmp('nir_fneg(b, %s)' % self.val(ty, a))
        elif op in ('fcmp', 'icmp'):
            _, pred, rest = rhs.split(None, 2)
            parts = split_top(rest)
            ty, a = split_tv(parts[0]); bb = parts[1]
            A, B = self.val(ty, a), self.val(ty, bb)
            tab = {'oeq': ('feq', 0), 'ueq': ('feq', 0), 'one': ('fneu', 0), 'une': ('fneu', 0), 'olt': ('flt', 0), 'ult': ('flt', 0),
                   'ogt': ('flt', 1), 'ugt': ('flt', 1), 'oge': ('fge', 0), 'uge': ('fge', 0), 'ole': ('fge', 1), 'ule': ('fge', 1),
                   'eq': ('ieq', 0), 'ne': ('ine', 0), 'ult_i': ('ult', 0), 'slt': ('ilt', 0), 'sgt': ('ilt', 1), 'sge': ('ige', 0), 'sle': ('ige', 1),
                   'ugt_i': ('ult', 1), 'uge_i': ('uge', 0), 'ule_i': ('uge', 1)}
            key = pred + ('_i' if op == 'icmp' and pred in ('ult', 'ugt', 'uge', 'ule') else '')
            if key == 'true': R = self.tmp('nir_imm_true(b)')
            else:
                fn, sw = tab[key]
                R = self.tmp('nir_%s(b, %s, %s)' % (fn, B if sw else A, A if sw else B))
        elif op == 'select':
            ops = self.operands(rhs[len('select '):])
            h1 = self.vals.get(ops[1][1]) if ops[1][1].startswith('%') else None
            h2 = self.vals.get(ops[2][1]) if ops[2][1].startswith('%') else None
            if isinstance(h1, tuple) and h1[0] in ('tex', 'smp', 'texdyn', 'smpdyn') or isinstance(h2, tuple) and h2[0] in ('tex', 'smp', 'texdyn', 'smpdyn'):
                if h1 is None: h1 = ('tex', NULL_TEXTURE) if 'texture' in ops[1][0] else ('smp', INLINE_SAMPLER)
                if h2 is None: h2 = ('tex', NULL_TEXTURE) if 'texture' in ops[2][0] else ('smp', INLINE_SAMPLER)
                kind = 'texdyn' if h1[0] in ('tex', 'texdyn') else 'smpdyn'
                e1 = h1[1] if h1[0].endswith('dyn') else 'nir_imm_int(b, %d)' % h1[1]
                e2 = h2[1] if h2[0].endswith('dyn') else 'nir_imm_int(b, %d)' % h2[1]
                self.vals[dst] = (kind, self.tmp('nir_bcsel(b, %s, %s, %s)' % (self.val(*ops[0]), e1, e2))); return
            if '*' in ops[1][0]:
                a1 = self.pval(*ops[1]); a2 = self.pval(*ops[2])
                self.vals[dst] = self.merge(self.val(*ops[0]), a1, a2); return
            R = self.tmp('nir_bcsel(b, %s, %s, %s)' % tuple(self.val(*o) for o in ops))
        elif op in ('zext', 'sext', 'trunc', 'fpext', 'fptrunc', 'bitcast', 'sitofp', 'uitofp', 'fptosi', 'fptoui'):
            body, dty = rhs.split(None, 1)[1].rsplit(' to ', 1)
            sty, v = split_tv(body)
            if sty.endswith('*'):
                p = self.vals[v] if v in self.vals else self.cptr(body)
                if p is None: raise Unsupported('bitcast of ' + v[:30])
                if p[0] in ('slot', 'smp', 'tex'): self.vals[dst] = p; return
                if p[0] == 'cptr': self.vals[dst] = p; return
                self.vals[dst] = (p[0], p[1], re.sub(r'\s*addrspace\(\d+\)\*$', '', dty)); return
            A = self.val(sty, v); _, ds = scal(dty); _, ss = scal(sty); db = BITS[ds]
            if op == 'zext': R = self.tmp('nir_b2iN(b, %s, %d)' % (A, db)) if ss == 'i1' else self.tmp('nir_u2uN(b, %s, %d)' % (A, db))
            elif op == 'sext': R = self.tmp('nir_ineg(b, nir_b2iN(b, %s, %d))' % (A, db)) if ss == 'i1' else self.tmp('nir_i2iN(b, %s, %d)' % (A, db))
            elif op == 'trunc': R = self.tmp('nir_ine_imm(b, %s, 0)' % A) if ds == 'i1' else self.tmp('nir_u2uN(b, %s, %d)' % (A, db))
            elif op in ('fpext', 'fptrunc'): R = self.tmp('nir_f2fN(b, %s, %d)' % (A, db))
            elif op == 'sitofp': R = self.tmp('nir_i2fN(b, %s, %d)' % (A, db))
            elif op == 'uitofp': R = self.tmp('nir_u2fN(b, %s, %d)' % (A, db))
            elif op == 'fptosi': R = self.tmp('nir_f2iN(b, %s, %d)' % (A, db))
            elif op == 'fptoui': R = self.tmp('nir_f2uN(b, %s, %d)' % (A, db))
            else:
                dn, _ = scal(dty)
                R = self.tmp('nir_bitcast_vector(b, %s, %d)' % (A, db)) if BITS[ds] != BITS[ss] else A
        elif op == 'extractelement':
            parts = split_top(rhs[len('extractelement '):])
            vt, v = split_tv(parts[0]); it, iv = split_tv(parts[1])
            if not iv.isdigit():
                n_, _ = scal(vt)
                V = self.val(vt, v); I = self.val(it, iv)
                acc = 'nir_channel(b, %s, 0)' % V
                for c in range(1, n_):
                    acc = 'nir_bcsel(b, nir_ieq_imm(b, %s, %d), nir_channel(b, %s, %d), %s)' % (I, c, V, c, acc)
                R = self.tmp(acc)
            else:
                R = self.tmp('nir_channel(b, %s, %s)' % (self.val(vt, v), iv))
        elif op == 'insertelement':
            parts = split_top(rhs[len('insertelement '):])
            vt, v = split_tv(parts[0]); et, e = split_tv(parts[1]); it, idx = split_tv(parts[2])
            if not idx.isdigit():
                n_, _ = scal(vt)
                V0 = self.val(vt, v); E = self.val(et, e); I = self.val(it, idx)
                comps = ['nir_bcsel(b, nir_ieq_imm(b, %s, %d), %s, nir_channel(b, %s, %d))' % (I, c, E, V0, c) for c in range(n_)]
                self.vals[dst] = self.tmp('nir_vec(b, (nir_def *[]){%s}, %d)' % (', '.join(comps), n_)); return
            R = self.tmp('nir_vector_insert_imm(b, %s, %s, %s)' % (self.val(vt, v), self.val(et, e), idx))
        elif op == 'shufflevector':
            parts = split_top(rhs[len('shufflevector '):])
            t1, a = split_tv(parts[0]); t2, bb = split_tv(parts[1]); mt, mask = split_tv(parts[2])
            n1, s = scal(t1); nm, _ = scal(mt)
            A = self.val(t1, a); B = self.val(t2, bb) if bb not in ('undef', 'poison') else None
            if mask.strip() == 'zeroinitializer': idx = [0] * nm
            else: idx = [(-1 if 'undef' in c or 'poison' in c else int(c.split()[-1])) for c in split_top(mask.strip()[1:-1])]
            ch = []
            for k in idx:
                if k < 0: ch.append('nir_imm_zero(b, 1, %d)' % BITS[s])
                elif k < n1: ch.append('nir_channel(b, %s, %d)' % (A, k))
                else: ch.append('nir_channel(b, %s, %d)' % (B, k - n1))
            R = self.tmp(('nir_vec(b, (nir_def *[]){%s}, %d)' % (', '.join(ch), len(ch))) if len(ch) > 1 else ch[0])
        elif op == 'extractvalue':
            parts = split_top(rhs[len('extractvalue '):])
            aggty, agg = parts[0].rsplit(' ', 1)
            idx = int(parts[1])
            A = self.vals[agg]
            if isinstance(A, dict): R = A[idx]
            else: raise Unsupported('extractvalue of non-struct')
        elif op == 'insertvalue':
            parts = split_top(rhs[len('insertvalue '):])
            aggty, a = parts[0].rsplit(' ', 1)
            et, e = parts[1].rsplit(' ', 1)
            idx = int(parts[2])
            A = dict(self.vals[a]) if a.startswith('%') else {}
            A[idx] = self.val(et, e)
            self.vals[dst] = A; return
        elif op == 'getelementptr':
            body = rhs[len('getelementptr '):]
            parts = split_top(body)
            srcty = parts[0]; ptrty, ptr = parts[1].rsplit(' ', 1)
            p = self.vals[ptr] if ptr in self.vals else (self.cptr(parts[1]) or self.gaddr(parts[1]))
            if p is None: raise Unsupported('gep base ' + ptr[:30])
            self.vals[dst] = self.gep_via(p, srcty, [x.rsplit(' ', 1) for x in parts[2:]]); return
        elif op == 'load':
            parts = split_top(rhs[len('load '):])
            ty = parts[0].strip()
            ptr = ptr_of(parts[1])
            al = parts[2].split()[-1] if len(parts) > 2 and parts[2].startswith('align') else '4'
            n, s = scal(ty)
            fc = re.search(r'MTL_FC_INIT_(\d+)_', ptr)
            if ptr.startswith('@') and fc:
                k = int(fc.group(1))
                w = self.tmp('nir_load_push_constant(b, 1, 32, nir_imm_int(b, 0), .base = %d, .range = 4)' % (PUSH_FC + 4 * k))
                if n != 1:
                    if BITS[s] * n > 32: raise Unsupported('wide vector function constant')
                    eb = BITS[s]
                    comps = ['nir_u2uN(b, nir_iand_imm(b, nir_ushr_imm(b, %s, %d), %d), %d)' % (w, eb * c, (1 << eb) - 1, eb) for c in range(n)]
                    self.vals[dst] = self.tmp('nir_vec(b, (nir_def *[]){%s}, %d)' % (', '.join(comps), n)); return
                if s in ('float',): R = w
                elif s == 'half': R = self.tmp('nir_f2f16(b, nir_bitcast_vector(b, %s, 32))' % w)
                elif s == 'i1': R = self.tmp('nir_ine_imm(b, %s, 0)' % w)
                else: R = self.tmp('nir_u2uN(b, %s, %d)' % (w, BITS[s])) if BITS[s] != 32 else w
                self.vals[dst] = R; return
            if (ptr.startswith('@') or ptr.startswith('GEP:')) and self.cptr(parts[1]) is None:
                gp = self.gaddr(parts[1])
                if gp is None: raise Unsupported('load from ' + ptr[:40])
                key = (gp[1], gp[2])
                if key not in self.globals: self.globals[key] = self.tmp(self.const(ty, 'zeroinitializer'))
                self.vals[dst] = self.globals[key]; return
            if not ptr.startswith('%'):
                cp = self.cptr(parts[1])
                if cp is None: raise Unsupported('load from ' + ptr[:40])
                self.vals[dst] = self.tmp(self.cload(cp, ty)); return
            p = self.vals[ptr]
            if ty.endswith('*'):
                if p[0] == 'ptr': raise Unsupported('pointer loaded from memory')
                self.vals[dst] = self.load_via(p, ty, al); return
            if ty.startswith('%') or ty.startswith('{') or ty.startswith('['):
                if p[0] in ('smp', 'tex', 'smpdyn', 'texdyn', 'slot'): self.vals[dst] = self.load_via(p, ty, al); return
                raise Unsupported('aggregate load')
            self.vals[dst] = self.load_via(p, ty, al); return
            if ty.startswith('%') or ty.startswith('{') or ty.startswith('['): raise Unsupported('aggregate load')
            R = self.tmp('nir_load_global(b, %s, %s, %d, %d)' % (self.guard(p[1]), al or 4, n, BITS[s]))
        elif op == 'store':
            parts = split_top(rhs[len('store '):])
            ty, v = split_tv(parts[0])
            ptr = ptr_of(parts[1])
            al = parts[2].split()[-1] if len(parts) > 2 and parts[2].startswith('align') else '4'
            if ptr.startswith('%') and isinstance(self.vals.get(ptr), tuple) and self.vals[ptr][0] == 'slot':
                key = self.vals[ptr][1]
                if '*' in ty or v.startswith('%') and isinstance(self.vals.get(v), tuple):
                    self.slots[key] = self.vals[v] if v.startswith('%') else self.pval(ty, v)
                else:
                    nv = self.val(ty, v); old_v = self.slots.get(key)
                    if self.cur_pred is not None and isinstance(old_v, str):
                        nv = self.tmp('nir_bcsel(b, %s, %s, %s)' % (self.cur_pred, nv, old_v))
                    self.slots[key] = nv
                return
            pv_ = self.vals.get(ptr) if ptr.startswith('%') else None
            if isinstance(pv_, tuple) and pv_[0] == 'choice':
                raise Unsupported('store through selected pointer')
            gp = None
            if ptr.startswith('@') or ptr.startswith('GEP:'): gp = self.gaddr(parts[1])
            elif ptr.startswith('%') and isinstance(self.vals.get(ptr), tuple) and self.vals[ptr][0] == 'gptr': gp = self.vals[ptr]
            if gp is not None:
                key = (gp[1], gp[2])
                nv = self.pval(ty, v) if ty.endswith('*') else self.val(ty, v)
                old_v = self.globals.get(key)
                if self.cur_pred is not None and old_v is not None:
                    nv = self.merge(self.cur_pred, nv, old_v)
                self.globals[key] = nv; return
            sv = self.val(ty, v)
            self.lines.append('\tnir_store_global(b, %s, %s, %s, BITFIELD_MASK(%s->num_components));' % (self.guard(self.vals[ptr][1]), al or 4, sv, sv)); return
        elif op == 'call':
            R = self.call(rhs)
            if R is None: return
        elif op == 'alloca':
            key = '%s#%d' % (dst, self.ctr[0]); self.slots[key] = None
            self.vals[dst] = ('slot', key); return
        elif op == 'phi':
            R = self.phi(rhs)
        elif op == 'ret':
            self.ret(rhs); return
        else:
            raise Unsupported('opcode ' + op)
        if dst: self.vals[dst] = R

    def call(self, rhs):
        m = re.match(r'^call (.+?) @([\w.]+)\((.*)\)( #\d+)?$', rhs)
        if not m: raise Unsupported('call syntax')
        rty, fn, args = m.group(1), m.group(2), m.group(3)
        ops = self.operands(args) if args.strip() else []
        base = re.sub(r'(\.(v\d+)?[fiu]\d+)+$', '', fn)
        V = lambda k: self.val(*ops[k])
        n, s = scal(rty) if not rty.startswith('{') else (0, '')
        un = {'air.fast_saturate': 'fsat', 'air.saturate': 'fsat', 'air.fast_fabs': 'fabs', 'air.fabs': 'fabs', 'air.fast_floor': 'ffloor',
              'air.floor': 'ffloor', 'air.fast_ceil': 'fceil', 'air.fast_sqrt': 'fsqrt', 'air.sqrt': 'fsqrt', 'air.fast_rsqrt': 'frsq',
              'air.fast_fract': 'ffract', 'air.fract': 'ffract', 'air.sign': 'fsign', 'air.fast_log2': 'flog2', 'air.fast_sin': 'fsin',
              'air.fast_cos': 'fcos', 'air.fast_exp': 'fexp2', 'air.exp': 'fexp2', 'air.fast_log': 'flog2', 'air.log': 'flog2',
              'air.exp2': 'fexp2', 'air.fast_exp2': 'fexp2', 'air.rsqrt': 'frsq', 'air.log2': 'flog2', 'air.sin': 'fsin', 'air.cos': 'fcos',
              'air.dfdx': 'fddx', 'air.dfdy': 'fddy'}
        bi = {'air.fast_fmax': 'fmax', 'air.fmax': 'fmax', 'air.fast_fmin': 'fmin', 'air.fmin': 'fmin', 'air.min.s': 'imin', 'air.min.u': 'umin',
              'air.powr': 'fpow', 'air.fast_powr': 'fpow', 'air.fast_pow': 'fpow', 'air.pow': 'fpow'}
        if fn in self.funcs:
            if self.depth > 8: raise Unsupported('inline depth')
            callee = self.funcs[fn]
            sub = Fn(self.mod, callee, None, parent=self)
            params = list(callee.arguments)
            for k2, prm in enumerate(params):
                pname = '%' + (prm.name or str(k2))
                t2, v2 = ops[k2]
                if '__air_sampler_state' in v2 or '__air_sampler_state' in t2: sub.vals[pname] = ('smp', INLINE_SAMPLER)
                elif v2.startswith('%') and isinstance(self.vals.get(v2), tuple): sub.vals[pname] = self.vals[v2]
                elif v2.startswith('%') or not ('*' in t2): sub.vals[pname] = self.val(t2, v2)
                else:
                    cp = self.cptr(v2) or self.gaddr(v2)
                    if cp is None: raise Unsupported('pointer constant arg to ' + fn[:30])
                    sub.vals[pname] = cp
            res = sub.run_body(self.cur_pred)
            if res is None or rty == 'void': return None
            if rty.startswith('{') or rty.startswith('<{'): return res
            return res.get(0)
        if base in un:
            e = 'nir_%s(b, %s)' % (un[base], V(0))
            if base in ('air.fast_exp', 'air.exp'): e = 'nir_fexp2(b, nir_fmul_imm(b, %s, 1.4426950408889634))' % V(0)
            if base in ('air.fast_log', 'air.log'): e = 'nir_fmul_imm(b, nir_flog2(b, %s), 0.6931471805599453)' % V(0)
            return self.tmp(e)
        if base in bi: return self.tmp('nir_%s(b, %s, %s)' % (bi[base], V(0), V(1)))
        if base in ('air.fma',): return self.tmp('nir_ffma(b, %s, %s, %s)' % (V(0), V(1), V(2)))
        if base in ('air.mix',): return self.tmp('nir_flrp(b, %s, %s, %s)' % (V(0), V(1), V(2)))
        if base in ('air.clamp', 'air.fast_clamp'): return self.tmp('nir_fclamp(b, %s, %s, %s)' % (V(0), V(1), V(2)))
        if base == 'air.dot': return self.tmp('nir_fdot(b, %s, %s)' % (V(0), V(1)))
        if base == 'air.fwidth': return self.tmp('nir_fadd(b, nir_fabs(b, nir_fddx(b, %s)), nir_fabs(b, nir_fddy(b, %s)))' % (V(0), V(0)))
        if base == 'air.fast_atan2': return self.tmp('nir_atan2(b, %s, %s)' % (V(0), V(1)))
        if base.startswith('air.convert'):
            dk = fn.split('.')[2]; sk = fn.split('.')[-2]
            A = V(0); db = BITS[s]
            if dk == 'f': return self.tmp(('nir_f2fN' if sk == 'f' else 'nir_i2fN' if sk == 's' else 'nir_u2fN') + '(b, %s, %d)' % (A, db))
            if dk == 's': return self.tmp(('nir_f2iN' if sk == 'f' else 'nir_i2iN') + '(b, %s, %d)' % (A, db))
            if dk == 'u': return self.tmp(('nir_f2uN' if sk == 'f' else 'nir_u2uN') + '(b, %s, %d)' % (A, db))
        if base == 'air.is_function_constant_defined':
            k = int(re.search(r'MTL_FC_INIT_(\d+)_', args).group(1))
            mask = self.tmp('nir_load_push_constant(b, 1, 64, nir_imm_int(b, 0), .base = %d, .range = 8)' % PUSH_FCDEF)
            return self.tmp('nir_ine_imm(b, nir_iand_imm(b, %s, %du), 0)' % (mask, 1 << k) if k < 32 else
                            'nir_ine_imm(b, nir_iand(b, %s, nir_imm_int64(b, 1ull << %d)), 0)' % (mask, k))
        if base in ('air.any', 'air.all'):
            A = V(0); nn, _ = scal(ops[0][0])
            acc = 'nir_channel(b, %s, 0)' % A
            for c in range(1, nn): acc = 'nir_%s(b, %s, nir_channel(b, %s, %d))' % ('ior' if base == 'air.any' else 'iand', acc, A, c)
            return self.tmp(acc)
        if base == 'air.unpack.unorm4x8':
            r = self.tmp('nir_unpack_unorm_4x8(b, %s)' % V(0))
            return self.tmp('nir_f2fN(b, %s, %d)' % (r, BITS[s])) if BITS[s] != 32 else r
        if base in ('air.get_width_texture_2d', 'air.get_height_texture_2d') and CUR_KIND[0] == 'kernel':
            # kernels: size from the push block (a size query became an unencodable TEX_GATHER in compute shaders)
            th = self.vals[ops[0][1]] if ops[0][1].startswith('%') else ('tex', NULL_TEXTURE)
            if th[0] != 'tex' or th[1] > 3: raise Unsupported('kernel texture size slot')
            w = self.tmp('nir_load_push_constant(b, 1, 32, nir_imm_int(b, 0), .base = %d, .range = 4)' % (PUSH_CS_TEXSZ + 4 * th[1]))
            return self.tmp('nir_iand_imm(b, %s, 0xffff)' % w) if 'width' in base else self.tmp('nir_ushr_imm(b, %s, 16)' % w)
        if base in ('air.get_width_texture_2d', 'air.get_height_texture_2d'):
            th = self.vals[ops[0][1]] if ops[0][1].startswith('%') else ('tex', NULL_TEXTURE)
            te = th[1] if th[0] == 'texdyn' else 'nir_imm_int(b, %d)' % th[1]
            lod = V(1) if len(ops) > 1 else 'nir_imm_int(b, 0)'
            sz = self.tmp('sm_txs_dyn(b, %s, %s)' % (te, lod))
            return self.tmp('nir_channel(b, %s, %d)' % (sz, 0 if 'width' in base else 1))
        if base == 'air.get_null_texture_2d':
            return ('tex', NULL_TEXTURE)
        if base == 'air.get_null_texture_3d':
            return ('tex', NULL_TEXTURE_3D)
        if base == 'air.normalize_function_constant_predicate':
            return V(0)
        if base == 'air.read_texture_2d':
            th = self.vals[ops[0][1]]
            m2 = re.match(r'\{ <(\d+) x (\w+)>', rty); nn, ss = int(m2.group(1)), m2.group(2)
            if th[0] == 'texdyn':
                r = self.tmp('sm_txf_dyn(b, %s, %s, %s, %d)' % (V(1), V(2), th[1], BITS[ss]))
                return {0: r}
            tex = th[1]
            r = self.tmp('nir_txf(b, %s, .texture_index = pan_res_handle(4, %d), .dest_type = nir_type_float%d, .lod = %s)'
                         % (V(1), tex, BITS[ss], V(2)) if False else
                         'sm_txf(b, %s, %s, %d, %d)' % (V(1), V(2), tex, BITS[ss]))
            return {0: r}
        if base == 'air.write_texture_2d':
            # compute-only: store straight to the texture's linear memory (address/pitch/format from the push block)
            th = self.vals[ops[0][1]]
            if th[0] != 'tex' or th[1] > 1: raise Unsupported('write_texture_2d slot')
            o = PUSH_CS_TEXW + 16 * th[1]
            va = self.tmp('nir_load_push_constant(b, 1, 64, nir_imm_int(b, 0), .base = %d, .range = 8)' % o)
            pitch = self.tmp('nir_load_push_constant(b, 1, 32, nir_imm_int(b, 0), .base = %d, .range = 4)' % (o + 8))
            fmt = self.tmp('nir_load_push_constant(b, 1, 32, nir_imm_int(b, 0), .base = %d, .range = 4)' % (o + 12))
            xy = self.tmp('nir_u2u32(b, %s)' % V(1))
            col = self.tmp('nir_f2f32(b, %s)' % V(2))
            sw = self.tmp('nir_vec4(b, nir_channel(b, %s, 2), nir_channel(b, %s, 1), nir_channel(b, %s, 0), nir_channel(b, %s, 3))' % (col, col, col, col))
            c4 = self.tmp('nir_bcsel(b, nir_ine_imm(b, %s, 0), %s, %s)' % (fmt, sw, col))
            u = self.tmp('nir_f2u32(b, nir_fadd_imm(b, nir_fmul_imm(b, nir_fsat(b, %s), 255.0), 0.5))' % c4)
            # manual byte packing: nir_pack_unorm_4x8 becomes MKVEC.v4i8, which the Valhall packer cannot encode
            px = self.tmp('nir_ior(b, nir_ior(b, nir_channel(b, %s, 0), nir_ishl_imm(b, nir_channel(b, %s, 1), 8)), nir_ior(b, nir_ishl_imm(b, nir_channel(b, %s, 2), 16), nir_ishl_imm(b, nir_channel(b, %s, 3), 24)))' % (u, u, u, u))
            off = self.tmp('nir_iadd(b, nir_imul(b, nir_channel(b, %s, 1), %s), nir_ishl_imm(b, nir_channel(b, %s, 0), 2))' % (xy, pitch, xy))
            addr = self.tmp('nir_iadd(b, %s, nir_u2u64(b, %s))' % (va, off))
            self.lines.append('\tnir_store_global(b, %s, 4, %s, 0x1);' % (self.guard(addr), px))
            return None
        if base == 'air.sample_texture_3d':
            th = self.vals[ops[0][1]]
            sh = ('smp', INLINE_SAMPLER) if '__air_sampler_state' in ops[1][1] or '__air_sampler_state' in ops[1][0] else self.vals[ops[1][1]]
            m2 = re.match(r'\{ <(\d+) x (\w+)>', rty); ss = m2.group(2)
            te = th[1] if th[0] == 'texdyn' else 'nir_imm_int(b, %d)' % th[1]
            se = sh[1] if sh[0] == 'smpdyn' else 'nir_imm_int(b, %d)' % sh[1]
            return {0: self.tmp('sm_tex3d_dyn(b, %s, %s, %s, %d)' % (V(2), te, se, BITS[ss]))}
        if base == 'air.sample_texture_2d':
            th = self.vals[ops[0][1]]
            sh = ('smp', INLINE_SAMPLER) if '__air_sampler_state' in ops[1][1] or '__air_sampler_state' in ops[1][0] else self.vals[ops[1][1]]
            m2 = re.match(r'\{ <(\d+) x (\w+)>', rty); ss = m2.group(2)
            te = th[1] if th[0] == 'texdyn' else 'nir_imm_int(b, %d)' % th[1]
            se = sh[1] if sh[0] == 'smpdyn' else 'nir_imm_int(b, %d)' % sh[1]
            r = self.tmp('sm_tex_dyn(b, %s, %s, %s, %d)' % (V(2), te, se, BITS[ss]))
            return {0: r}
        raise Unsupported('intrinsic ' + fn)

    def ret(self, rhs):
        m = re.match(r'^ret (.+) (\S+)$', rhs)
        if rhs == 'ret void': self.single_ret = {}; return
        ty, v = m.groups()
        self.single_ret = self.ret_members(ty, v)

    def ret_members(self, ty, v):
        if v.startswith('%'):
            agg = self.vals[v]
            return dict(agg) if isinstance(agg, dict) else {0: agg}
        mm = re.match(r'^<?\{(.*)\}>?$', ty.strip())
        if mm:      # constant aggregate (zeroinitializer / undef)
            return {i: self.tmp(self.const(et, 'zeroinitializer')) for i, et in enumerate(split_top(mm.group(1)))}
        return {0: self.val(ty, v)}

    def emit_outputs(self, members):
        kind, outs, args = self.md
        for i, o in enumerate(outs):
            if i not in members: continue
            val = members[i]
            if o['kind'] == 'position':
                self.lines.append('\tsm_store_position(b, %s);' % val)
            elif o['kind'] == 'vertex_output':
                self.lines.append('\tnir_store_output(b, %s, nir_imm_int(b, 0), .base = %d, .write_mask = BITFIELD_MASK(%s->num_components), .src_type = nir_type_float | %s->bit_size, .io_semantics.location = VARYING_SLOT_VAR0 + %d, .io_semantics.num_slots = 1);'
                                  % (val, o['slot'] + 1, val, val, o['slot']))
            elif o['kind'] == 'render_target':
                self.lines.append('\tnir_store_output(b, %s, nir_imm_int(b, 0), .base = %d, .write_mask = BITFIELD_MASK(%s->num_components), .src_type = nir_type_float | %s->bit_size, .io_semantics.location = FRAG_RESULT_DATA0 + %d, .io_semantics.num_slots = 1);'
                                  % (val, o['idx'], val, val, o['idx']))
            elif o['kind'] == 'point_size':
                pass                                    # triangles only for now
            else: raise Unsupported('output ' + o['kind'])

def entry_md(modtext, fname, slots):
    """parse !air.vertex/!air.fragment entry metadata -> (kind, outputs, args)"""
    mds = dict(re.findall(r'^(!\d+) = (.*)$', modtext, re.M))
    kind = None
    for k in ('vertex', 'fragment', 'kernel'):
        m = re.search(r'^!air\.%s = !\{(!\d+)\}' % k, modtext, re.M)
        if m: kind, ent = k, m.group(1)
    if not kind: raise Unsupported('no entry metadata')
    refs = re.findall(r'!\d+', mds[ent])
    outlist = re.findall(r'!\d+', mds[refs[0]]) if len(refs) > 0 else []
    arglist = re.findall(r'!\d+', mds[refs[1]]) if len(refs) > 1 else []
    def slot_of(name):
        if name not in slots: slots[name] = len(slots)
        return slots[name]
    outs = []
    for r in outlist:
        t = re.sub(r'!"air.function_constant", !\d+, ', '', mds[r])
        if '"air.position"' in t: outs.append({'kind': 'position'})
        elif '"air.vertex_output"' in t:
            nm = re.search(r'"air.vertex_output", !"([^"]+)"', t).group(1); outs.append({'kind': 'vertex_output', 'slot': slot_of(nm)})
        elif '"air.render_target"' in t:
            outs.append({'kind': 'render_target', 'idx': int(re.search(r'"air.render_target", i32 (\d+)', t).group(1))})
        elif '"air.point_size"' in t: outs.append({'kind': 'point_size'})
        else: outs.append({'kind': 'other:' + t[:40]})
    args = []
    for r in arglist:
        t = re.sub(r'!"air.function_constant", !\d+, ', '', mds[r])
        if '"air.arg_unused"' in t and '"air.buffer"' not in t and '"air.texture"' not in t: args.append({'kind': 'unused'}); continue
        loc = re.search(r'"air.location_index", i32 (\d+)', t)
        loc = int(loc.group(1)) if loc else 0
        if '"air.vertex_input"' in t: args.append({'kind': 'vertex_input', 'loc': loc})
        elif '"air.buffer"' in t: args.append({'kind': 'buffer', 'loc': loc})
        elif '"air.texture"' in t: args.append({'kind': 'texture', 'loc': loc})
        elif '"air.sampler"' in t: args.append({'kind': 'sampler', 'loc': loc})
        elif '"air.position"' in t: args.append({'kind': 'position'})
        elif '"air.fragment_input"' in t:
            nm = re.search(r'"air.fragment_input", !"([^"]+)"', t).group(1); args.append({'kind': 'fragment_input', 'slot': slot_of(nm)})
        elif '"air.vertex_id"' in t: args.append({'kind': 'vertex_id'})
        elif '"air.instance_id"' in t: args.append({'kind': 'instance_id'})
        elif '"air.thread_position_in_grid"' in t: args.append({'kind': 'gid'})
        elif '"air.thread_position_in_threadgroup"' in t: args.append({'kind': 'lid'})
        elif '"air.threadgroup_position_in_grid"' in t: args.append({'kind': 'wgid'})
        elif '"air.point_coord"' in t: args.append({'kind': 'point_coord'})
        elif '"air.render_target"' in t:
            args.append({'kind': 'rt_in', 'idx': int(re.search(r'"air.render_target", i32 (\d+)', t).group(1))})
        else: args.append({'kind': 'other:' + t[:60]})
    return kind, outs, args

def translate(path, slots):
    mod = llb.parse_bitcode(open(path, 'rb').read())
    text = str(mod)
    ent = None
    for k in ('vertex', 'fragment', 'kernel'):
        m = re.search(r'^!air\.%s = !\{(!\d+)\}' % k, text, re.M)
        if m:
            mm = re.search(r'^%s = !\{[^@]*@([\w.$]+)' % re.escape(m.group(1)), text, re.M)
            ent = mm.group(1) if mm else None
    funcs = {f.name: f for f in mod.functions if not f.is_declaration}
    if ent not in funcs: raise Unsupported('entry not found')
    fdef = funcs[ent]
    md = entry_md(text, fdef.name, slots)
    CUR_KIND[0] = md[0]
    F = Fn(mod, fdef, md)
    for f2 in mod.functions:     # static initialisers (air.static_init) run first
        if not f2.is_declaration and re.search(r'section "air.static_init"', str(f2)):
            sub = Fn(mod, f2, None, parent=F); sub.run_body()
    body = F.build()
    return md[0], fdef.name, body, bytes(F.cdata)

if __name__ == '__main__':
    import os
    slots = {}
    jobs = []        # (bitcode path, published name)
    for arg in sys.argv[1:]:
        if arg.endswith('.json'):            # {published name: file in pl_bc}
            for pub, fn in json.load(open(arg)).items(): jobs.append((os.path.join('pl_bc', fn), pub))
        elif os.path.isdir(arg):
            jobs += [(os.path.join(arg, n), None) for n in sorted(os.listdir(arg)) if n.endswith('.bc')]
        else:
            jobs.append((arg, None))
    maxlines = int(os.environ.get('AIR_MAXLINES', '0'))
    names = [j[0] for j in jobs]
    ok, bad, out = 0, {}, []
    for path, pub in jobs:
        n = path
        try:
            kind, fname, body, cdata = translate(path, slots)
            if maxlines and body.count('\n') > maxlines: raise Unsupported('too large (%d lines)' % body.count('\n'))
            if pub: fname = pub
            out.append((kind, fname, body, cdata)); ok += 1
        except Unsupported as e:
            bad[str(e).split(' ')[0] + ' ' + str(e).split(' ')[1] if ' ' in str(e) else str(e)] = bad.get(str(e), 0) + 1
            bad.setdefault('_list', []).append((n, str(e)))
        except Exception as e:
            bad.setdefault('_list', []).append((n, 'EXC ' + repr(e)[:80]))
    lst = bad.pop('_list', [])
    from collections import Counter
    print('translated %d / %d' % (ok, len(names)), file=sys.stderr)
    for k, v in Counter(r for _, r in lst).most_common(25): print('  %3d  %s' % (v, k), file=sys.stderr)
    json.dump(slots, open('varying_slots.json', 'w'), indent=1)
    with open('air_gen.inc', 'w') as f:
        cid = lambda nm: re.sub(r'[^A-Za-z0-9_]', '_', nm)
        for kind, fname, body, cdata in out:
            f.write('static void air_build_%s(nir_builder *b)\n{\n%s\n}\n' % (cid(fname), body))
            f.write('static const unsigned char air_cdata_%s[] = { %s };\n' % (cid(fname), ', '.join(str(x) for x in cdata) or '0'))
        f.write('static const struct { const char *name; int stage; void (*build)(nir_builder *); const unsigned char *cdata; unsigned cdata_size; } air_shaders[] = {\n')
        for kind, fname, body, cdata in out:
            f.write('\t{ "%s", %s, air_build_%s, air_cdata_%s, %d },\n' % (fname, {'vertex': 'MESA_SHADER_VERTEX', 'fragment': 'MESA_SHADER_FRAGMENT', 'kernel': 'MESA_SHADER_COMPUTE'}[kind], cid(fname), cid(fname), len(cdata)))
        f.write('};\n')
