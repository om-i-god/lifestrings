# lifestrings — devlog

A running design log. Written from the project's current state (v1.3) rather than
as a dated release history — the repo was published after most of the design work,
so dates below are noted only where they're actually known.

## The idea

A pendulum-wave music box. The north star is Daniel Olejnik's *Lucid Rhythms*
([ruta-sound.com](https://www.ruta-sound.com/copy-of-modular)) — meditative
pendulum-wave videos with long ringing tones and slow drifting polymeter. The
goal was never a sequencer in the metronome sense. It's **physics, not a grid**:
each voice swings at its own period, the periods drift in and out of phase, and
the music is whatever falls out of that.

## From hypnotizer to lifestrings (2026-05-10)

The project started life as `hypnotizer`. The rename to **lifestrings** came once
the central metaphor settled: not a hypnotic spiral but a row of living strings on
a beam, each one breathing at its own rate. The rename was a clarification of
identity, not a feature change.

## Why rotated 90° CCW

The norns screen is 128×64 — wide and short. Pendulums want to be **tall**: you
need vertical room for a string to hang and swing. So the whole instrument is built
to be played with the unit rotated 90° counter-clockwise, giving a 64-wide ×
128-tall canvas from the player's point of view (encoders read E1 E2 E3 left→right
along the top).

All draw code is written in user-natural `(u, v)` coordinates — u horizontal 0..63,
v vertical 0..127 — and `lcd_*` helpers map those to the physical screen via
`(127 - v, u)`. Keeping the drawing math in the rotated frame meant the geometry
stayed readable; the rotation is a thin translation layer at the edge.

A consequence: **no on-screen text.** Text doesn't survive the rotation cleanly, so
all state is communicated visually (a tiny modifier indicator, dots, ripples)
instead of labels.

## One beam, seventeen strings

All 17 voices hang from a single beam at user-top (v=8):

- **3 bass voices** at beam positions 1, 9, 17 — the two edges and the middle.
  Lengths `{105, 115, 105}`, so the *middle* bass is the longest and strikes near
  the canvas bottom. Slow periods (~35–70s).
- **14 lead voices** fill the 14 positions between them. Lengths follow a **chevron**
  via `25 + 65·sin(π·(p−1)/16)`, so leads near the middle are tallest (~89px) and
  leads near the edges are shortest (~38px). Fast periods (~5–10s).

The chevron shape is the visual signature — a rippling field that's tallest in the
center and tapers to the edges, like a suspension bridge cable or a row of wine
glasses.

## Keeping the swing legible

A real pendulum's horizontal travel depends on its length and release angle. If
every string used the same angle, the long ones would sweep huge arcs and the short
ones would barely move. So `theta_max` is **derived per voice** to hold the
horizontal swing at a constant `SIDEWAYS_TARGET = 7px` regardless of length. Long
strings sweep through tiny angles, short strings through bigger ones — and the whole
ensemble reads as one coherent field rather than a jumble of mismatched arcs.

Each voice fires **once per swing**, on its left→right zero crossing (sin going from
negative to non-negative). Unidirectional triggering makes the instrument breathe:
sound on the forward pass, silence on the return.

## Bass re-anchors the key

The harmonic move that makes it feel composed rather than random: **every bass
strike re-anchors `current_lead_root`** to its own note transposed up an octave.
Bass plays scale degrees 1/3/5 an octave down; leads play degrees 1–14 over ~two
octaves. When a bass hits, the lead pool modulates to a new key center — but the
scale *type* is preserved (major stays major). The leads keep their phases; they
don't reset. So a bass strike feels like the ground shifting under a melody that
keeps flowing.

## Sound

PolyPerc with a long release (3s default), low cutoff (800Hz), and low velocity
(64), plus global reverb (`audio.rev_on()` in init). The point is ringing and
blooming, not percussion. Notes overlap and decay into each other.

## Avoiding the silent-start trap

Naively, a slow pendulum might take a full period before its first trigger — so the
instrument could sit silent for tens of seconds on load. To avoid this, phases are
seeded so sound starts immediately: bass voices begin at phase ≈ 2π − ε (staggered)
so they fire within the first second, and leads are scattered into [π, 2π) so every
trigger lands within half a period.

## Visual vocabulary

With no text, the screen leans on motion:

- **Trails** — 8-frame smooth falloff behind each bob.
- **Pluck wave** — a bright pulse travelling pivot→bob along the string for ~180ms
  after a strike.
- **Strike comet** — a 7px motion-blur streak trailing behind a left→right strike.
- **Tonic dot** above lead[1]'s pivot, pulsing on each bass re-anchor.
- **Beam ripple** — a brightness wave radiating along the beam from a bass pivot on
  bass strike.
- **Anchor dots** — faint marks at each natural strike point, brightening on strike.

## Published (2026-05-31)

v1.3 pushed to [github.com/om-i-god/lifestrings](https://github.com/om-i-god/lifestrings)
— public, with a README and `;install` support. This was a packaging step; the code
was already at v1.3.

## Design guardrails

The identity is "physics, not metronome" + the *Lucid Rhythms* aesthetic: no
tempo-locked subdivisions, no quantized triggers, no fast/percussive defaults. Long
releases, slow tempos, ringing tones, space between notes. Any move toward "tighter"
or "more rhythmic" breaks the concept and should be a deliberate, confirmed choice —
not a default.
