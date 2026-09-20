shader_type spatial;
render_mode unshaded, wireframe, cull_disabled, depth_test_disabled, shadows_disabled, fog_disabled;

uniform vec4 wire_color : source_color = vec4(0.416, 0.514, 0.592, 1.0);

void fragment() {
	ALBEDO = wire_color.rgb;
}
