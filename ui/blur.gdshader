shader_type canvas_item;
// Blurs what is behind this rect, with no color added.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float amount : hint_range(0.0, 5.0) = 3.0;   // 0 = sharp, higher = blurrier

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE * exp2(amount);
	vec3 c = vec3(0.0);
	float total = 0.0;
	// 5x5 gaussian-ish taps on a mipmap level: smooth and cheap
	for (int x = -2; x <= 2; x++) {
		for (int y = -2; y <= 2; y++) {
			float w = exp(-float(x * x + y * y) / 4.0);
			c += textureLod(screen_tex, SCREEN_UV + vec2(float(x), float(y)) * px, amount).rgb * w;
			total += w;
		}
	}
	COLOR = vec4(c / total, 1.0);
}
