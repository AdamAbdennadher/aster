shader_type canvas_item;
// Retro filter on the 3D image: fewer colors + ordered dithering, chromatic aberration, vignette, tint.
// The UI is drawn above this layer at full resolution, so text stays sharp.

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
uniform float color_levels : hint_range(2.0, 64.0) = 32.0;
uniform float dither_strength : hint_range(0.0, 2.0) = 0.5;
uniform float chromatic_aberration : hint_range(0.0, 0.01) = 0.0015;
uniform float vignette : hint_range(0.0, 1.0) = 0.35;
uniform vec3 tint : source_color = vec3(1.0, 0.96, 0.92);
uniform float pixel_rows = 360.0;   // must match the 3D resolution (see game.gd) so the dither lines up with the big pixels

const float BAYER[16] = float[](
	0.0, 8.0, 2.0, 10.0,
	12.0, 4.0, 14.0, 6.0,
	3.0, 11.0, 1.0, 9.0,
	15.0, 7.0, 13.0, 5.0
);

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 offset = (uv - 0.5) * chromatic_aberration;
	vec3 c = vec3(
		texture(screen_tex, uv + offset).r,
		texture(screen_tex, uv).g,
		texture(screen_tex, uv - offset).b
	);
	// dither pattern in low-res pixels, not screen pixels
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	ivec2 p = ivec2(floor(uv * vec2(pixel_rows * aspect, pixel_rows))) % 4;
	float threshold = BAYER[p.y * 4 + p.x] / 16.0 - 0.5;
	c += threshold * dither_strength / color_levels;
	c = floor(c * color_levels + 0.5) / color_levels;
	c *= mix(1.0, smoothstep(0.85, 0.25, length(uv - 0.5)), vignette);
	COLOR = vec4(c * tint, 1.0);
}
