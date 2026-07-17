--[[
    OBS Auto-Restart Frozen Capture Sources (macOS ScreenCaptureKit fix)
    --------------------------------------------------------------------
    Version:  1.0.0
    Author:   assasadev
    License:  MIT
    Repo:     https://github.com/assasadev/obs-mac-screencapture-auto-restart

    macOS ScreenCaptureKit occasionally stops delivering frames (Discord /
    Meet / OBS all hit it). The picture freezes on the last frame while OBS
    keeps running and recording.

    Detection (pixel-hash):
        The SCK source is not an async-frame source and exposes no frame
        timestamps, so every check we render each watched source downscaled
        into a small off-screen texture, read the pixels back (LuaJIT FFI),
        and hash them. If the hash stops changing for `freeze_timeout`
        seconds while the source is active, it is considered frozen.
        NOTE: a completely idle screen (nothing moving, cursor still) looks
        identical to a freeze; keep the timeout comfortably high.

    Restart (settings nudge):
        Hiding/showing the source does NOT touch the SCK stream, and the
        source's own "Reactivate" button only works after a flagged failure.
        What reliably works: sck_video_capture_update() tears down and
        rebuilds the SCStream whenever a relevant setting changes. So we
        flip "show_cursor" and flip it back -- two forced stream rebuilds,
        no lasting settings change. (obs-studio/plugins/mac-capture/
        mac-sck-video-capture.m, sck_video_capture_update.)

    Sleep / wake:
        System sleep suspends OBS, so a large wall-clock gap between timer
        ticks is treated as a wake event and all watched sources are
        rebuilt immediately (SCK streams are typically dead after sleep).

    Auto-detection:
        All inputs whose type id is in `capture_ids` are watched. The list is
        re-scanned every check, so sources added later are picked up
        automatically and removed ones are dropped.

    Install: OBS -> Tools -> Scripts -> "+" -> this file.
    Watch Tools -> Scripts -> Script Log for activity.
]]

obs = obslua

local ffi_ok, ffi = pcall(require, "ffi")

-- ---- configurable (from properties) ----
local capture_ids_raw  = "screen_capture,display_capture,window_capture"
local check_interval   = 2       -- seconds between checks
local freeze_timeout   = 10      -- seconds of identical pixels before restart
local restart_gap_ms   = 400     -- gap between the two setting flips
local cooldown         = 30      -- min seconds between restarts per source
local periodic_restart = 0       -- >0: preventively restart every N seconds
local wake_restart     = true    -- restart all sources after system sleep/wake
local verbose          = true

-- ---- runtime ----
local capture_ids   = {}
local state         = {}   -- name -> {hash, changed_at, recovered_at, restarting}
local detect_ok     = false
local last_check_at = nil  -- wall-clock time of the previous timer tick

local function log(fmt, ...)
    if not verbose then return end
    print(string.format("[%s] [auto-restart] %s",
        os.date("%Y-%m-%d %H:%M:%S"), string.format(fmt, ...)))
end

local function split_ids(csv)
    local set = {}
    for id in string.gmatch(csv or "", "[^,%s]+") do set[id] = true end
    return set
end

-- Run fn once after delay_ms, then self-remove.
local function run_once(delay_ms, fn)
    local wrapper
    wrapper = function()
        obs.timer_remove(wrapper)
        fn()
    end
    obs.timer_add(wrapper, delay_ms)
end

-- ========================================================================
-- Restart: force sck_video_capture_update() to rebuild the SCStream by
-- flipping show_cursor, then restoring it. Each flip fails the plugin's
-- "nothing changed" early-return, so the stream is torn down and rebuilt.
-- ========================================================================

local function apply_cursor_flag(name, value)
    local src = obs.obs_get_source_by_name(name)
    if src == nil then return false end
    -- obs_source_get_settings returns the source's own settings object with
    -- the plugin defaults attached, so reads reflect effective values.
    local settings = obs.obs_source_get_settings(src)
    obs.obs_data_set_bool(settings, "show_cursor", value)
    obs.obs_source_update(src, settings)
    obs.obs_data_release(settings)
    obs.obs_source_release(src)
    return true
end

local function restart_source(name)
    local src = obs.obs_get_source_by_name(name)
    if src == nil then return end
    local settings = obs.obs_source_get_settings(src)
    local cursor = obs.obs_data_get_bool(settings, "show_cursor")
    obs.obs_data_release(settings)
    obs.obs_source_release(src)

    local st = state[name]
    if st then st.restarting = true end
    log("restarting '%s' (stream rebuild via settings nudge)", name)

    apply_cursor_flag(name, not cursor)          -- rebuild #1
    run_once(restart_gap_ms, function()
        apply_cursor_flag(name, cursor)          -- rebuild #2, original value
        local s = state[name]
        if s then
            s.restarting   = false
            s.hash         = nil
            s.changed_at   = os.time()
            s.recovered_at = os.time()
        end
        log("'%s' restarted", name)
    end)
end

-- ========================================================================
-- Detection: downscaled render -> staging surface -> pixel hash, via FFI.
-- ========================================================================

local C            -- ffi namespace with libobs symbols
local texrender    -- reused gs_texrender
local stagesurf    -- reused staging surface
local SNAP_W, SNAP_H = 48, 27
local GS_RGBA, GS_ZS_NONE = 3, 0
local GS_BLEND_ZERO, GS_BLEND_ONE = 0, 1

local function init_ffi()
    if not ffi_ok then return false end
    local ok, err = pcall(function()
        ffi.cdef[[
            typedef struct obs_source obs_source_t;
            typedef struct gs_texrender gs_texrender_t;
            typedef struct gs_stagesurf gs_stagesurf_t;
            typedef struct gs_texture gs_texture_t;

            obs_source_t *obs_get_source_by_name(const char *name);
            void obs_source_release(obs_source_t *source);
            uint32_t obs_source_get_base_width(obs_source_t *source);
            uint32_t obs_source_get_base_height(obs_source_t *source);
            void obs_source_video_render(obs_source_t *source);
            void obs_enter_graphics(void);
            void obs_leave_graphics(void);

            gs_texrender_t *gs_texrender_create(int format, int zsformat);
            void gs_texrender_destroy(gs_texrender_t *texrender);
            void gs_texrender_reset(gs_texrender_t *texrender);
            bool gs_texrender_begin(gs_texrender_t *texrender, uint32_t cx, uint32_t cy);
            void gs_texrender_end(gs_texrender_t *texrender);
            gs_texture_t *gs_texrender_get_texture(const gs_texrender_t *texrender);
            void gs_ortho(float left, float right, float top, float bottom,
                          float znear, float zfar);
            void gs_blend_state_push(void);
            void gs_blend_state_pop(void);
            void gs_blend_function(int src, int dest);

            gs_stagesurf_t *gs_stagesurface_create(uint32_t width, uint32_t height,
                                                   int color_format);
            void gs_stagesurface_destroy(gs_stagesurf_t *stagesurf);
            void gs_stage_texture(gs_stagesurf_t *dst, gs_texture_t *src);
            bool gs_stagesurface_map(gs_stagesurf_t *stagesurf, uint8_t **data,
                                     uint32_t *linesize);
            void gs_stagesurface_unmap(gs_stagesurf_t *stagesurf);
        ]]
    end)
    if not ok and not tostring(err):find("redefine") then
        log("ffi cdef failed: %s", tostring(err))
        return false
    end

    -- libobs is already loaded into the OBS process; try the global
    -- namespace first, then the framework path.
    local candidates = {
        function() return ffi.C.obs_enter_graphics and ffi.C end,
        function() return ffi.load(
            "/Applications/OBS.app/Contents/Frameworks/libobs.framework/Versions/A/libobs") end,
        function() return ffi.load("obs") end,
    }
    for _, get in ipairs(candidates) do
        local ok2, lib = pcall(get)
        if ok2 and lib ~= nil then
            C = lib
            return true
        end
    end
    log("could not resolve libobs symbols via ffi")
    return false
end

local function ensure_gfx_objects()
    if texrender ~= nil then return true end
    texrender = C.gs_texrender_create(GS_RGBA, GS_ZS_NONE)
    stagesurf = C.gs_stagesurface_create(SNAP_W, SNAP_H, GS_RGBA)
    return texrender ~= nil and stagesurf ~= nil
end

local function destroy_gfx_objects()
    if C == nil then return end
    C.obs_enter_graphics()
    if texrender ~= nil then C.gs_texrender_destroy(texrender); texrender = nil end
    if stagesurf ~= nil then C.gs_stagesurface_destroy(stagesurf); stagesurf = nil end
    C.obs_leave_graphics()
end

-- FNV-1a over the downscaled RGBA pixels. Returns nil if the source could
-- not be rendered this cycle.
local function snapshot_hash(name)
    local src = C.obs_get_source_by_name(name)
    if src == nil then return nil end

    local w = C.obs_source_get_base_width(src)
    local h = C.obs_source_get_base_height(src)
    if w == 0 or h == 0 then
        C.obs_source_release(src)
        return nil
    end

    local hash = nil
    C.obs_enter_graphics()
    if ensure_gfx_objects() then
        C.gs_texrender_reset(texrender)
        if C.gs_texrender_begin(texrender, SNAP_W, SNAP_H) then
            C.gs_ortho(0.0, w, 0.0, h, -100.0, 100.0)
            C.gs_blend_state_push()
            C.gs_blend_function(GS_BLEND_ONE, GS_BLEND_ZERO)
            C.obs_source_video_render(src)
            C.gs_blend_state_pop()
            C.gs_texrender_end(texrender)

            local tex = C.gs_texrender_get_texture(texrender)
            if tex ~= nil then
                C.gs_stage_texture(stagesurf, tex)
                local pdata = ffi.new("uint8_t*[1]")
                local plinesize = ffi.new("uint32_t[1]")
                if C.gs_stagesurface_map(stagesurf, pdata, plinesize) then
                    local data, linesize = pdata[0], plinesize[0]
                    -- Rolling checksum kept within double precision; we only
                    -- need "did any pixel change", not a cryptographic hash.
                    local sum = 0xcbf29ce4
                    for y = 0, SNAP_H - 1 do
                        local row = data + y * linesize
                        for x = 0, SNAP_W * 4 - 1 do
                            sum = (sum % 0x1000000) * 0x193 + row[x]
                        end
                    end
                    hash = sum
                    C.gs_stagesurface_unmap(stagesurf)
                end
            end
        end
    end
    C.obs_leave_graphics()
    C.obs_source_release(src)
    return hash
end

-- ========================================================================
-- Main check loop
-- ========================================================================

local function check_sources()
    local now     = os.time()
    local present = {}

    -- System sleep suspends the whole OBS process, so timers stop ticking.
    -- A large wall-clock gap between two ticks therefore means the machine
    -- just woke up -- and the SCK streams are typically dead (black screen).
    -- Proactively rebuild every watched source instead of waiting for the
    -- pixel detector's timeout + cooldown.
    local woke = false
    local wake_gap = check_interval * 5 + 10
    if last_check_at ~= nil and (now - last_check_at) >= wake_gap then
        if wake_restart then
            woke = true
            log("system wake detected (%ds without ticks); restarting capture sources",
                now - last_check_at)
        end
    end
    last_check_at = now

    local sources = obs.obs_enum_sources()
    if sources == nil then return end

    for _, source in ipairs(sources) do
        local id = obs.obs_source_get_id(source)
        if capture_ids[id] and obs.obs_source_active(source) then
            local name = obs.obs_source_get_name(source)
            present[name] = true
            local st = state[name]
            if st == nil then
                st = { hash = nil, changed_at = now, recovered_at = now,
                       restarting = false }
                state[name] = st
                log("watching '%s' (%s)", name, id)
            end

            if not st.restarting then
                if woke then
                    st.hash = nil
                    st.changed_at = now
                    restart_source(name)
                elseif periodic_restart > 0
                   and (now - st.recovered_at) >= periodic_restart then
                    log("preventive restart of '%s'", name)
                    restart_source(name)
                elseif detect_ok then
                    local h = snapshot_hash(name)
                    if h ~= nil then
                        if st.hash == nil or h ~= st.hash then
                            st.hash = h
                            st.changed_at = now
                        elseif (now - st.changed_at) >= freeze_timeout
                               and (now - st.recovered_at) >= cooldown then
                            log("freeze detected on '%s' (pixels unchanged %ds)",
                                name, now - st.changed_at)
                            restart_source(name)
                        end
                    end
                end
            end
        end
    end
    obs.source_list_release(sources)

    for name, st in pairs(state) do
        if not present[name] and not st.restarting then
            state[name] = nil
        end
    end
end

-- ========================================================================
-- OBS script hooks
-- ========================================================================

function script_description()
    return [[<b>Auto-Restart Frozen Capture Sources</b> v1.0.0<br/>
Detects the macOS ScreenCaptureKit freeze by hashing each capture source's
rendered pixels; when they stop changing, the source's capture stream is
force-rebuilt via a settings nudge (the same rebuild path as the source's
own Reactivate button, but without requiring a flagged failure).<br/><br/>
Also rebuilds capture sources after system sleep/wake. Auto-detects all
capture sources and picks up new ones automatically. A fully idle screen
looks like a freeze, so keep the timeout generous. If pixel detection is
unavailable, set a preventive restart interval.<br/><br/>
<a href="https://github.com/assasadev/obs-mac-screencapture-auto-restart">GitHub</a>]]
end

local function on_restart_all(props, prop)
    local sources = obs.obs_enum_sources()
    if sources == nil then return true end
    for _, source in ipairs(sources) do
        if capture_ids[obs.obs_source_get_id(source)]
           and obs.obs_source_active(source) then
            restart_source(obs.obs_source_get_name(source))
        end
    end
    obs.source_list_release(sources)
    return true
end

function script_properties()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_text(props, "capture_ids",
        "Watched source type ids (comma-separated)", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_int(props, "check_interval",
        "Check interval (seconds)", 1, 60, 1)
    obs.obs_properties_add_int(props, "freeze_timeout",
        "Freeze timeout (seconds)", 4, 300, 1)
    obs.obs_properties_add_int(props, "restart_gap_ms",
        "Settings flip gap (ms)", 100, 3000, 50)
    obs.obs_properties_add_int(props, "cooldown",
        "Min seconds between restarts (per source)", 5, 600, 1)
    obs.obs_properties_add_int(props, "periodic_restart",
        "Preventive restart every N sec (0 = off)", 0, 3600, 10)
    obs.obs_properties_add_bool(props, "wake_restart",
        "Restart capture sources after system wake")
    obs.obs_properties_add_bool(props, "verbose", "Verbose logging")
    obs.obs_properties_add_button(props, "restart_all",
        "Restart all capture sources now (test)", on_restart_all)
    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "capture_ids",
        "screen_capture,display_capture,window_capture")
    obs.obs_data_set_default_int(settings, "check_interval", 2)
    obs.obs_data_set_default_int(settings, "freeze_timeout", 10)
    obs.obs_data_set_default_int(settings, "restart_gap_ms", 400)
    obs.obs_data_set_default_int(settings, "cooldown", 30)
    obs.obs_data_set_default_int(settings, "periodic_restart", 0)
    obs.obs_data_set_default_bool(settings, "wake_restart", true)
    obs.obs_data_set_default_bool(settings, "verbose", true)
end

function script_update(settings)
    obs.timer_remove(check_sources)
    capture_ids_raw  = obs.obs_data_get_string(settings, "capture_ids")
    check_interval   = obs.obs_data_get_int(settings, "check_interval")
    freeze_timeout   = obs.obs_data_get_int(settings, "freeze_timeout")
    restart_gap_ms   = obs.obs_data_get_int(settings, "restart_gap_ms")
    cooldown         = obs.obs_data_get_int(settings, "cooldown")
    periodic_restart = obs.obs_data_get_int(settings, "periodic_restart")
    wake_restart     = obs.obs_data_get_bool(settings, "wake_restart")
    verbose          = obs.obs_data_get_bool(settings, "verbose")

    capture_ids = split_ids(capture_ids_raw)
    state = {}
    last_check_at = nil
    obs.timer_add(check_sources, check_interval * 1000)
end

function script_load(settings)
    detect_ok = init_ffi()
    if detect_ok then
        log("pixel-hash freeze detection active")
    else
        log("WARNING: pixel detection unavailable; set a preventive " ..
            "restart interval instead")
    end
end

function script_unload()
    obs.timer_remove(check_sources)
    destroy_gfx_objects()
end
