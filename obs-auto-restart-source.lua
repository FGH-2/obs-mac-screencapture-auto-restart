--[[
    OBS Auto-Restart Frozen Capture Sources (macOS ScreenCaptureKit fix)
    --------------------------------------------------------------------
    Version:  1.1.2
    Author:   FGH-2
    License:  MIT
    Repo:     https://github.com/FGH-2/obs-mac-screencapture-auto-restart

    macOS ScreenCaptureKit occasionally stops delivering frames (Discord /
    Meet / OBS all hit it). The picture freezes on the last frame while OBS
    keeps running and recording. OBS logs this as a mac-screencapture
    "Stream stopped with error" (often code 3821, "stopped by the system").

    Detection:
        Pixel-hash: each watched source is rendered downscaled into a small
        off-screen texture and checksummed. Unchanged pixels only count as a
        freeze after the source has shown motion at least once -- a static
        desktop is not treated as frozen (that used to hammer-rebuild SCK
        every cooldown and provoke more stream-stops).
        Dead stream: a previously working source that now reports 0x0 or
        fails to render is restarted immediately.
        OBS log: new "Stream stopped with error" lines trigger an immediate
        restart of sources that look stuck. Only a complete log line is
        consumed, so a burst cannot skip a half-written line. A stop within
        2s of a teardown we caused is treated as our own echo; a later stop
        (the rebuilt stream dying again) is kept and retried.

    Restart:
        If OBS has flagged the capture as failed, click its Reactivate
        button (one clean rebuild). Otherwise flip show_cursor and flip it
        back so sck_video_capture_update() tears down and rebuilds the
        SCStream. Teardowns are serialized. Success is logged only after
        frames resume; otherwise we retry with backoff.

    Sleep / wake:
        A large wall-clock gap between timer ticks is treated as a wake
        and watched sources are rebuilt.

    Auto-detection:
        All inputs whose type id is in `capture_ids` and that are currently
        active are watched. Hidden / inactive sources are skipped.

    Install: OBS -> Tools -> Scripts -> "+" -> this file.
    Watch Tools -> Scripts -> Script Log for activity.
]]

obs = obslua

local ffi_ok, ffi = pcall(require, "ffi")

-- ---- configurable (from properties) ----
local capture_ids_raw      = "screen_capture,display_capture,window_capture"
local check_interval       = 2       -- seconds between checks
local freeze_timeout       = 10      -- seconds of identical pixels before restart
local restart_gap_ms       = 400     -- gap between the two setting flips
local cooldown             = 30      -- min seconds between freeze-restarts
local periodic_restart     = 0       -- >0: preventively restart every N seconds
local wake_restart         = true    -- restart all sources after system sleep/wake
local stream_stop_restart  = true    -- restart on OBS SCK stream-stop log lines
local require_motion       = true    -- freeze detector needs prior pixel change
local verbose              = true

-- ---- runtime ----
local capture_ids   = {}
local state         = {}   -- name -> per-source table
local detect_ok     = false
local last_check_at = nil
local epoch         = 0    -- bumped on reload so delayed timers go stale

local pending       = {}   -- serialized rebuild queue (source names)
local tearing       = false
local own_budget    = 0    -- stream-stop lines we expect from our teardown
local own_until     = 0    -- those echoes only count until this time
local last_real_stop_at = 0

local RECOVER_WAIT = 8     -- seconds to wait for frames after a rebuild
local SETTLE       = 6     -- don't call it recovered before this
local OWN_ECHO     = 2     -- seconds: a stop this soon is our own teardown
local DEATH_RETRY  = 3     -- min seconds between death-signal retries

-- OBS log tail (do not print the match strings below -- they would re-fire)
local OBS_STOP_MARK = "Stream stopped with error"
local obs_log_path  = nil
local obs_log_pos   = 0

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

local function run_once(delay_ms, fn)
    local token = epoch
    local wrapper
    wrapper = function()
        obs.timer_remove(wrapper)
        if token == epoch then fn() end
    end
    obs.timer_add(wrapper, delay_ms)
end

local function new_state(now)
    return {
        hash         = nil,
        changed_at   = now,
        recovered_at = now,
        restarting   = false,
        nudge_done   = false,
        saw_motion   = false,
        had_frame    = false,
        logged_idle  = false,
        logged_gfx   = false,
        moved_tick   = false,
        pre_hash     = nil,
        reason       = nil,
        restart_at   = 0,
        attempts     = 0,
        next_ok      = 0,
        needs_retry  = false,
        again        = false,
        gen          = 0,
    }
end

-- ========================================================================
-- OBS log tail -- pick up SCK stream-stop lines from the current session
-- ========================================================================

local function obs_logs_dir()
    local home = os.getenv("HOME")
    if home == nil or home == "" then return nil end
    return home .. "/Library/Application Support/obs-studio/logs"
end

local function newest_log_file()
    local dir = obs_logs_dir()
    if dir == nil then return nil end
    local p = io.popen('ls -t "' .. dir .. '"/*.txt 2>/dev/null')
    if p == nil then return nil end
    local first = p:read("*l")
    p:close()
    return first
end

local function attach_obs_log(from_end)
    local path = newest_log_file()
    if path == nil then
        obs_log_path, obs_log_pos = nil, 0
        return false
    end
    if path ~= obs_log_path then
        obs_log_path = path
        obs_log_pos  = 0
        if from_end then
            local f = io.open(path, "rb")
            if f then
                obs_log_pos = f:seek("end") or 0
                f:close()
            end
        end
    end
    return true
end

-- Read newly written log bytes, but only through the last complete line.
-- A check that lands mid-write used to advance past a half-written
-- stream-stop, and that line was never seen again.
local function consume_stream_stops()
    if not attach_obs_log(false) then return 0 end
    local f = io.open(obs_log_path, "rb")
    if f == nil then
        obs_log_path = nil
        return 0
    end
    local size = f:seek("end") or 0
    if size < obs_log_pos then obs_log_pos = 0 end  -- truncated
    f:seek("set", obs_log_pos)
    local chunk = f:read("*a") or ""
    f:close()

    local last_nl = 0
    local p = 1
    while true do
        local j = chunk:find("\n", p, true)
        if not j then break end
        last_nl = j
        p = j + 1
    end
    if last_nl == 0 then return 0 end

    local complete = chunk:sub(1, last_nl)
    obs_log_pos = obs_log_pos + last_nl

    local n, i = 0, 1
    while true do
        local j = complete:find(OBS_STOP_MARK, i, true)
        if not j then break end
        n = n + 1
        i = j + 1
    end
    return n
end

-- Stops logged while we tear a stream down are ours. Anything later is a
-- new death and must not be discarded just because a rebuild is in flight.
local function take_real_stops(n)
    if n <= 0 then return 0 end
    local now = os.time()
    if now <= own_until and own_budget > 0 then
        local eat = math.min(n, own_budget)
        own_budget = own_budget - eat
        n = n - eat
    end
    if now > own_until then own_budget = 0 end
    return n
end

local function note_own_teardown()
    own_budget = own_budget + 1
    local until_t = os.time() + OWN_ECHO
    if until_t > own_until then own_until = until_t end
end

-- ========================================================================
-- Restart: official Reactivate if OBS flagged the capture, else cursor nudge
-- ========================================================================

local function apply_cursor_flag(name, value)
    local src = obs.obs_get_source_by_name(name)
    if src == nil then return false end
    local settings = obs.obs_source_get_settings(src)
    obs.obs_data_set_bool(settings, "show_cursor", value)
    obs.obs_source_update(src, settings)
    obs.obs_data_release(settings)
    obs.obs_source_release(src)
    return true
end

-- Uses the source's Reactivate button when capture_failed is set (the
-- path OBS enables after a stream-stop). Avoids a double cursor-flip
-- teardown, which itself often produces another stream-stop.
local function try_reactivate(name)
    local src = obs.obs_get_source_by_name(name)
    if src == nil then return false end
    local ok, clicked = pcall(function()
        local props = obs.obs_source_properties(src)
        if props == nil then return false end
        local prop = obs.obs_properties_get(props, "reactivate_capture")
        local did = false
        if prop ~= nil and obs.obs_property_enabled(prop) then
            did = obs.obs_property_button_clicked(prop, src) and true or false
        end
        obs.obs_properties_destroy(props)
        return did
    end)
    obs.obs_source_release(src)
    return ok and clicked
end

local function mark_recovered(st, name, how)
    st.restarting   = false
    st.nudge_done   = false
    st.attempts     = 0
    st.recovered_at = os.time()
    st.next_ok      = os.time() + DEATH_RETRY
    st.reason       = nil
    log("'%s' recovered (%s)", name, how)
end

local function fail_recovery(st, name)
    st.attempts    = (st.attempts or 0) + 1
    local exp      = 2 ^ math.min(st.attempts - 1, 4)
    local wait     = math.min(cooldown, DEATH_RETRY * exp)
    st.next_ok     = os.time() + wait
    st.restarting  = false
    st.nudge_done  = false
    st.needs_retry = true
    log("'%s' rebuild did not restore frames (attempt %d); retry in %ds",
        name, st.attempts, wait)
end

local function reason_accepts_same_hash(reason)
    return reason == "stream-stop" or reason == "no-frame" or reason == "wake"
end

local request_restart, pump_queue, begin_rebuild

function request_restart(name, reason, force)
    local st = state[name]
    if st == nil then return end
    -- A new stream-stop during a teardown is remembered and run the
    -- moment that teardown finishes, instead of waiting out a backoff.
    if st.restarting then
        if force then st.again = true end
        return
    end
    if not force and st.next_ok > os.time() then return end

    st.restarting  = true
    st.nudge_done  = false
    st.needs_retry = false
    st.again       = false
    st.reason      = reason
    st.pre_hash    = st.hash
    st.restart_at  = os.time()
    st.gen         = (st.gen or 0) + 1
    pending[#pending + 1] = name
    pump_queue()
end

function pump_queue()
    if tearing then return end
    if #pending == 0 then return end
    local name = table.remove(pending, 1)
    if state[name] == nil then
        pump_queue()
        return
    end
    begin_rebuild(name)
end

local function finish_nudge(name, gen)
    local s = state[name]
    if s == nil or s.gen ~= gen then return end
    if s.again then
        s.restarting = false
        s.nudge_done = false
        s.again = false
        request_restart(name, "stream-stop", true)
        return
    end
    s.nudge_done = true
    s.hash = nil
end

function begin_rebuild(name)
    local st = state[name]
    if st == nil then
        pump_queue()
        return
    end

    tearing = true
    note_own_teardown()
    local gen = st.gen

    if try_reactivate(name) then
        log("rebuilding '%s' (%s, via OBS Reactivate)", name, st.reason or "?")
        finish_nudge(name, gen)
        tearing = false
        pump_queue()
        return
    end

    local src = obs.obs_get_source_by_name(name)
    if src == nil then
        log("cannot rebuild '%s': source missing", name)
        st.restarting = false
        tearing = false
        pump_queue()
        return
    end
    local settings = obs.obs_source_get_settings(src)
    local cursor = obs.obs_data_get_bool(settings, "show_cursor")
    obs.obs_data_release(settings)
    obs.obs_source_release(src)

    log("rebuilding '%s' (%s, via settings nudge)", name, st.reason or "?")
    if not apply_cursor_flag(name, not cursor) then
        log("cannot rebuild '%s': settings update failed", name)
        st.restarting = false
        tearing = false
        pump_queue()
        return
    end
    note_own_teardown()
    run_once(restart_gap_ms, function()
        note_own_teardown()
        apply_cursor_flag(name, cursor)
        finish_nudge(name, gen)
        tearing = false
        pump_queue()
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

-- Returns hash, err. err is nil on success, else "missing", "zero_size", "gfx".
local function snapshot_hash(name)
    local src = C.obs_get_source_by_name(name)
    if src == nil then return nil, "missing" end

    local w = C.obs_source_get_base_width(src)
    local h = C.obs_source_get_base_height(src)
    if w == 0 or h == 0 then
        C.obs_source_release(src)
        return nil, "zero_size"
    end

    local hash, err = nil, "gfx"
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
                    local sum = 0xcbf29ce4
                    for y = 0, SNAP_H - 1 do
                        local row = data + y * linesize
                        for x = 0, SNAP_W * 4 - 1 do
                            sum = (sum % 0x1000000) * 0x193 + row[x]
                        end
                    end
                    hash, err = sum, nil
                    C.gs_stagesurface_unmap(stagesurf)
                end
            end
        end
    end
    C.obs_leave_graphics()
    C.obs_source_release(src)
    return hash, err
end

local function handle_recovery(st, name, h, err, now)
    if not st.nudge_done then return end

    -- A newer stream-stop is handled by the check loop, which restarts
    -- immediately. Don't declare success and don't sit on a backoff.
    if st.again or last_real_stop_at > st.restart_at then
        return
    end

    if h ~= nil then
        if h ~= st.hash then
            st.hash = h
            st.changed_at = now
            st.saw_motion = true
        end
        st.had_frame = true
        -- The follow-up -3821 usually lands a few seconds after the
        -- rebuild. Wait it out before calling the source recovered.
        if (now - st.restart_at) < SETTLE then return end

        local changed = (st.pre_hash == nil or h ~= st.pre_hash)
        if changed then
            mark_recovered(st, name, "frames changed")
        elseif reason_accepts_same_hash(st.reason) then
            mark_recovered(st, name, "frames resumed")
        else
            st.saw_motion = false
            st.logged_idle = false
            mark_recovered(st, name, "source up, pixels unchanged; now idle")
        end
        return
    end

    if (now - st.restart_at) >= RECOVER_WAIT then
        if err == "gfx" then
            -- graphics glitch, not a dead SCK stream -- wait another cycle
            st.restart_at = now
            return
        end
        fail_recovery(st, name)
    end
end

-- ========================================================================
-- Main check loop
-- ========================================================================

local function check_sources()
    local now     = os.time()
    local present = {}

    local stops = take_real_stops(consume_stream_stops())
    local stream_alert = stream_stop_restart and stops > 0
    if stream_alert then
        last_real_stop_at = now
        log("OBS reported %d capture stream-stop(s); checking watched sources",
            stops)
    end

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
                st = new_state(now)
                state[name] = st
                log("watching '%s' (%s)", name, id)
            end

            local h, err = nil, "nodetect"
            if detect_ok then
                h, err = snapshot_hash(name)
            end

            local moved = (h ~= nil and st.hash ~= nil and h ~= st.hash)
            st.moved_tick = moved

            if st.restarting then
                handle_recovery(st, name, h, err, now)
            else
                if h ~= nil then
                    if moved then
                        st.saw_motion  = true
                        st.logged_idle = false
                    end
                    if st.hash == nil or moved then
                        st.hash       = h
                        st.changed_at = now
                    end
                    st.had_frame  = true
                    st.logged_gfx = false
                elseif err == "gfx" and not st.logged_gfx then
                    log("snapshot failed for '%s' (graphics); will retry", name)
                    st.logged_gfx = true
                end

                if st.needs_retry and now >= st.next_ok then
                    log("retrying '%s' after a failed rebuild", name)
                    request_restart(name, st.reason or "retry", true)
                elseif woke then
                    request_restart(name, "wake", true)
                elseif periodic_restart > 0
                   and (now - st.recovered_at) >= periodic_restart then
                    log("preventive restart of '%s'", name)
                    request_restart(name, "periodic", true)
                elseif detect_ok and st.had_frame
                   and (err == "zero_size" or err == "missing") then
                    log("no frame from '%s' (%s) after it was working", name, err)
                    request_restart(name, "no-frame")
                elseif detect_ok and h ~= nil and not moved then
                    local frozen = (now - st.changed_at) >= freeze_timeout
                    local cooled = (now - st.recovered_at) >= cooldown
                    local motion_ok = (not require_motion) or st.saw_motion
                    if frozen and cooled and motion_ok then
                        log("freeze detected on '%s' (had motion, pixels unchanged %ds)",
                            name, now - st.changed_at)
                        request_restart(name, "freeze")
                    elseif frozen and require_motion and not st.saw_motion
                       and not st.logged_idle then
                        log("'%s' looks idle (no pixel change since watch start); " ..
                            "not treating as freeze", name)
                        st.logged_idle = true
                    end
                end
            end
        end
    end
    obs.source_list_release(sources)

    -- OBS does not name which source died. Restart every watched source
    -- on this check, even if its pixels just changed. Cooldown does not
    -- apply. If a teardown is still in progress, chain another the moment
    -- it finishes.
    if stream_alert then
        for name, st in pairs(state) do
            if present[name] then
                if st.restarting and not st.nudge_done then
                    st.again = true
                    log("stream-stop: '%s' teardown in progress; rebuilding again as soon as it finishes",
                        name)
                else
                    st.restarting = false
                    st.nudge_done = false
                    log("stream-stop: rebuilding '%s' now", name)
                    request_restart(name, "stream-stop", true)
                end
            end
        end
    end

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
    return [[<b>Auto-Restart Frozen Capture Sources</b> v1.1.2<br/>
Detects a dead or frozen macOS Screen Capture stream and rebuilds it.
Uses OBS's Reactivate button when the capture is already flagged, otherwise
a brief show-cursor settings nudge.<br/><br/>
Restarts immediately when OBS logs a ScreenCaptureKit stream-stop, or when
a working source goes to 0x0 / no frame. Pixel-freeze restarts only after
the source has shown motion, so an idle display is not hammered every
cooldown. Success is logged only after frames actually resume.<br/><br/>
<a href="https://github.com/FGH-2/obs-mac-screencapture-auto-restart">GitHub</a>]]
end

local function on_restart_all(props, prop)
    local sources = obs.obs_enum_sources()
    if sources == nil then return true end
    for _, source in ipairs(sources) do
        if capture_ids[obs.obs_source_get_id(source)]
           and obs.obs_source_active(source) then
            request_restart(obs.obs_source_get_name(source), "manual", true)
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
        "Min seconds between freeze-restarts (per source)", 5, 600, 1)
    obs.obs_properties_add_int(props, "periodic_restart",
        "Preventive restart every N sec (0 = off)", 0, 3600, 10)
    obs.obs_properties_add_bool(props, "wake_restart",
        "Restart capture sources after system wake")
    obs.obs_properties_add_bool(props, "stream_stop_restart",
        "Restart immediately when OBS logs a SCK stream-stop")
    obs.obs_properties_add_bool(props, "require_motion",
        "Only treat unchanged pixels as freeze after motion")
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
    obs.obs_data_set_default_bool(settings, "stream_stop_restart", true)
    obs.obs_data_set_default_bool(settings, "require_motion", true)
    obs.obs_data_set_default_bool(settings, "verbose", true)
end

function script_update(settings)
    obs.timer_remove(check_sources)
    epoch            = epoch + 1
    pending          = {}
    tearing          = false
    own_budget       = 0
    own_until        = 0
    last_real_stop_at = 0

    capture_ids_raw      = obs.obs_data_get_string(settings, "capture_ids")
    check_interval       = obs.obs_data_get_int(settings, "check_interval")
    freeze_timeout       = obs.obs_data_get_int(settings, "freeze_timeout")
    restart_gap_ms       = obs.obs_data_get_int(settings, "restart_gap_ms")
    cooldown             = obs.obs_data_get_int(settings, "cooldown")
    periodic_restart     = obs.obs_data_get_int(settings, "periodic_restart")
    wake_restart         = obs.obs_data_get_bool(settings, "wake_restart")
    -- New keys are missing from older saved script settings;
    -- obs_data_get_bool would return false and disable the fix.
    if obs.obs_data_has_user_value(settings, "stream_stop_restart") then
        stream_stop_restart = obs.obs_data_get_bool(settings, "stream_stop_restart")
    else
        stream_stop_restart = true
    end
    if obs.obs_data_has_user_value(settings, "require_motion") then
        require_motion = obs.obs_data_get_bool(settings, "require_motion")
    else
        require_motion = true
    end
    verbose              = obs.obs_data_get_bool(settings, "verbose")

    capture_ids = split_ids(capture_ids_raw)
    state = {}
    last_check_at = nil
    obs.timer_add(check_sources, check_interval * 1000)
end

function script_load(settings)
    detect_ok = init_ffi()
    attach_obs_log(true)
    if detect_ok then
        log("pixel-hash freeze detection active")
    else
        log("WARNING: pixel detection unavailable; set a preventive " ..
            "restart interval instead")
    end
    if obs_log_path then
        log("watching OBS log for capture stream-stops")
    else
        log("WARNING: could not open OBS log; stream-stop detection off")
    end
end

function script_unload()
    epoch = epoch + 1
    obs.timer_remove(check_sources)
    destroy_gfx_objects()
end
