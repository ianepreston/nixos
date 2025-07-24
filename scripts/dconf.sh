#!/usr/bin/env nu

def parse_dump [] {
	lines
	| split list --split before --regex '^\[.*\]$' # split into multiple lists, each containing all lines of a single section, including the header.
	| skip 1 # we assume there's no global section.
	| each { |group| {
		name:     ($group | first | parse '[{name}]' | get 0.name), # unwrap the section name.
		contents: ($group | skip 1 | parse '{key}={value}' | transpose --header-row --as-record) # parse the individual KV pairs.
	} }
	| transpose --header-row --as-record # construct a single record with section names as keys.
}

def format_dump [] {
	($in
		| transpose name contents
		| where contents != {} # filter out empty sections, as dconf2nix chokes on these.
		| update contents { transpose key value | format pattern "{key}={value}" | str join "\n" }
		| format pattern "[{name}]\n{contents}" | str join "\n\n"
	) + "\n" # dconf2nix requires a trailing newline.
}

dconf dump /
	| parse_dump
	# filter out state & automatically inferred stuff.
	| (reject
		# 'org/gnome/desktop/a11y/applications'
    'apps/seahorse/windows/key-manager'
    'apps/seahorse/listing'
    'org/gnome/Console'
    'org/gnome/TextEditor'
    'org/gnome/control-center'
    'org/gnome/shell/extensions/quicksettings-audio-devices-renamer'
    'org/gnome/shell/extensions/quicksettings-audio-devices-hider'
		'org/gnome/desktop/interface'
		# 'org/gnome/desktop/sound'
		# 'org/gnome/desktop/wm/preferences'
		'org/gtk/settings/file-chooser'
	)
	| upsert 'com/github/wwmm/easyeffects/streamoutputs' { default {} | reject --ignore-errors 'output-device' }
	| upsert 'com/github/wwmm/easyeffects/streaminputs'  { default {} | reject --ignore-errors 'input-device' }
  # I don't think I want most things tracked in nix, let's try being selective
  | (select
  'org/gnome/mutter/keybindings'
  'org/gnome/settings-daemon/plugins/media-keys'
  'org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0'
  'org/gnome/shell/extensions/paperwm'
  'org/gnome/shell/keybindings'
  )
	| format_dump
	| dconf2nix
	| alejandra
  | save  -f home/optional/gnome/dconf.nix
