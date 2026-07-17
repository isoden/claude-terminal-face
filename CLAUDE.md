# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An ASCII-art robot face (PRAGMATA/Stellar Blade "digital cabin face" motif) implemented twice:
in-browser (`misc/claude-terminal-face-proto.html`) and as a Ghostty terminal-background custom shader
(`claude-terminal-face.glsl`, `claude-terminal-face-status.glsl`). **`docs/SPEC.md` is the authoritative design doc** —
read it before making non-trivial changes; it documents the rationale, constraints, and known
issues in detail. Don't duplicate its content here; this file only covers what you need to start
working productively.

## No build/test tooling

This is a dependency-free static project — no `package.json`, no bundler, no linter, no test
suite. There is nothing to `npm install` or `npm run build`.

- **`misc/claude-terminal-face-proto.html`**: open the file directly in a browser.
- **`claude-terminal-face.glsl` / `claude-terminal-face-status.glsl`**: these cannot be "run" standalone — they are
  Ghostty custom shaders (Shadertoy-style `mainImage`) meant to be referenced from
  `~/.config/ghostty/config` via `custom-shader = ...`. Ghostty hot-reloads custom shaders on
  save (1.2.0+), but the intended runtime is a real Ghostty terminal, not a browser.
- **`misc/shader-preview.html`**: a standalone WebGL2 harness for iterating on the GLSL files without
  a real Ghostty install. Open it in a browser, pick a `.glsl` file via the file input, and it
  compiles/renders it live with sliders for the fake state (`since`, `err`, gaze) plus a
  **"Ghostty simulation" toggle** that flips `fragCoord.y` to reproduce Ghostty's actual
  coordinate convention (see below) — always test with this ON, since Chrome's native
  `gl_FragCoord` uses the opposite convention and will hide orientation bugs. Re-select the same
  file after editing it to recompile.

### Compile-checking the GLSL with glslang (required before calling a shader change done)

Ghostty compiles custom shaders with glslang, not with the browser's WebGL2 compiler, so
`misc/shader-preview.html` saying "compiled OK" is NOT sufficient: the harness silently keeps
rendering the previous program if you re-select the same filename (the file input fires no
change event), and its stale "compiled OK" once masked a use-before-declaration bug that made
the face vanish in real Ghostty. Always validate with the real compiler
(`brew install glslang`, already installed on this machine):

```sh
cd "$(mktemp -d)"
cat > header.glsl <<'EOF'
#version 430 core
layout(binding = 0) uniform sampler2D iChannel0;
layout(binding = 1) uniform Globals {
    uniform vec3 iResolution;
    uniform float iTime;
    uniform float iTimeDelta;
    uniform float iFrameRate;
    uniform int iFrame;
    uniform vec4 iMouse;
    uniform vec4 iDate;
    uniform vec4 iCurrentCursor;
    uniform vec4 iPreviousCursor;
    uniform vec4 iCurrentCursorColor;
    uniform vec4 iPreviousCursorColor;
    uniform float iTimeCursorChange;
};
layout(location = 0) out vec4 _fragColor;
EOF
cat > footer.glsl <<'EOF'
void main() { mainImage(_fragColor, gl_FragCoord.xy); }
EOF
cat header.glsl /path/to/repo/claude-terminal-face-status.glsl footer.glsl > test.frag
glslang --target-env vulkan1.2 -S frag test.frag   # exit 0 = OK
```

There's no automated way to verify the GLSL against real Ghostty *rendering* (glslang only
proves it compiles); changes affecting layout/orientation/timing should be sanity-checked with
`misc/shader-preview.html` (reload the page before re-uploading an edited file — see above) and,
when possible, called out to the user for a real-Ghostty check.

## Architecture

### Shared design (all three files)

Faces are **not** sprites — each expression is a signed distance field (SDF), and transitions are
done by lerping distance values (`d = mix(sdf_A, sdf_B, t)`), not by cross-fading images. Eyes and
mouth are separate SDF fields (`min(eyes, mouth)`) so blinking can blend just the eye field while
the mouth keeps its current shape. Face space is centered at origin with **y positive = down**;
shared layout constants (`EX`, `EY`, `TH`, mouth arc centers) are duplicated across
`misc/claude-terminal-face-proto.html` (JS) and both `.glsl` files — changing one without the others causes visible
drift (docs/SPEC.md §7.4 tracks this as a known issue; there's no single source of truth yet).

Luminance is derived from the distance field (core + exponential bloom) and quantized into an
ASCII ramp `" .:-+=*%#@"` — this softens sub-cell motion into perceived brightness changes rather
than jaggy 1-cell jumps.

### `misc/claude-terminal-face-proto.html`

Plain JS + DOM, no framework. A `<pre>` of `60×28` pre-created `<span>` cells is mutated
per-frame; only cells whose character/level actually changed are touched (`prevCh`/`prevLv`
caches) — `innerHTML` is never rewritten. 7 expressions are defined in the `EXPR` array as
`{eyes, mouth}` SDF functions; `setExpr()` drives a `from → to` morph over `MORPH_MS`.

### `claude-terminal-face.glsl` / `claude-terminal-face-status.glsl`

Ghostty custom shaders are **stateless** Shadertoy-style fragment shaders — no persistent state
between frames, no arbitrary texture inputs. Two consequences that shape the code:

- **5×5 bitmap pseudo-font baked into the shader** (`glyphBits`/`glyphPixel`) since there's no
  font atlas texture available. Glyphs must stay ordered by lit-pixel count (monotonic ramp) —
  see docs/SPEC.md §3.3 before adding characters.
- **Expression state is a pure function of `iTime - iTimeCursorChange`** (time since last
  keypress) rather than actual stored state — `faceField()` computes SMILE/IDLE/SLEEP blend
  weights from elapsed time every frame (docs/SPEC.md §3.4).

`claude-terminal-face-status.glsl` additionally reacts to shell command exit codes, which Ghostty shaders
have no direct access to. The workaround: the shell prompt encodes `$status` into the terminal
**cursor color** via OSC 12, and the shader reads `iCurrentCursorColor`/`iPreviousCursorColor` to
derive an `err` blend weight toward a SAD expression (docs/SPEC.md §5). This is a real side channel
with real limitations (effectively 1 bit of info, occupies the cursor color) — read docs/SPEC.md §5.3
before extending it.

**Known platform quirk (already fixed, don't reintroduce):** Ghostty's `fragCoord.y` is
top-down-origin, the _opposite_ of the Shadertoy/OpenGL convention these shaders otherwise follow.
Both files have a `TOPDOWN_Y` constant (default `1.0`, matching real Ghostty behavior) that
governs both the face's y-flip and the glyph row lookup in `glyphPixel` — these two must stay in
sync, and if Ghostty ever standardizes its coordinate convention, flip `TOPDOWN_Y` to `0.0` rather
than resurrecting the old unconditional `p.y = -p.y`.
