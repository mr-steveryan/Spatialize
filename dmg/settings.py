# dmgbuild settings for the Spatialize installer window. Used by dmg/build.sh (run that, not this).
# Paths below are relative to the repo root; `app` is passed in with -D app=<path>.

app = defines["app"]  # noqa: F821  (injected by dmgbuild -D)

files = [app]
symlinks = {"Applications": "/Applications"}
icon = "waveform.icns"
background = "dmg/background.png"  # dmgbuild adds background@2x.png automatically

# Icon positions match dmg/background.png (660x400 pt, icons at y=205). Height adds 32 pt for the title bar.
window_rect = ((200, 120), (660, 432))
icon_size = 128
text_size = 13
icon_locations = {
    "Spatialize.app": (170, 205),
    "Applications": (490, 205),
}
