class_name UIStyle
## Shared look for every screen: thin white Urbanist text, keycaps and sliders.

const WHITE := Color(1.0, 0.98, 0.94)
const RED := Color(1.0, 0.22, 0.25)
const DIM := Color(1.0, 0.98, 0.94, 0.5)

static var _fonts := {}


## weight: 100 (thin) to 900 (black). spacing: extra pixels between letters.
static func font(weight := 300, spacing := 0) -> Font:
	var key := "%d_%d" % [weight, spacing]
	if not _fonts.has(key):
		var f := FontVariation.new()
		f.base_font = load("res://fonts/Urbanist.ttf")
		f.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
		f.spacing_glyph = spacing
		_fonts[key] = f
	return _fonts[key]


## glow > 0 adds a soft halo of the same color around the letters (off by default).
static func label(size: int, color: Color, glow := 0.0, weight := 400, spacing := 1) -> LabelSettings:
	var s := LabelSettings.new()
	s.font = font(weight, spacing)
	s.font_size = size
	s.font_color = color
	s.shadow_color = Color(color, glow * 0.5)
	s.shadow_size = maxi(1, size / 6)
	s.shadow_offset = Vector2.ZERO
	return s


## A key drawn as a small outlined cap, e.g. keycap("ESC")
static func keycap(text: String) -> PanelContainer:
	var cap := PanelContainer.new()
	var box := StyleBoxFlat.new()
	box.bg_color = Color(1, 1, 1, 0.05)
	box.border_color = Color(WHITE, 0.55)
	box.set_border_width_all(1)
	box.set_corner_radius_all(2)
	box.content_margin_left = 3
	box.content_margin_right = 3
	box.content_margin_top = 0
	box.content_margin_bottom = 0
	cap.add_theme_stylebox_override("panel", box)
	var l := Label.new()
	l.text = text
	l.label_settings = label(7, WHITE, 0.0, 500, 1)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_child(l)
	return cap


## Thin line slider with a small white dot
static func style_slider(slider: HSlider) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(WHITE, 0.2)
	track.content_margin_top = 0.5
	track.content_margin_bottom = 0.5
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(WHITE, 0.85)
	fill.content_margin_top = 0.5
	fill.content_margin_bottom = 0.5
	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)
	slider.add_theme_icon_override("grabber", _dot(4, WHITE))
	slider.add_theme_icon_override("grabber_highlight", _dot(5, WHITE))
	slider.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


static func _dot(radius: int, color: Color) -> Texture2D:
	var size := radius * 2 + 2
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := Vector2(size, size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			img.set_pixel(x, y, Color(color, clampf(radius + 0.5 - d, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)
