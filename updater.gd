extends Node
## Checks the latest GitHub release at startup and updates the game.
## Windows: downloads aster-windows.zip, swaps the exe with a small batch script once the game has quit, restarts it.
## macOS: downloads aster-macos.zip to the Downloads folder and shows it (the app has to be replaced by hand).
## Releases must be tagged vX.Y (e.g. v2.1) and the version in Project Settings > Application > Config > Version
## must match the tag of the build.

signal update_available(version: String)
signal progress_changed(text: String)

const RELEASES_API := "https://api.github.com/repos/lennyblk/aster/releases/latest"
const WINDOWS_ASSET := "aster-windows.zip"
const MAC_ASSET := "aster-macos.zip"

var latest_version := ""
var _asset_url := ""
var _http: HTTPRequest
var _download_path := ""
var _downloading := false


func current_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.0"))


func _ready() -> void:
	# only exported builds update themselves
	if OS.has_feature("editor") or not (OS.get_name() == "Windows" or OS.get_name() == "macOS"):
		return
	_http = HTTPRequest.new()
	_http.timeout = 15.0
	add_child(_http)
	_http.request_completed.connect(_on_release_info)
	_http.request(RELEASES_API, ["User-Agent: aster-game", "Accept: application/vnd.github+json"])


func _on_release_info(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_http.request_completed.disconnect(_on_release_info)
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		return
	var tag := str(data.get("tag_name", "")).trim_prefix("v")
	if tag == "" or not _is_newer(tag, current_version()):
		return
	var wanted := WINDOWS_ASSET if OS.get_name() == "Windows" else MAC_ASSET
	for asset in data.get("assets", []):
		if asset.get("name", "") == wanted:
			_asset_url = asset.get("browser_download_url", "")
	if _asset_url == "":
		return
	latest_version = tag
	update_available.emit(tag)


# "2.10" > "2.9": compares each number in turn
func _is_newer(a: String, b: String) -> bool:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in maxi(pa.size(), pb.size()):
		var x := int(pa[i]) if i < pa.size() else 0
		var y := int(pb[i]) if i < pb.size() else 0
		if x != y:
			return x > y
	return false


func start_update() -> void:
	if _downloading or _asset_url == "":
		return
	_downloading = true
	if OS.get_name() == "Windows":
		DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir().path_join("update"))
		_download_path = OS.get_user_data_dir().path_join("update").path_join(WINDOWS_ASSET)
	else:
		_download_path = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS).path_join(MAC_ASSET)
	_http.download_file = _download_path
	_http.timeout = 0.0
	_http.request_completed.connect(_on_downloaded)
	_http.request(_asset_url, ["User-Agent: aster-game"])
	set_process(true)


func _process(_delta: float) -> void:
	if not _downloading or _http.get_body_size() <= 0:
		return
	var pct := int(100.0 * _http.get_downloaded_bytes() / _http.get_body_size())
	progress_changed.emit("downloading  %d %%" % pct)


func _on_downloaded(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_downloading = false
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		progress_changed.emit("download failed")
		return
	if OS.get_name() == "Windows":
		_install_windows()
	else:
		progress_changed.emit("downloaded  ·  replace aster with the new version")
		OS.shell_show_in_file_manager(_download_path)


func _install_windows() -> void:
	progress_changed.emit("installing")
	var zip := ZIPReader.new()
	if zip.open(_download_path) != OK:
		progress_changed.emit("update failed")
		return
	var new_exe := ""
	for file in zip.get_files():
		if file.to_lower().ends_with(".exe"):
			new_exe = OS.get_user_data_dir().path_join("update").path_join(file.get_file())
			var f := FileAccess.open(new_exe, FileAccess.WRITE)
			if f == null:
				break
			f.store_buffer(zip.read_file(file))
			f.close()
			break
	zip.close()
	if new_exe == "" or not FileAccess.file_exists(new_exe):
		progress_changed.emit("update failed")
		return

	# The running exe can't be overwritten: a batch script waits for the game to quit, copies the new exe
	# over the old one, starts it again and deletes itself.
	var exe := OS.get_executable_path().replace("/", "\\")
	var src := new_exe.replace("/", "\\")
	var bat := OS.get_user_data_dir().path_join("update").path_join("update.bat").replace("/", "\\")
	var script := "@echo off\r\n" \
		+ ":wait\r\n" \
		+ "tasklist /FI \"PID eq %d\" | find \"%d\" >nul && (timeout /t 1 /nobreak >nul & goto wait)\r\n" % [OS.get_process_id(), OS.get_process_id()] \
		+ "copy /Y \"%s\" \"%s\" >nul\r\n" % [src, exe] \
		+ "start \"\" \"%s\"\r\n" % exe \
		+ "del \"%s\"\r\n" % src \
		+ "(goto) 2>nul & del \"%~f0\"\r\n"
	var f := FileAccess.open(bat, FileAccess.WRITE)
	if f == null:
		progress_changed.emit("update failed")
		return
	f.store_string(script)
	f.close()
	OS.create_process("cmd.exe", ["/c", bat])
	get_tree().quit()
