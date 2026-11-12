"""AIR (Metal LLVM IR) -> Mesa nir_builder C code. v0: straight-line functions.
Push-constant ABI (bytes):  0..63  buffer[i] GPU VA (u64)       64..191 attr[L] {u64 va, u32 stride, u32 pad}
                           192..215 viewport scale.xyz, offset.xyz (f32)
Texture i -> pan_res_handle(4, i), sampler i -> pan_res_handle(3, i).  Varyings: global name -> VAR0+slot."""
import re, sys, json
import llvmlite.binding as llb
llb.initialize(); llb.initialize_native_target(); llb.initialize_native_asmprinter()

PUSH_BUF, PUSH_ATTR, PUSH_VP = 0, 64, 192

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

class Fn:
    def __init__(self, mod, f, md):
        self.mod, self.f, self.md = mod, f, md
        self.lines, self.vals, self.n = [], {}, 0
        self.types = Types(str(mod))
    def tmp(self, expr):
        self.n += 1; v = 'v%d' % self.n
        self.lines.append('\tnir_def *%s = %s;' % (v, expr)); return v
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
            if v.startswith('0x'):
                import struct
                fv = struct.unpack('<d', struct.pack('<Q', int(v, 16)))[0]
            else: fv = float(v)
            return 'nir_imm_floatN_t(b, %r, %d)' % (fv, BITS[s])
        if v == 'true': v = '1'
        if v == 'false': v = '0'
        return 'nir_imm_intN_t(b, %s, %d)' % (int(v), max(BITS[s], 1) if s != 'i1' else 1)
    def val(self, ty, txt):
        txt = txt.strip()
        if txt.startswith('%'):
            if txt not in self.vals: raise Unsupported('value ' + txt)
            return self.vals[txt]
        return self.tmp(self.const(ty, txt))

    def operands(self, s):
        """split 'T a, T b' operand list text into [(type, value)]"""
        out = []
        for o in split_top(s):
            o = re.sub(r'\b(nocapture|readonly|readnone|noalias|nonnull|noundef|inreg|zeroext|signext)\b', '', o).strip()
            m = re.match(r'^(.*?)\s+(%[\w.]+|-?[\d.e+\-]+|0x[0-9A-Fa-f]+|true|false|undef|poison|zeroinitializer|null|<.*>)$', o)
            if not m: raise Unsupported('operand ' + o)
            out.append((m.group(1).strip(), m.group(2).strip()))
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
                                           % (n, BITS[s], a['slot'], a['slot']))
            elif a['kind'] in ('vertex_id',):
                self.vals[name] = self.tmp('nir_load_vertex_id(b)')
            elif a['kind'] == 'unused':
                pass
            else:
                raise Unsupported('arg kind ' + a['kind'])
        blocks = list(self.f.blocks)
        if len(blocks) != 1: raise Unsupported('%d blocks (control flow)' % len(blocks))
        for ins in blocks[0].instructions:
            self.ins(ins)
        return '\n'.join(self.lines)

    def ins(self, ins):
        t = str(ins).strip()
        t = re.sub(r',\s*!\w+ !\d+', '', t)
        m = re.match(r'^(%[\w.]+) = (.*)$', t)
        dst, rhs = (m.group(1), m.group(2)) if m else (None, t)
        rhs = re.sub(r'\b(fast|nnan|ninf|nsz|arcp|contract|afn|reassoc|nuw|nsw|exact|inbounds|tail)\b\s*', '', rhs).strip()
        op = rhs.split()[0]
        R = None
        if op in ('fadd', 'fsub', 'fmul', 'fdiv', 'add', 'sub', 'mul', 'and', 'or', 'xor', 'shl', 'lshr', 'ashr', 'udiv', 'sdiv', 'urem', 'srem', 'frem'):
            m = re.match(r'^\w+ (.+?) (\S+), (\S+)$', rhs)
            ty, a, bb = m.groups()
            fn = {'fadd': 'fadd', 'fsub': 'fsub', 'fmul': 'fmul', 'fdiv': 'fdiv', 'add': 'iadd', 'sub': 'isub', 'mul': 'imul',
                  'and': 'iand', 'or': 'ior', 'xor': 'ixor', 'shl': 'ishl', 'lshr': 'ushr', 'ashr': 'ishr',
                  'udiv': 'udiv', 'sdiv': 'idiv', 'urem': 'umod', 'srem': 'irem', 'frem': 'fmod'}[op]
            R = self.tmp('nir_%s(b, %s, %s)' % (fn, self.val(ty, a), self.val(ty, bb)))
        elif op == 'fneg':
            m = re.match(r'^fneg (.+?) (\S+)$', rhs); R = self.tmp('nir_fneg(b, %s)' % self.val(*m.groups()))
        elif op in ('fcmp', 'icmp'):
            m = re.match(r'^\w+ (\w+) (.+?) (\S+), (\S+)$', rhs)
            pred, ty, a, bb = m.groups(); A, B = self.val(ty, a), self.val(ty, bb)
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
            R = self.tmp('nir_bcsel(b, %s, %s, %s)' % tuple(self.val(*o) for o in ops))
        elif op in ('zext', 'sext', 'trunc', 'fpext', 'fptrunc', 'bitcast', 'sitofp', 'uitofp', 'fptosi', 'fptoui'):
            m = re.match(r'^\w+ (.+?) (\S+) to (.+)$', rhs)
            sty, v, dty = m.groups()
            if sty.endswith('*'):
                p = self.vals[v]; self.vals[dst] = (p[0], p[1], re.sub(r'\s*addrspace\(\d+\)\*$', '', dty)); return
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
            m = re.match(r'^extractelement (.+?) (\S+), \w+ (\d+)$', rhs)
            if not m: raise Unsupported('dynamic extractelement')
            R = self.tmp('nir_channel(b, %s, %s)' % (self.val(m.group(1), m.group(2)), m.group(3)))
        elif op == 'insertelement':
            m = re.match(r'^insertelement (.+?) (\S+), (.+?) (\S+), \w+ (\d+)$', rhs)
            if not m: raise Unsupported('dynamic insertelement')
            vt, v, et, e, idx = m.groups()
            R = self.tmp('nir_vector_insert_imm(b, %s, %s, %s)' % (self.val(vt, v), self.val(et, e), idx))
        elif op == 'shufflevector':
            m = re.match(r'^shufflevector (<\d+ x \w+>) (\S+), (<\d+ x \w+>) (\S+), (<\d+ x i32>) (.+)$', rhs)
            t1, a, t2, bb, mt, mask = m.groups()
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
            p = self.vals[ptr]
            if p[0] != 'ptr': raise Unsupported('gep on ' + p[0])
            addr, cur = p[1], srcty
            idxs = [x.rsplit(' ', 1) for x in parts[2:]]
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
            self.vals[dst] = ('ptr', addr, cur); return
        elif op == 'load':
            m = re.match(r'^load (.+?), (.+?) (%[\w.]+)(, align (\d+))?$', rhs)
            ty, _, ptr, _, al = m.groups()
            p = self.vals[ptr]; n, s = scal(ty)
            if ty.startswith('%') or ty.startswith('{') or ty.startswith('['): raise Unsupported('aggregate load')
            R = self.tmp('nir_load_global(b, %s, %s, %d, %d)' % (p[1], al or 4, n, BITS[s]))
        elif op == 'store':
            m = re.match(r'^store (.+?) (\S+), (.+?) (%[\w.]+)(, align (\d+))?$', rhs)
            ty, v, _, ptr, _, al = m.groups()
            self.lines.append('\tnir_store_global(b, %s, %s, %s, 0xf);' % (self.vals[ptr][1], al or 4, self.val(ty, v))); return
        elif op == 'call':
            R = self.call(rhs)
            if R is None: return
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
              'air.dfdx': 'fddx', 'air.dfdy': 'fddy'}
        bi = {'air.fast_fmax': 'fmax', 'air.fmax': 'fmax', 'air.fast_fmin': 'fmin', 'air.fmin': 'fmin', 'air.min.s': 'imin', 'air.min.u': 'umin',
              'air.powr': 'fpow', 'air.fast_powr': 'fpow', 'air.fast_pow': 'fpow'}
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
        if base == 'air.fast_atan2': return self.tmp('nir_fatan2(b, %s, %s)' % (V(0), V(1)))
        if base.startswith('air.convert'):
            dk = fn.split('.')[2]; sk = fn.split('.')[-2]
            A = V(0); db = BITS[s]
            if dk == 'f': return self.tmp(('nir_f2fN' if sk == 'f' else 'nir_i2fN' if sk == 's' else 'nir_u2fN') + '(b, %s, %d)' % (A, db))
            if dk == 's': return self.tmp(('nir_f2iN' if sk == 'f' else 'nir_i2iN') + '(b, %s, %d)' % (A, db))
            if dk == 'u': return self.tmp(('nir_f2uN' if sk == 'f' else 'nir_u2uN') + '(b, %s, %d)' % (A, db))
        if base == 'air.read_texture_2d':
            tex = self.vals[ops[0][1]][1]
            m2 = re.match(r'\{ <(\d+) x (\w+)>', rty); nn, ss = int(m2.group(1)), m2.group(2)
            r = self.tmp('nir_txf(b, %s, .texture_index = pan_res_handle(4, %d), .dest_type = nir_type_float%d, .lod = %s)'
                         % (V(1), tex, BITS[ss], V(2)) if False else
                         'sm_txf(b, %s, %s, %d, %d)' % (V(1), V(2), tex, BITS[ss]))
            return {0: r}
        if base == 'air.sample_texture_2d':
            tex = self.vals[ops[0][1]][1]; smp = self.vals[ops[1][1]][1]
            m2 = re.match(r'\{ <(\d+) x (\w+)>', rty); ss = m2.group(2)
            r = self.tmp('sm_tex(b, %s, %d, %d, %d)' % (V(2), tex, smp, BITS[ss]))
            return {0: r}
        raise Unsupported('intrinsic ' + fn)

    def ret(self, rhs):
        kind, outs, args = self.md
        m = re.match(r'^ret (.+) (\S+)$', rhs)
        if rhs == 'ret void': return
        ty, v = m.groups()
        agg = self.vals[v] if v.startswith('%') else None
        members = agg if isinstance(agg, dict) else {0: self.val(ty, v)}
        for i, o in enumerate(outs):
            if i not in members: continue
            val = members[i]
            if o['kind'] == 'position':
                self.lines.append('\tsm_store_position(b, %s);' % val)
            elif o['kind'] == 'vertex_output':
                self.lines.append('\tnir_store_output(b, %s, nir_imm_int(b, 0), .base = %d, .write_mask = BITFIELD_MASK(%s->num_components), .src_type = nir_type_float | %s->bit_size, .io_semantics.location = VARYING_SLOT_VAR0 + %d, .io_semantics.num_slots = 1);'
                                  % (val, o['slot'], val, val, o['slot']))
            elif o['kind'] == 'render_target':
                self.lines.append('\tnir_store_output(b, %s, nir_imm_int(b, 0), .base = %d, .write_mask = BITFIELD_MASK(%s->num_components), .src_type = nir_type_float | %s->bit_size, .io_semantics.location = FRAG_RESULT_DATA0 + %d, .io_semantics.num_slots = 1);'
                                  % (val, o['idx'], val, val, o['idx']))
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
        t = mds[r]
        if '"air.position"' in t: outs.append({'kind': 'position'})
        elif '"air.vertex_output"' in t:
            nm = re.search(r'"air.vertex_output", !"([^"]+)"', t).group(1); outs.append({'kind': 'vertex_output', 'slot': slot_of(nm)})
        elif '"air.render_target"' in t:
            outs.append({'kind': 'render_target', 'idx': int(re.search(r'"air.render_target", i32 (\d+)', t).group(1))})
        elif '"air.point_size"' in t: outs.append({'kind': 'point_size'})
        else: outs.append({'kind': 'other:' + t[:40]})
    args = []
    for r in arglist:
        t = mds[r]
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
        else: args.append({'kind': 'other:' + t[:60]})
    return kind, outs, args

def translate(path, slots):
    mod = llb.parse_bitcode(open(path, 'rb').read())
    text = str(mod)
    fdef = [f for f in mod.functions if not f.is_declaration][0]
    md = entry_md(text, fdef.name, slots)
    body = Fn(mod, fdef, md).build()
    return md[0], fdef.name, body

if __name__ == '__main__':
    import os
    slots = {}
    names = sys.argv[2:] or [n[:-3] for n in sorted(os.listdir(sys.argv[1]))]
    ok, bad, out = 0, {}, []
    for n in names:
        try:
            kind, fname, body = translate(os.path.join(sys.argv[1], n + '.bc'), slots)
            out.append((kind, fname, body)); ok += 1
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
        for kind, fname, body in out:
            f.write('static void air_build_%s(nir_builder *b)\n{\n%s\n}\n' % (fname, body))
        f.write('static const struct { const char *name; int stage; void (*build)(nir_builder *); } air_shaders[] = {\n')
        for kind, fname, body in out:
            f.write('\t{ "%s", %s, air_build_%s },\n' % (fname, {'vertex': 'MESA_SHADER_VERTEX', 'fragment': 'MESA_SHADER_FRAGMENT', 'kernel': 'MESA_SHADER_COMPUTE'}[kind], fname))
        f.write('};\n')
