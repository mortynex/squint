# dmgbuild settings for the release DMG (used by release.sh).
# Icon positions must match tools/make-dmg-background.swift.
import os.path

app = defines["app"]
here = os.path.dirname(os.path.abspath(defines["settings"]))

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")

background = os.path.join(here, "background.png")
# Outer frame: 400 pt of content plus the title bar.
window_rect = ((200, 200), (640, 428))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (170, 200),
    "Applications": (470, 200),
}
