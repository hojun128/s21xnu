#!/usr/bin/env python3
"""Specialize an AIR function on given function-constant values (LLVM IR text in, bitcode out).

usage: specialize.py IN.ll OUT.bc name=value ...   (names with or without the fc_ prefix; unlisted constants = 0)

The fc initializer globals become plain constants, air.is_function_constant_defined folds to true, then SCCP /
CFG simplification / DCE drop the dead paths, so large generic shaders (fixed_frag_lph_cpf) become compilable."""
import re, sys
import llvmlite.binding as llvm

src, dst = sys.argv[1], sys.argv[2]
vals = {}
for a in sys.argv[3:]:
    k, v = a.split('=')
    vals[k if k.startswith('fc_') else 'fc_' + k] = int(v, 0)
t = open(src).read()
used = set()
def fcglob(m):
    name, ty = m.group(1), m.group(3)
    v = vals.get(name, 0); used.add(name)
    if ty.startswith('<'):
        n = int(re.match(r'<(\d+) x', ty).group(1))
        init = '<' + ', '.join('i8 %d' % ((v >> (8 * i)) & 0xff) for i in range(n)) + '>'
    else:
        init = str(v)
    return '%s = internal addrspace(2) constant %s %s,' % (m.group(0).split(' =')[0], ty, init)
t = re.sub(r'@_Z\d+(fc_\w+?)\.MTL_FC_INIT_(\d+)_\w+ = internal (?:unnamed_addr )?addrspace\(2\) externally_initialized constant (<\d+ x i8>|i\d+|float|half) undef, section "air.fc_initializer",', fcglob, t)
t = re.sub(r'(%[\w.]+) = tail call i1 @air\.is_function_constant_defined\([^\n]*?\)( #\d+)?$', r'\1 = and i1 true, true', t, flags=re.M)
miss = set(vals) - used
if miss: print('unknown constants:', ' '.join(sorted(miss)), file=sys.stderr); sys.exit(1)
llvm.initialize(); llvm.initialize_native_target(); llvm.initialize_native_asmprinter()
def opt(text, inline):
    m = llvm.parse_assembly(text); m.verify()
    pm = llvm.create_module_pass_manager()
    if inline: pm.add_function_inlining_pass(1000)
    for _ in range(3):
        pm.add_sroa_pass(); pm.add_gvn_pass(); pm.add_sccp_pass(); pm.add_cfg_simplification_pass(); pm.add_aggressive_dead_code_elimination_pass()
    pm.add_global_optimizer_pass(); pm.add_global_dce_pass()
    pm.run(m)
    return str(m)
# pass 1 folds the static initialiser, which copies the constants into internal globals: plain constant stores
# there turn those globals into constants (stores removed), then pass 2 folds the shader itself
t = opt(t, False)
init = re.search(r'define internal void @[^\n]*\n(.*?)\n\}', t, re.S)
nconst = 0
if init:
    body = init.group(1)
    for g, ty, v in re.findall(r'store (i\d+|float|half) ([-\w.]+), \1 addrspace\(2\)\* (@_ZL\w+), align', body) and \
            [(m.group(3), m.group(1), m.group(2)) for m in re.finditer(r'store (i\d+|float|half) ([-\w.]+), \1 addrspace\(2\)\* (@_ZL\w+), align', body)]:
        if len(re.findall(re.escape(g) + r',', body)) != 1: continue        # stored more than once: leave it
        t2 = re.sub(r'^%s = internal (unnamed_addr )?addrspace\(2\) global %s [^,\n]+,' % (re.escape(g), ty),
                    '%s = internal addrspace(2) constant %s %s,' % (g, ty, v), t, flags=re.M)
        if t2 == t: continue
        t = re.sub(r'\n  store %s %s, %s addrspace\(2\)\* %s, align[^\n]*' % (ty, re.escape(v), ty, re.escape(g)), '', t2, count=1)
        nconst += 1
print('%d initialiser globals made constant' % nconst, file=sys.stderr)
# the struct-valued constants (fragment shader config) are stored field by field: run the initialiser at the top of the
# entry function too, so GVN forwards those stores into the loads (the initialiser still runs as air.static_init)
ent = re.search(r'define [^\n]*@(?!_GLOBAL)[\w.]+\([^\n]*\{\n', t)
ini = re.search(r'define internal void (@[\w.$"]+)\(\)', t)
if ini and ent: t = t[:ent.end()] + '  call void %s()\n' % ini.group(1) + t[ent.end():]
out = opt(t, True)
# then drop stores into globals nothing reads any more (implicit fc predicates, forwarded config fields)
for _ in range(2):
    dead = []
    for g in set(re.findall(r'store [^\n]*?(@[\w.]+)(?:, align|\))', out)):
        uses = len(re.findall(re.escape(g) + r'\b', out))
        stores = len(re.findall(r'\n\s+store [^\n]*' + re.escape(g) + r'\b', out))
        decl = len(re.findall(r'\n' + re.escape(g) + r' = ', out))
        meta = len(re.findall(r'(?:![^\n]*|@llvm\.compiler\.used[^\n]*?)' + re.escape(g) + r'\b', out))
        if uses - decl - stores - meta <= 0: dead.append(g)
    for g in dead: out = re.sub(r'\n\s+store [^\n]*' + re.escape(g) + r'\b[^\n]*', '', out)
    out = opt(out, True)

# undefined outputs fold to NaN vectors, which the translator does not parse
out = re.sub(r'<(\d+) x half> <half 0xH7E00(?:, half 0xH7E00)*>', r'<\1 x half> zeroinitializer', out)
# undef lanes inside constants / shuffle masks and any()/all() of constant vectors: give the translator plain values
out = re.sub(r'(<\d+ x i32> <[^>]*?)i32 undef', lambda m: m.group(0).replace('i32 undef', 'i32 0'), out)
while re.search(r'<[^<>\n]*\b(float|half) undef', out):
    out = re.sub(r'(<[^<>\n]*\b)(float|half) undef', lambda m: m.group(1) + m.group(2) + ' 0.0' if m.group(2) == 'float' else m.group(1) + 'half 0xH0000', out)
out = re.sub(r'tail call i1 @air\.(any|all)\.v\di1\(<\d x i1> zeroinitializer\)( #\d+)?', 'and i1 false, false', out)
m = llvm.parse_assembly(out)
pm = llvm.create_module_pass_manager()
for _ in range(2):
    pm.add_sccp_pass(); pm.add_cfg_simplification_pass(); pm.add_aggressive_dead_code_elimination_pass()
pm.run(m)
out = str(m)
out = re.sub(r'(<\d+ x i32> <[^>]*?)i32 undef', lambda m: m.group(0).replace('i32 undef', 'i32 0'), out)
m = llvm.parse_assembly(out)
open(dst, 'wb').write(m.as_bitcode())
print('%s: %d IR lines' % (dst, out.count('\n')), file=sys.stderr)
