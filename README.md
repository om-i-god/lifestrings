# lifestrings

A pendulum-wave sequencer for [norns](https://monome.org/docs/norns/).

Hold the norns rotated **90° CCW** (encoders along the top from your POV, reading
E1 E2 E3 left→right). 17 pendulums hang from a single beam at user-top: 3 bass at
the ends + middle, 14 leads filling between. Each fires once per swing on its
left→right pass through the pivot. Bass strikes re-anchor the lead scale to a new
root — physics, not a metronome.

## Controls

- **E1** lead period · **E2** amp · **E3** spread
- **K1 + E1** cutoff · **K1 + E2** root · **K1 + E3** mode
- **K2 + E1** octave · **K2 + E2** note length
- **K1 + K2** sync · **K1 + K3** scatter

## Requirements

- norns
- engine: `PolyPerc` (ships with norns)

## Install

```
;install https://github.com/om-i-god/lifestrings
```

Or copy `lifestrings.lua` to `dust/code/lifestrings/` on your norns.

## Devlog

See [DEVLOG.md](DEVLOG.md) for the design narrative — why it's rotated, how the
chevron of strings works, and how bass strikes re-anchor the key.

## Version

v1.3
