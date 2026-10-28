shader_type canvas_item;
// One instanced quad per falling note (MultiMeshInstance2D): rounded corners, border, black-key split,
// glass highlight and neon outline, all per pixel so the whole waterfall is a single draw call.
// Per instance: transform scales a unit quad to the tile, COLOR.rgb = left fill, CUSTOM = (right fill rgb, is_black).
// Fills arrive in sRGB; with HDR 2D on, the canvas works in linear space, so they're converted here.

uniform float radius = 3.0;
uniform float border = 2.0;
uniform vec4 border_white : source_color = vec4(1.0);
uniform vec4 border_black : source_color = vec4(0.05, 0.05, 0.05, 1.0);
uniform float alpha = 1.0;
uniform float glow = 1.2;  // HDR boost so fills cross the bloom threshold
uniform int style = 1;  // 0 solid, 1 glass, 2 neon
uniform bool linear = false;  // true when the viewport uses HDR 2D

varying vec2 px_size;
varying vec3 right_col;
varying float is_black;

void vertex() {
	px_size = vec2(length(MODEL_MATRIX[0].xy), length(MODEL_MATRIX[1].xy));  // includes the instance scale
	right_col = INSTANCE_CUSTOM.rgb;
	is_black = INSTANCE_CUSTOM.a;
}

vec3 to_linear(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThan(c, vec3(0.04045)));
}

float rounded_box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 p = (UV - 0.5) * px_size;  // pixels from the tile center
	float d = rounded_box(p, px_size * 0.5, min(radius, 0.5 * min(px_size.x, px_size.y)));
	vec3 left_col = linear ? to_linear(COLOR.rgb) : COLOR.rgb;
	vec3 fill = UV.x < 0.5 ? left_col : (linear ? to_linear(right_col) : right_col);
	vec4 edge = is_black > 0.5 ? border_black : border_white;
	float fill_a = alpha;
	float bw = border;
	if (style == 1) {
		fill *= glow;
	} else if (style == 2) {
		edge = vec4(left_col * glow * glow, 1.0);
		fill_a = 0.25 * alpha;
		bw = max(border, 2.0);
	}
	vec4 col = vec4(fill, fill_a);
	float from_top = p.y + px_size.y * 0.5;
	if (style == 1 && px_size.y > 8.0 && from_top > 2.0 && from_top < 4.0 && abs(p.x) < px_size.x * 0.5 - 3.0) {
		col = mix(col, vec4(1.0, 1.0, 1.0, alpha), 0.45);  // glass top-edge highlight
	}
	if (bw > 0.0) {
		col = mix(col, vec4(edge.rgb, edge.a * alpha), clamp(d + bw + 0.5, 0.0, 1.0));
	}
	COLOR = vec4(col.rgb, col.a * clamp(0.5 - d, 0.0, 1.0));  // 1px anti-aliased outer edge
}
