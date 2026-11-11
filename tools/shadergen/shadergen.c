/* Host tool: builds tiny NIR shaders and compiles them with Mesa's Valhall (arch 9) compiler.
 * Emits C arrays to stdout for embedding in malitri. */
#include <stdio.h>
#include "compiler/nir/nir_builder.h"
#include "compiler/glsl_types.h"
#include "panfrost/compiler/bifrost_compile.h"
#include "panfrost/util/pan_ir.h"
#include "util/u_dynarray.h"

#define GPU_ID 0x92020010u

static void emit(const char *name, nir_shader *nir, bool fs)
{
	struct panfrost_compile_inputs in = { .gpu_id = GPU_ID, .no_ubo_to_push = true };
	struct util_dynarray bin; util_dynarray_init(&bin, NULL);
	struct pan_shader_info info; memset(&info, 0, sizeof info);
	if (fs) {
		in.bifrost.rt_conv[0] = 0; /* blendable RGBA8 handled by blend descriptor */
	}
	bifrost_preprocess_nir(nir, GPU_ID);
	bifrost_compile_shader_nir(nir, &in, &bin, &info);
	fprintf(stderr, "%s: %u bytes preload=%llx work_reg=%u idvs=%d\n", name, (unsigned)bin.size,
	    (unsigned long long)info.preload, info.work_reg_count, info.vs.idvs);
	printf("static const unsigned char %s[] = {", name);
	for (unsigned i = 0; i < bin.size; i++) printf("%s0x%02x,", (i % 16) ? "" : "\n", ((uint8_t *)bin.data)[i]);
	printf("\n};\n");
	printf("#define %s_PRELOAD 0x%llxull\n", name, (unsigned long long)info.preload);
	printf("#define %s_PUSH_WORDS %u\n", name, (unsigned)info.push.count);
	if (!fs) printf("#define %s_IDVS %d\n#define %s_SECOND_OFF %u\n", name, info.vs.idvs, name, (unsigned)info.vs.secondary_offset);
}

int main(void)
{
	glsl_type_singleton_init_or_ref();

	/* fragment: constant green */
	{
		nir_builder b = nir_builder_init_simple_shader(MESA_SHADER_FRAGMENT, &bifrost_nir_options_v9, "fs");
		nir_def *c = nir_imm_vec4(&b, 0.0f, 1.0f, 0.0f, 1.0f);
		nir_store_output(&b, c, nir_imm_int(&b, 0), .base = 0, .write_mask = 0xf,
		    .src_type = nir_type_float32, .io_semantics.location = FRAG_RESULT_DATA0, .io_semantics.num_slots = 1);
		b.shader->info.outputs_written = BITFIELD64_BIT(FRAG_RESULT_DATA0);
		emit("FS_GREEN", b.shader, true);
	}
	/* vertex: screen-space triangle from vertex id */
	{
		nir_builder b = nir_builder_init_simple_shader(MESA_SHADER_VERTEX, &bifrost_nir_options_v9, "vs");
		nir_def *vid = nir_load_vertex_id(&b);
		nir_def *x = nir_bcsel(&b, nir_ieq_imm(&b, vid, 1), nir_imm_float(&b, 60.0f), nir_imm_float(&b, 4.0f));
		nir_def *y = nir_bcsel(&b, nir_ieq_imm(&b, vid, 2), nir_imm_float(&b, 60.0f), nir_imm_float(&b, 4.0f));
		nir_def *pos = nir_vec4(&b, x, y, nir_imm_float(&b, 0.5f), nir_imm_float(&b, 1.0f));
		nir_store_output(&b, pos, nir_imm_int(&b, 0), .base = 0, .write_mask = 0xf,
		    .src_type = nir_type_float32, .io_semantics.location = VARYING_SLOT_POS, .io_semantics.num_slots = 1);
		b.shader->info.outputs_written = BITFIELD64_BIT(VARYING_SLOT_POS);
		emit("VS_TRI", b.shader, false);
	}
	/* vertex: big screen-space triangle (1080x2400 display) */
	{
		nir_builder b = nir_builder_init_simple_shader(MESA_SHADER_VERTEX, &bifrost_nir_options_v9, "vs2");
		nir_def *vid = nir_load_vertex_id(&b);
		nir_def *x = nir_bcsel(&b, nir_ieq_imm(&b, vid, 0), nir_imm_float(&b, 100.0f),
		    nir_bcsel(&b, nir_ieq_imm(&b, vid, 1), nir_imm_float(&b, 980.0f), nir_imm_float(&b, 540.0f)));
		nir_def *y = nir_bcsel(&b, nir_ieq_imm(&b, vid, 2), nir_imm_float(&b, 2000.0f), nir_imm_float(&b, 300.0f));
		nir_def *pos = nir_vec4(&b, x, y, nir_imm_float(&b, 0.5f), nir_imm_float(&b, 1.0f));
		nir_store_output(&b, pos, nir_imm_int(&b, 0), .base = 0, .write_mask = 0xf,
		    .src_type = nir_type_float32, .io_semantics.location = VARYING_SLOT_POS, .io_semantics.num_slots = 1);
		b.shader->info.outputs_written = BITFIELD64_BIT(VARYING_SLOT_POS);
		emit("VS_BIG", b.shader, false);
	}
	/* compute: copy one 32-bit pixel per invocation.
	 * push: [0]=src u64, [8]=dst u64, [16]=src stride, [20]=dst stride, [24]=width */
	{
		nir_builder b = nir_builder_init_simple_shader(MESA_SHADER_COMPUTE, &bifrost_nir_options_v9, "cs_copy");
		b.shader->info.workgroup_size[0] = 64;
		b.shader->info.workgroup_size[1] = 1;
		b.shader->info.workgroup_size[2] = 1;
		nir_def *id = nir_load_global_invocation_id(&b, 32);
		nir_def *x = nir_channel(&b, id, 0), *y = nir_channel(&b, id, 1);
		nir_def *w = nir_load_push_constant(&b, 1, 32, nir_imm_int(&b, 0), .base = 24, .range = 4);
		nir_push_if(&b, nir_ult(&b, x, w));
		{
			nir_def *src = nir_load_push_constant(&b, 1, 64, nir_imm_int(&b, 0), .base = 0, .range = 8);
			nir_def *dst = nir_load_push_constant(&b, 1, 64, nir_imm_int(&b, 0), .base = 8, .range = 8);
			nir_def *ss = nir_load_push_constant(&b, 1, 32, nir_imm_int(&b, 0), .base = 16, .range = 4);
			nir_def *ds = nir_load_push_constant(&b, 1, 32, nir_imm_int(&b, 0), .base = 20, .range = 4);
			nir_def *xo = nir_ishl_imm(&b, x, 2);
			nir_def *so = nir_iadd(&b, nir_imul(&b, y, ss), xo);
			nir_def *dof = nir_iadd(&b, nir_imul(&b, y, ds), xo);
			nir_def *sa = nir_iadd(&b, src, nir_u2u64(&b, so));
			nir_def *da = nir_iadd(&b, dst, nir_u2u64(&b, dof));
			nir_def *v = nir_load_global(&b, sa, 4, 1, 32);
			nir_store_global(&b, da, 4, v, 0x1);
		}
		nir_pop_if(&b, NULL);
		b.shader->info.num_ubos = 0;
		emit("CS_COPY", b.shader, false);
	}
	return 0;
}
