-- lifestrings
-- pendulum-wave sequencer (rotated)
--
-- hold the norns rotated 90° CCW
-- (encoders along the top from
-- the user's POV, reading
-- E1 E2 E3 left→right).
--
-- 17 pendulums hang from a single
-- beam at user-top: 3 bass at the
-- ends + middle, 14 leads filling
-- between. each fires once per
-- swing on its left→right pass
-- through the pivot. bass strikes
-- re-anchor the lead scale to a
-- new root.
--
-- E1 lead period   E2 amp   E3 spread
-- K1+E1 cutoff  E2 root  E3 mode
-- K2+E1 octave  E2 length
-- K1+K2 sync    K1+K3 scatter

engine.name = "PolyPerc"

local MusicUtil = require "musicutil"

-- ------------------------------------------------------------
-- constants
-- ------------------------------------------------------------

local NUM_BASS = 3
local NUM_LEAD = 14
local BASS_DEGREES = { 1, 3, 5 }

-- rotated layout (user-coords: u horizontal 0..63, v vertical 0..127)
local BEAM_V = 8
local BEAM_U_MIN = 8
local BEAM_U_MAX = 56
local VOICE_SPACING = (BEAM_U_MAX - BEAM_U_MIN) / 16   -- = 3 px between adjacent voices

-- bass at unified positions 1, 9, 17 (left edge, middle, right edge of beam)
local BASS_POS = { 1, 9, 17 }
-- leads fill positions 2..8 and 10..16
local LEAD_POS = { 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16 }

local function pos_to_u(p)
  return BEAM_U_MIN + (p - 1) * VOICE_SPACING
end

-- pendulum geometry: visual lengths span the full canvas in a chevron pattern
-- (longest at the middle of the beam, shortest at the edges). theta_max is
-- derived per-pendulum to keep horizontal swing ≈ SIDEWAYS_TARGET regardless
-- of length.
local SIDEWAYS_TARGET = 7

-- bass lengths are looked up by voice index 1..3 (positions 1, 9, 17 along beam)
local BASS_LENGTHS = { 105, 115, 105 }
-- lead length pattern across unified positions: base + amp * sin(π · p_norm)
local LEAD_BASE = 25
local LEAD_AMP = 65

-- animation tuning
local TRAIL_LEN = 8
local PLUCK_TTL = 0.18
local COMET_TTL = 0.30
local COMET_LEN = 7
local RIPPLE_TTL = 0.55
local RIPPLE_MAX_DIST = 28
local RIPPLE_SPREAD = 4
local TONIC_FADE = 1.5

-- decay pillar (vertical column of light below a strike, fading over note_length)
local PILLAR_LEAD_HEIGHT = 26
local PILLAR_LEAD_LVL = 4
local PILLAR_BASS_HEIGHT = 50
local PILLAR_BASS_LVL = 7

-- scale-degree glow bonus added to bob base brightness (consonance lookup)
-- idx = degree within octave (1..7). tonic/fifth/third get a glint.
local DEGREE_GLOW = { 3, 0, 1, 0, 2, 0, 0 }

-- help-overlay (appears on any input; fades after a few seconds idle)
local OVERLAY_HOLD = 3.0     -- s of full visibility after last input
local OVERLAY_FADE = 0.7     -- s of fade after hold elapses

-- ------------------------------------------------------------
-- state
-- ------------------------------------------------------------

local bass_pendulums = {}    -- { phase, pluck_t }
local lead_pendulums = {}
local bass_flash = {}
local lead_flash = {}
local bass_trails = {}
local lead_trails = {}

local comets = {}            -- { u, v, life, ttl }
local ripples = {}           -- { u, life, ttl }
local pillars = {}           -- { u, v_top, t_start, ttl, max_lvl, height }
local tonic_pulse = 0
local overlay_until = 0      -- wall-clock time when overlay should disappear

local screen_dirty = true
local k1_held = false
local k2_held = false
local midi_out
local current_lead_root = nil

-- ------------------------------------------------------------
-- helpers
-- ------------------------------------------------------------

local function lerp(a, b, t) return a + (b - a) * t end

local function build_scale_names()
  local names = {}
  for i = 1, #MusicUtil.SCALES do
    table.insert(names, MusicUtil.SCALES[i].name)
  end
  return names
end

local function note_name(num)
  return MusicUtil.note_num_to_name(num, true)
end

local function get_scale_notes(root_override)
  local root = root_override or params:get("root")
  local scale_idx = params:get("scale")
  return MusicUtil.generate_scale(root, scale_idx, 4)
end

-- voice geometry
local function bass_u(i) return pos_to_u(BASS_POS[i]) end
local function lead_u(i) return pos_to_u(LEAD_POS[i]) end

local function bass_length(i)
  return BASS_LENGTHS[i]
end

local function lead_length(i)
  local p = LEAD_POS[i]
  return LEAD_BASE + LEAD_AMP * math.sin(math.pi * (p - 1) / 16)
end

local function theta_max_for(length)
  return math.asin(math.min(1, SIDEWAYS_TARGET / length))
end

-- voice timing
local function lead_period(i)
  local base = params:get("base_period")
  local spread = params:get("spread")
  return base / (1 + (i - 1) * spread)
end

local function bass_period(i)
  local base = params:get("base_period") * params:get("bass_ratio")
  local spread = params:get("spread")
  return base / (1 + (i - 1) * spread)
end

-- bob position in user coords
local function bob_uv(pivot_u, pivot_v, length, theta_max, phase)
  local theta = theta_max * math.sin(phase)
  return pivot_u + length * math.sin(theta),
         pivot_v + length * math.cos(theta)
end

-- ------------------------------------------------------------
-- screen rotation: user (u, v) -> logical (x = 127 - v, y = u)
-- (90° CCW: encoders at user-top, reading E1 E2 E3 left→right)
-- ------------------------------------------------------------

local function lcd_move(u, v) screen.move(127 - v, u) end
local function lcd_line(u, v) screen.line(127 - v, u) end

local function lcd_pt(u, v, lvl)
  screen.level(lvl)
  screen.rect(127 - v, u, 1, 1)
  screen.fill()
end

local function lcd_box(u, v, s, lvl)
  local half = math.floor(s / 2)
  screen.level(lvl)
  screen.rect(127 - v - half, u - half, s, s)
  screen.fill()
end

-- ------------------------------------------------------------
-- trail
-- ------------------------------------------------------------

local function push_trail(trail, u, v)
  table.insert(trail, 1, { u = u, v = v })
  while #trail > TRAIL_LEN do
    table.remove(trail)
  end
end

-- ------------------------------------------------------------
-- help overlay (fade-in/out hint of what each encoder/key does)
-- ------------------------------------------------------------

local function bump_overlay()
  overlay_until = util.time() + OVERLAY_HOLD + OVERLAY_FADE
end

local function overlay_brightness()
  local r = overlay_until - util.time()
  if r <= 0 then return 0
  elseif r < OVERLAY_FADE then return r / OVERLAY_FADE
  else return 1.0 end
end

-- ------------------------------------------------------------
-- animation spawn / update
-- ------------------------------------------------------------

local function spawn_comet(u, v)
  table.insert(comets, { u = u, v = v, life = 1.0, ttl = COMET_TTL })
end

local function spawn_ripple(u)
  table.insert(ripples, { u = u, life = 1.0, ttl = RIPPLE_TTL })
end

local function spawn_pillar(u, v_top, ttl, tier)
  table.insert(pillars, {
    u = u, v_top = v_top, t_start = util.time(), ttl = ttl,
    max_lvl = (tier == "bass") and PILLAR_BASS_LVL or PILLAR_LEAD_LVL,
    height  = (tier == "bass") and PILLAR_BASS_HEIGHT or PILLAR_LEAD_HEIGHT,
  })
end

local function update_anims(dt)
  for j = #comets, 1, -1 do
    comets[j].life = comets[j].life - dt / comets[j].ttl
    if comets[j].life <= 0 then table.remove(comets, j) end
  end
  for j = #ripples, 1, -1 do
    ripples[j].life = ripples[j].life - dt / ripples[j].ttl
    if ripples[j].life <= 0 then table.remove(ripples, j) end
  end
  local now = util.time()
  for j = #pillars, 1, -1 do
    if now - pillars[j].t_start >= pillars[j].ttl then
      table.remove(pillars, j)
    end
  end
  if tonic_pulse > 0 then
    tonic_pulse = math.max(0, tonic_pulse - dt / TONIC_FADE)
  end
end

-- scale-degree glow bonus: how much extra base brightness this voice's bob gets
local function lead_glow(i)
  return DEGREE_GLOW[((i - 1) % 7) + 1] or 0
end

local function bass_glow(i)
  return DEGREE_GLOW[BASS_DEGREES[i]] or 0
end

-- ------------------------------------------------------------
-- audio
-- ------------------------------------------------------------

local function lead_note(i)
  local notes = get_scale_notes(current_lead_root)
  return notes[i] or notes[1]
end

local function bass_note(i)
  local notes = get_scale_notes()
  local degree = BASS_DEGREES[i] or 1
  return (notes[degree] or notes[1]) - 12
end

local function trigger(tier, i)
  local base_note = (tier == "bass") and bass_note(i) or lead_note(i)
  local note = util.clamp(base_note + params:get("octave") * 12, 0, 127)
  local len = params:get("note_length")
  local vel = params:get("velocity")

  if params:string("engine_on") == "on" then
    engine.hz(MusicUtil.note_num_to_freq(note))
  end

  if params:string("midi_on") == "on" and midi_out then
    local ch = params:get("midi_channel")
    midi_out:note_on(note, vel, ch)
    clock.run(function()
      clock.sleep(len)
      midi_out:note_off(note, 0, ch)
    end)
  end

  if tier == "bass" then
    bass_flash[i] = 1.0
    bass_pendulums[i].pluck_t = util.time()
    local strike_v = BEAM_V + bass_length(i)
    spawn_comet(bass_u(i), strike_v)
    spawn_ripple(bass_u(i))
    spawn_pillar(bass_u(i), strike_v + 2, len, "bass")
    tonic_pulse = 1.0
    current_lead_root = base_note + 12
  else
    lead_flash[i] = 1.0
    lead_pendulums[i].pluck_t = util.time()
    local strike_v = BEAM_V + lead_length(i)
    spawn_comet(lead_u(i), strike_v)
    spawn_pillar(lead_u(i), strike_v + 2, len, "lead")
  end
end

local function step_tier(arr, flash, period_fn, tier_name, dt, fade_rate)
  for i = 1, #arr do
    local p = arr[i]
    local omega = 2 * math.pi / period_fn(i)
    local prev = p.phase
    p.phase = p.phase + omega * dt

    if math.sin(prev) < 0 and math.sin(p.phase) >= 0 then
      trigger(tier_name, i)
    end

    if flash[i] > 0 then
      flash[i] = math.max(0, flash[i] - dt * fade_rate)
    end
  end
end

local function physics_loop()
  local last = util.time()
  while true do
    clock.sleep(1 / 60)
    local now = util.time()
    local dt = now - last
    last = now

    step_tier(bass_pendulums, bass_flash, bass_period, "bass", dt, 1.2)
    step_tier(lead_pendulums, lead_flash, lead_period, "lead", dt, 3.5)

    update_anims(dt)
    screen_dirty = true
  end
end

local function screen_loop()
  while true do
    clock.sleep(1 / 30)
    if screen_dirty then
      redraw()
      screen_dirty = false
    end
  end
end

-- ------------------------------------------------------------
-- drawing
-- ------------------------------------------------------------

local function draw_pendulum(pivot_u, length, theta_max, phase, trail, flash, bob_size, pluck_t, glow)
  local pivot_v = BEAM_V
  local bu, bv = bob_uv(pivot_u, pivot_v, length, theta_max, phase)
  local bui = math.floor(bu + 0.5)
  local bvi = math.floor(bv + 0.5)

  -- string with brightness gradient: top half at lvl 1, bottom half at lvl 2.
  -- gives the string subtle "weight" near the bob without geometric sag.
  local mid_u = lerp(pivot_u, bu, 0.45)
  local mid_v = lerp(pivot_v, bv, 0.45)
  screen.level(1)
  lcd_move(pivot_u, pivot_v); lcd_line(mid_u, mid_v); screen.stroke()
  screen.level(2)
  lcd_move(mid_u, mid_v);     lcd_line(bu, bv);       screen.stroke()

  -- pluck wave: bright pulse traveling pivot→bob just after a strike
  if pluck_t then
    local age = util.time() - pluck_t
    if age < PLUCK_TTL then
      local progress = age / PLUCK_TTL
      local pu = lerp(pivot_u, bu, progress)
      local pv = lerp(pivot_v, bv, progress)
      lcd_pt(pu, pv, math.floor(15 * (1 - progress)))
    end
  end

  -- trail: smooth falloff old→new
  push_trail(trail, bui, bvi)
  for j = #trail, 2, -1 do
    local t = trail[j]
    local lvl = math.floor(8 * (TRAIL_LEN - j + 1) / TRAIL_LEN)
    if lvl > 0 then lcd_pt(t.u, t.v, lvl) end
  end

  -- anchor dot at strike point (faint always; pulses on strike)
  local anchor_lvl = 1 + math.floor(7 * flash)
  lcd_pt(pivot_u, pivot_v + length, anchor_lvl)

  -- bloom: dim cardinal-direction halo around bob when flash is fresh.
  -- gives strikes a sense of radiance the bare pixel can't convey.
  if flash > 0.2 then
    local bloom_lvl = math.floor(7 * flash)
    if bloom_lvl > 0 then
      lcd_pt(bui - 1, bvi, bloom_lvl); lcd_pt(bui + 1, bvi, bloom_lvl)
      lcd_pt(bui, bvi - 1, bloom_lvl); lcd_pt(bui, bvi + 1, bloom_lvl)
    end
    if bob_size >= 3 then
      local outer = math.floor(4 * flash)
      if outer > 0 then
        lcd_pt(bui - 2, bvi, outer); lcd_pt(bui + 2, bvi, outer)
        lcd_pt(bui, bvi - 2, outer); lcd_pt(bui, bvi + 2, outer)
      end
    end
  end

  -- bob — punches up by 1px while flash is fresh; glow bonus adds idle shine
  -- for consonant scale degrees (tonic/fifth brighter than passing tones).
  local bob_lvl = math.min(15, 5 + (glow or 0) + math.floor(10 * flash))
  local effective_size = bob_size + ((flash > 0.5) and 1 or 0)
  if effective_size <= 1 then
    lcd_pt(bui, bvi, bob_lvl)
  else
    lcd_box(bui, bvi, effective_size, bob_lvl)
  end
end

local function draw_pillar(p)
  local age = util.time() - p.t_start
  local life = 1 - age / p.ttl
  if life <= 0 then return end
  for k = 0, p.height do
    local v = p.v_top + k
    if v > 126 then break end
    local fade = 1 - k / p.height
    local lvl = math.floor(p.max_lvl * life * fade)
    if lvl > 0 then
      lcd_pt(p.u, v, lvl)
    end
  end
end

local function draw_comet(c)
  -- streak in -u direction (motion-blur trail behind a left→right strike)
  for k = 0, COMET_LEN - 1 do
    local fade = (1 - k / COMET_LEN)
    local lvl = math.floor(15 * c.life * c.life * fade)
    if lvl > 0 then
      lcd_pt(c.u - k, c.v, lvl)
    end
  end
end

local function draw_beam_with_ripples()
  -- per-pixel: base brightness + max ripple contribution
  for u = BEAM_U_MIN - 2, BEAM_U_MAX + 2 do
    local lvl = 2
    for _, r in ipairs(ripples) do
      local progress = 1 - r.life
      local target_dist = progress * RIPPLE_MAX_DIST
      local d = math.abs(math.abs(u - r.u) - target_dist)
      if d < RIPPLE_SPREAD then
        local rl = math.floor(13 * r.life * r.life * (1 - d / RIPPLE_SPREAD))
        if rl > lvl then lvl = rl end
      end
    end
    lcd_pt(u, BEAM_V, lvl)
  end
end

local function draw_tonic()
  if tonic_pulse > 0 then
    local lvl = 1 + math.floor(10 * tonic_pulse)
    lcd_pt(lead_u(1), BEAM_V - 4, lvl)
    if lvl > 4 then
      lcd_pt(lead_u(1), BEAM_V - 5, math.floor(lvl / 2))
    end
  end
end

local function draw_overlay()
  local b = overlay_brightness()
  if b <= 0 then return end

  -- choose label set for current modifier state. labels are drawn natural
  -- (sideways from the user's rotated POV) at logical (x=2, y=2..) — i.e.,
  -- a thin strip at user-bottom. brief tilt-of-the-head reads them.
  local labels
  if k1_held then
    labels = "K1: cut  rt  mod"
  elseif k2_held then
    labels = "K2: oct  len"
  else
    labels = "1per  2amp  3spr"
  end

  local lvl = math.floor(b * 13)
  if lvl < 1 then return end
  screen.level(lvl)
  screen.move(2, 6)
  screen.text(labels)

  -- a second line of compound hints (sync / scatter)
  if k1_held then
    screen.level(math.floor(b * 9))
    screen.move(2, 12)
    screen.text("K1+K2 sync  K1+K3 scatter")
  end
end

function redraw()
  screen.clear()
  screen.aa(0)

  draw_beam_with_ripples()

  -- decay pillars sit BELOW strike points; draw before pendulums so the
  -- pendulum geometry overlays them at their tops (clean attachment).
  for _, pil in ipairs(pillars) do draw_pillar(pil) end

  -- iterate unified positions so neighbors interleave naturally
  for p = 1, 17 do
    if p == 1 or p == 9 or p == 17 then
      local bi = (p == 1) and 1 or ((p == 9) and 2 or 3)
      local len = bass_length(bi)
      draw_pendulum(bass_u(bi), len, theta_max_for(len),
        bass_pendulums[bi].phase, bass_trails[bi], bass_flash[bi], 3,
        bass_pendulums[bi].pluck_t, bass_glow(bi))
    else
      local li = (p <= 8) and (p - 1) or (p - 2)
      local len = lead_length(li)
      draw_pendulum(lead_u(li), len, theta_max_for(len),
        lead_pendulums[li].phase, lead_trails[li], lead_flash[li], 1,
        lead_pendulums[li].pluck_t, lead_glow(li))
    end
  end

  for _, c in ipairs(comets) do draw_comet(c) end
  draw_tonic()
  draw_overlay()

  screen.update()
end

-- ------------------------------------------------------------
-- input
-- ------------------------------------------------------------

local function sync_all()
  for i = 1, NUM_BASS do bass_pendulums[i].phase = 0 end
  for i = 1, NUM_LEAD do lead_pendulums[i].phase = 0 end
end

local function scatter_all()
  for i = 1, NUM_BASS do bass_pendulums[i].phase = math.random() * 2 * math.pi end
  for i = 1, NUM_LEAD do lead_pendulums[i].phase = math.random() * 2 * math.pi end
end

function init()
  params:add_separator("hypnotizer")

  params:add_number("root", "root", 24, 96, 48,
    function(p) return note_name(p:get()) end)
  params:set_action("root", function()
    current_lead_root = nil
    screen_dirty = true
  end)

  params:add_option("scale", "scale", build_scale_names(), 1)
  params:set_action("scale", function()
    current_lead_root = nil
    screen_dirty = true
  end)

  params:add_number("octave", "octave", -3, 3, 0)
  params:set_action("octave", function() screen_dirty = true end)

  params:add_control("base_period", "lead period",
    controlspec.new(0.25, 30, "exp", 0, 10, "s"))

  params:add_control("bass_ratio", "bass ratio",
    controlspec.new(1, 12, "lin", 0.1, 7, "x"))

  params:add_control("spread", "spread",
    controlspec.new(0, 0.3, "lin", 0.001, 0.06, ""))

  params:add_separator("output")
  params:add_option("engine_on", "engine", { "off", "on" }, 2)
  params:add_option("midi_on", "midi out", { "off", "on" }, 1)
  params:add_number("midi_device", "midi device", 1, 4, 1)
  params:set_action("midi_device", function(d) midi_out = midi.connect(d) end)
  params:add_number("midi_channel", "midi channel", 1, 16, 1)
  params:add_control("note_length", "note length",
    controlspec.new(0.05, 8, "lin", 0.01, 2.0, "s"))
  params:add_control("velocity", "velocity",
    controlspec.new(1, 127, "lin", 1, 64, ""))

  params:add_separator("engine")
  params:add_control("amp", "amp", controlspec.new(0, 1, "lin", 0.01, 0.4, ""))
  params:add_control("cutoff", "cutoff",
    controlspec.new(50, 12000, "exp", 0, 800, "Hz"))
  params:add_control("release", "release",
    controlspec.new(0.1, 8, "lin", 0.01, 3.0, "s"))
  params:add_control("pw", "pw", controlspec.new(0, 1, "lin", 0.01, 0.3, ""))

  params:set_action("amp", function(x) engine.amp(x) end)
  params:set_action("cutoff", function(x) engine.cutoff(x) end)
  params:set_action("release", function(x) engine.release(x) end)
  params:set_action("pw", function(x) engine.pw(x) end)

  midi_out = midi.connect(1)

  -- bass: stagger phases just before zero-crossing so they fire promptly on load
  for i = 1, NUM_BASS do
    bass_pendulums[i] = {
      phase = 2 * math.pi - 0.1 - 0.3 * (i - 1),
      pluck_t = nil,
    }
    bass_flash[i] = 0
    bass_trails[i] = {}
  end
  -- leads: scatter biased into the second half of the cycle so triggers come fast
  for i = 1, NUM_LEAD do
    lead_pendulums[i] = {
      phase = math.pi + math.random() * math.pi,
      pluck_t = nil,
    }
    lead_flash[i] = 0
    lead_trails[i] = {}
  end

  params:bang()

  audio.rev_on()
  audio.level_eng_rev(0.4)
  audio.level_rev_dac(0.4)

  clock.run(physics_loop)
  clock.run(screen_loop)
end

function enc(n, d)
  bump_overlay()
  if n == 1 then
    if k1_held then
      params:delta("cutoff", d)
    elseif k2_held then
      params:delta("octave", d)
    else
      params:delta("base_period", d)
    end
  elseif n == 2 then
    if k1_held then
      params:delta("root", d)
    elseif k2_held then
      params:delta("note_length", d)
    else
      params:delta("amp", d)
    end
  elseif n == 3 then
    if k1_held then
      params:delta("scale", d)
    else
      params:delta("spread", d)
    end
  end
  screen_dirty = true
end

function key(n, z)
  bump_overlay()
  if n == 1 then
    k1_held = (z == 1)
  elseif n == 2 then
    if z == 1 then
      if k1_held then
        sync_all()
      else
        k2_held = true
      end
    else
      k2_held = false
    end
  elseif n == 3 then
    if z == 1 and k1_held then
      scatter_all()
    end
  end
  screen_dirty = true
end
