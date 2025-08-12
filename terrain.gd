# res://Terrain.gd (Godot 4)
extends Node2D

# ========== 基本設定 ==========
const TILE := 32
const SIZE := Vector2i(32, 18)
const MAX_H := 5
const DESIRED_H := 2                       # 目標高さ（黄色）
const DAILY_TZ_OFFSET_SEC := 0             # デイリー切替（UTC基準）

# ========== 色 ==========
const SOIL_BROWN    := Color(0.70, 0.55, 0.28) # h=0
const SOIL_BLEND    := Color(0.80, 0.70, 0.38) # h=1
const GOAL_YELLOW   := Color(0.93, 0.86, 0.35) # h=2
const YELLOW_GREEN  := Color(0.62, 0.85, 0.45) # h=3
const GREEN         := Color(0.16, 0.60, 0.20) # h=4
const DEEP_GREEN    := Color(0.06, 0.35, 0.10) # h=5

# ========== エクスポート ==========
@export var hud_path: NodePath
@export var target_rect: Rect2i = Rect2i(Vector2i(8, 5), Vector2i(16, 8))
@export var sfx_dig_path: NodePath
@export var sfx_place_path: NodePath
@export var sfx_ng_path: NodePath

# ========== 状態 ==========
var heights: Array = []      # heights[x][y]（0..5）
var inventory: int = 0
var clicks_total: int = 0
var clicks_success: int = 0
var start_msec: int = -1
var finish_msec: int = -1
var result_shown: bool = false
var day_id: int = 0
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

# 参照
@onready var hud: Label = (get_node_or_null(hud_path) as Label)
@onready var sfx_dig: Node = get_node_or_null(sfx_dig_path)
@onready var sfx_place: Node = get_node_or_null(sfx_place_path)
@onready var sfx_ng: Node = get_node_or_null(sfx_ng_path)

# オーバーレイ
var overlay_layer: CanvasLayer
var rules_overlay: Control
var result_overlay: Control

# ========== ライフサイクル ==========
func _ready() -> void:
	day_id = _current_day_id()

	overlay_layer = CanvasLayer.new()
	overlay_layer.name = "OverlayLayer"
	overlay_layer.layer = 100
	add_child(overlay_layer)

	_generate_world_daily()
	_build_rules_overlay()
	_build_result_overlay()
	_show_rules_overlay(true)
	_update_hud()
	queue_redraw()

func _process(_delta: float) -> void:
	if hud and start_msec >= 0 and finish_msec < 0:
		_update_hud()

# ========== デイリー生成 ==========
func _current_day_id() -> int:
	var now_s: int = Time.get_unix_time_from_system()
	var shift: int = DAILY_TZ_OFFSET_SEC
	return int(floor(float(now_s + shift) / 86400.0))

func _generate_world_daily() -> void:
	rng.seed = day_id
	heights.clear()
	heights.resize(SIZE.x)
	for x in range(SIZE.x):
		var col: Array = []
		col.resize(SIZE.y)
		for y in range(SIZE.y):
			var base: int = rng.randi_range(0, MAX_H)
			if x > 0:
				base = int(clamp(int(heights[x - 1][y]) + rng.randi_range(-1, 1), 0, MAX_H))
			if y > 0 and rng.randi_range(0, 100) < 50:
				base = int(clamp(int(col[y - 1]) + rng.randi_range(-1, 1), 0, MAX_H))
			col[y] = base
		heights[x] = col
	inventory = 0
	clicks_total = 0
	clicks_success = 0
	start_msec = -1
	finish_msec = -1
	result_shown = false

# ========== 描画 ==========
func _draw() -> void:
	for x in range(SIZE.x):
		for y in range(SIZE.y):
			var h: int = int(heights[x][y])
			var in_target: bool = target_rect.has_point(Vector2i(x, y))
			var col: Color
			if in_target:
				match h:
					0: col = SOIL_BROWN
					1: col = SOIL_BLEND
					2: col = GOAL_YELLOW
					3: col = YELLOW_GREEN
					4: col = GREEN
					_: col = DEEP_GREEN
			else:
				var shade: float = 0.18 + 0.10 * (float(h) / float(MAX_H))
				col = Color(shade, shade, shade, 0.85)
			draw_rect(Rect2(Vector2(x * TILE, y * TILE), Vector2(TILE - 1, TILE - 1)), col)

	var outline_rect: Rect2 = Rect2(
		Vector2(target_rect.position.x * TILE, target_rect.position.y * TILE),
		Vector2(target_rect.size.x * TILE, target_rect.size.y * TILE)
	)
	draw_rect(outline_rect, Color(1, 1, 1, 1), false, 2.0)

# UI（ルール/結果オーバーレイ）表示中はゲーム入力をブロック
func _ui_blocking() -> bool:
	return (rules_overlay and rules_overlay.visible) or (result_overlay and result_overlay.visible)

# 入力ハンドラ（Godot 4）
func _unhandled_input(event: InputEvent) -> void:
	# オーバーレイが出ているときは Esc で閉じるだけ許可
	if _ui_blocking():
		if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			if rules_overlay and rules_overlay.visible:
				_show_rules_overlay(false)
			elif result_overlay and result_overlay.visible:
				_close_result_overlay()
		return

	# マウスクリック（掘る/盛る）
	if event is InputEventMouseButton and event.pressed:
		var m: Vector2 = get_local_mouse_position()
		var cell: Vector2i = Vector2i(int(floor(m.x / TILE)), int(floor(m.y / TILE)))
		if _in_bounds(cell):
			clicks_total += 1
			_start_timer_if_needed()
			var ok: bool = false
			if event.button_index == MOUSE_BUTTON_LEFT:
				ok = _dig(cell)          # 掘る
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				ok = _place(cell)        # 盛る
			if ok:
				clicks_success += 1
				_play_sfx(sfx_dig if event.button_index == MOUSE_BUTTON_LEFT else sfx_place)
			else:
				_play_sfx(sfx_ng)
			_update_hud()
		return

	# キー入力
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R:
				_generate_world_daily()   # 同じデイリーを再生成
				_update_hud()
				queue_redraw()
			KEY_SPACE:
				_auto_step()              # 自動1手（スコア加算なし）
			KEY_H:
				_show_rules_overlay(true) # ルールを開く
			KEY_ESCAPE:
				# 何も開いていない時のEscはルールを開く/閉じるトグルにしてもOK
				if rules_overlay and rules_overlay.visible:
					_show_rules_overlay(false)
				else:
					_show_rules_overlay(true)

			# ▼ モバイル解像度テスト（PC上で素早く確認）
			KEY_F6:  get_window().size = Vector2i(360, 800)   # 小さめスマホ縦
			KEY_F7:  get_window().size = Vector2i(414, 896)   # iPhone系目安
			KEY_F8:  get_window().size = Vector2i(720, 1600)  # 一般的スマホ縦
			KEY_F9:  get_window().size = Vector2i(1080, 2400) # 大型スマホ縦
			KEY_F10: get_window().size = Vector2i(800, 1280)  # タブレット縦
			KEY_F11: get_window().size = Vector2i(1600, 720)  # スマホ横
			KEY_F12: get_window().size = Vector2i(1024, 576)  # 開発時サイズに戻す



func _in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.x < SIZE.x and c.y >= 0 and c.y < SIZE.y

# ========== 隣接 & 斜面チェック ==========
func _neighbors4(c: Vector2i) -> Array:
	var arr: Array = []
	var offs: Array = [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]
	for d in offs:
		var p: Vector2i = c + d
		if _in_bounds(p):
			arr.append(p)
	return arr

func _reachable_now(c: Vector2i) -> bool:
	var h: int = int(heights[c.x][c.y])
	for n in _neighbors4(c):
		var hn: int = int(heights[n.x][n.y])
		if abs(h - hn) <= 1:
			return true
	return false

func _stable_after(c: Vector2i, new_h: int) -> bool:
	for n in _neighbors4(c):
		var hn: int = int(heights[n.x][n.y])
		if abs(new_h - hn) <= 1:
			return true
	return false

# ========== 掘る/盛る ==========
func _dig(c: Vector2i) -> bool:
	var h: int = int(heights[c.x][c.y])
	if h <= 0:
		return false
	if not _reachable_now(c):
		return false
	if not _stable_after(c, h - 1):
		return false
	heights[c.x][c.y] = h - 1
	inventory += 1
	_check_goal()
	queue_redraw()
	return true

func _place(c: Vector2i) -> bool:
	var h: int = int(heights[c.x][c.y])
	if inventory <= 0 or h >= MAX_H:
		return false
	if not _reachable_now(c):
		return false
	if not _stable_after(c, h + 1):
		return false
	heights[c.x][c.y] = h + 1
	inventory -= 1
	_check_goal()
	queue_redraw()
	return true

# ========== サウンド ==========
func _play_sfx(node: Node) -> void:
	if node and node.has_method("play"):
		node.play()

# ========== タイマー/スコア ==========
func _start_timer_if_needed() -> void:
	if start_msec < 0:
		start_msec = Time.get_ticks_msec()

func _elapsed_seconds() -> float:
	if start_msec < 0:
		return 0.0
	var end_ms: int = (finish_msec if finish_msec >= 0 else Time.get_ticks_msec())
	return float(end_ms - start_msec) / 1000.0

func _deviation_sum() -> int:
	var sum: int = 0
	for x in range(target_rect.position.x, target_rect.position.x + target_rect.size.x):
		for y in range(target_rect.position.y, target_rect.position.y + target_rect.size.y):
			if _in_bounds(Vector2i(x, y)):
				sum += abs(int(heights[x][y]) - DESIRED_H)
	return sum

func _update_hud() -> void:
	if not hud:
		return
	var dev: int = _deviation_sum()
	if dev == 0 and start_msec >= 0 and finish_msec < 0:
		finish_msec = Time.get_ticks_msec()
	var elapsed: float = _elapsed_seconds()
	var fails: int = clicks_total - clicks_success
	var date_str: String = _day_string()
	var msg: String = "Daily: %s  Seed: #%d\n" % [date_str, day_id]
	msg += "Goal H: %d  Inventory: %d\n" % [DESIRED_H, inventory]
	msg += "Clicks: %d (OK:%d / NG:%d)   Time: %ss\n" % [clicks_total, clicks_success, fails, String.num(elapsed, 1)]
	msg += "Rule: STRICT (事前+事後: 隣接どれか1方向と段差≤1)"
	hud.text = msg

func _check_goal() -> void:
	var dev: int = _deviation_sum()
	if dev == 0 and not result_shown:
		finish_msec = Time.get_ticks_msec()
		result_shown = true
		_update_hud()
		_show_result_overlay()

func _day_string() -> String:
	var unix: int = Time.get_unix_time_from_system()
	var sec: int = DAILY_TZ_OFFSET_SEC
	var day_sec: int = (unix + sec) - ((unix + sec) % 86400)
	var dict: Dictionary = Time.get_datetime_dict_from_unix_time(day_sec)
	return "%04d-%02d-%02d" % [int(dict["year"]), int(dict["month"]), int(dict["day"])]

# ========== 自動1手 ==========
func _auto_step() -> void:
	for x in range(target_rect.position.x, target_rect.position.x + target_rect.size.x):
		for y in range(target_rect.position.y, target_rect.position.y + target_rect.size.y):
			var c: Vector2i = Vector2i(x, y)
			if _in_bounds(c) and int(heights[x][y]) > DESIRED_H:
				if _dig(c):
					return
	if inventory > 0:
		for x2 in range(target_rect.position.x, target_rect.position.x + target_rect.size.x):
			for y2 in range(target_rect.position.y, target_rect.position.y + target_rect.size.y):
				var c2: Vector2i = Vector2i(x2, y2)
				if _in_bounds(c2) and int(heights[x2][y2]) < DESIRED_H:
					if _place(c2):
						return

# ========== オーバーレイ ==========
func _build_rules_overlay() -> void:
	rules_overlay = _make_overlay()
	overlay_layer.add_child(rules_overlay)

	var title: String = "整地ちゅう（あそびかた）"
	var body: String = \
"■毎日0:00(UTC)に全員同じマップが出題\n" + \
"■黄色の高さにそろえよう。山は掘って、谷は盛る\n" + \
"■操作　左クリック：掘る（土+1）／ 右クリック：盛る（土-1）\n" + \
"※一番高いマスは盛れず、一番低いマスは掘れません。\n" + \
"■作業できる条件　上下左右のどれか1マスと“高さの差が1まで”ならOK。\n" + \
"※さらに、作業の前後どちらでもこの条件を満たす必要があります。\n" + \
"■ クリアとスコア\n" + \
"対象エリアが全部“黄色の高さ”になればクリア！\n" + \
"クリックは失敗もカウント。クリックが少なく、時間が短いほど高スコアです。"

	_overlay_set_content(rules_overlay, title, body, [
		{"text":"スタート", "cb": func(): _show_rules_overlay(false), "style":"primary"}
	])

func _build_result_overlay() -> void:
	result_overlay = _make_overlay()
	overlay_layer.add_child(result_overlay)
	_overlay_set_content(result_overlay, "結果", "", [])

func _show_rules_overlay(show: bool) -> void:
	if rules_overlay:
		rules_overlay.visible = show
	if hud:
		hud.visible = not show

func _close_result_overlay() -> void:
	if result_overlay:
		result_overlay.visible = false
	if hud:
		hud.visible = true

func _show_result_overlay() -> void:
	if not result_overlay:
		return
	var fails: int = clicks_total - clicks_success
	var elapsed: float = _elapsed_seconds()
	var date_str: String = _day_string()

	# モード表記を削除した共有テキスト
	var share: String = "Seichi Daily %s  #%d\nClicks:%d (OK:%d / NG:%d)\nTime:%ss" % [
		date_str, day_id, clicks_total, clicks_success, fails, String.num(elapsed, 1)
	]
	var body: String = \
"日付:  %s  /  Seed: #%d\n" % [date_str, day_id] + \
"クリック:  %d  (OK:%d / NG:%d)\n" % [clicks_total, clicks_success, fails] + \
"タイム:  %ss\n\n" % [String.num(elapsed, 1)] + \
"シェアできます！"

	_overlay_set_content(result_overlay, "ゴール！", body, [
		{"text":"結果をコピー", "cb": func(): DisplayServer.clipboard_set(share), "style":"primary"},
		{"text":"Tweetする",   "cb": func(): OS.shell_open("https://twitter.com/intent/tweet?text=" + _urlencode(share)), "style":"primary"},
		{"text":"閉じる",       "cb": func(): _close_result_overlay()}
	])
	result_overlay.visible = true
	if hud:
		hud.visible = false

# ========== ユーティリティ ==========
func _urlencode(s: String) -> String:
	var t: String = s
	t = t.replace("%", "%25")
	t = t.replace("\n", "%0A")
	t = t.replace(" ", "%20")
	t = t.replace("#", "%23")
	t = t.replace(":", "%3A")
	t = t.replace("/", "%2F")
	t = t.replace("(", "%28").replace(")", "%29")
	return t

# “別ウィンドウ風”オーバーレイ生成（中央固定・ダークカード・白文字／左揃え）
func _make_overlay() -> Control:
	var root: Control = Control.new()
	root.name = "Overlay"
	root.visible = false
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg: ColorRect = ColorRect.new()
	bg.name = "BG"
	bg.color = Color(0, 0, 0, 0.65)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	var panel: Control = Control.new()
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(640, 360)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	root.add_child(panel)

	var card: ColorRect = ColorRect.new()
	card.name = "Card"
	card.color = Color(0.12, 0.12, 0.14, 0.98)
	card.set_anchors_preset(Control.PRESET_FULL_RECT)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(card)

	var margin: MarginContainer = MarginContainer.new()
	margin.name = "Margin"
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	panel.add_child(margin)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)   # ← パネルいっぱいに広げる

	var v: VBoxContainer = VBoxContainer.new()
	v.name = "VBox"
	v.alignment = BoxContainer.ALIGNMENT_BEGIN
	v.add_theme_constant_override("separation", 12)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(v)

	var title: Label = Label.new()
	title.name = "Title"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(title)

	var sep: HSeparator = HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 8)
	sep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(sep)

	var body: Label = Label.new()
	body.name = "Body"
	body.autowrap_mode = TextServer.AUTOWRAP_WORD
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	body.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(body)

	var btn_row: HBoxContainer = HBoxContainer.new()
	btn_row.name = "Buttons"
	btn_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	btn_row.add_theme_constant_override("separation", 12)
	btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(btn_row)

	call_deferred("_recenter_panel", panel)
	panel.resized.connect(func(): _recenter_panel(panel))
	get_viewport().size_changed.connect(func(): _recenter_panel(panel))

	return root

# オーバーレイ内容の適用
func _overlay_set_content(overlay: Control, title: String, body: String, buttons: Array) -> void:
	if overlay == null:
		return
	var v: VBoxContainer = overlay.find_child("VBox", true, false) as VBoxContainer
	if v == null:
		push_error("VBox not found in overlay")
		return
	var title_node: Label = v.find_child("Title", true, false) as Label
	var body_node: Label = v.find_child("Body", true, false) as Label
	var btn_row: HBoxContainer = v.find_child("Buttons", true, false) as HBoxContainer
	if title_node == null or body_node == null or btn_row == null:
		push_error("Overlay parts not found (Title/Body/Buttons)")
		return

	title_node.text = title
	body_node.text = body

	for c in btn_row.get_children():
		c.queue_free()

	for item in buttons:
		var b: Button = Button.new()
		b.text = String(item["text"])
		var cb = item["cb"]
		b.pressed.connect(cb)
		btn_row.add_child(b)
		if b.text == "スタート" or (item.has("style") and String(item["style"]) == "primary"):
			_style_button_primary(b)

# 中央固定：サイズ確定後・リサイズ時にも追従
func _recenter_panel(panel: Control) -> void:
	if panel == null:
		return
	var sz: Vector2 = panel.get_combined_minimum_size()
	if panel.custom_minimum_size.x > sz.x:
		sz.x = panel.custom_minimum_size.x
	if panel.custom_minimum_size.y > sz.y:
		sz.y = panel.custom_minimum_size.y
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -sz.x * 0.5
	panel.offset_right =  sz.x * 0.5
	panel.offset_top = -sz.y * 0.5
	panel.offset_bottom =  sz.y * 0.5

# 白背景＋ダーク文字ボタン（Godot 4）
func _style_button_primary(b: Button) -> void:
	var normal: StyleBoxFlat = StyleBoxFlat.new()
	normal.bg_color = Color(1, 1, 1, 1)
	normal.set_border_width_all(2)
	normal.border_color = Color(0.16, 0.18, 0.22, 1)
	normal.set_corner_radius_all(10)

	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(0.95, 0.96, 0.98, 1)

	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = Color(0.90, 0.92, 0.95, 1)

	var disabled: StyleBoxFlat = normal.duplicate()
	disabled.bg_color = Color(0.88, 0.90, 0.93, 1)
	disabled.border_color = Color(0.5, 0.5, 0.55, 1)

	var focus: StyleBoxFlat = normal.duplicate()
	focus.border_color = Color(0.25, 0.45, 1.0, 1)

	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_stylebox_override("focus", focus)

	var font_col: Color = Color(0.10, 0.12, 0.16, 1)
	b.add_theme_color_override("font_color", font_col)
	b.add_theme_color_override("font_hover_color", font_col)
	b.add_theme_color_override("font_pressed_color", font_col)
	b.add_theme_color_override("font_disabled_color", Color(0.4, 0.42, 0.48, 1))

	b.custom_minimum_size = Vector2(120, 36)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
