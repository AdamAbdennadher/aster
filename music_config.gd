class_name MusicConfig
extends Resource
## Music settings, edited in the Inspector by opening music_config.tres.
## The name shown in game is the file name (rename the file to rename the track).

@export var menu_track: AudioStream
@export var playlist: Array[AudioStream] = []
@export var crossfade := 2.0          ## seconds of overlap between two tracks
@export var volume_db := -6.0
