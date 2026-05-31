# lifestrings

A pendulum-wave sequencer for [norns](https://monome.org/docs/norns/).

17 strings sit on a single beam, the whole rig rotated 90° counter-clockwise so the
pendulums swing across the screen. Each string's chevron length sets its period, so
they drift in and out of phase over a 30-second cycle — a pendulum-wave music box.

## Controls

- **E1** — master tune
- **E2** — tempo / time-scale
- **E3** — spread (period range)
- **K2** — reset all to phase zero
- **K3** — cycle scale
- **K1 + K3** — cycle waveform

## Requirements

- norns
- engine: `PolyPerc` (ships with norns)

## Install

Copy `lifestrings.lua` to `dust/code/lifestrings/` on your norns, or clone:

```
;install https://github.com/om-i-god/lifestrings
```

## Version

v1.3
