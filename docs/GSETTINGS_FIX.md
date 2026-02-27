# GSettings Schema Fix for GNOME Wayland Preview Window

## Problem
ffplay preview window was crashing with:
```
(ffplay:XXXXX): GLib-GIO-ERROR **: HH:MM:SS.XXX: Settings schema 'org.gnome.settings-daemon.plugins.xsettings' does not contain a key named 'antialiasing'
Trace/breakpoint trap (core dumped)
```

## Root Cause
The GNOME Settings schema was missing the `antialiasing` key in the main schema definition (it was only in the deprecated schema).

## Solution Applied
Added the `antialiasing` key to `/usr/share/glib-2.0/schemas/org.gnome.settings-daemon.plugins.xsettings.gschema.xml`:

```xml
<key name="antialiasing" type="s">
  <default>'grayscale'</default>
  <summary>Antialiasing</summary>
  <description>The type of antialiasing to use when rendering fonts...</description>
</key>
```

Then recompiled schemas:
```bash
sudo glib-compile-schemas /usr/share/glib-2.0/schemas/
```

And cleared local cache:
```bash
rm -rf ~/.cache/glib-2.0/schemas/
dconf update
```

## Result
✅ Preview window now opens without crashes on Wayland
✅ FFmpeg video capture works properly with live preview

## Testing
After applying the fix:
- `copt --host --preview --hls` - Preview window opens successfully
- No more `Trace/breakpoint trap` errors
