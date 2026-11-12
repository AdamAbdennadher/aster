extends Node
## Shared leaderboard on Supabase (autoload "Online"). Every new personal best is sent with the player's
## name; the leaderboard shows the best time of each player on a map.
## Only the project URL and the public (anon / publishable) key go here, NEVER the database password.
## The table, view and access rules are created by docs/supabase.sql.

signal leaderboard_loaded(rows)   # Array of {player_id, player_name, map, time_ms} for every map, null on failure

const SUPABASE_URL := "https://vekiqhgaexvqodrjhlec.supabase.co"  
const SUPABASE_KEY := "sb_publishable_jWjf7uAL0tn2LtVZRyZQPQ_TOQIXrt3"
const PLAYER_FILE := "user://player.cfg"

var player_name := ""
var player_id := ""       
var _uploaded := {}   # map id -> best time (ms) already on the leaderboard


func _ready() -> void:
	# the leaderboard is opened from the pause menu: requests must keep running while the tree is paused
	process_mode = Node.PROCESS_MODE_ALWAYS
	var cfg := ConfigFile.new()
	if cfg.load(PLAYER_FILE) == OK:
		player_name = cfg.get_value("player", "name", "")
		player_id = cfg.get_value("player", "id", "")
		_uploaded = cfg.get_value("player", "uploaded", {})
	if player_id == "":
		player_id = Crypto.new().generate_random_bytes(16).hex_encode()
		_save()
	Game.lap_completed.connect(_on_lap_completed)
	sync_local_bests()
	if is_configured() and player_name != "":
		fetch_leaderboard()


func is_configured() -> bool:
	return SUPABASE_URL != "" and SUPABASE_KEY != ""


func set_player_name(new_name: String) -> void:
	player_name = new_name.strip_edges().left(16)
	# resend every best under this name: the leaderboard shows the name of each player's latest upload
	_uploaded = {}
	_save()
	sync_local_bests()


# Sends every local best that is not on the leaderboard yet (made offline, before choosing a name, or when
# a previous upload failed)
func sync_local_bests() -> void:
	for m in Game.MAPS:
		var best: float = Game.best_time(m.scene)
		if best < INF and int(round(best * 1000.0)) < int(_uploaded.get(map_id(m.scene), 1 << 30)):
			submit_time(m.scene, best)


func map_id(scene_path: String) -> String:
	return scene_path.get_file().get_basename()


func submit_time(scene_path: String, time: float) -> void:
	if not is_configured() or player_name == "":
		return
	var id := map_id(scene_path)
	var ms := int(round(time * 1000.0))
	var body := JSON.stringify({
		"player_id": player_id,
		"player_name": player_name,
		"map": id,
		"time_ms": ms,
	})
	_request("/rest/v1/lap_times", HTTPClient.METHOD_POST, body, ["Prefer: return=minimal"], func(ok: bool, _data):
		if ok and ms < int(_uploaded.get(id, 1 << 30)):
			_uploaded[id] = ms
			_save())


func fetch_leaderboard() -> void:
	if not is_configured():
		leaderboard_loaded.emit(null)
		return
	sync_local_bests()
	var query := "/rest/v1/leaderboard?select=player_id,player_name,map,time_ms&order=time_ms.asc&limit=1000"
	_request(query, HTTPClient.METHOD_GET, "", [], func(ok: bool, data):
		if ok and data is Array:
			_restore_missing_bests(data)
		leaderboard_loaded.emit(data if ok and data is Array else null))


# A personal best that is not (or no longer) on the leaderboard, e.g. rows deleted by hand, is sent again
func _restore_missing_bests(rows: Array) -> void:
	if player_name == "":
		return
	for m in Game.MAPS:
		var best: float = Game.best_time(m.scene)
		if best == INF:
			continue
		var id := map_id(m.scene)
		var online := 1 << 30
		for r in rows:
			if r.get("map", "") == id and r.get("player_id", "") == player_id:
				online = int(r.get("time_ms", online))
		if int(round(best * 1000.0)) < online:
			_uploaded.erase(id)
			submit_time(m.scene, best)


func _on_lap_completed(time: float, rank: int, _previous_best: float) -> void:
	if rank == 1:   # new personal best
		submit_time(Game.current_map, time)


func _request(path: String, method: int, body: String, extra_headers: Array, done: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	var headers := PackedStringArray(["apikey: " + SUPABASE_KEY, "Content-Type: application/json"])
	if SUPABASE_KEY.begins_with("eyJ"):
		headers.append("Authorization: Bearer " + SUPABASE_KEY)   # legacy anon key (a JWT)
	for h in extra_headers:
		headers.append(h)
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, response: PackedByteArray):
		http.queue_free()
		if done.is_valid():
			var ok := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
			var data = JSON.parse_string(response.get_string_from_utf8()) if ok and response.size() > 0 else null
			done.call(ok, data))
	if http.request(SUPABASE_URL + path, headers, method, body) != OK:
		http.queue_free()
		if done.is_valid():
			done.call(false, null)


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", player_name)
	cfg.set_value("player", "id", player_id)
	cfg.set_value("player", "uploaded", _uploaded)
	cfg.save(PLAYER_FILE)
