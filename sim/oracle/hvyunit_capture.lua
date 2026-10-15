-- hvyunit-mister: MAME oracle capture for Heavy Unit (Kaneko/Taito 1988).
--
--   HV_OUT=<dir> HV_FRAMES=<n> [HV_PLAY=1] [HV_PIX=1] [HV_STATE=1] [HV_TAPS=1] \
--     mame hvyunit -rompath <roms> -video none -sound none -nothrottle \
--          -skip_gameinfo -autoboot_script sim/oracle/hvyunit_capture.lua
--   (tools/capture.ps1 does all of that, including the sandboxed directories.)
--
-- Everything is keyed by the capture's own frame counter F: 0 is the first
-- frame_done after boot.
--
-- HOW THE FILES RELATE (measured; 100% pixel-exact, see docs/oracle.md):
-- frame_done F runs at vblank start F, right after MAME renders.  But
-- screen:pixels() returns the bitmap rendered at the PREVIOUS vblank, coloured
-- with the palette current when it is read.  So frames/f<F>.raw is built from
--     tilemap RAM + scroll   state/s<F-1>.bin
--     sprite RAM             state/s<F-2>.bin   (Pandora draws at eof, a frame
--                                                before the render shows it)
--     palette                state/s<F>.bin
--
--   frames/f<F>.raw   the visible 256x224 pixels MAME rendered, u32 host-endian
--                     xRGB exactly as screen:pixels() returns them
--   state/s<F>.bin    machine state read inside frame_done F (layout below)
--   taps.log          one line per tapped Z80 I/O access:
--                       <r|w> <cpu> F vpos port data pc
--                     vpos is MAME's 256-line frame position (vblank begins
--                     at line 240); cpu is main|sub|snd
--   index.txt         F, screen frame number, machine time, scroll registers
--
-- state/s<F>.bin, fixed layout, 0x1C10 bytes:
--   0x0000  4096  sprite RAM, as the MAIN Z80 sees it (0xC000-0xCFFF).  This is
--                 NOT the Pandora's internal order: MAME's spriteram_r swaps
--                 address lines, so a CPU offset o holds internal byte
--                 {o[11], o[7:0], o[10:8]}.  tools/hv_oracle.py undoes that.
--   0x1000  1024  BG video RAM   (sub Z80 0xC000-0xC3FF)
--   0x1400  1024  BG colour RAM  (sub Z80 0xC400-0xC7FF)
--   0x1800   512  palette high bytes (sub Z80 0xD000-0xD1FF)
--   0x1A00   512  palette low bytes  (sub Z80 0xD800-0xD9FF)
--   0x1C00    16  regs: [0]=scrollx [1]=scrolly [2]=port0 (sub OUT 00h: bank
--                 + scroll high bits) [3..15]=0.  These are driver members
--                 MAME does not expose, so they are tracked from write taps.
--
-- MAME re-runs an -autoboot_script after every machine reset, so only the
-- first load does anything.  Tap handles live in globals: a local goes out of
-- scope, is garbage collected, and the tap silently stops.

if _G.hv_capture_loaded then
	print("[hv] autoboot script re-run after a machine reset: ignored")
	return
end
_G.hv_capture_loaded = true

local out      = os.getenv("HV_OUT") or "hv_capture"
local maxf     = tonumber(os.getenv("HV_FRAMES") or "600")
local do_pix   = (os.getenv("HV_PIX")   or "1") == "1"
local do_state = (os.getenv("HV_STATE") or "1") == "1"
local do_taps  = (os.getenv("HV_TAPS")  or "1") == "1"
-- HV_PLAY=1: coin up, start, then hold right + autofire so the capture reaches
-- real gameplay (scrolling, many sprites) instead of only the attract mode.
local do_play    = (os.getenv("HV_PLAY") or "0") == "1"
local play_coin  = tonumber(os.getenv("HV_PLAY_COIN")  or "420")
local play_start = tonumber(os.getenv("HV_PLAY_START") or "480")

os.execute('mkdir "' .. out:gsub("/", "\\") .. '\\frames" 2>nul')
os.execute('mkdir "' .. out:gsub("/", "\\") .. '\\state" 2>nul')

local machine = manager.machine
local scr     = machine.screens[":screen"]
local maincpu = machine.devices[":maincpu"]
local subcpu  = machine.devices[":subcpu"]
local sndcpu  = machine.devices[":soundcpu"]
local mprog   = maincpu.spaces["program"]
local sprog   = subcpu.spaces["program"]
local mio     = maincpu.spaces["io"]
local sio     = subcpu.spaces["io"]
local zio     = sndcpu.spaces["io"]
local ioport  = machine.ioport

local F = 0
local idx  = io.open(out .. "/index.txt", "w")
local taps = do_taps and io.open(out .. "/taps.log", "w") or nil

-- MAME models this board as 256 lines; vblank starts after visible line 239.
local T_FRAME = scr.frame_period
local T_SCAN  = T_FRAME / 256
local function vpos_now()
	local tv = scr:time_until_vblank_start():as_double()
	local t = (240 * T_SCAN - tv) % T_FRAME
	return math.floor(t / T_SCAN + 1e-9)
end

-- driver registers not visible through any address space
local reg = { scrollx = 0, scrolly = 0, port0 = 0 }

local dumping = false
local function tapline(kind, cpu, port, data, pc)
	if dumping or not taps then return end
	taps:write(string.format("%s %s %d %d %02x %02x %04x\n", kind, cpu, F, vpos_now(), port, data & 0xff, pc))
end

-- globals, deliberately (see header)
hv_tap_sub_w = sio:install_write_tap(0x00, 0xff, "hv_sub_io_w", function(o, d, m)
	o = o & 0xff
	if     o == 0x00 then reg.port0   = d & 0xff
	elseif o == 0x06 then reg.scrolly = d & 0xff
	elseif o == 0x08 then reg.scrollx = d & 0xff end
	tapline("w", "sub", o, d, subcpu.state["PC"].value)
end)
-- HV_MCUPC=1: also log the 8751's program counter at every sub-CPU I/O read.
-- The sub CPU polls the Mermaid every few microseconds during a handshake, so
-- this is a free, fine-grained trace of the firmware's path through a command:
--   q F vpos port data mcu_pc
local mcu_pc_on = (os.getenv("HV_MCUPC") or "0") == "1"
local mermaid   = machine.devices[":mermaid"]
if do_taps then
	hv_tap_sub_r  = sio:install_read_tap (0x00, 0xff, "hv_sub_io_r",  function(o, d, m)
		tapline("r", "sub", o & 0xff, d, subcpu.state["PC"].value)
		if mcu_pc_on and not dumping then
			taps:write(string.format("q %d %d %02x %02x %04x\n", F, vpos_now(), o & 0xff, d & 0xff,
				mermaid.state["PC"].value))
		end
	end)
	hv_tap_main_w = mio:install_write_tap(0x00, 0xff, "hv_main_io_w", function(o, d, m) tapline("w", "main", o & 0xff, d, maincpu.state["PC"].value) end)
	hv_tap_main_r = mio:install_read_tap (0x00, 0xff, "hv_main_io_r", function(o, d, m) tapline("r", "main", o & 0xff, d, maincpu.state["PC"].value) end)
	hv_tap_snd_w  = zio:install_write_tap(0x00, 0xff, "hv_snd_io_w",  function(o, d, m) tapline("w", "snd",  o & 0xff, d, sndcpu.state["PC"].value) end)
	-- the sound CPU polls the YM2203 status port thousands of times a frame;
	-- those reads are noise unless HV_TAPS_SND=1
	local snd_reads = (os.getenv("HV_TAPS_SND") or "0") == "1"
	hv_tap_snd_r  = zio:install_read_tap (0x00, 0xff, "hv_snd_io_r",  function(o, d, m)
		o = o & 0xff
		if snd_reads or o ~= 0x02 then tapline("r", "snd", o, d, sndcpu.state["PC"].value) end
	end)
end

-- every write the main Z80 makes into the Pandora RAM window, with its raster
-- position:  s F vpos cpu_offset data pc     (HV_TAPS_SPR=0 to disable)
if do_taps and (os.getenv("HV_TAPS_SPR") or "1") == "1" then
	hv_tap_spr_w = mprog:install_write_tap(0xc000, 0xcfff, "hv_spr_w", function(o, d, m)
		if dumping then return end
		taps:write(string.format("s %d %d %03x %02x %04x\n", F, vpos_now(), (o - 0xc000) & 0xfff, d & 0xff,
			maincpu.state["PC"].value))
	end)
end

-- the sub Z80's writes to BG video/colour RAM and the palette, with raster position:
--   v F vpos sub_offset data pc      (sub_offset is the Z80 address, e.g. c010)
if do_taps and (os.getenv("HV_TAPS_VID") or "1") == "1" then
	local function vid(o, d, m)
		if dumping then return end
		taps:write(string.format("v %d %d %04x %02x %04x\n", F, vpos_now(), o & 0xffff, d & 0xff,
			subcpu.state["PC"].value))
	end
	hv_tap_vid_w1 = sprog:install_write_tap(0xc000, 0xc7ff, "hv_vram_w", vid)
	hv_tap_vid_w2 = sprog:install_write_tap(0xd000, 0xd1ff, "hv_pale_w", vid)
	hv_tap_vid_w3 = sprog:install_write_tap(0xd800, 0xd9ff, "hv_pall_w", vid)
end

hv_reset_notifier = emu.add_machine_reset_notifier(function()
	idx:write(string.format("RESET at F=%d time %.6f frame_number %d\n", F, machine.time:as_double(), scr:frame_number()))
	print(string.format("[hv] machine reset at F=%d", F))
end)

-- digital inputs for HV_PLAY
local fld = {}
if do_play then
	local want = {
		[":IN0"] = { ["Coin 1"] = "coin", ["1 Player Start"] = "start" },
		[":IN1"] = { ["P1 Button 1"] = "fire", ["P1 Right"] = "right" },
	}
	for tag, names in pairs(want) do
		local port = ioport.ports[tag]
		if port then
			for name, f in pairs(port.fields) do
				if names[name] then fld[names[name]] = f end
			end
		end
	end
	local have = {}
	for k in pairs(fld) do have[#have + 1] = k end
	table.sort(have)
	print("[hv] HV_PLAY: input fields found: " .. table.concat(have, ","))
end

local function play_inputs()
	if not do_play then return end
	local function hold(f, from, to)
		if not f then return end
		if F == from then f:set_value(1) elseif F == to then f:clear_value() end
	end
	hold(fld.coin,  play_coin,  play_coin + 8)
	hold(fld.start, play_start, play_start + 8)
	if F == play_start + 30 and fld.right then fld.right:set_value(1) end
	if fld.fire and F > play_start + 30 then
		if (F % 8) == 0 then fld.fire:set_value(1) elseif (F % 8) == 4 then fld.fire:clear_value() end
	end
end

local function read8(space, a, b) return space:read_range(a, b, 8, 1) end

-- HV_MCU=1: also dump the 8751's 128-byte internal RAM every frame, to mcu/m<F>.bin
-- (the same instant as state/s<F>.bin).  The RTL testbench writes the same file.
local do_mcu = (os.getenv("HV_MCU") or "0") == "1"
if do_mcu then os.execute('mkdir "' .. out:gsub("/", "\\") .. '\\mcu" 2>nul') end
local function dump_mcu(path)
	local sp = machine.devices[":mermaid"].spaces["idata"]       -- the 8051's internal RAM
	local f = io.open(path, "wb")
	f:write(sp:read_range(0, 0x7f, 8, 1))
	f:close()
end

local function dump_state(path)
	local f = io.open(path, "wb")
	f:write(read8(mprog, 0xc000, 0xcfff))
	f:write(read8(sprog, 0xc000, 0xc3ff))
	f:write(read8(sprog, 0xc400, 0xc7ff))
	f:write(read8(sprog, 0xd000, 0xd1ff))
	f:write(read8(sprog, 0xd800, 0xd9ff))
	f:write(string.char(reg.scrollx, reg.scrolly, reg.port0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
	f:close()
end

-- HV_STIM=1: from frame HV_STIM_FROM on, overwrite video state with seeded
-- pseudo-random data so features the game never uses (flip X, Y bit 8,
-- scrollY, every palette bank, 9-bit position wrap) are exercised too.  The
-- palette is deliberately left to the game: the pixel file is coloured with
-- the palette read at frame_done, so changing it here would break the pairing.
--
-- ORDER MATTERS.  The sprite table is written BEFORE the state dump, because
-- Pandora's eof() follows this callback in the same instant and draws what is
-- in RAM now, so the dump for this frame must contain it.  Tilemap RAM and
-- scroll are written AFTER the dump, because the frame just rendered used their
-- previous values and the dump has to describe those.
local do_stim   = (os.getenv("HV_STIM") or "0") == "1"
local stim_from = tonumber(os.getenv("HV_STIM_FROM") or "200")
local lcg = 1
local function rnd() lcg = (lcg * 1103515245 + 12345) & 0x7fffffff; return (lcg >> 8) & 0xff end

local function stim_sprites()
	lcg = F * 7919 + 17
	for o = 0, 0xfff do mprog:write_u8(0xc000 + o, rnd()) end
end

local function stim_bg()
	lcg = F * 104729 + 31
	for i = 0, 0x3ff do
		sprog:write_u8(0xc000 + i, rnd())                    -- tile code low byte
		sprog:write_u8(0xc400 + i, rnd())                    -- colour bank + code high nibble
	end
	-- keep p0[5:0] (ROM bank bits and the game's own use), randomise scroll high bits
	sio:write_u8(0x00, (reg.port0 & 0x3f) | (rnd() & 0xc0))
	sio:write_u8(0x06, rnd())
	sio:write_u8(0x08, rnd())
end

hv_frame_done = function()
	play_inputs()
	dumping = true                       -- read_range goes through the same taps
	if do_pix then
		local pix = scr:pixels()
		local f = io.open(string.format("%s/frames/f%05d.raw", out, F), "wb")
		f:write(pix); f:close()
	end
	if do_stim and F >= stim_from then stim_sprites() end
	if do_state then dump_state(string.format("%s/state/s%05d.bin", out, F)) end
	if do_mcu then dump_mcu(string.format("%s/mcu/m%05d.bin", out, F)) end
	if do_stim and F >= stim_from then stim_bg() end
	dumping = false
	-- integer microseconds: %.6f prints a locale comma on this machine
	idx:write(string.format("%d %d %d sx=%02x sy=%02x p0=%02x\n", F, scr:frame_number(),
		math.floor(machine.time:as_double() * 1e6), reg.scrollx, reg.scrolly, reg.port0))
	if taps then taps:write(string.format("F %d\n", F)) end
	F = F + 1
	if F >= maxf then
		idx:close(); if taps then taps:close() end
		print(string.format("[hv] captured %d frames into %s", F, out))
		machine:exit()
	end
end
emu.register_frame_done(hv_frame_done)
print(string.format("[hv] capture to %s: pix=%s state=%s taps=%s play=%s frames=%d T_FRAME=%.6f",
	out, tostring(do_pix), tostring(do_state), tostring(do_taps), tostring(do_play), maxf, T_FRAME))
