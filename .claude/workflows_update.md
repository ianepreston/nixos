Using Aerospace + Hammerspoon has been decent for unifying my workflow, but
aerospace in particular feels glitchy. Sometimes windows minimize themselves out
of sight, particularly when changing displays (coming off dock or cycling
between work and personal machine). Hammerspoon sometimes works but a lot of its
configs are opaque and flaky.

Doing some further research, I think I can do a few mac key rebinds and get back
to an otherwise vanilla MacOS window management experience, and then modify
GNOME to match.

One key modification here is that I've added a hyper key
(shift+alt/opt+cmd/meta+ctrl) to my home row. This opens up a modifier that I
can use that is guaranteed to not have any MacOS conflict, and negates my
challenges with trying to use globe/fn shortcuts without an apple keyboard.

# Modifications to make

## Application launch

`cmd+space` is still fine to launch spotlight on MacOS, I never deviated here.
GNOME currently just uses `super`, let's make this `super+space` to align more
closely

## Navigating between apps

Hammerspoon is currently configured for `opt+tab` to show a menu of windows on
the current workspace, which aligns with GNOME `alt+tab` alternating windows
within a given workspace. This may have to be modified if I move away from
aerospace and to actual MacOS virtual desktops. `cmd+tab` to do full app cycling
in MacOS is fine to keep as is and I don't use that in GNOME

## Navigating between windows of the same app

`cmd+backtick` in MacOS is fine, I rarely use this. Not sure what it is in GNOME
which shows how often I use it. As a future enhancement I'd love to unify
switching to just be by windows, but I think MacOS is specifically designed
against this so it's fine to leave for now.

## Hiding the current app

I think by default this is `cmd+h` in MacOS. Not sure what it's set to in GNOME,
I think `ctrl+down arrow` or something. Fine to set this to `cmd+h` in both,
although I don't use it much.

## Virtual desktop navigation

`ctrl + left/right arrow`. I don't love this because I have another layer for
arrows, but I bet I could train my fingers to learn it. Let's go with it and
modify GNOME to follow suit.

`ctrl + [number]` should move me to virtual desktops by number. Doesn't seem to
be working on MacOS now, maybe a hammerspoon or aerospace conflict. GNOME should
have the same behaviour, although I'm less reliant on that functionality there.
These shortcuts might also just have to be turned on in MacOS.

### Side note on virtual desktops

Two nice things here would be to have my Nix config auto populate multiple
virtual desktops and auto assign certain apps to certain desktops. Are
either/both of those things possible with nix darwin?

## Window resizing and management

Here is where we have to replace the globe key with hyper. While we're at it,
might as well use vim motions for positioning. I also don't do up/down splits
ever so we can just ignore that. Remember, `hyper = ctrl+opt+cmd+shift`.

Left half: `hyper+h` Right half: `hyper+l` Fill screen (maximize): `hyper+k`

## Mission control

`ctrl + up arrow` in MacOS brings up Mission control, there's a similar config
in my GNOME settings to make the upper left corner of my window be a hot corner
for that. Let's turn it on as a hot corner in MacOS and set `ctrl+up arrow` to
do the same thing in GNOME so we have parity.

Right now from mission control I can't use my keyboard to select windows or
desktops, this might be due to an aerospace or hammerspoon conflict. Keep that
in mind for testing once we remove the other issues.

## Copy/Paste

`cmd+c` and `cmd+v` work great, and ghostty already has been configured to use
them in GNOME. Configure GNOME to use them universally

## Browser

`ctrl+l` opens the menu bar in both, this is great

`ctrl+t` opens a new tab in GNOME, `cmd+t` does it in MacOS. Can we set `cmd+t`
to do this in GNOME? Ditto for `cmd/ctrl+w` mismatch for closing tabs.

`ctrl+tab` already switches tabs in both, this is great.

## Other stuff

Menu bar access in MacOS brings up a help search with `cmd+shift+/` or `cmd+?`.
Can I do anything like that in Gnome? If not don't worry about it.
