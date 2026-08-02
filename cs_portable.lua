-- ==========================================================
--  CRITICAL STRIKE — admin console (v2)
--
--  v2 quality pass over cs_admin.lua. Same features, same payload, same
--  globals (__CS_ADMIN / CSAdmin ScreenGui), so v1 and v2 tear each other
--  down cleanly on inject. Differences are quality-only:
--    - dead retired-module amp-skip and dead ClassModule speed probes removed
--      (CS_CONSTRAINTS.md 5b: no code paths that can never run)
--    - reach/ladder skip spawn-protected targets (Stats.Safe, 0003.lua:4715)
--    - pending-confirmation reaping runs pre-match too (no pre-arm growth)
--    - panel drag can no longer stick to the cursor on an off-header release
--    - delayed UI writes are pcall-guarded against a torn-down panel
--    - hot reload watches cs_adminv2.lua (its own deploy name)
--  NOTE: tools/build_admin.sh only regenerates cs_admin.lua's payload. After
--  an engine edit, re-splice this file too or its payload is stale.
--
--  UI/UX lifted verbatim from internal/admin_core.lua:
--    ']' opens a bottom-center command bar, '>' green prompt,
--    Code font, inline grey ghost autocomplete, Tab accepts,
--    stroke flashes green/red on success/failure, black panel
--    above with 26px toggle rows.
--  Only CS combat features are wired in — no goto/tp/esp/etc.
--
--  CONFIDENCE is part of the UI. Commands and rows are tagged:
--    (no mark) PROVEN — observed server-confirmed on 2026-07-25
--    ?         UNPROVEN — plausible, never confirmed. Console
--                prints [?] and the row shows '?' until a
--                DamageIndicator confirms it live, then it
--                promotes itself to proven.
--
--  PROVEN: forged Damage:InvokeServer (6/10 direct, victim-swap
--    2/2 at 139-153 studs), self-heal via ClassModule:Heal,
--    cooldown clamp/wipe, BaseSpeed bonus.
--  UNPROVEN: kill (damage ceiling unknown), heal on others,
--    amp multiplier on legit swings, enemy EffectApply, truedmg, dtype.
--  DEAD: EffectApply Freeze (self-only / snowball HitSelf).
--  DEAD, not included: hitbox extend, HRP jitter.
--
--  EFFECT SAFETY: the Agency kick (1-2s) is keyed on INSTANCE IDENTITY and
--    victim relation, not on the remote. Sending an effect Instance that no
--    real client ever emits — 61 of the 71 RS.Effects children are orphans
--    with zero call sites — or a legit Instance at an illegal victim is what
--    gets you kicked. Proven live: StunLong survives, bare RS.Effects.Stun
--    kicks, enemy Freeze kicks, UndeadSave kicks, Slow survives.
--    So names resolve THROUGH A CANON PATH TABLE first (see CANON_PATH):
--    'stun' means RS.SubClasses.GOLEM.Effects.Stun, never RS.Effects.Stun.
--    Tags: SAFE (dumped enemy call site), MEDIUM (genuine enemy sites but
--    event-gated, e.g. TurkeyBurn), RISK (self-only or proven kick), ? (no
--    known enemy site). DEFAULT-DENY: only SAFE and MEDIUM may be aimed at
--    another player; RISK / ? / unknown are refused with the reason unless
--    the command starts with 'force'. 'effect me <name>' is always allowed.
--    Explicit paths work too: 'effect <player> SubClasses/GOLEM/Stun'.
--
--  COMMANDS
--    dmg <player> <amount>     forged damage
--    kill <player>            ? max-damage attempt
--    heal [amount]             self heal
--    healother <player> [amt] ? heal another character
--    healaura <on|off>        ? heal nearest in range
--    reach <on|off|dmg N|range N>   damage aura
--    amp <mult|off>           ? multiply legit swing damage
--    cd <off|half|zero>        cooldown mode
--    speed <n|off>             BaseSpeed bonus
--    ladder                   ? damage ceiling probe
--    effect [force] <p|me> <name|path> ? EffectApply, SAFE/MEDIUM only
--    loopeffect [force] <p|me> <name> [i]? re-fire it every i seconds
--    loopeffect off [player]   stop every loop / one player's loops
--    loopheal [who] [amt] [i]  heal loop — self proven, others ?
--    loopheal off [who]        stop every heal loop / one target's
--    stun <player> [interval] ? sustained CC — loops StunLong to keep the
--                                target locked. 'stun off [player]' stops it
--    freeze <player> [i]      ? alias of stun. RS.Effects.Freeze is self-only
--                                and KICKS on enemies, so freeze uses the
--                                StunLong lock instead of a real Freeze
--    unstun [player]           release the stun/freeze lock (all or one)
--    truedmg <player> <amt>   ? Damage dtype TrueDamage
--    dtype <player> <amt> <t> ? Damage dtype Cross|Fixed|...
--    effects [all] [filter]    SAFE/MEDIUM names; 'all' reveals RISK too
--    help / help <cmd>         command list / detail for one command
--    menu                      toggle panel
--    unload
--
--  Player args resolve exact -> prefix -> substring on Name and
--  DisplayName ('res' finds 'resetyv'); ties fail soft and print
--  the candidates. Tab accepts the grey ghost — it completes
--  command names, player names and effect names.
--  Empty Enter in the ']' bar prints help.
--
--  HUD (cs_hub style, instance-only GUI — no child LocalScripts):
--    tabs MAIN / EFFECTS / BINDS / PROJ / AIM, draggable header, live class status.
--    MAIN     toggle rows (ON/OFF, cooldown cycles off|half|zero),
--             numeric boxes, Self heal CAST row. '?' on a row until
--             a DamageIndicator confirms that feature live.
--    EFFECTS  filter box + scrollable list from effectCatalog(). The list is
--             default-deny: SAFE + MEDIUM only until the SAFE/ALL pill is
--             flipped, because a listed name is a name a hand clicks.
--             Clicking a name opens the ']' bar pre-filled with
--             'effect  <Name>' and parks the caret in the empty
--             player slot — type the player, press Enter. The
--             player slot is first in the grammar, so the caret
--             goes in the GAP rather than at the end of the line;
--             that keeps one click + one word + Enter. The LOOP
--             pill switches the prefix to 'loopeffect  <Name>'.
--             STOP clears every running loop.
--    BINDS    every key is rebindable: click the key button, press
--             the next key (Esc cancels). Capture ignores
--             gameProcessed. Binds live in BINDS for the session.
--             Toggle rows on MAIN carry their own bind button too.
--    PROJ     __CS_PFORGE wrapper: preset + live catalog list, pick
--             resets damage to 10, dmg/speed/range boxes, FIRE and
--             PREVIEW (forge J=fire). Forge embedded in payload;
--             loads automatically on PROJ tab open.
--    AIM      heatseek hub — lazy-load per toggle (musketeer ally echo, elem Smolder
--             ally echo/HS, sniper/musk, chrono, swordmancer, self elem Smolder HS).
--             Friends whitelist + player list. Elem needs Classes.ELEMENTALIST.Projectile stream.
--
--  COMMANDS (aim / heatseek hub)
--    ally <player|off>     echo ally / clear (musk + elem; comma-separated names)
--    allyecho <on|off>     musketeer echo forge
--    allyhs <on|off>       musketeer heatseek on your echoes
--    allyelem|allysmolder <on|off>  elem Smolder ally echo + HS
--    hs sniper|chrono|sword|elem|ally|off   load/enable shot HS or ally HS; off destroys all hub HS
--    friend <player>       friends whitelist add
--    unfriend <player>     whitelist remove
--    friends <on|off|list> whitelist toggle / list
--
--  KEYS (rebindable): Z cooldown, C speed, X reach, V healaura,
--    B amp, H self heal, RightShift show/hide HUD, K unload.
--    ']' opens the command bar and is NOT rebindable. Binds are
--    inert while the bar is open so typing never fires a toggle.
--
--  Re-inject safe: self-teardown on load; K = unload
--  UNLOADS_ON_INJECT: __CS_HUB, __CS_CLASS_BUFF, __CS_NO_CD,
--    __CS_LEGIT_NO_CD, __CS_REACH, __CS_HEAL_AURA, __CS_HEAL_BIND
--  (does NOT unload hub HS or __CS_PFORGE on re-inject — lazy until toggled;
--   K/unload destroys the engine, the panel and any retired module a previous inject left running)
-- ==========================================================

local S = {
    alive = true,
    armed = false,
    conns = {},
    cm = nil,
    getUtil = nil,
    damageRemote = nil,
    healRemote = nil,
    effectRemote = nil,
    orig = {},

    cdMode = "off",
    cdMult = 0.5,
    minCd = 0.05,
    fullCd = {},
    lastClass = nil,

    -- Panel position, in pixel offsets. Defaults match the frame's original
    -- literal Position so a fresh install lands exactly where it always did.
    panelX = 24,
    panelY = 120,

    speedOn = false,
    speedBonus = 4,
    origBaseSpeed = nil,
    lastWritten = nil,

    selfHealAmount = 50,

    reachOn = false,
    reachDmg = 10,
    reachRange = 45,
    lastReach = 0,

    healAuraOn = false,
    healAmount = 25,
    healRange = 45,
    lastHeal = 0,

    ampOn = false,

    -- OVERRIDE CONE (MAIN row "override"). Mirrors Core.fovBoostSticky, the
    -- sticky half of the LeftAlt override. DELIBERATELY ABSENT from the
    -- persisted config schema: this is the one switch that suspends every
    -- legitness gate in the engine, and HANDOFF_2026-07-31_EVENING.md §1 is
    -- explicit that a surface left armed through an inject is what puts you in
    -- a lobby already misbehaving. It boots off, every time.
    overrideOn = false,
    ampMult = 3,

    -- ladder probe
    ladder = nil,
    ladderIdx = 0,
    lastLadder = 0,
    ladderMax = 0,

    -- loopeffect: key "<userid>|<EffectName>" -> { player, name, interval, last }
    -- cc = true marks a stun/freeze lock so 'stun off' can stop those without
    -- touching a hand-started loopeffect
    loops = {},
    loopFill = false,   -- EFFECTS tab click fills 'loopeffect' instead of 'effect'
    fxShowAll = false,  -- EFFECTS tab: default-deny list, ALL reveals RISK/?

    -- loopheal: key "self" or "<userid>" -> { player, amount, interval, last }
    -- deliberately a separate store — 'loopeffect off' must not stop a heal
    healLoops = {},

    -- live confirmation promotes UNPROVEN -> proven
    confirmed = {
        kill = false, healother = false, amp = false, healaura = false,
        effect = false, stun = false, freeze = false, truedmg = false,
        dtype = false, loopeffect = false, loopheal = false,
    },
    -- confirmed.effect is a command-level UI mark and latches once. Effect
    -- probing needs a finer store or the first effect that lands blinds every
    -- later one: fxConfirmed keys "<EffectName>|<userId>", fxSeen keys names.
    fxConfirmed = {},
    fxSeen = {},
    pending = {},
    fireInterval = 0.35,
    capturing = nil,    -- bind key currently waiting for a keypress
}

-- loopeffect cadence. Below ~0.15s the EffectApply invokes stack up faster
-- than the server answers them, so the floor is not negotiable.
local LOOP_INTERVAL = 0.35
local LOOP_MIN_INTERVAL = 0.15

-- loopheal is slower on purpose: Heal is a RemoteFunction round-trip and a
-- heal that lands twice inside one server tick is wasted either way.
local HEAL_LOOP_INTERVAL = 0.5
local HEAL_LOOP_MIN_INTERVAL = 0.2

-- ']' is fixed: it is the console key and every other bind is inert while
-- the bar is open, so it can never be captured away by the bind menu.
local OPEN_KEY = Enum.KeyCode.RightBracket

local BINDS = {
    cd = Enum.KeyCode.Z,
    speed = Enum.KeyCode.C,
    reach = Enum.KeyCode.X,
    heal = Enum.KeyCode.V,
    amp = Enum.KeyCode.B,
    selfHeal = Enum.KeyCode.H,
    gui = Enum.KeyCode.RightShift,
    unload = Enum.KeyCode.K,
    -- Sticky override toggle. N is free; LeftAlt stays the momentary hold and is
    -- owned by the engine, not by this table.
    override = Enum.KeyCode.N,
}
S.binds = BINDS

local Log = (function()
    local ok, L = pcall(function() return loadfile("log.lua")()("cs_admin") end)
    if ok and L then return L end
    return { info = function(m) print("[CSAdmin] " .. tostring(m)) end,
             warn = function(m) warn("[CSAdmin] " .. tostring(m)) end,
             err = function(m) warn("[CSAdmin] " .. tostring(m)) end }
end)()

local G = getgenv()

-- Destroy every panel this script has ever created, by NAME, in BOTH places one
-- can live.
--
-- The ScreenGui is parented to gethui() when available and PlayerGui otherwise.
-- Two consequences that a handle-based teardown cannot cover:
--
--   1. The orphan belongs to a module instance that is already gone -- there is
--      no handle left to call. This is the purgeRetiredModules lesson again:
--      deleting the loader does not remove what is already on screen.
--   2. The two builds need not agree on the parent. If gethui() succeeded last
--      inject and fails this one (or vice versa), the previous panel is in a
--      container the new instance never looks at, so it survives a perfectly
--      correct teardown and you get two HUDs.
--
-- Sweeping by name in both containers is the only version that is right in all
-- four combinations.
local function destroyPanels()
    local seen = {}
    local function sweep(parent)
        if not parent or seen[parent] then return end
        seen[parent] = true
        for _, ch in ipairs(parent:GetChildren()) do
            if ch.Name == "CSAdmin" and ch:IsA("ScreenGui") then
                pcall(function() ch:Destroy() end)
            end
        end
    end
    if gethui then pcall(function() sweep(gethui()) end) end
    -- Resolved through the service, NOT the `lp` local: that local is declared
    -- further down the file, so naming it here would capture a nil global and
    -- this sweep would silently do half its job. Same declaration-order trap
    -- that made every ally APPLY crash silently once.
    pcall(function()
        local plr = game:GetService("Players").LocalPlayer
        sweep(plr and plr:FindFirstChildOfClass("PlayerGui"))
    end)
end

-- A previous instance that is STILL ALIVE when we get here is the two-panel /
-- double-toggle bug: two panels restore the same panelX/panelY from the same
-- config file, so they stack pixel-on-pixel, and both bind the same keys. You
-- click the top pill, it flips ITS OWN S, and the identical panel underneath
-- still reads ON -- which looks exactly like "the button did not switch".
-- Named loudly rather than silently cleaned up, because if this fires the
-- previous teardown did not work and that is worth knowing.
do
    local prev = G.__CS_ADMIN
    if prev and prev.alive then
        warn("[CSAdmin] a LIVE previous instance was still resident at inject — "
            .. "destroying it. If you saw a toggle that would not switch, this "
            .. "was why: two stacked panels, two sets of keybinds.")
    end
end

for _, k in ipairs({ "__CS_ADMIN", "__CS_HUB", "__CS_CLASS_BUFF", "__CS_NO_CD",
    "__CS_LEGIT_NO_CD", "__CS_REACH", "__CS_HEAL_AURA", "__CS_HEAL_BIND" }) do
    local prev = G[k]
    if prev and prev.destroy then pcall(prev.destroy) end
end
-- Whether or not those destroy() calls existed or succeeded, remove any panel
-- still on screen. An inject must never be able to leave two HUDs up.
destroyPanels()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer

-- ============ config ============
--
-- Settings survive a rejoin; switches do not.
--
-- Everything here used to reset to the shipped default on every inject, so a
-- session started by re-typing the same four numbers. What is persisted is the
-- TUNING -- amounts, ranges, multipliers, intervals, keybinds. What is
-- deliberately NOT persisted is the on/off state of anything: cd, speed, reach,
-- heal aura, amp and every heatseek class all boot OFF, every time. A script
-- that restores its own switches comes up hot the instant you inject in a live
-- match, which is the one moment you least want it to.
--
-- Same file format as cs_engine_caps.txt: flat `key = value` lines, no
-- HttpService, readable and hand-editable. The engine keeps its own state file;
-- this one is the panel's.
-- Raw ally name string, mirrored here so the config layer can persist it. The
-- engine holds the authoritative parsed copy (Core.ally.raw); this is the text.
S.allyNames = S.allyNames or ""
S.allyAssist = S.allyAssist or false
-- Defaults ON, on instruction 2026-07-31. See CFG_SPEC.armAll.
if S.armAll == nil then S.armAll = true end
-- Visual debug cone. Persisted; see CFG_SPEC.coneVis.
S.coneVis = S.coneVis or false
-- HUD visibility (RightShift). Persisted; see CFG_SPEC.hudVisible.
S.hudVisible = (S.hudVisible ~= false)
-- No S.highNoon. High Noon is armed by its CLASS (`hs COWBOY`), not by a
-- setting of its own -- see the highNoon block in cs_classes.lua for why the
-- separate switch was removed. Nothing to persist, nothing to restore.

local CFG_FILE = "cs_admin_config.txt"

-- key -> kind. The spec is the whole contract: a setting that is not listed is
-- not persisted, so runtime state (loops, confirmations, probe ladders) cannot
-- leak into the file by accident.
local CFG_SPEC = {
    cdMult = "number",
    minCd = "number",
    speedBonus = "number",
    selfHealAmount = "number",
    reachDmg = "number",
    reachRange = "number",
    healAmount = "number",
    healRange = "number",
    ampMult = "number",
    fireInterval = "number",
    loopFill = "boolean",
    fxShowAll = "boolean",

    -- Ally names, as the raw comma-separated string the user typed.
    --
    -- Persisted because it is the one setting you retype every single session,
    -- and because a mistyped ally name fails silently -- `zoeyzplaz10` vs
    -- `zoeyzplayz10` cost a whole test session once. Saving the resolved-and-
    -- verified string means that only has to be got right once.
    --
    allyNames = "string",

    -- ALLY ASSIST IS THE ONE TOGGLE THAT DOES PERSIST. Deliberate exception to
    -- "nothing is armed on inject", made on explicit instruction 2026-07-31:
    -- the names were being restored while the switch that uses them was not, so
    -- every reload and every hot reload silently left ally assist off with the
    -- allies still listed in the panel. That reads as "ally heatseek is broken"
    -- and cost real test sessions.
    --
    -- Scope of the exception is narrow and stays narrow: CLASS arming still
    -- always boots OFF (see Core.registerClass -- it refuses to restore
    -- `enabled` from the state file). This restores one ally switch, not a
    -- loadout. Nothing here can put a class in the air on its own.
    allyAssist = "boolean",

    -- Arm EVERY registered class on load. Defaults true, on instruction
    -- 2026-07-31.
    --
    -- This reverses the "nothing is armed on inject" rule for class toggles, and
    -- the reason it is acceptable is narrower than it looks: a class only ever
    -- acts on bodies whose OWN provenance resolves to it. Arming all seventeen
    -- does not make seventeen steerers fight over one bolt -- it makes the
    -- engine ready for whichever class you happen to switch to, which is what
    -- the per-class toggle was making you do by hand every single round.
    --
    -- The real cost is that heatseek is live the moment you inject, including in
    -- a lobby. `hs off` still disarms everything and is remembered.
    armAll = "boolean",

    -- Visual debug cone. Persisted on instruction 2026-07-31.
    --
    -- Third narrow exception to "on/off state is never persisted", and the
    -- easiest of the three to justify: this switch draws lines on your own
    -- screen. It arms nothing, it steers nothing, and unlike allyAssist or
    -- armAll it cannot put a projectile in the air. The rule exists so that
    -- injecting never silently resumes ACTING; an overlay does not act.
    --
    -- It matters because the cone is a diagnostic you turn on precisely when
    -- you are iterating -- which is exactly when hot reload fires most often,
    -- and every rebuild was silently turning it back off mid-investigation.
    coneVis = "boolean",

    -- HUD shown or hidden, toggled with RightShift.
    --
    -- Persisted because hot reload fires constantly while iterating and rebuilt
    -- the panel VISIBLE every time, so hiding it never lasted more than a few
    -- seconds. Defaults true -- a panel that boots hidden with no visible way
    -- back is the same unreachable-UI failure as a panel dragged off-screen.
    hudVisible = "boolean",

    -- No highNoon key. It was one, and a stale `highNoon = true` may still be
    -- sitting in an existing cs_admin_config.txt -- loadConfig ignores keys that
    -- are not in this table, so the leftover is inert and gets dropped on the
    -- next save. Do not re-add it: arming lives with the class now.

    -- ==================================================================
    -- COMBAT TOGGLES — persisted on instruction 2026-07-31.
    --
    -- This is the widest of the exceptions to "on/off state is never
    -- persisted", and unlike coneVis these DO act: they change your walk speed,
    -- your damage, your cooldowns and your reach. Stated plainly so nobody has
    -- to rediscover it -- with these saved ON, injecting or hot reloading puts
    -- you straight back into a modified character, lobby included, with no
    -- keypress in between.
    --
    -- Instructed anyway, and the reason is the same one behind allyAssist: a
    -- rebuild during iteration silently dropped every toggle, so the thing you
    -- were mid-way through testing quietly stopped being tested. Re-arming four
    -- switches after each of a dozen rebuilds is where real sessions went.
    --
    -- `hs off` remains the disarm for heatseek; these have their own `off`
    -- arguments and are remembered the same way, so turning one off persists
    -- just as turning it on does.
    -- ==================================================================
    -- Where you dragged the panel to. A position, not a switch, so this one sits
    -- squarely inside the original persistence rule rather than being another
    -- exception to it -- it was simply never wired up.
    panelX     = "number",
    panelY     = "number",

    speedOn    = "boolean",   -- walk speed bonus
    ampOn      = "boolean",   -- damage multiplier
    reachOn    = "boolean",   -- reach hits
    healAuraOn = "boolean",   -- heal aura
    cdMode     = "string",    -- cooldowns: off | half | zero
}

-- Shipped defaults, captured before loadConfig can overwrite anything, so
-- `config` can mark what you actually changed and `config reset` has something
-- true to go back to. Same approach as the engine's T_DEFAULTS.
local CFG_DEFAULTS = {}
for key in pairs(CFG_SPEC) do CFG_DEFAULTS[key] = S[key] end
local BIND_DEFAULTS = {}
for name, kc in pairs(BINDS) do BIND_DEFAULTS[name] = kc end

local function serialiseConfig()
    local out = {}
    for key, kind in pairs(CFG_SPEC) do
        local v = S[key]
        if type(v) == kind then
            -- Strings are written raw and read back to end-of-line, so a value
            -- may contain commas and underscores -- both of which occur in real
            -- Roblox usernames and in a multi-ally list. Newlines are stripped
            -- because they would break the one-setting-per-line format.
            if kind == "string" then
                local clean = v:gsub("[\r\n]", "")
                if clean ~= "" then
                    out[#out + 1] = ("%s = %s"):format(key, clean)
                end
            else
                out[#out + 1] = ("%s = %s"):format(key, tostring(v))
            end
        end
    end
    -- Binds are stored by KeyCode NAME, not by EnumItem or number: the numeric
    -- values are not a stable contract, and a name reads correctly in the file.
    for name, kc in pairs(BINDS) do
        if typeof(kc) == "EnumItem" then
            out[#out + 1] = ("bind.%s = %s"):format(name, kc.Name)
        end
    end
    table.sort(out)
    return table.concat(out, "\n") .. "\n"
end

local function loadConfig()
    if not (isfile and readfile and isfile(CFG_FILE)) then return false end
    local ok, body = pcall(readfile, CFG_FILE)
    if not ok or type(body) ~= "string" then return false end

    local n = 0
    -- Line-based, not one global gmatch.
    --
    -- The previous value pattern was `([%w%.%-]+)`, which stops at the first
    -- character outside [A-Za-z0-9.-]. That silently truncated any value with an
    -- underscore or a comma in it -- so an ally list like
    -- `zoeyzplayz10,Starplatinum_Jba` would have been read back as `zoeyzplayz10`
    -- and the second ally would vanish on every restart, with nothing to say so.
    -- Reading to end-of-line makes the format able to carry the values it has to.
    for line in body:gmatch("[^\r\n]+") do
        local key, raw = line:match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
        if key and raw then
            local kind = CFG_SPEC[key]
            if kind == "number" then
                local num = tonumber(raw)
                if num then S[key] = num; n = n + 1 end
            elseif kind == "boolean" then
                if raw == "true" or raw == "false" then
                    S[key] = (raw == "true"); n = n + 1
                end
            elseif kind == "string" then
                S[key] = raw; n = n + 1
            end
        end
    end

    for name, keyName in body:gmatch("bind%.([%w_]+)%s*=%s*(%w+)") do
        -- Only rebind keys that already exist. An unknown name in the file is a
        -- stale key from an older build, not a new binding to invent.
        if BINDS[name] and Enum.KeyCode[keyName] then
            BINDS[name] = Enum.KeyCode[keyName]
            n = n + 1
        end
    end

    return n > 0, n
end

local function saveConfig()
    if not writefile then return false end
    return (pcall(writefile, CFG_FILE, serialiseConfig()))
end

S.saveConfig = saveConfig

do
    local loaded, count = loadConfig()
    -- cdMode is the only persisted string with a closed set of legal values, and
    -- the file is documented as hand-editable. Everything downstream compares it
    -- against "off"/"half"/"zero" and treats anything else as "not off", so a
    -- typo would silently leave cooldown modification half-enabled in a state no
    -- command can produce. Clamped once, here, rather than defended at each of
    -- the four read sites.
    if S.cdMode ~= "off" and S.cdMode ~= "half" and S.cdMode ~= "zero" then
        Log.warn(("config: unknown cdMode %q — using off"):format(tostring(S.cdMode)))
        S.cdMode = "off"
    end
    if loaded then
        Log.info(("config restored (%d settings) from " .. CFG_FILE):format(count))
    else
        -- Write the defaults out on first boot. Without this the file only
        -- appears after the first setting is changed, so a fresh install looks
        -- like the config system was never added at all -- and there is nothing
        -- to hand-edit until you have already done the thing it saves you from.
        if saveConfig() then
            Log.info("config: wrote defaults to " .. CFG_FILE)
        else
            Log.warn("config: writefile unavailable — settings will not persist")
        end
    end
end

-- Autosave by diff rather than a save() call at every mutation site. There are
-- dozens of those -- commands, UI boxes, the bind capture -- and the one that
-- gets missed is the setting that mysteriously never sticks. Snapshotting is
-- cheap and cannot be forgotten.
task.spawn(function()
    local last = serialiseConfig()
    while S.alive do
        task.wait(5)
        if not S.alive then break end
        local now = serialiseConfig()
        if now ~= last then
            last = now
            saveConfig()
        end
    end
end)

-- ============ engine self-extract ============
--
-- cs_admin.lua is the only file that ever gets injected. The engine
-- (cs_core.lua + cs_classes.lua) ships embedded below.
--
-- IMPORTANT: the workspace copies are written for INSPECTION ONLY. What
-- actually executes is the embedded string, always. Editing the workspace copy
-- does nothing -- that is deliberate, and it is what makes the old
-- workspace-cache shadowing bug impossible to reproduce: there is exactly one
-- source of truth, and it travels inside this file.
--
-- To change the engine: edit engine/*.lua in the repo, run tools/build_admin.sh.
--
-- The payload is GENERATED. Edit engine/cs_core.lua and engine/cs_classes.lua
-- in the repo, then run tools/build_admin.sh. Never hand-edit the block.

-- >>> ENGINE PAYLOAD BEGIN (generated by tools/build_admin.sh — do not edit)
local ENGINE_PAYLOAD = {}
ENGINE_PAYLOAD["cs_core.lua"] = [==[
-- ==========================================================
--  CRITICAL STRIKE — cs_core.lua
--  One projectile / heatseek engine. Classes are data, not files.
--
--  Replaces eight near-identical modules (cs_sniper_heatseek,
--  cs_swordmancer_heatseek, cs_chronos_heatseek, cs_elementalist_heatseek,
--  cs_trickster_heatseek, and the three ally echo variants), each of which
--  carried its own copy of the target pipeline, lock scoring, steering and
--  registry. Every bug found so far had to be fixed two or three times.
--
--  Loaded by cs_admin.lua, which self-extracts it into the Potassium
--  workspace on inject. Not meant to be injected directly.
--
--  Layout:
--    1  services, log, state
--    2  tunables
--    3  target pipeline   (validity + hittability gates)
--    4  line of sight
--    5  lock scoring      (hard cone, sticky lock, soft widening)
--    6  steering          (BodyVelocity only, predictive lead)
--    7  projectile facts  (speed / range / lifetime)
--    8  registry          (live bodies, lifetime, cleanup)
--    9  damage ledger     (shared by heatseek and reach)
--   10  spawn             (typed wrapper over all 12 CreateProjectile params)
--   11  class registry    (per-class config + shot gating)
--   12  watcher + dispatch
--   13  telemetry
--   14  public API
--
--  Dump citations are file:line inside full_dump/scripts/.
-- ==========================================================

local G = getgenv()
local GKEY = "__CS_CORE"

if G[GKEY] and type(G[GKEY].destroy) == "function" then
    pcall(G[GKEY].destroy)
end

--------------------------------------------------------------------------
-- 1. SERVICES, LOG, STATE
--------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer

local Log = (function()
    local ok, L = pcall(function() return loadfile("log.lua")()("cs_core") end)
    if ok and L then return L end
    return {
        session = function(m) print("[Core] " .. tostring(m or "session")) end,
        info = function(m) print("[Core] " .. tostring(m)) end,
        warn = function(m) warn("[Core] " .. tostring(m)) end,
        err = function(m, e) warn("[Core] " .. tostring(m) .. " " .. tostring(e or "")) end,
    }
end)()

local Core = {}

--------------------------------------------------------------------------
-- 1b. STRUCTURED LOGGING
--
-- The log is the primary diagnostic for this engine -- three separate bugs this
-- month were found in it and could not have been found any other way (the
-- CHRONO/CHRONOS alias, the ELEMENTALIST VFX claims, the abandoned echoes). Two
-- things were wrong with it:
--
--  1. It was all one undifferentiated stream at one level. Either every
--     diagnostic was on, and a busy match wrote 400 KB of `owner <name>` lines
--     that buried the four lines that mattered, or they were behind T.debug and
--     the log was eleven lines of startup.
--
--  2. Nothing tied the lines from one CAST together. "Duplicate projectiles" is
--     definitionally a statement about one cast producing several steered
--     bodies, and the log had no way to express that -- you had to eyeball
--     timestamps and guess which claims belonged to the same keypress.
--
-- So: categories that can be switched independently, and a cast id stamped on
-- every line that belongs to one cast. `#7 claim attack` appearing four times is
-- the duplicate bug, visible at a glance, and dupWatch below reports it without
-- being asked.
--------------------------------------------------------------------------

-- Defaults chosen so a busy match stays readable. `mover` and `target` are the
-- per-frame firehoses and are opt-in for deep debugging only.
local LOGCAT = {
    boot   = true,      -- load, build stamp, class registration, audit warnings
    cfg    = true,      -- tunable changes, toggles, ally names
    cast   = true,      -- one line per detected cast, plus duplicate warnings
    claim  = true,      -- a body accepted for steering
    echo   = true,      -- ally echo forge / cleanup lifecycle
    flight = true,      -- one line per completed flight, with the legit score
    lock   = true,      -- target acquisition
    reject = true,      -- why a body or candidate was refused (rate limited)
    perf   = true,      -- tier changes and bench output
    mover  = false,     -- every mover write. Per frame, per body.
    target = false,     -- every candidate evaluation. Per candidate, per scan.
}

Core.LOGCAT = LOGCAT

function Core.setLogCat(cat, on)
    if LOGCAT[cat] == nil then return false, "unknown log category" end
    LOGCAT[cat] = on and true or false
    return true
end

function Core.logCats()
    local out = {}
    for k, v in pairs(LOGCAT) do out[#out + 1] = k .. "=" .. (v and "on" or "off") end
    table.sort(out)
    return out
end

-- Cast identity.
--
-- There is no cast id on the wire, so one is synthesised: bodies from the same
-- owner inside CAST_WINDOW are one cast. That is the same heuristic the ally
-- echo budget uses, deliberately -- one definition of "a cast", used by both the
-- thing that limits them and the thing that reports on them.
local CAST_WINDOW = 0.30

-- A real multi-body cast emits its bodies in the SAME FRAME, or within one or two
-- of it. Rapid clicking is 100ms+ apart. So the burst window, not the cast window,
-- is what identifies a duplicate.
--
-- This matters because the first version warned on CAST_WINDOW alone and produced
-- nothing but false positives on the live log: four `attack, attack, attack`
-- warnings inside one second at 05:05:31 were the user clicking fast, and
-- `attack, critical` was M1 then F. Neither is a duplicate. A detector that cries
-- wolf on normal play is worse than no detector -- it trains you to ignore the
-- one line that matters.
local BURST_WINDOW = 0.06

local nextCastId = 0
local casts = {}        -- [ownerKey] = { id, at, lastAt, claims, names, seen, burst }

local function castKey(owner)
    return owner or "self"
end

-- Returns castId, claimIndex, castRec, dupKind.
--
-- dupKind is the honest classification of what just happened:
--   nil        -- a separate cast, or a repeat of the same body in a volley
--   "volley"   -- same body name again inside one burst. GHOST Pulse Rifle is five
--                 bullets, Smolder is five bolts. Expected, not a bug.
--   "distinct" -- a DIFFERENT body name inside one burst. This is the real
--                 duplicate signature: one cast emitting attack + AttackSpirit +
--                 critical means the `allow` list is too loose.
local function castFor(owner, bodyName)
    local key = castKey(owner)
    local now = os.clock()
    local name = bodyName or "?"
    local c = casts[key]

    if not c or (now - c.at) > CAST_WINDOW then
        nextCastId = nextCastId + 1
        c = { id = nextCastId, at = now, lastAt = now, claims = 1,
              names = { name }, seen = { [name] = 1 }, burst = 1 }
        casts[key] = c
        return c.id, 1, c, nil
    end

    local inBurst = (now - c.lastAt) <= BURST_WINDOW
    c.lastAt = now
    c.claims = c.claims + 1
    c.names[#c.names + 1] = name

    local dupKind = nil
    if inBurst then
        c.burst = c.burst + 1
        if c.seen[name] then
            dupKind = "volley"
        else
            dupKind = "distinct"
        end
    else
        -- Same cast id for budget purposes, but a new burst: reset so a long
        -- staggered ability (PROGRAMMER's Malware fires sub-waves over ~2s) does
        -- not read as one enormous duplicate.
        c.burst = 1
    end
    c.seen[name] = (c.seen[name] or 0) + 1
    return c.id, c.claims, c, dupKind
end

Core.castFor = castFor

-- Prune. Player-keyed and would otherwise hold a reference to everyone seen.
local function sweepCasts()
    local now = os.clock()
    for k, c in pairs(casts) do
        if (now - c.at) > 10 then casts[k] = nil end
    end
end

local function logx(cat, msg)
    if not LOGCAT[cat] then return end
    Log.info(msg)
end

local function logwarn(cat, msg)
    if not LOGCAT[cat] then return end
    Log.warn(msg)
end

Core.logx = logx

local S = {
    alive = true,
    conns = {},
    classes = {},       -- [name]  = config
    classOrder = {},    -- sorted names, so dispatch is deterministic
    aliasMap = {},      -- [CurrentClass value] = config
    registry = {},      -- [proj]  = record
    ledger = {},        -- [victim] = last damage clock
    cm = nil,           -- ClassModule
    stickyTarget = nil,
    stickyUntil = 0,
}

local function conn(sig, fn)
    local c = sig:Connect(fn)
    table.insert(S.conns, c)
    return c
end

local function char()
    local c = lp.Character
    if not c or not c.Parent then return nil end
    return c
end

local function myClass()
    local c = char()
    local cc = c and c:FindFirstChild("CurrentClass")
    return cc and cc.Value or "none"
end

--------------------------------------------------------------------------
-- 2. TUNABLES
--
-- Live-adjustable from the panel. Anything the lock or steering reads goes
-- here rather than into a per-class file, so tuning is one surface.
--------------------------------------------------------------------------

local T = {
    -- Lock geometry. lockFovDeg is a hard cone: outside it we do not lock at
    -- all. This is what stops the engine picking targets behind the player.
    --
    -- Tuned from live logs. At the old 35 deg / 90 studs, cs_chronos_hs.log
    -- shows `valid=17 inCone=0` on 262 of ~276 scans -- fifteen to twenty valid
    -- targets on the map and essentially never one inside the cone. That is
    -- what "sometimes it works, sometimes it doesn't" actually was: it was
    -- almost never locking. 50 deg with a 170-stud floor is still a cone in
    -- front of you, not a global aimbot.
    -- MUST stay at or under legitMaxTotalDeviationDeg. This is not a taste
    -- setting, it is a consistency requirement.
    --
    -- A target 50 deg off-axis needs ~50 deg of heading change to reach. With a
    -- 30 deg deviation budget the bolt structurally CANNOT get there -- so it
    -- steered at the maximum rate for the whole flight, spent the budget, and
    -- froze pointing at nothing. That is what "flails around then hits them"
    -- looks like from the inside, and at the old 50 deg (soft-widened to 85 deg)
    -- most locks outside about 30 deg were exactly this.
    --
    -- Locking only what we can reach smoothly is both better looking and a
    -- higher hit rate: the volleys it gives up were the ones that missed anyway.
    -- 26 -> 34, moved WITH the deviation budget to preserve the invariant below:
    -- soft-widened this is 34 * 1.15 = 39.1, just inside the 40 degree budget. A
    -- wider cone also means more shots find a target at all, which is the other
    -- half of "not locking".
    --
    -- 34 -> 38. "no target" was the single most common flight outcome on the
    -- 16:39 build -- 22 of 59 -- which is the cone, not the guidance: the bolt
    -- never found anything to steer at. Moved WITH the budget as always
    -- (38 * 1.15 = 43.7, inside 44). Deliberately not pushed further: the budget
    -- would have to follow past 45, where a bolt starts visibly ending up
    -- somewhere it was never thrown.
    -- NOTE: this is now an UPPER BOUND, not the effective cone. pickTarget clamps
    -- it to legitMaxTotalDeviationDeg - LOCK_DEV_MARGIN, so raising it past that
    -- ceiling does nothing. Raise the budget first if you genuinely want a wider
    -- cone -- and read what that costs in the legitness section before you do.
    -- 38 -> 49. Locks were the complaint, and the cone was the binding limit:
    -- `out of cone` plus a hard ceiling of 38 deg after the budget clamp. 49 is
    -- the new ceiling (budget 55 - margin 6). Raised WITH the budget below, as
    -- always -- the clamp in pickTarget means raising this alone does nothing.
    lockFovDeg = 49,

    -- UNIVERSAL CONE SCALE. Multiplies whatever cone is in force -- lockFovDeg
    -- and every per-class/per-body `lockFov` override alike -- so tightening the
    -- cone across the roster is one number instead of 31 edits. 0.75 is a 25%
    -- narrower cone everywhere.
    --
    -- Applied at the two places a cone is ever consumed: the lock scan in
    -- pickTarget and the on-screen cone in the visual overlay. Both call
    -- Core.fovScaleNow(), so the picture cannot drift from the behaviour --
    -- which it silently would if either one applied the scale itself.
    lockFovScale = 0.75,

    -- Hold-to-widen multiplier, on top of lockFovScale, while the boost key is
    -- down. 0.75 * 1.5 = 1.125 of the raw cone -- but see the ceiling note in
    -- pickTarget: the deviation budget still clamps the result, so the widened
    -- cone lands AT the ceiling rather than above it. That clamp is the
    -- legitness invariant, not a bug to route around.
    lockFovBoostMult = 1.5,

    lockRange = 170,

    -- COWBOY High Noon only, and deliberately outside the rules above.
    --
    -- Every other cone in this engine is capped by the deviation budget, because
    -- a lock the steering cannot turn to is a miss manufactured at lock time.
    -- The High Noon round is the one shot that does not steer at ALL: it is
    -- aimed at spawn with CFrame.lookAt and flies straight (see fireHighNoon),
    -- so it spends zero deviation and the budget has no say over what it can
    -- reach. Capping it at 49 deg was applying a steering constraint to a bolt
    -- that never steers.
    --
    -- Its real tell is different and worth naming, because it is what limits
    -- these two numbers: the round leaves the muzzle already pointing at the
    -- target, so the visible giveaway is the SPAWN ANGLE off the caster's
    -- facing. 75 deg is wide enough to cover anyone a Sharpshooter would
    -- plausibly swing onto during an 8s stance without the bullet leaving the
    -- barrel sideways. Past ~90 it would fire behind the player.
    -- Assumed lateral speed of a target, used ONLY to size the lock margin
    -- against the bolt's own speed (see pickTarget). Roughly a strafing player.
    lockDriftStudsPerSec = 16,

    -- Upward knockback on High Noon hits. UNPROVEN -- see burnOnHit. Safe to
    -- default true only because High Noon itself is off until switched on, so
    -- nothing fires by merely injecting. `hstune highNoonKnockup false` kills it
    -- mid-match with no rebuild.
    highNoonKnockup = true,
    highNoonKnockupPower = 75,   -- the game's own value at 0250.lua:36

    highNoonFovDeg = 75,
    -- Lock cap AND the spawned body's own Range -- one number by construction,
    -- because a lock further than the bolt can fly is the lockCap bug.
    highNoonRange = 700,

    -- If nothing is inside the hard cone, widen once by this factor before
    -- giving up. Prevents dead volleys without letting the cone go global.
    -- Soft widening must also stay inside the budget: 34 * 1.15 = 39.1 deg against
    -- a 40 deg budget. It was 1.7, which widened to 85 deg -- nearly three times
    -- what the bolt could actually turn.
    softFovMult = 1.15,
    softFovEnabled = true,

    -- Blended cost = angle*angleWeight + normalisedDistance*distWeight.
    -- Pure angle-minimum made volleys flip-flop between two similar targets.
    angleWeight = 1.0,
    distWeight = 0.45,

    -- A lock is reused for this long so a multi-bolt cast stays coherent
    -- (ELEMENTALIST Smolder is 5 bolts). A new target must beat the sticky one
    -- by stickyMargin to take over.
    stickyTtl = 1.25,
    stickyMargin = 0.15,

    -- ---------------------------------------------------------------------
    -- LEGITNESS
    --
    -- The goal is a shot that looks like it was aimed slightly better than it
    -- was -- not a homing missile. Detection here is a human typing aimbotcheck
    -- (0691.lua); nothing inspects projectile paths. So the thing being
    -- optimised against is "would somebody watching this call it out", and the
    -- tells, in the order a person actually notices them, are:
    --
    --   1. The bolt corrects the instant it leaves the muzzle. Nothing a player
    --      throws changes direction in the first few frames.
    --   2. It curves a long way in total. A bolt that ends up 90 deg from where
    --      it was thrown is unmistakable no matter how gently it got there.
    --   3. It turns hard for its speed. The eye reads the RADIUS of the arc, not
    --      degrees per frame -- which is why one global degrees-per-frame is
    --      wrong: at speed 80 it is a lazy drift, at speed 300 it is a hook.
    --   4. It keeps adjusting right up to contact, so it looks magnetic.
    --   5. It leads by an implausible amount and visibly flies at empty space.
    --
    -- Every knob below exists for one of those five, and each one trades hit
    -- consistency for believability in a way that can be turned down. Being
    -- wrong here does not cost a shot, it costs the account -- so the defaults
    -- are the conservative end, and a missed shot on a badly aimed throw is the
    -- intended behaviour, not a failure.
    -- ---------------------------------------------------------------------

    -- Reference turn rate, in degrees per frame, for a bolt travelling at
    -- LEGIT_REF_SPEED. The effective clamp scales INVERSELY with the body's own
    -- Speed so the arc radius stays roughly constant across kits -- see
    -- steerClampFor(). This replaces a flat 12 deg/frame applied to a speed-80
    -- PROGRAMMER bolt and a speed-250 MUSKETEER bolt alike.
    --
    -- 7 -> 10, raised on measurement, not feel: clamp utilisation was a median of
    -- 80% of frames and p90 of 100%, i.e. the bolt was pinned against this limit
    -- for most of most flights. When the clamp is saturated it is the bottleneck
    -- and nothing else matters -- raising PN_GAIN or the deviation budget while
    -- pinned here changes nothing.
    --
    -- 10 -> 13. Still pinned after the last raise, and harder than before: of 28
    -- flights on the 16:39 build, clamp utilisation was a MEDIAN of 100% and a p90
    -- of 100% -- every flight spent essentially every steered frame against this
    -- limit. 14 of those 28 ended `froze=missed`, which is what a saturated clamp
    -- looks like from the outside: the bolt is turning as hard as it is allowed
    -- and still cannot get there. This is the binding constraint, so it is the
    -- one that buys tracking. Deviation was NOT binding (median 2, p90 25 against
    -- a 40 budget, one single `froze=dev`), so raising that alone would have done
    -- nothing.
    maxSteerDegPerFrame = 13,

    -- (1) Fly straight out of the muzzle for this long. The single most visible
    -- tell, and the cheapest to remove: the bolt leaves along the direction the
    -- player actually aimed, and only then begins to correct.
    legitMuzzleDelay = 0.10,

    -- (1) and (3) Ease steering authority in over this long, starting after the
    -- muzzle delay, instead of applying the full clamp on the first steered
    -- frame. A step change in curvature is itself a tell.
    legitRampSec = 0.25,

    -- (2) Hard ceiling on TOTAL angular deviation from the direction the bolt
    -- was thrown. Once spent, steering stops for the rest of the flight and the
    -- bolt flies straight -- so a badly aimed shot misses, exactly as it would
    -- have. This is the strongest single lever and the one that keeps a heatseek
    -- looking like good aim rather than software.
    -- 30 -> 40. Ten flights in the last run ended `froze=dev`, meaning they spent
    -- the whole budget and gave up while still needing to turn; observed dev had
    -- a p90 of 31 against a 30 cap, so the budget was the second binding limit.
    --
    -- 40 degrees is still a curve rather than a hook, and it is spread over the
    -- WHOLE flight -- total deviation says nothing about instantaneous curvature,
    -- which is what maxSteerDegPerFrame governs and what the eye actually reads.
    -- Above roughly 45 a bolt starts visibly ending up somewhere it was never
    -- thrown, which is the point of having a budget at all.
    --
    -- 40 -> 44, and ONLY to preserve the FOV invariant as lockFovDeg went
    -- 34 -> 38 (38 * 1.15 = 43.7). It is not the binding constraint and raising
    -- it does not by itself buy tracking: observed dev was a median of 2 and a
    -- p90 of 25 against the 40 cap, with exactly one flight in 28 ending
    -- `froze=dev`. Kept under 45 on purpose.
    -- 44 -> 55, raised ON INSTRUCTION to buy lock coverage. This is the setting
    -- that gates the cone (pickTarget clamps the cone to budget - margin), so
    -- 44 was capping the cone at 38 deg and that was the reason GAMBLER was
    -- taking almost no locks.
    --
    -- This is the one change here with a real legitness cost, and it is a
    -- deliberate trade, not an oversight: past about 45 deg a bolt can end up
    -- somewhere it visibly was not thrown. It is also the first knob to wind
    -- back if shots start looking wrong -- `hstune legitMaxTotalDeviationDeg 44`
    -- and `hstune lockFovDeg 38` restores the previous behaviour exactly.
    --
    -- Note the deviation budget still STOPS steering when spent, so a badly
    -- aimed shot still misses. This widens what counts as recoverable; it does
    -- not remove the guard.
    legitMaxTotalDeviationDeg = 55,

    -- See RETURN_ARM_DIST. Distance from the owner at which a returning body
    -- starts handing steering back; authority reaches zero at RETURN_TRIP_DIST
    -- (8 studs), where the flight ends anyway. 20 gives roughly a third of a
    -- second of fade on a speed-70 JESTER ball -- long enough that the handover
    -- is not a step, short enough that it is not giving up the return leg.
    legitReturnFadeStuds = 20,

    -- (4) Stop steering inside this distance of the target. Terminal-phase
    -- corrections are what read as magnetic; by this range the shot has already
    -- either worked or not.
    legitTerminalFreezeStuds = 10,

    -- (5) Cap on predictive lead, in seconds of target velocity. Was effectively
    -- 1.0s, which on a sprinting target aims at open ground far enough ahead that
    -- the bolt visibly flies at nothing and then converges.
    predictiveLead = true,
    legitMaxLeadSec = 0.30,

    -- Master switch. false = the old behaviour (immediate full-authority
    -- steering, no deviation budget). Kept so the difference can be measured
    -- rather than argued about.
    legitMode = true,

    losRecheckSec = 0.1,

    -- Mid-flight: drop the lock if LOS breaks. Matches the old modules.
    requireLos = true,

    -- Initial lock: if nothing in the cone has clear LOS, still take the best
    -- in-cone target. The old modules did exactly this (their `bestCone` path,
    -- logged as no-LOS) and it is a meaningful share of real locks -- a target
    -- behind a railing or mid-corner is usually hittable by the time the bolt
    -- arrives. Refusing it made the engine strictly weaker than what it replaced.
    allowNoLosLock = true,

    -- Hard ceiling on how long we will steer one body. Without this a bolt
    -- that never finds a target keeps its mover refreshed and can orbit the
    -- map before connecting with something unrelated.
    maxFlightSec = 8,

    -- Shared damage ledger: ignore repeat damage on the same victim inside
    -- this window, so reach and heatseek cannot double-dip (and amp with them).
    damageCooldown = 0.15,

    debug = false,
}

-- Shipped defaults, captured before anything can change them, so the state file
-- can record only what the user actually tuned.
local T_DEFAULTS = {}
for k, v in pairs(T) do T_DEFAULTS[k] = v end

local MOVER_MAX_FORCE = Vector3.new(1e7, 1e7, 1e7)

-- The game drives real projectiles with a LinearVelocity at 1e9 per axis
-- (0704.lua:711). Writing our 1e7 into it does not just fail to steer -- it
-- WEAKENS the mover, so gravity and drag start winning and the bolt sags.
-- Match the game's number when we are writing into the game's own mover.
local LV_MAX_FORCE = Vector3.new(1e9, 1e9, 1e9)
local NPC_FOLDERS = { "NPC's", "NPCs", "AIs", "Dummys", "Dummies" }
local CLASSIFY_HEARTBEATS = 3
-- Only used when no mover exists yet. Frost CreateBodyVelocity is actually a
-- LinearVelocity under an Attachment (0705.lua:698) and often appears one
-- frame after CreateProjectile returns — ensureMover situation 3 switches to
-- it. Prefer starting steer immediately over a blind multi-frame wait: short
-- kits (FROST E 15–70ms) cannot spare ~33ms.
local MOVER_WAIT_HEARTBEATS = 1
local OWNER_WAIT_SEC = 0.25
local CORE_TAG = "CsCoreTag"


-- Boomerang detection: the body must travel at least RETURN_ARM_DIST away
-- before coming back within RETURN_TRIP_DIST counts as "returning".
-- Degrees of deviation budget a lock must leave unspent to be worth taking.
--
-- Measured from the GAMBLER 03:28 session: locks at 40.4-41.3 degrees spent
-- 45-46 degrees of budget, so the real cost of a lock runs about 5 degrees over
-- its angle -- curved path plus lead. 6 gives that a little room. Too small and
-- edge locks freeze mid-flight (the bug this fixes); too large and the cone
-- shrinks for no reason, which shows up as `out of cone` climbing in the reject
-- histogram with no matching drop in `froze=dev`.
local LOCK_DEV_MARGIN = 6

-- Half-width, in studs, of the cylinder down the middle of the lock cone. A
-- target within this of the aim line is lockable regardless of its ANGLE, which
-- is what makes close-range targets acquirable at all -- see scanCone.
--
-- 8 studs is a bit under two character widths, so it covers "they are basically
-- in front of me" without reaching a second person standing beside them. It is
-- deliberately small: this rule exists to fix a geometry blind spot, not to
-- widen the cone generally, and every stud of it is a lock the angular cone
-- would have refused.
-- 8 -> 16. Reported live: GAMBLER was taking essentially no locks. 8 studs is
-- about two character widths and only rescued targets almost exactly on the aim
-- line; 16 covers "they are in front of me" as a player actually means it. Still
-- bounded in studs, so at 55 studs it is worth 17 deg and cannot become a
-- wide-angle lock at distance.
local CLOSE_LOCK_STUDS = 16

local RETURN_ARM_DIST = 25
local RETURN_TRIP_DIST = 8
-- Outer edge of the return fade band. A tunable rather than a constant for two
-- reasons: cs_core.lua is at the 200 top-level-local ceiling so a new `local`
-- here would refuse the whole engine, and this is a look-and-feel number that
-- wants `hstune legitReturnFadeStuds N` mid-match rather than a rebuild.
-- Between this and RETURN_TRIP_DIST our steering authority fades to zero, so
-- the game's return script inherits a coasting body instead of a turning one.

-- Mid-flight LOS does not arm until the body has travelled this far from where
-- it spawned. See the arm-on-travel note in the steer loop.
local LOS_ARM_STUDS = 8

--------------------------------------------------------------------------
-- 2b. PERF BUDGET AND BENCHMARKING
--
-- Everything the engine does happens on the client's frame, and the workload
-- scales with how many bodies are in the air: two allies on a five-bolt kit is
-- ten steer coroutines, each raycasting for line of sight and each re-scanning
-- for a target. There was no measurement of any of it, so "the script crashes
-- our game" had no numbers behind it and no way to tell which part was costing
-- the frames.
--
-- Two jobs here:
--
--  1. MEASURE. Named spans with call count, total ms, worst single call and
--     ms-per-frame. os.clock() only, no allocation inside a span, so measuring
--     does not distort what it measures. `Core.benchReport()` prints it and the
--     `bench` command surfaces it.
--
--  2. ADAPT. A rolling FPS estimate picks a tier, and the tier scales the work:
--     how often line of sight is re-checked, how many echoes a cast may forge,
--     and whether steering runs every frame or every other frame. The engine
--     gives up accuracy before it gives up the frame rate -- a bolt that hooks a
--     little less is a fair trade for a game that does not stutter, and it is
--     also the more legit-looking failure mode.
--
-- Tier thresholds are hysteretic (drop at one FPS, recover at a higher one) so a
-- frame rate sitting on a boundary cannot oscillate the whole engine's
-- behaviour every second.
--------------------------------------------------------------------------

local PERF_FPS_ALPHA = 0.1          -- EMA weight for the frame-rate estimate
local PERF_TIER_REVIEW_SEC = 1.0

local perf = {
    enabled = true,
    fps = 60,
    worstFrameMs = 0,
    engineMsThisFrame = 0,
    engineMsPeak = 0,
    engineMsEma = 0,
    frames = 0,
    tier = "full",
    tierChanges = 0,
    lastTierAt = 0,
    spans = {},                     -- [label] = { n, total, max, frameTotal }
    startedAt = os.clock(),
}

Core.perf = perf

-- Tier table. `los` multiplies the LOS re-check interval, `cast` caps echoes per
-- cast, `steerEvery` steers 1-in-N frames.
local PERF_TIERS = {
    full    = { los = 1.0, cast = 99, steerEvery = 1, dropBelow = 45 },
    reduced = { los = 2.0, cast = 2,  steerEvery = 1, dropBelow = 28, recoverAbove = 52 },
    minimal = { los = 4.0, cast = 1,  steerEvery = 2, recoverAbove = 34 },
}

function Core.perfTier() return PERF_TIERS[perf.tier] end

-- Open a span. Returns the clock to hand back to perfEnd. Deliberately not a
-- closure-taking wrapper: a wrapper allocates a closure per call, and these are
-- the hottest paths in the engine.
local function perfBegin()
    if not perf.enabled then return nil end
    return os.clock()
end

local function perfEnd(label, t0)
    if not t0 then return end
    local ms = (os.clock() - t0) * 1000
    local s = perf.spans[label]
    if not s then
        s = { n = 0, total = 0, max = 0, frameTotal = 0 }
        perf.spans[label] = s
    end
    s.n = s.n + 1
    s.total = s.total + ms
    s.frameTotal = s.frameTotal + ms
    if ms > s.max then s.max = ms end
    perf.engineMsThisFrame = perf.engineMsThisFrame + ms
end

Core.perfBegin = perfBegin
Core.perfEnd = perfEnd

-- Called once per Heartbeat from the sweep, which already runs every frame.
local function perfFrame(dt)
    perf.frames = perf.frames + 1

    if dt and dt > 0 then
        local fps = 1 / dt
        perf.fps = perf.fps + (fps - perf.fps) * PERF_FPS_ALPHA
        local frameMs = dt * 1000
        if frameMs > perf.worstFrameMs then perf.worstFrameMs = frameMs end
    end

    local em = perf.engineMsThisFrame
    if em > perf.engineMsPeak then perf.engineMsPeak = em end
    perf.engineMsEma = perf.engineMsEma + (em - perf.engineMsEma) * PERF_FPS_ALPHA
    perf.engineMsThisFrame = 0
    for _, s in pairs(perf.spans) do s.frameTotal = 0 end

    local now = os.clock()
    if now - perf.lastTierAt < PERF_TIER_REVIEW_SEC then return end
    perf.lastTierAt = now

    local was = perf.tier
    local fps = perf.fps
    if perf.tier == "full" then
        if fps < PERF_TIERS.full.dropBelow then perf.tier = "reduced" end
    elseif perf.tier == "reduced" then
        if fps < PERF_TIERS.reduced.dropBelow then
            perf.tier = "minimal"
        elseif fps > PERF_TIERS.reduced.recoverAbove then
            perf.tier = "full"
        end
    else
        if fps > PERF_TIERS.minimal.recoverAbove then perf.tier = "reduced" end
    end

    if perf.tier ~= was then
        perf.tierChanges = perf.tierChanges + 1
        logwarn("perf", ("perf tier %s -> %s (fps=%.0f engine=%.2fms/frame)")
            :format(was, perf.tier, fps, perf.engineMsEma))
    end
end

function Core.resetBench()
    perf.spans = {}
    perf.worstFrameMs = 0
    perf.engineMsPeak = 0
    perf.frames = 0
    perf.tierChanges = 0
    perf.startedAt = os.clock()
    return true
end

-- Snapshot for the panel and the `bench` command.
function Core.bench()
    local rows = {}
    for label, s in pairs(perf.spans) do
        rows[#rows + 1] = {
            label = label,
            n = s.n,
            total = s.total,
            avg = s.n > 0 and (s.total / s.n) or 0,
            max = s.max,
            perFrame = perf.frames > 0 and (s.total / perf.frames) or 0,
        }
    end
    -- Sorted by total cost: the answer to "what is eating my frames" is the top
    -- row, and it must not depend on hash order.
    table.sort(rows, function(a, b) return a.total > b.total end)
    return {
        elapsed = os.clock() - perf.startedAt,
        frames = perf.frames,
        fps = perf.fps,
        worstFrameMs = perf.worstFrameMs,
        engineMsPeak = perf.engineMsPeak,
        engineMsEma = perf.engineMsEma,
        tier = perf.tier,
        tierChanges = perf.tierChanges,
        activeFlights = 0,      -- filled by the caller; registry is defined below
        rows = rows,
    }
end

function Core.benchReport()
    local b = Core.bench()
    b.activeFlights = Core.activeCount()
    Log.info(("BENCH %.1fs frames=%d fps=%.0f worstFrame=%.1fms engine=%.2fms/frame (peak %.2f) tier=%s changes=%d flights=%d")
        :format(b.elapsed, b.frames, b.fps, b.worstFrameMs,
            b.engineMsEma, b.engineMsPeak, b.tier, b.tierChanges, b.activeFlights))
    if #b.rows == 0 then
        Log.info("BENCH no spans recorded — nothing has fired yet")
    end
    for _, r in ipairs(b.rows) do
        Log.info(("BENCH   %-18s n=%-6d total=%8.1fms avg=%6.3fms max=%6.2fms %6.3fms/frame")
            :format(r.label, r.n, r.total, r.avg, r.max, r.perFrame))
    end
    return b
end

--------------------------------------------------------------------------
-- 3. TARGET PIPELINE
--------------------------------------------------------------------------

-- CheckAlive (0704.lua:248)
local function statsHP(c)
    local st = c and c:FindFirstChild("Stats")
    local v = st and st:FindFirstChild("CurrentHP")
    return v and v.Value or nil
end

local function isFainted(c)
    if not c then return true end
    if c:GetAttribute("Fainted") == true then return true end
    local fv = c:FindFirstChild("Fainted")
    if fv and fv:IsA("BoolValue") and fv.Value then return true end
    local st = c:FindFirstChild("Stats")
    local sf = st and st:FindFirstChild("Fainted")
    if sf and sf:IsA("BoolValue") and sf.Value then return true end
    return false
end

-- Mirrors CheckTeam (0704.lua:233) exactly: raw Team.Value ==, then
-- Player.Team with a Neutral guard, then FriendlyDummy. No blank/neutral
-- exemption -- in FFA characters carry no Team child at all, so the first
-- branch is simply skipped. An earlier session "improved" this and was wrong.
local function sameTeam(aChar, bChar)
    if not aChar or not bChar then return false end
    local at = aChar:FindFirstChild("Team")
    local bt = bChar:FindFirstChild("Team")
    if at and bt and at:IsA("StringValue") and bt:IsA("StringValue") then
        return at.Value == bt.Value
    end
    local ap = Players:GetPlayerFromCharacter(aChar)
    local bp = Players:GetPlayerFromCharacter(bChar)
    if ap and bp and ap.Team == bp.Team and ap.Team ~= nil and ap.Neutral ~= true then
        return true
    end
    return false
end

local function isFriendlyDummy(c)
    local fd = c and c:FindFirstChild("FriendlyDummy")
    return fd ~= nil and fd:IsA("BoolValue")
end

-- HasEffect (0003.lua:895)
local function headTag(c, name)
    local head = c and c:FindFirstChild("Head")
    return head and head:FindFirstChild(name) or nil
end

-- CheckSafe (0003.lua:4715). spawn_state.txt shows Safe = 1 on a fresh spawn,
-- so everyone who just respawned is immune while still looking lockable.
local function isSafe(c)
    local st = c and c:FindFirstChild("Stats")
    local sv = st and st:FindFirstChild("Safe")
    return sv ~= nil and sv.Value > 0
end

-- HitboxStatusEffectCheck (0704.lua:351). Both in a Challenge: hittable only
-- if the duel pairs the two of us. Exactly one: never hittable, by either.
local function challengeBlocked(myChar, c)
    local mine, theirs = headTag(myChar, "Challenge"), headTag(c, "Challenge")
    if mine and theirs then
        local a = mine:FindFirstChild("Against")
        local b = theirs:FindFirstChild("Against")
        return not ((a and a.Value == c) or (b and b.Value == myChar))
    end
    return (mine or theirs) ~= nil
end

-- Reflection-class dimension split: both parties must be in the same plane.
local function alternateBlocked(myChar, c)
    return (headTag(myChar, "Alternate") ~= nil) ~= (headTag(c, "Alternate") ~= nil)
end

-- @PairID (attributes_catalog.txt) marks the partner in Pair Elimination.
-- Deliberately kept out of sameTeam: CheckTeam never reads it, so mirroring it
-- there would desync us from the collision oracle. Targeting filter only.
local function samePair(myChar, c)
    local mp = Players:GetPlayerFromCharacter(myChar)
    local tp = Players:GetPlayerFromCharacter(c)
    if not mp or not tp then return false end
    local a, b = mp:GetAttribute("PairID"), tp:GetAttribute("PairID")
    return a ~= nil and a == b
end

-- FRIENDS WHITELIST
--
-- Ported here from the retired ally echo module, which was the only place it
-- ever lived -- so the panel's "friends whitelist" toggle and the `friend` /
-- `friends` commands drove a module that, once the engine took over ally assist,
-- was no longer steering anything. The toggle read ON and changed nothing.
--
-- Keyed by exact Player.Name, not by the prefix match Core.isAllyPlayer uses:
-- an ally name is something you type and want expanded, whereas a whitelist
-- entry decides whether a real person gets shot at, and a prefix there would
-- silently protect everyone whose name starts the same way.
local friends = {
    on = false,
    names = {},     -- [exact Player.Name] = true
}

function Core.setFriendsWhitelistOn(on)
    friends.on = on and true or false
    logx("cfg", "friends whitelist " .. (friends.on and "ON" or "off"))
    return friends.on
end
function Core.friendsWhitelistOn() return friends.on end
function Core.addFriend(name)
    if not name or name == "" then return false end
    friends.names[name] = true
    return true
end
function Core.removeFriend(name)
    if not name then return false end
    friends.names[name] = nil
    return true
end
function Core.isFriend(name)
    return name ~= nil and friends.names[name] == true
end
function Core.friendsList()
    local out = {}
    for n in pairs(friends.names) do out[#out + 1] = n end
    table.sort(out)
    return out
end

-- PROTECTED IDENTITIES — hardcoded, not configurable, not a whitelist.
--
-- Every copy of this engine refuses to LOCK these names. It exists because the
-- portable build is handed to other people: when the holder assists a third
-- player, the echo bolts forged for that assist are owned by the holder's
-- client and steer at whatever the cone finds -- which in FFA legitimately
-- includes the person who gave them the script.
--
-- Deliberately NOT the friends whitelist, and not reachable from any command or
-- panel row. A toggle is something the holder can turn off, forget, or fail to
-- restore from a config file they do not have; the whole value here is that it
-- cannot be any of those. On Core rather than a chunk-level `local` because
-- cs_core.lua is at Luau's 200 top-level-local ceiling.
--
-- Player.Name only. Display names are not unique and are not what the engine
-- enumerates, so matching one would be both spoofable and wrong.
--
-- SCOPE, honestly: this stops GUIDANCE. It does not make anyone invincible.
-- The holder's ordinary attacks are created and resolved by the game's own
-- handler (0463.lua:12) and never pass through here -- a shot aimed at you by
-- hand still lands. What it removes is bolts CURVING into you.
Core.protectedNames = {
    keeley7823 = true,
}

function Core.isProtected(c)
    local p = c and Players:GetPlayerFromCharacter(c)
    return p ~= nil and Core.protectedNames[string.lower(p.Name)] == true
end

-- friendBlocked() was deleted here, not disabled: rejectReason was its only
-- caller, and "no exceptions" removed that call. A predicate nothing asks is
-- dead code that still loads (CS_CONSTRAINTS 5b).
--
-- The friends LIST itself is left intact above (addFriend / friendsList / the
-- `friend` command / the panel toggle) but it no longer influences targeting at
-- all, which means the whitelist toggle now reads ON and changes nothing --
-- precisely the bug that porting it into the engine was meant to fix. It should
-- be removed outright across cs_core, cs_admin and the AIM panel; that spans
-- three files and the user's UI, so it is flagged rather than done here.

-- nil = valid target, otherwise a short reason string for the histogram.
-- `ctx` carries optional per-shot exclusions (ally echo passes the shooter).
function Core.rejectReason(c, myChar, ctx)
    if not c or not c.Parent then return "orphaned" end
    if not c:IsA("Model") then return "not model" end
    if c == myChar then return "self" end
    if ctx then
        if ctx.exclude and ctx.exclude[c] then return "excluded" end
        if ctx.shooter and c == ctx.shooter then return "shooter" end
    end
    -- ONE hard exclusion, and it is not a soft one. See Core.protectedNames:
    -- a fixed identity that no build may lock, so that handing the portable to
    -- somebody does not hand them a homing weapon aimed at you. It reports its
    -- own reason, so unlike the whitelist it can never refuse a target silently
    -- -- `reject: protected` in the histogram names it every time.
    if Core.isProtected(c) then return "protected" end

    -- NO OTHER SOFT EXCLUSIONS. Instructed 2026-07-31: "Heatseek should work
    -- against friends and allies and everything. No exceptions." That still
    -- stands for everyone who is not in the list above -- the two are different
    -- things: this is a build-time constant, those were user-facing lists that
    -- made whole players permanently unhittable by accident, across sessions,
    -- silently, because ally and friend names persisted.
    --
    -- The `friend` and `ally` rejects that sat here are DELETED, not disabled
    -- (CS_CONSTRAINTS 5b). Both were OUR policy, not the game's:
    --
    --  * `friend` came from the retired ally-echo module -- the only thing
    --    keeping guidance off a whitelisted name.
    --  * `ally` was added earlier today, because with the whitelist off a named
    --    ally in the cone was a valid target and volleys steered into them.
    --
    -- Both are wrong for how this game actually plays. FFA characters carry no
    -- Team child, so the person you assist is simultaneously a legitimate
    -- opponent -- and refusing to lock them made a whole player permanently
    -- unhittable, silently, ACROSS SESSIONS, because ally names persist.
    -- Assisting someone's bolts and being able to shoot them are independent.
    --
    -- Deliberately KEPT below: same team, partner, safe, challenge, alternate.
    -- Those are not policy, they are the game's own collision oracle (CheckTeam
    -- 0704.lua:233, CheckSafe 0003.lua:4715, HitboxStatusEffectCheck
    -- 0704.lua:351). The server refuses those hits outright, so locking one does
    -- not gain a target, it spends the whole volley on a body that cannot be
    -- damaged. CS_CONSTRAINTS section 5: never target what the game cannot let
    -- you hit.
    if isFriendlyDummy(c) then return "friendly dummy" end
    if myChar and sameTeam(myChar, c) then return "same team" end
    if myChar and samePair(myChar, c) then return "partner" end
    if isSafe(c) then return "safe" end
    if myChar and challengeBlocked(myChar, c) then return "challenge" end
    if myChar and alternateBlocked(myChar, c) then return "alternate" end
    if isFainted(c) then return "fainted" end
    local hp = statsHP(c)
    if hp ~= nil and hp <= 0 then return "hp<=0" end
    local hum = c:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health <= 0 then return "dead" end
    -- No damage surface at all -> never hittable, so a lock on it is always a
    -- wasted volley. Both HP branches above are `if present and dead`, so a
    -- model carrying NEITHER Stats.CurrentHP NOR a Humanoid fell through every
    -- gate and was rated a perfectly good target.
    --
    -- workspace["NPC's"].RandomizerBlocker is exactly that: a rig with a
    -- HumanoidRootPart that 0196.lua slides up and down to block the Randomizer
    -- stand. It is in NPC_FOLDERS, so enumerateCandidates picks it up every
    -- rebuild. In cs_core.log it is the `nearest` on EVERY no-lock line of the
    -- 18:32 and 18:40 windows, and it took 20 of the 529 locks outright
    -- (NormalDummy1-4 and SuperDummy add 38 more from the same folder).
    -- Both HP names come from the game: Stats.CurrentHP is what
    -- ExecuteKillEffect writes (0638.lua:271) and what spawn_state.txt reports
    -- as the local HP source.
    if hp == nil and not hum then return "not damageable" end
    -- ...and a Humanoid ALONE is not a damage surface either. This is the same
    -- bug one gate wider, and it is why RandomizerBlocker survived the fix
    -- above: the rig HAS a Humanoid, so `hp == nil and not hum` is false and it
    -- sailed through. It has been the `nearest` on essentially every no-lock
    -- line since, at 340-410 studs, which makes the whole diagnostic lie --
    -- `valid=13 far=13` reads as "thirteen people, all too far away" when the
    -- real content is "thirteen map props and not one reachable player".
    --
    -- The game's HP system is Stats-based: Stats.CurrentHP is what
    -- ExecuteKillEffect writes (0638.lua:271) and what spawn_state.txt reports
    -- as the local HP source. Every real combatant, player or AI, therefore
    -- carries one. Scenery rigs animated by a LocalScript (0196.lua slides this
    -- one up and down to block the Randomizer stand) carry a Humanoid for the
    -- rig and nothing else.
    --
    -- So: a model that is not a PLAYER character must present a Stats HP value
    -- to be worth a lock. Players are exempt because their Stats folder can
    -- legitimately be mid-replication on a fresh join, and refusing a real
    -- person over a race is far worse than admitting a prop.
    if hp == nil and not Players:GetPlayerFromCharacter(c) then
        return "npc no stats"
    end
    if not c:FindFirstChild("HumanoidRootPart") then return "no hrp" end
    return nil
end

function Core.isValidTarget(c, myChar, ctx)
    return Core.rejectReason(c, myChar or char(), ctx) == nil
end

-- Candidate enumeration, cached.
--
-- This is the single most expensive thing the engine does, and it used to run
-- raw on every call. pickTarget scans twice (hard cone, then soft-widened), and
-- every projectile and every ally bolt calls pickTarget -- so one five-bolt
-- volley from each of two allies was twenty full enumerations inside a couple of
-- frames, each one walking every player, five NPC folders and, worst of all,
-- workspace:GetChildren() in full with two FindFirstChild calls per child.
-- workspace holds the whole map.
--
-- Two caches with different lifetimes, because the two halves change at
-- completely different rates:
--
--  * Players and their characters: one frame. Cheap to rebuild, and a character
--    that respawns mid-volley must not be steered at for long.
--  * Loose workspace AI/Dummy models: NPC_STALE_SEC. The map's model list does
--    not change between frames, and this is the scan that costs.
--
-- Both tables are rebuilt in place rather than reallocated, so a busy volley
-- does not hand the garbage collector a table per bolt.
local NPC_STALE_SEC = 2.0
local candCache = {}            -- reused output list
local candSeen = {}             -- reused dedupe set
local candBuiltAt = 0
local npcCache = {}             -- reused list of loose workspace models
local npcBuiltAt = 0

local function rebuildNpcCache()
    table.clear(npcCache)
    for _, folderName in ipairs(NPC_FOLDERS) do
        local folder = workspace:FindFirstChild(folderName)
        if folder then
            for _, ch in ipairs(folder:GetChildren()) do
                npcCache[#npcCache + 1] = ch
            end
        end
    end
    -- CheckIfAI (0637.lua:73). The expensive one: a full workspace walk.
    for _, ch in ipairs(workspace:GetChildren()) do
        if ch:IsA("Model") and (ch:FindFirstChild("AI") or ch:FindFirstChild("Dummy")) then
            npcCache[#npcCache + 1] = ch
        end
    end
    npcBuiltAt = os.clock()
end

function Core.enumerateCandidates()
    local now = os.clock()
    -- One rebuild per frame at most. Two scan passes inside one pickTarget, and
    -- every bolt of a volley inside the same frame, all share this.
    if now - candBuiltAt < (1 / 60) and #candCache > 0 then
        return candCache
    end

    local t0 = perfBegin()
    table.clear(candCache)
    table.clear(candSeen)

    local function consider(model)
        if not model or candSeen[model] or not model:IsA("Model") then return end
        candSeen[model] = true
        candCache[#candCache + 1] = model
    end

    -- A player with no Character is INVISIBLE to every diagnostic we have:
    -- consider() drops nil before rejectReason runs, so they are absent from the
    -- candidate list, absent from the reject histogram, and absent from the
    -- no-lock line. "The engine never even considered them" and "the engine
    -- refused them" look identical from the log, and they have opposite fixes.
    -- Counted here so the no-lock line can say which one happened.
    S.noCharPlayers = 0
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then
            if p.Character then
                consider(p.Character)
            else
                S.noCharPlayers = S.noCharPlayers + 1
            end
        end
    end

    if now - npcBuiltAt > NPC_STALE_SEC then rebuildNpcCache() end
    for _, ch in ipairs(npcCache) do
        -- Cached instances can be destroyed between rebuilds; consider() only
        -- checks IsA, so the parent check has to happen here.
        if ch.Parent then consider(ch) end
    end

    candBuiltAt = now
    perfEnd("enumerate", t0)
    return candCache
end

--------------------------------------------------------------------------
-- 4. LINE OF SIGHT
--------------------------------------------------------------------------

-- Reused across every LOS call.
--
-- This used to allocate a RaycastParams, an exclusion table AND the folder-name
-- table below on every single call -- and it is called once per in-cone candidate
-- per scan pass, twice per pickTarget, per bolt. That is three allocations per
-- candidate, thrown away immediately: the engine's largest source of garbage,
-- and garbage collection is exactly what a frame-rate complaint feels like.
--
-- Safe to share because a raycast does not yield: nothing else can run between
-- filling this in and consuming it.
local LOS_FOLDERS = { "ClientProjectiles", "ClientEffects", "ClientProjectileGhost" }
local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
losParams.IgnoreWater = true
losParams.RespectCanCollide = true
local losList = {}

local function losExclude(myChar, tgtChar, ctx)
    table.clear(losList)
    if myChar then losList[#losList + 1] = myChar end
    if tgtChar then losList[#losList + 1] = tgtChar end
    -- The SHOOTER, for an ally echo.
    --
    -- This omission killed ally heatseek outright. An echo is spawned at the
    -- ally's muzzle -- inside their character -- so the very first line-of-sight
    -- ray, cast from the echo's own position, hit the ALLY and reported no LOS.
    -- The flight aborted on frame one with zero steer frames. Live evidence:
    -- 89 of 157 MEDIC ally flights ended "lost LOS" at t=0.01-0.02s, frm=0.
    --
    -- Same shape as the boomerang-guard bug: a rule written for a body launched
    -- from MY muzzle, applied unchanged to one launched from somebody else's.
    if ctx then
        if ctx.exclude then
            for inst in pairs(ctx.exclude) do
                losList[#losList + 1] = inst
            end
        end
        if ctx.shooter then losList[#losList + 1] = ctx.shooter end
    end
    for _, n in ipairs(LOS_FOLDERS) do
        local f = workspace:FindFirstChild(n)
        if f then losList[#losList + 1] = f end
    end
    return losList
end

local function aimPart(c)
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart")
        or c:FindFirstChild("UpperTorso")
        or c:FindFirstChild("Torso")
end

function Core.hasClearLos(fromPos, tgtChar, myChar, ctx)
    if not fromPos or not tgtChar or not tgtChar.Parent then return false end
    local aim = aimPart(tgtChar)
    if not aim then return false end
    local delta = aim.Position - fromPos
    local dist = delta.Magnitude
    if dist < 0.5 then return true end
    local t0 = perfBegin()
    losParams.FilterDescendantsInstances = losExclude(myChar, tgtChar, ctx)
    local hit = workspace:Raycast(fromPos, delta.Unit * dist, losParams)
    perfEnd("los", t0)
    return hit == nil
end

--------------------------------------------------------------------------
-- 5. LOCK SCORING
--------------------------------------------------------------------------

-- Where the search cone starts, and which way it points.
--
-- `ctx.originPos` / `ctx.originLook` override it for ALLY ECHOES, and getting this
-- wrong made ally heatseek structurally impossible rather than merely bad.
--
-- An echo is forged at the ALLY's muzzle, travelling in the direction the ALLY
-- aimed -- routinely 100+ studs from me and pointing somewhere else entirely. The
-- cone was still being built from MY camera, so the engine picked whatever was in
-- front of ME and handed the echo a target it would have to turn 60-90 degrees to
-- reach. The deviation budget is 30 degrees, so it could never get there: it
-- steered as far as it was allowed, missed, and then orbited. Every ally class
-- behaved the same way, which is why "ally heatseek does not work" was reported
-- for fighter, musket and medic alike.
--
-- Targeting from the echo's own geometry also picks the target the ally was
-- actually shooting at, which is both the plausible flight and the one worth
-- contributing damage to. We still own the body, so the hit still resolves to us.
-- MIRROR of the game's own CharCF (0003.lua:3808), branch for branch.
--
-- This is the oracle CreateProjectile uses when a caller passes no spawn CFrame
-- (0003.lua:3017), so it is where our shots actually get thrown. Do not
-- "simplify" it -- the same instruction that applies to CheckTeam applies here,
-- and for the same reason: a targeting axis that disagrees with the launch axis
-- produces confident locks the bolt can never fly to.
--
-- It was simplified once, on 2026-07-31, down to `HumanoidRootPart.CFrame`. That
-- is CharCF's LAST branch -- the fallback -- and taking it unconditionally threw
-- away the two that normally decide:
--
--   1. RotationType == CameraRelative -> camera yaw, flattened to XZ.
--   2. PlayerGui.Aim.Active -> Aim.TargetCFrame, the aim GUI, which is the
--      ordinary third-person aiming path and carries PITCH.
--
-- Symptom of getting it wrong: `no lock — cap=38 fov=49 valid=15 cone=0` on
-- every class at once. Plenty of hittable people, none of them in front of an
-- aim vector that was pointing wherever the character's body happened to face.
--
-- Written defensively (the Aim GUI may not exist yet on a fresh spawn) but the
-- ORDER is exact, because the order is the contract.
local UserGameSettings = UserSettings():GetService("UserGameSettings")

local function gameAimCFrame(mc, root)
    if not (mc and root) then return nil end

    -- Both spellings, exactly as the game checks them.
    local noTurn = mc:FindFirstChild("NoTurn") or mc:FindFirstChild("NoTurnNew")

    -- Branch 1: camera-relative rotation. Camera yaw only -- the Vector3(1,0,1)
    -- multiply is the game deliberately discarding pitch, so we discard it too.
    if not noTurn then
        local cam = workspace.CurrentCamera
        local ok, cf = pcall(function()
            if UserGameSettings.RotationType == Enum.RotationType.CameraRelative and cam then
                local flat = cam.CFrame.LookVector * Vector3.new(1, 0, 1)
                if flat.Magnitude > 1e-4 then
                    return CFrame.new(root.Position, root.Position + flat.Unit)
                end
            end
            return nil
        end)
        if ok and cf then return cf end
    end

    -- Branch 2: the Aim GUI. This is the one the simplification lost, and it is
    -- the path that carries pitch -- aiming up or down is expressed here and
    -- nowhere else.
    if not noTurn then
        local ok, cf = pcall(function()
            local gui = lp:FindFirstChild("PlayerGui")
            local aim = gui and gui:FindFirstChild("Aim")
            local active = aim and aim:FindFirstChild("Active")
            local target = aim and aim:FindFirstChild("TargetCFrame")
            if active and active.Value == true and target then return target.Value end
            return nil
        end)
        if ok and cf then return cf end
    end

    -- Branch 3 (mobile MobileCamera) is deliberately not mirrored: this runs on
    -- a desktop executor, UIS.TouchEnabled is false, and a branch that can never
    -- be taken is a branch that can never be verified.

    -- Branch 4: the fallback the simplification mistook for the rule.
    return root.CFrame
end

local function aimOrigin(ctx)
    if ctx and ctx.originPos and ctx.originLook then
        return ctx.originPos, ctx.originLook
    end
    -- BOTH position and direction come from the CHARACTER. Mirror the game's own
    -- spawn oracle; do not substitute the camera for either.
    --
    -- The game never launches a projectile along the camera. Two helpers decide
    -- where a bolt is thrown and both are character-based:
    --
    --   Cfr()     -> HumanoidRootPart.CFrame, verbatim (0003.lua:3805). This is
    --               what class abilities pass as the spawn CFrame -- 29 call
    --               sites across the dump, e.g. 0607.lua:175, 0608.lua:53.
    --   CharCF()  -> CreateProjectile's DEFAULT when the caller passes no CFrame
    --               (0003.lua:3017). Its camera branch is
    --                   CFrame.new(pos, pos + cam.LookVector * Vector3(1,0,1).Unit)
    --               (0003.lua:3812) -- camera YAW only, pitch multiplied out --
    --               and it otherwise returns the HumanoidRootPart CFrame.
    --   MouseCfr() -> Mouse.Origin. Used by ZERO class scripts.
    --
    -- So the flight axis is the character's facing, horizontal, in every path.
    --
    -- Using cam.CFrame.LookVector here made the search axis diverge from the
    -- flight axis the moment they stopped agreeing, which right-click-drag does
    -- by design: orbiting the camera does not turn the character. Looking down
    -- at the map from above while the character still faced an enemy pointed the
    -- whole cone at the floor -- the engine searched somewhere the bolt was never
    -- going to fly, so it locked nothing, or locked something it then burned the
    -- entire deviation budget trying to turn toward.
    --
    -- Discarding camera pitch is CORRECT here rather than a loss of precision:
    -- the game discards it too (the Vector3(1,0,1) above), and a root part on a
    -- standing character carries no pitch of its own. A cone that tilts when the
    -- bolt cannot is a cone that lies.
    --
    -- The ORIGIN argument below is a separate, older fix and still stands.
    --
    -- In third person the camera sits roughly 12-15 studs BEHIND the character,
    -- and the bolt spawns at the muzzle. Every distance in targeting -- the
    -- lockCap test above all -- was therefore being measured from a point well
    -- behind the thing actually doing the travelling, so the bolt's whole range
    -- budget had the camera offset subtracted from it before the search even
    -- started.
    --
    -- This is invisible on a long bolt and fatal on a short one, which is exactly
    -- the signature it presented with. MUSKETEER is range=500 (cap 550) and loses
    -- 2% of its search volume. RECON's `attack` is range=26 -- cap 28.6 -- so it
    -- lost around half, and the log shows every one of its casts ending
    -- `no target t=0.02s` while `out of range` climbed 200 counts in two seconds
    -- (16:48:21-22). SWORDMANCER (35), FIGHTER (40), MEDIC (60) sit in the same
    -- band. Same shape as the lockCap bug fixed on 2026-07-30: a distance budget
    -- being spent on something that is not the bolt's flight.
    --
    -- The ally echo path was already correct -- it passes ctx.originPos and
    -- ctx.originLook from the ally's own muzzle and facing, handled above, which
    -- is why only self shots were ever affected by any of this.
    local mc = char()
    local root = mc and mc:FindFirstChild("HumanoidRootPart")
    if root then
        local cf = gameAimCFrame(mc, root)
        return root.Position, (cf or root.CFrame).LookVector
    end
    -- No root: nothing of ours is being thrown anyway. The camera is NOT a
    -- fallback for direction -- guessing an axis the game does not use is worse
    -- than declining to lock, because a wrong axis still produces confident
    -- locks that the bolt then cannot fly to.
    return nil, nil
end

-- Range-driven cap. A bolt cannot hit something further away than it can fly.
--
-- This was `math.max(projRange, T.lockRange)` -- the LARGER of the two -- which is
-- correct only for long-range kits and catastrophic for short ones. MEDIC's
-- attack is range=60 and FIGHTER's E is range=40, and both were being given a
-- 170-stud lock cap: the engine locked targets three to four times further away
-- than the bolt could physically reach.
--
-- Every downstream symptom followed from that. The bolt flew its 40-60 studs at a
-- target 150 away and expired ("gone"), the line-of-sight ray had to cross 150
-- studs of map so it was routinely blocked ("lost LOS" -- 56 of 85 flights), and
-- the reject histogram filled with "out of range" from scanning a volume four
-- times too big. It presented as "heatseek does not work on MEDIC or FIGHTER"
-- while working fine on MUSKETEER, which is range=500 and so was never affected.
--
-- The previous comment is a fair warning in the other direction: an earlier
-- version used min(Range, 120) and capped long bolts at 120 while they flew 150+.
-- The fix for that was never "take the larger", it was "trust the body's own
-- Range", which is what this does. T.lockRange is now only the fallback for a
-- body that does not declare one.
-- OBSERVED REACH, per body name. `Range` is NOT the travel limit.
--
-- Measured 2026-07-31 across 78 flights: every body that expired naturally
-- ("flight end", i.e. it was not stopped by a hit, a lost target or LOS) flew
-- far past its declared Range --
--
--   FROST ability2      Range=35   flew 75-76   2.17x
--   NECROMANCER attack  Range=50   flew 87      1.74x
--   NECRO attackBullet  Range=70   flew 120     1.71x
--   COWBOY attack       Range=70   flew 100     1.43x
--
-- lockCap was Range * 1.1, so FROST E refused every target past 38 studs while
-- its bolt could reach 76. That is the whole of "FROST E does not work",
-- for self and for allies: the guidance was fine, the lock was told the bolt
-- was half as long as it is. It reads as a RANGE no-lock (`far>0 wide=0`), the
-- one shape the docs call "positioning, nothing to tune" -- which is why it
-- survived so long.
--
-- LEARNED, never guessed, and only ever WIDENED to a distance a body has
-- actually been seen to fly. A global multiplier was the obvious alternative
-- and is wrong: the ratio runs from 0.9 to 2.2 across bodies, so any single
-- constant either under-caps FROST or re-creates the 2026-07-30 lockCap bug on
-- ARCHER (Range=210), where scanning a volume four times too big filled the
-- histogram with `out of range` and blocked LOS across half the map.
--
-- Recorded ONLY from natural expiry. A flight that ended on a hit, a dead
-- target or lost LOS proves nothing about how far the body could have gone.
--
-- Keyed by CLASS + body name, never body name alone. `ability2` is FROST's E
-- (declares 35, flies 76) and also RANGER's (declares 100, flies 160). Under a
-- name-only key RANGER taught FROST a reach of 160, so FROST scanned to
-- cap=176 and locked targets its 76-stud bolt could never reach -- every such
-- flight ended `gone`. Same shape as the bug this table was added to fix, one
-- level up.
--
-- The key is built inline in both users rather than in a shared helper: this
-- chunk sits at Luau's 200-local-per-function ceiling, and one more top-level
-- `local` makes the whole engine fail to compile. `loadstring` then returns
-- nil and the only symptom is `engine: cs_core failed to load — attempt to
-- call a nil value` pointing at cs_admin's loadstring line. The bundled
-- luau-compile.exe does NOT enforce this, so the build reports clean.
local observedReach = {}

local function noteObservedReach(classKey, bodyName, studs)
    if not bodyName or not studs or studs <= 0 then return end
    local k = string.lower(tostring(classKey or "?") .. "/" .. bodyName)
    if studs > (observedReach[k] or 0) then
        observedReach[k] = studs
        return true
    end
    return false
end

-- What the lock should treat as this body's reach: its declared Range, or the
-- furthest it has actually been observed to fly, whichever is greater.
local function reachFor(cfg, proj, declared)
    local r = declared or 0
    local seen = proj and observedReach[
        string.lower(tostring(cfg and cfg.name or "?") .. "/" .. proj.Name)]
    if seen and seen > r then r = seen end

    -- PER-BODY REACH SCALE, applied last so it scales the reach actually in
    -- force -- declared Range or learned observedReach, whichever won above.
    -- Scaling `declared` instead would be silently undone the moment the body
    -- flew further than its Range, which is the normal case (HANDOFF night §1).
    --
    -- This shortens what the LOCK will reach for. It does not shorten the bolt,
    -- which flies exactly as far as it always did -- the effect is that distant
    -- targets are no longer locked at all, and a shot that would have curved
    -- across the map to reach one now flies straight past as an honest miss.
    --
    -- Config shape (engine/cs_classes.lua):
    --     lockReachScale = 0.85                        -- whole class
    --     lockReachScale = { attack = 0.85, ability1 = 0.5 }   -- per body
    local sc = cfg and cfg.lockReachScale
    if type(sc) == "table" and proj then
        local v = sc[string.lower(proj.Name)]
        if type(v) ~= "number" then v = sc.default end
        sc = v
    end
    if type(sc) == "number" and sc > 0 then r = r * sc end
    return r
end

Core.observedReach = observedReach

local function lockCap(projRange)
    if projRange and projRange > 0 then
        -- Small margin: Range is the bolt's travel limit, and a target moving
        -- toward us can be caught marginally beyond it by the time it arrives.
        return projRange * 1.1
    end
    return T.lockRange
end

-- Blended cost. Lower is better. Angle dominates, distance breaks ties, which
-- is what stops two similarly-aligned targets from flip-flopping mid-volley.
local function lockCost(angDeg, dist, cap, fov)
    local a = (angDeg / math.max(fov, 1e-3)) * T.angleWeight
    local d = (dist / math.max(cap, 1e-3)) * T.distWeight
    return a + d
end

-- `countRejects` exists because pickTarget scans twice (hard cone, then a
-- soft-widened retry). Counting on both passes double-reports every rejected
-- candidate and makes the histogram -- the diagnostic this is all for -- lie.
--
-- `st`, when passed, is filled with WHY this scan found nothing: how many valid
-- candidates died on range vs on the cone, and the nearest one's geometry. The
-- global reject histogram cannot answer that -- it pools every scan from every
-- class and both the self and ally paths, and it is throttled, so "out of range"
-- being top says nothing about the scan you are looking at. Without this, a
-- `no lock ... valid=11 cone=0` line is unattributable: 2026-07-31 ARCHER
-- (16 of 17 casts `no target`) could not be told apart from an aim-axis bug
-- without cross-referencing timestamps by hand.
local function scanCone(fromPos, look, cap, fov, myChar, ctx, countRejects, closeStuds, closeMaxAng, st)
    -- nil means the global rule. A cast window may widen it -- see castWindow.
    closeStuds = closeStuds or CLOSE_LOCK_STUDS
    -- Hard ceiling on the CYLINDER branch. See the admission test below.
    closeMaxAng = closeMaxAng or 90
    local best, bestCost, bestAng, bestDist = nil, math.huge, 0, 0
    -- Geometry is carried for the no-LOS candidate too. Without it the fallback
    -- lock in pickTarget logged the untouched initialisers -- every no-LOS lock
    -- printed `ang=0.0 dist=0.0`, which is what hid 69 lobby-prop locks in
    -- plain sight: they looked like a distance-zero glitch rather than a lock.
    local bestNoLos, bestNoLosCost, bestNoLosAng, bestNoLosDist = nil, math.huge, 0, 0
    local valid, inCone = 0, 0
    -- Cost of the current sticky target, measured in THIS pass. Comparing
    -- against a cost stored at lock time would be meaningless: lockCost
    -- normalises by fov and cap, and both differ between the hard pass, the
    -- soft-widened pass, and projectiles with different Range.
    local stickyCostNow = nil

    for _, c in ipairs(Core.enumerateCandidates()) do
        local why = Core.rejectReason(c, myChar, ctx)
        if why then
            if countRejects then Core.noteReject(why) end
            -- PLAYERS, SEPARATELY. The reject histogram is global and anonymous,
            -- so "everybody is Safe because the round ended" and "the map props
            -- are not damageable" land in the same bucket and the no-lock line
            -- reports the props. A no-lock is only ever interesting because a
            -- PERSON was not lockable, so count people on their own.
            if st and Players:GetPlayerFromCharacter(c) then
                st.playerWhy = st.playerWhy or {}
                st.playerWhy[why] = (st.playerWhy[why] or 0) + 1
            end
        else
            valid = valid + 1
            if st and Players:GetPlayerFromCharacter(c) then
                st.validPlayers = (st.validPlayers or 0) + 1
            end
            local ph = c:FindFirstChild("HumanoidRootPart")
            if ph then
                local dir = ph.Position - fromPos
                local dist = dir.Magnitude
                -- Nearest VALID candidate, tracked before the range gate so the
                -- "everybody was too far" case still reports a distance instead
                -- of infinity -- that is precisely the case worth naming.
                if st and dist > 0.5 and dist < st.nearDist then
                    st.nearDist = dist
                    st.nearAng = math.deg(math.acos(math.clamp(look:Dot(dir.Unit), -1, 1)))
                    st.nearName = c.Name
                end
                if dist > 0.5 and dist <= cap then
                    local ang = math.deg(math.acos(math.clamp(look:Dot(dir.Unit), -1, 1)))
                    -- Perpendicular offset from the aim line, in STUDS.
                    --
                    -- A pure angular cone is the wrong shape at close range and
                    -- systematically refuses the targets it should want most.
                    -- Someone 3 studs to your side is 3.4 deg off at 50 studs
                    -- and 31 deg off at 5 studs -- the same enemy, standing
                    -- directly in front of you, rejected `out of cone` purely
                    -- for being close.
                    --
                    -- That is exactly backwards for the shotgun kits. GAMBLER's
                    -- 3-chip volley and RECON's scatter converge naturally at
                    -- point-blank, which is where a small nudge is least visible
                    -- and the assist reads most like ordinary spread.
                    --
                    -- So the cone is a cone with a cylinder down its middle:
                    -- inside `fov` degrees OR within CLOSE_LOCK_STUDS of the aim
                    -- line. The cylinder is bounded in studs, so it cannot open
                    -- up into a wide-angle lock at distance -- at 50 studs it is
                    -- worth 9 deg, at 100 studs 4.6 deg, and it never exceeds
                    -- the angular cone where the angular cone is the wider rule.
                    local lateral = math.sin(math.rad(ang)) * dist
                    -- The cylinder is bounded by the DEVIATION CEILING, not
                    -- by 90 degrees.
                    --
                    -- It used to be `ang < 90`, and that quietly undid the one
                    -- invariant pickTarget exists to enforce. The angular cone is
                    -- clamped to legitMaxTotalDeviationDeg - LOCK_DEV_MARGIN so
                    -- the engine never commits to a target the budget cannot
                    -- steer to -- and then this branch let anything up to 89
                    -- degrees straight through, as long as it was laterally
                    -- close.
                    --
                    -- Airborne enemies are exactly that shape. Someone hovering
                    -- overhead is only a few studs off the aim LINE while being
                    -- 70-85 degrees off the aim ANGLE, so the cylinder admitted
                    -- them and the bolt then spent its entire budget climbing,
                    -- froze, and flew straight past. Reported as "the projectiles
                    -- just go up up and away, or curve around him" -- 7 of 10
                    -- flights ended froze=dev with dev at 57-60 against a 55 cap.
                    --
                    -- The cylinder still does its real job: its whole purpose is
                    -- a target 3 studs to the side at 5 studs range, which is
                    -- 31 degrees -- comfortably inside the ceiling. Only the
                    -- unreachable extremes are refused now, and refusing them is
                    -- better than a lock that was always going to miss.
                    if ang <= fov or (lateral <= closeStuds and ang <= closeMaxAng) then
                        inCone = inCone + 1
                        local cost = lockCost(ang, dist, cap, fov)
                        if c == S.stickyTarget then stickyCostNow = cost end
                        -- (geometry rejects below are also gated on countRejects)
                        if Core.hasClearLos(fromPos, c, myChar, ctx) then
                            if cost < bestCost then
                                best, bestCost, bestAng, bestDist = c, cost, ang, dist
                            end
                        elseif cost < bestNoLosCost then
                            bestNoLos, bestNoLosCost = c, cost
                            bestNoLosAng, bestNoLosDist = ang, dist
                        end
                    else
                        if st then st.outCone = st.outCone + 1 end
                        if countRejects then Core.noteReject("out of cone") end
                    end
                else
                    if st then st.outRange = st.outRange + 1 end
                    if countRejects then Core.noteReject("out of range") end
                end
            end
        end
    end

    return best, bestCost, bestAng, bestDist, bestNoLos, valid, inCone,
        stickyCostNow, bestNoLosCost, bestNoLosAng, bestNoLosDist
end

-- Picks one target. Hard cone first; one soft-widened retry; sticky lock is
-- preferred unless a new candidate beats it by stickyMargin.
-- Per-body lock cone override.
--
-- Some kits mix a shot that must look impeccable with one where a wider assist
-- is wanted, in the SAME class -- ARCHER is the case this was built for: the
-- click is a marksman's aimed arrow and any visible curve on it is the most
-- obvious tell in the game, while Q fires a fan of arrows at once where a wider
-- cone reads as ordinary spread.
--
-- Config shape (engine/cs_classes.lua):
--     lockFov = 22                       -- whole class
--     lockFov = { attack = 22, ability1 = 44 }   -- per body, by name
--
-- Returns nil when the class has no opinion, which leaves T.lockFovDeg in
-- charge exactly as before. A returned value is still clamped by the deviation
-- ceiling in pickTarget, so an override can tighten the cone freely but can
-- never widen it past what the budget can actually steer to -- the invariant
-- that keeps a lock from being one the bolt cannot reach.
local function lockFovFor(cfg, proj)
    local lf = cfg and cfg.lockFov
    if not lf then return nil end
    if type(lf) == "number" then return lf end
    if type(lf) == "table" and proj then
        local v = lf[string.lower(proj.Name)]
        if type(v) == "number" then return v end
        local d = lf.default
        if type(d) == "number" then return d end
    end
    return nil
end

-- PER-BODY DEVIATION BUDGET -- the total heading change a body may spend.
--
-- Global by default (T.legitMaxTotalDeviationDeg). A per-body override exists
-- because the budget, not the cone, is what actually refuses a close target at
-- a steep angle -- and that is a shape some kits produce constantly.
--
-- JESTER's Q is the case. The ball carries the player INTO THE AIR, so the
-- people worth hitting are below and in front: 40-55 degrees off the aim axis
-- at 10-20 studs. pickTarget clamps every cone to `budget - margin`, and the
-- margin scales as atan(lockDriftStudsPerSec / boltSpeed) -- which for a
-- speed-70 ball is 6 + 12.9 = 18.9 degrees, leaving a 36 degree ceiling. A
-- lockFov of 38 or 50 makes no difference at all; both get clamped to 36 and
-- the target below you is refused. Raising the budget for that ONE body is the
-- only lever that moves it.
--
-- The distance cancellation is why the cone cannot be fixed instead: drift is
-- v*t and t is dist/speed, so the angular drift a target subtends is v/speed
-- regardless of range. A close target does NOT get a cheaper margin.
--
-- Config shape (engine/cs_classes.lua):
--     lockDev = 70                      -- whole class
--     lockDev = { ability1 = 75 }       -- per body, by name
function Core.lockDevFor(cfg, proj)
    local d = cfg and cfg.lockDev
    if type(d) == "table" and proj then
        local v = d[string.lower(proj.Name)]
        if type(v) ~= "number" then v = d.default end
        d = v
    end
    if type(d) == "number" and d > 0 then return d end
    return T.legitMaxTotalDeviationDeg
end

-- How far a body must be from its owner before we steer it at all.
--
-- Was read straight off cfg.flight and therefore applied to EVERY body of the
-- class. It exists for kits where one body name covers two phases -- JESTER's Q
-- ball is summoned under the player, ridden, then kicked -- and applying it to
-- the class also gagged that class's m1 for its first 12 studs.
--
-- Config shape (engine/cs_classes.lua):
--     steerAfterOwnerStuds = 12                  -- whole class (back-compat)
--     steerAfterOwnerStuds = { ability1 = 12 }   -- per body, by name
--
-- On Core rather than a chunk-level `local`: cs_core.lua is at Luau's 200
-- top-level-local ceiling and the 201st makes Potassium refuse the engine.
function Core.steerAfterOwnerStudsFor(cfg, proj)
    local v = cfg and cfg.flight and cfg.flight.steerAfterOwnerStuds
    if type(v) == "number" then return v end
    if type(v) == "table" and proj then
        local n = v[string.lower(proj.Name)]
        if type(n) ~= "number" then n = v.default end
        if type(n) == "number" then return n end
    end
    return nil
end

-- Per-body "the shot does not come out of ME" flag.
--
-- The self targeting path anchors the search cone at the PLAYER's root and the
-- camera's look (aimOrigin), because for every class up to now the bolt spawns
-- at the caster's muzzle and flies where the caster is facing. CONTROLLER breaks
-- that: its ATK barrage is fired by a DRONE that hovers wherever the marker was
-- placed, which is routinely tens of studs away and pointing somewhere else
-- entirely. Anchoring at the player there is the same class of bug as the
-- third-person camera offset and the ally-echo boomerang -- a distance and an
-- angle measured from a point that is not the thing travelling. The symptom is
-- `no target` on shots the drone was aimed straight at, plus locks the bolt then
-- burns its whole deviation budget turning toward.
--
-- The fix is the mechanism the ally path already uses: hand pickTarget an origin
-- taken from the BODY (ctx.originPos / ctx.originLook), which is also what the
-- mid-flight relock does. This flag only says WHICH bodies need it.
--
-- Config shape (engine/cs_classes.lua):
--     lockFromBody = true                    -- every body of the class
--     lockFromBody = { "attack" }            -- these bodies only, by name
--
-- Deliberately NOT the default for everyone: a body welded to or spawned inside
-- the caster has a meaningless LookVector for a frame or two, and the player-root
-- origin is the more truthful one there.
-- Hung off `Core` rather than declared as a top-level local: cs_core.lua sits
-- at Luau's 200 top-level-local ceiling and one more chunk-level `local` makes
-- Potassium refuse the whole script (tools/build_admin.sh checks this).
function Core.lockFromBody(cfg, proj)
    local lb = cfg and cfg.lockFromBody
    if not lb or not proj then return false end
    if lb == true then return true end
    if type(lb) == "table" then
        local n = string.lower(proj.Name)
        for _, b in ipairs(lb) do
            if n == string.lower(b) then return true end
        end
    end
    return false
end

-- `fovCeiling` overrides the deviation-budget ceiling, and exists for ONE case:
-- a shot that is aimed at spawn and never steered. The ceiling below is there to
-- stop the engine committing to a target the STEERING budget cannot turn to --
-- so for a round with zero steered frames it is measuring the wrong thing
-- entirely. High Noon is that round (see fireHighNoon). Anything that actually
-- steers must leave this nil and take the budget's answer.
function Core.pickTarget(projRange, myChar, ctx, fovOverride, closeStuds, fovCeiling, boltSpeed, devBudget)
    local tPick = perfBegin()
    myChar = myChar or char()
    local fromPos, look = aimOrigin(ctx)
    if not fromPos or not look or look.Magnitude < 1e-6 then
        perfEnd("pickTarget", tPick)
        return nil
    end
    look = look.Unit
    local cap = lockCap(projRange)

    -- The cone is bounded by what the DEVIATION BUDGET can actually reach, with
    -- real headroom -- not by lockFovDeg alone.
    --
    -- The invariant was documented as "lockFovDeg * softFovMult must stay at or
    -- under legitMaxTotalDeviationDeg", and at 38 * 1.15 = 43.7 against 44 it
    -- technically held -- by 0.3 degrees. That is not headroom, and the premise
    -- was wrong anyway: the deviation a bolt SPENDS is not the angle it locked
    -- at. It accumulates along a curved path and pays for target lead on top, so
    -- it lands ABOVE the lock angle every time.
    --
    -- Measured, GAMBLER, 03:28 session: locks at ang=40.4 / 40.7 / 41.3 -- all
    -- acquired on the soft retry -- produced flights that froze at dev=45 and
    -- dev=46 against the 44 budget. About +5 degrees over the lock angle,
    -- consistently. Those shots were abandoned mid-flight: the engine committed
    -- to a target it could not legitimately reach, spent the whole budget, and
    -- froze pointing at nothing. A miss manufactured at lock time.
    --
    -- Enforced here rather than as a comment on the tunable, because a comment is
    -- what failed: two separate retunes moved lockFovDeg and the budget together
    -- and both times the margin ended up at zero.
    -- A per-body override replaces T.lockFovDeg as the REQUEST, never as the
    -- ceiling: the devCeiling clamp below still applies to it unchanged, so a
    -- class asking for a wider cone than the deviation budget can steer to gets
    -- the budget's answer, not its own.
    -- The lock margin SCALES WITH THE BOLT'S SPEED. A flat 6 degrees is a
    -- fast-bolt number and it is why slow kits die on the budget.
    --
    -- The margin covers the gap between the angle a bolt LOCKS at and the
    -- deviation it SPENDS getting there -- it always lands above the lock angle,
    -- because the path is curved and it pays for target lead on top. The size of
    -- that gap is not a constant: a target strafing at v studs/s swings through
    -- roughly atan(v / boltSpeed) of extra angle over the whole flight, because
    -- flight time is dist/speed and the drift is v*t -- the distance cancels.
    --
    -- So it is ~4 degrees for a speed-250 MUSKETEER round and ~13 degrees for a
    -- speed-70 JESTER ball, from the same geometry. Measured, and this is the
    -- whole diagnosis of "JESTER is not consistent": GAMBLER (fast) overshot its
    -- lock angle by about +5, exactly as the old margin assumed, while JESTER
    -- locked at 41-48 degrees and spent 55-62 -- +14 to +20 -- so 22 of its 36
    -- flights ended `froze=dev` against a 20% fault threshold.
    --
    -- Same structural insight the turn clamp already uses (it scales as
    -- 1/Speed for the same reason). The lock margin never got it.
    --
    -- Refusing those locks is the POINT, not a cost: they were flights that
    -- curved to the cap, froze, and flew past. A no-lock is an honest miss.
    local baseFov = (fovOverride or T.lockFovDeg) * Core.fovScaleNow()
    local devCeiling = fovCeiling
    -- Override mode suspends the ceiling as well as the gates. The ceiling
    -- exists to stop the engine locking a target the deviation budget cannot
    -- turn to -- and in override there IS no deviation budget, so keeping it
    -- would silently eat the widened cone and make the mode feel like it does
    -- nothing (the earlier +50% that arrived as +33%).
    if not devCeiling and Core.overrideActive() then devCeiling = 180 end
    if not devCeiling then
        local margin = LOCK_DEV_MARGIN
        if boltSpeed and boltSpeed > 1 then
            margin = margin + math.deg(math.atan(T.lockDriftStudsPerSec / boltSpeed))
        end
        -- devBudget is the per-body override when the class declares one, and
        -- T.legitMaxTotalDeviationDeg otherwise. The margin is subtracted from
        -- whichever is in force, so the invariant "never lock what the budget
        -- cannot steer to" holds unchanged -- it is simply measured against the
        -- budget this body actually has.
        devCeiling = (devBudget or T.legitMaxTotalDeviationDeg) - margin
    end
    local softFov = math.min(baseFov * T.softFovMult, devCeiling)
    local hardFov = math.min(baseFov, softFov)

    -- Attribution for the `no lock` line. Reset before the soft retry so it
    -- always describes the WIDEST scan actually run -- the one that had the best
    -- chance and still found nothing.
    local st = { outRange = 0, outCone = 0, nearDist = math.huge, nearAng = 0 }
    local usedFov = hardFov

    local best, cost, ang, dist, noLos, valid, inCone, stickyCostNow, noLosCost,
        noLosAng, noLosDist =
        scanCone(fromPos, look, cap, hardFov, myChar, ctx, true, closeStuds, devCeiling, st)

    if not best and T.softFovEnabled and softFov > hardFov then
        st.outRange, st.outCone, st.nearDist, st.nearAng, st.nearName = 0, 0, math.huge, 0, nil
        st.playerWhy, st.validPlayers = nil, nil
        usedFov = softFov
        best, cost, ang, dist, noLos, valid, inCone, stickyCostNow, noLosCost,
            noLosAng, noLosDist =
            scanCone(fromPos, look, cap, softFov, myChar, ctx, false, closeStuds, devCeiling, st)
    end

    -- No LOS-clear target in the cone: fall back to the best in-cone one.
    -- noLosCost is a real, comparable cost from the same scan, so the sticky
    -- comparison below still works rather than being short-circuited by inf.
    if not best and T.allowNoLosLock and noLos then
        best, cost = noLos, noLosCost
        -- Carry its geometry into the log line as well, or the lock prints the
        -- scan's untouched 0/0 and reads as a distance-zero bug.
        ang, dist = noLosAng, noLosDist
        -- Counted separately, NOT as a reject: the histogram is "why shots were
        -- refused", and quietly filing a successful lock in there would corrupt
        -- the one diagnostic we rely on.
        Core.stats.noLosLocks = Core.stats.noLosLocks + 1
    end

    -- Sticky: keep the current lock for volley coherence unless clearly beaten.
    -- stickyCostNow comes from the same scan as `cost`, so the two are directly
    -- comparable; a stored cost would not be.
    local now = os.clock()
    local sticky = S.stickyTarget
    if sticky and now < S.stickyUntil and Core.isValidTarget(sticky, myChar, ctx) then
        if not best or best == sticky then
            perfEnd("pickTarget", tPick)
            return sticky
        end
        -- Sticky is out of the cone entirely this pass: it has nothing to
        -- defend with, so let the new target take over.
        if stickyCostNow and cost > stickyCostNow - T.stickyMargin then
            perfEnd("pickTarget", tPick)
            return sticky
        end
    end

    if best then
        S.stickyTarget = best
        S.stickyUntil = now + T.stickyTtl
        Core.stats.locks = Core.stats.locks + 1
        -- Logged unconditionally. The whole of last session's cs_core.log was
        -- eleven lines of startup and nothing else, because every diagnostic
        -- sat behind T.debug -- so "is it even locking?" was unanswerable from
        -- the log, which is exactly what the log is for.
        logx("lock", ("lock %s ang=%.1f dist=%.1f valid=%d cone=%d")
            :format(best.Name, ang, dist, valid, inCone))
    else
        -- WHY nothing was locked, with the geometry that decided it.
        --
        -- `no target` is the most common flight outcome by a wide margin, and
        -- until now the log could not tell you whether the cone was too narrow,
        -- the bolt too short, or there was genuinely nobody there. The global
        -- reject histogram cannot answer it either -- it pools every scan from
        -- every class and both the self and ally paths, so `out of range` being
        -- top says nothing about which scan it came from.
        --
        -- valid = candidates that passed the hittability gates at all.
        -- cone = how many of those were inside the cone. valid>0 with cone=0 is
        -- a geometry problem; valid=0 means there was nobody to shoot and no
        -- amount of tuning changes that.
        --
        -- far/wide split the reject histogram cannot give you: of the `valid`
        -- candidates, how many were beyond the bolt's own reach versus outside
        -- the cone, and where the closest one actually was. `far>0 wide=0` with
        -- a near distance just over the cap is a RANGE answer -- the bolt cannot
        -- get there and no tuning changes that. `far=0 wide>0` is a geometry
        -- answer, and that is when to suspect the aim axis.
        local near = "none"
        if st.nearDist < math.huge then
            near = ("%s @%.0f studs %.0f deg"):format(st.nearName or "?", st.nearDist, st.nearAng)
        end
        -- Named outright when every valid candidate is beyond the bolt: that is
        -- a positioning fact, not an engine fault, and the silence read as
        -- "heatseek is broken" every time (ARCHER 14:29, SNIPER 15:43 — friend
        -- at 367+ studs vs a 220-stud charge-scaled cap).
        local tag = (valid > 0 and st.outRange == valid) and " — ALL BEYOND BOLT RANGE" or ""
        -- WHOSE no-lock this is. The line used to be identical for a self shot
        -- and for an ally echo pre-lock, so `echo: no target at forge time` --
        -- the reject that decides whether an ally gets an echo AT ALL -- had no
        -- geometry attached to it anywhere. For a short-range kit (FROST E is
        -- Range=35, so a cap near 38 studs) that is the difference between "the
        -- ally was out of reach" and "the cone refused them", and those have
        -- opposite fixes. Reported for years as "FROST E does nothing for
        -- allies" with nothing in the log to act on.
        local who = ""
        if ctx and ctx.isEcho then
            who = (" [ECHO PRE-LOCK <- %s]"):format(
                (ctx.allyPlayer and ctx.allyPlayer.Name) or ctx.allyName or "?")
        end
        -- THE PEOPLE LINE. `valid=11 ... nearest=NormalDummy2 @401 studs` is a
        -- true sentence that answers the wrong question: it describes the lobby
        -- props left in the candidate set after every human was refused, and it
        -- reads as a RANGE problem, which is the one bucket the docs call
        -- "positioning, nothing to tune". Final Strike on 2026-08-01 04:46 cost
        -- an hour to exactly this: twelve consecutive UNGUIDED bolts while the
        -- line pointed at a dummy 400 studs away.
        --
        -- So say it outright: how many PEOPLE were lockable, and if none, what
        -- refused each one by name. `players=0 (safe x1)` is the whole answer in
        -- six characters, and `players=0 (no character x1)` is the other one --
        -- a player whose Character is nil never reaches rejectReason at all and
        -- so cannot appear in any histogram.
        local pw = ""
        if st.playerWhy then
            local parts = {}
            for reason, n in pairs(st.playerWhy) do
                parts[#parts + 1] = ("%s x%d"):format(reason, n)
            end
            table.sort(parts)
            pw = " (" .. table.concat(parts, ", ") .. ")"
        end
        if S.noCharPlayers and S.noCharPlayers > 0 then
            pw = pw .. (" (no character x%d)"):format(S.noCharPlayers)
        end
        logx("lock", ("no lock — cap=%.0f fov=%.0f valid=%d players=%d%s cone=%d far=%d wide=%d nearest=%s%s%s")
            :format(cap, usedFov, valid, st.validPlayers or 0, pw,
                inCone, st.outRange, st.outCone, near, tag, who))
        -- ZERO PEOPLE LOCKABLE: name every one of them and why, unprompted.
        -- This is the line that would have ended the 2026-08-01 Final Strike
        -- hunt in one read instead of an hour of counter arithmetic. Self shots
        -- only -- an ally echo pre-lock failing to find a target for SOMEBODY
        -- ELSE's bolt is a different question and would double every line.
        if (st.validPlayers or 0) == 0 and not (ctx and ctx.isEcho) then
            Core.logPeopleSnapshot()
        end
    end
    perfEnd("pickTarget", tPick)
    return best
end

-- AUTOMATIC PEOPLE SNAPSHOT. Fires itself when a scan finds NOBODY.
--
-- The `why` command below answers the same question better, but it has to be
-- typed, and the moment worth diagnosing is a fight you are losing -- nobody
-- opens a console mid-duel. This runs on the failure itself, so the answer is
-- already in cs_core.log by the time anyone thinks to look.
--
-- Fires only when the scan produced zero lockable PEOPLE while people were in
-- the server: exactly the "twelve UNGUIDED bolts in a row" case, never during
-- ordinary play. Two guards keep it off the hot path:
--
--   * signature. One line per distinct set of reasons. A whole Final Strike
--     prints once, not once per bolt of every volley.
--   * floor. Even when the signature keeps changing (people moving in and out
--     of range), never more than one line every PEOPLE_SNAP_SEC.
--
-- Cost is one rejectReason per player, and only on a frame that already failed
-- to lock -- the same predicate the scan just ran, on a list that is at most
-- server size.
function Core.logPeopleSnapshot()
    local now = os.clock()
    if S.peopleSnapAt and (now - S.peopleSnapAt) < 1.0 then return end

    local mc = char()
    local rows, sig = {}, {}
    local fromPos = nil
    local root = mc and mc:FindFirstChild("HumanoidRootPart")
    if root then fromPos = root.Position end

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then
            local c = p.Character
            local why, dist
            if not c then
                -- The invisible case. Never appears in the reject histogram
                -- because consider() drops it before rejectReason ever runs.
                why = "NO CHARACTER (never enumerated)"
            else
                why = Core.rejectReason(c, mc, nil) or "LOCKABLE"
                local ph = c:FindFirstChild("HumanoidRootPart")
                if ph and fromPos then dist = (ph.Position - fromPos).Magnitude end
            end
            rows[#rows + 1] = dist
                and ("%s=%s @%.0f"):format(p.Name, why, dist)
                or  ("%s=%s"):format(p.Name, why)
            sig[#sig + 1] = p.Name .. "=" .. why
        end
    end
    if #rows == 0 then return end

    table.sort(sig)
    local signature = table.concat(sig, "|")
    -- Same reasons as last time: already said, and saying it again per bolt is
    -- how a diagnostic becomes noise nobody reads.
    if signature == S.peopleSnapSig and (now - (S.peopleSnapAt or 0)) < 15 then
        return
    end
    S.peopleSnapSig = signature
    S.peopleSnapAt = now
    table.sort(rows)
    logwarn("lock", "NOBODY LOCKABLE — " .. table.concat(rows, ", "))
end

-- ONE PERSON, RIGHT NOW, IN FULL. The `why <player>` command.
--
-- Every targeting diagnostic in this engine is an AGGREGATE: the reject
-- histogram is anonymous counters, the no-lock line names only the nearest valid
-- candidate, and the FLIGHT line names no target at all. So the one question
-- that actually gets asked in play -- "why did it not lock HIM" -- could only be
-- answered by inference from counter deltas, and that inference was wrong four
-- times in a row on 2026-08-01 (partner, then ARCHER's cone, then the round-end
-- Safe flag) before this existed.
--
-- Reads the same predicates the scan does, in the same order, so it cannot drift
-- from what targeting actually decides. Geometry is measured against the LAST
-- bolt's cone and reach (S.lastBoltFov / S.lastBoltRange), which is what the
-- next shot of the class in hand will use.
function Core.explainTarget(p)
    if not p then return "no such player" end
    if p == lp then return p.Name .. ": that is you" end
    local c = p.Character
    if not c then
        return p.Name .. ": NO CHARACTER — invisible to targeting. Not a "
            .. "candidate, and not in any reject bucket either."
    end

    local mc = char()
    local why = Core.rejectReason(c, mc, nil)
    local out = ("%s: %s"):format(p.Name, why and ("REFUSED — " .. why) or "lockable")

    -- The game's own oracle values, printed raw. `safe=1` next to `REFUSED —
    -- safe` is the difference between believing the engine and checking it.
    local stats = c:FindFirstChild("Stats")
    local function sv(n)
        local v = stats and stats:FindFirstChild(n)
        return v and tostring(v.Value) or "-"
    end
    out = out .. ("\n  state: safe=%s hp=%s disable=%s pairID=%s")
        :format(sv("Safe"), sv("CurrentHP"), sv("Disable"),
            tostring(p:GetAttribute("PairID")))
    local tags = {}
    for _, n in ipairs({ "Challenge", "Alternate", "FinalStrike" }) do
        if headTag(c, n) then tags[#tags + 1] = n end
    end
    if c:FindFirstChild("FinalStrike") then tags[#tags + 1] = "FinalStrike(char)" end
    out = out .. ("  tags: %s"):format(#tags > 0 and table.concat(tags, ",") or "none")

    -- In the candidate list at all? A model can be refused (a reason) or simply
    -- never enumerated (no reason anywhere), and those look identical in a log.
    local inCand = false
    for _, m in ipairs(Core.enumerateCandidates()) do
        if m == c then inCand = true break end
    end
    out = out .. ("\n  candidate: %s"):format(inCand and "yes" or "NO — not enumerated")

    -- Geometry against the cone the class in hand actually uses.
    local fromPos, look = aimOrigin(nil)
    local ph = c:FindFirstChild("HumanoidRootPart")
    if fromPos and look and ph then
        local dir = ph.Position - fromPos
        local dist = dir.Magnitude
        local ang = math.deg(math.acos(math.clamp(look:Dot(dir.Unit), -1, 1)))
        local fov = (S.lastBoltFov or T.lockFovDeg) * (T.lockFovScale or 1)
        if Core.overrideActive() then fov = fov * (T.lockFovBoostMult or 1) end
        local cap = S.lastBoltRange or T.lockRange
        out = out .. ("\n  geometry: %.0f studs (cap %.0f -> %s), %.0f deg (cone %.0f -> %s), los=%s")
            :format(dist, cap, dist <= cap and "in" or "TOO FAR",
                ang, fov, ang <= fov and "in" or "OUTSIDE",
                Core.hasClearLos(fromPos, c, mc, nil) and "clear" or "BLOCKED")
    else
        out = out .. "\n  geometry: unavailable (no root part or no aim origin)"
    end

    -- Ally state, because "I give him heatseek" is the other half of the
    -- question this command gets asked with. Assisting someone and being able to
    -- shoot them are independent, and the engine has no filter that links them.
    out = out .. ("\n  ally: %s (an ally is still a valid target — no filter links the two)")
        :format(Core.isAllyPlayer(p) and "YES, echo armed for them" or "no")
    return out
end

--------------------------------------------------------------------------
-- 6. STEERING
--------------------------------------------------------------------------

-- GUIDANCE LAW: proportional navigation, not pure pursuit.
--
-- This is the fix for "it rapidly goes around the target and then hits them".
--
-- Pure pursuit -- point the bolt at where the target is, every frame -- is what
-- was here, and it ORBITS by construction. As the bolt closes, the angle to the
-- target changes faster and faster; past some range the turn needed each frame
-- exceeds the clamp, so the bolt sails past, swings back, past again. Every
-- homing projectile written this way does it, and it looks like nothing a person
-- could throw.
--
-- Proportional navigation steers by the ROTATION RATE of the line of sight
-- instead of by the angle to the target. The property that matters: when the
-- bolt is on a collision course the line of sight stops rotating, losRate goes to
-- zero, and the guidance goes quiet -- the bolt coasts straight into the target.
-- Pure pursuit keeps correcting right up to contact; PN stops correcting as soon
-- as it is going to hit. That is the difference between "magnetic" and "well
-- aimed", and it is also why real missiles use it.
--
-- N = 3 is the standard gain. Below ~2 it under-corrects and misses; above ~5 it
-- gets twitchy on a strafing target, which is the jitter this is removing.
-- Navigation constant. Classical range is 3-5.
--
-- 4 rather than 3 because this engine spends the first ~0.10s of every flight not
-- steering at all (the muzzle delay) and stops again on approach (the terminal
-- freeze), so the usable guidance window is shorter than a missile's and the gain
-- has to make it up. Above ~5 it gets twitchy against a strafing target.
local PN_GAIN = 4.0

-- Ceiling on the line-of-sight rate fed to the guidance law, in radians/sec.
-- See proNavHeading(). 6 rad/s is far above anything a real intercept produces
-- and only clips the close-range singularity.
local PN_MAX_LOS_RATE = 6.0

-- Closest-approach detection. The range must exceed its own minimum by
-- MISS_OPEN_STUDS for MISS_OPEN_FRAMES consecutive guidance frames before the
-- flight is declared a miss and steering stops for good.
local MISS_OPEN_STUDS = 3
local MISS_OPEN_FRAMES = 4


-- Returns the desired heading, or nil when there is nothing to correct.
local function proNavHeading(current, los, losPrev, dt)
    if not losPrev or dt <= 0 then return nil end
    -- Rotation rate of the line of sight, as a vector. Its perpendicular part is
    -- the only part that means anything for guidance.
    local losRate = (los - losPrev) / dt
    losRate = losRate - current * losRate:Dot(current)

    -- Bound it. The line-of-sight rate goes to infinity as range goes to zero --
    -- a bolt passing a few studs from the target swings its LOS through a large
    -- angle in one frame, and the raw PN command becomes an enormous perpendicular
    -- kick. Unbounded, that is what starts the loop; the turn clamp then paints it
    -- as a smooth arc instead of a snap, which is why it read as "curves around
    -- the player" rather than as a glitch.
    if losRate.Magnitude > PN_MAX_LOS_RATE then
        losRate = losRate.Unit * PN_MAX_LOS_RATE
    end

    if losRate.Magnitude < 1e-6 then
        -- Line of sight is not rotating: already on an intercept course. Hold
        -- heading. This is the case pure pursuit could never detect.
        return nil
    end
    local desired = current + losRate * (PN_GAIN * dt)
    if desired.Magnitude < 1e-6 then return nil end
    return desired.Unit
end

-- Clamp turn rate. Instant 180s are the single most obvious tell to a human
-- watching, and detection here is a human typing aimbotcheck (0691.lua), not
-- a heuristic -- so this is the protective knob that actually matters.
local function clampSteer(current, desired, maxDeg)
    if current.Magnitude < 1e-6 then return desired end
    local dot = math.clamp(current.Unit:Dot(desired.Unit), -1, 1)
    local ang = math.deg(math.acos(dot))
    if ang <= maxDeg then return desired end
    local t = maxDeg / ang
    local blended = current.Unit:Lerp(desired.Unit, t)
    if blended.Magnitude < 1e-6 then return desired end
    return blended.Unit
end

-- Aim where the target will be, not where it is. Pure client maths.
local function leadPoint(targetPart, fromPos, projSpeed)
    local pos = targetPart.Position
    if not T.predictiveLead or projSpeed <= 0 then return pos end
    local vel = targetPart.AssemblyLinearVelocity
    if not vel or vel.Magnitude < 1e-3 then return pos end
    -- NO VERTICAL LEAD. A jumping target reads as "moving up fast", so lead
    -- aimed above their head -- but jump velocity is transient and they are
    -- back down before the bolt arrives. Leading a fall is equally wrong
    -- (they land). Horizontal velocity is the persistent part.
    vel = Vector3.new(vel.X, 0, vel.Z)
    if vel.Magnitude < 1e-3 then return pos end
    local flight = (pos - fromPos).Magnitude / projSpeed
    -- Lead is capped at legitMaxLeadSec, not 1.0s. A full second of lead on a
    -- sprinting target aims at open ground far enough away that the bolt is
    -- visibly flying at nothing before it converges -- which reads worse than
    -- simply missing.
    return pos + vel * math.min(flight, T.legitMaxLeadSec)
end

-- LEGITNESS: how hard may THIS body turn, this frame?
--
-- Three multipliers on the reference rate, in order of how much they matter to
-- somebody watching:
--
--  * Speed. What the eye reads is the RADIUS of the arc, and radius = speed /
--    turn rate. Holding degrees-per-frame constant across kits therefore makes
--    the arc tighter the faster the bolt goes -- a lazy drift on PROGRAMMER's
--    speed-80 bolt is a hook on MUSKETEER's speed-250 one, from the same number.
--    Scaling inversely with speed keeps the arc the same shape for every class,
--    which is also why this replaces the per-class tuning that kept coming out
--    wrong: it is derived from the body's own Speed rather than guessed.
--
--  * Ramp. Authority eases in over legitRampSec after the muzzle delay. A step
--    from zero to full curvature is itself visible.
--
--  * Perf tier. Under load the engine steers less often, and a less frequent
--    correction at the same per-frame clamp would turn a smooth arc into visible
--    zig-zag steps -- so the clamp comes down with the tier too.
local LEGIT_REF_SPEED = 200

-- Per-flight legit budget, scaled to the bolt the game actually gave us.
--
-- The tunables are ABSOLUTE (0.10s muzzle delay, 10 studs terminal freeze) and
-- were set against a long bolt -- MUSKETEER is speed 250, range 500, so about two
-- seconds of flight and the delay is 5% of it. Applied unchanged to a short bolt
-- they delete the flight: MEDIC ability2 is speed 100, range 30, which is 0.3s
-- end to end. A 0.10s delay plus a 0.25s ramp plus a 10-stud terminal freeze on a
-- 30-stud bolt leaves no steering at all.
--
-- Measured live, and it is worth stating plainly: 99 of 157 ally flights recorded
-- frm=0 -- zero steer frames -- and every one of them scored legit=100(A),
-- because a bolt that never steers has no tells. The metric reported perfect
-- success for total failure.
--
-- So each limit is now min(absolute, a fraction of THIS bolt's own flight). Short
-- bolts get proportionally short delays; long bolts are unchanged.
--
-- ...and scaled to the ENGAGEMENT, not to the bolt's nominal range.
--
-- `range` is how far the bolt COULD fly, which is not how long this shot lasts.
-- ARCHER's Power Arrow is speed 260 range 210 -- 0.81s of nominal flight, so a
-- 0.065s muzzle delay and a 0.162s ramp. That is 17 studs flown straight before
-- the first correction, with the clamp still ramping in over the next 40. Fired
-- at someone 18 studs away the arrow ARRIVES before steering begins, and the
-- engagement is over during the dead time. Live: `frm=3 turn=1 dev=0/55
-- max/frm=0.3 firstSteer=85ms` -- three frames, no correction at all.
--
-- Both slots showed it and it reads as "close up it just isn't consistent",
-- which is exactly what it is: at close range there was no assist whatsoever.
--
-- This is the same bug shape as the two already fixed above -- a guard sized
-- against something other than the shot being taken. The terminal freeze was
-- fixed by scaling it to `initialDist`; this is the muzzle and ramp getting the
-- same treatment, from the same reasoning.
--
-- Legitness is preserved because the dead time stays a FRACTION of what the
-- viewer actually sees. A shot at 18 studs is over in 0.07s: there is no
-- correction perceivable inside it, and a delay longer than the flight does not
-- buy believability, it just means no assist -- the argument this file already
-- makes for GAMBLER. Long engagements are unchanged: when the target is at or
-- beyond the bolt's range, min() picks `range` and the maths is what it was.
local function legitBudget(speed, range, engageDist)
    -- The shot ends at whichever comes first: the bolt's range, or the target.
    local effective = range
    if engageDist and engageDist > 0 and engageDist < effective then
        effective = engageDist
    end
    local flightTime = (speed > 0) and (effective / speed) or 1
    return {
        flightTime = flightTime,
        -- Fractions cut for short-range kits: 0.15 -> 0.08 and 0.35 -> 0.20.
        --
        -- These only bite when the bolt is SHORT. A long bolt is capped by the
        -- absolute T values instead, so MUSKETEER (2.0s of flight) still gets
        -- the full 0.10s muzzle and 0.25s ramp and is completely unaffected --
        -- its legitness is unchanged. GAMBLER (0.50s of flight) goes from
        -- 0.075 + 0.175 = 0.25s of dead time to 0.04 + 0.10 = 0.14s, turning
        -- 50% of the flight spent unguided into 28%. Usable guidance roughly
        -- doubles, which is the difference between "sometimes tracks" and
        -- "tracks".
        --
        -- Still legit on a short bolt: 0.14s is a quarter of a chip's flight,
        -- and the whole event is over in half a second -- too fast to read as a
        -- correction. A flat delay there does not buy believability, it just
        -- means no assist at all.
        muzzle   = math.min(T.legitMuzzleDelay, flightTime * 0.08),
        ramp     = math.min(T.legitRampSec, flightTime * 0.20),
        -- 0.15 -> 0.10: freeze later, so short bolts keep correcting closer in
        -- rather than going ballistic a third of the way to the target.
        terminal = math.min(T.legitTerminalFreezeStuds, range * 0.10),
    }
end

local function steerClampFor(speed, elapsed, steerEvery, budget)
    local base = T.maxSteerDegPerFrame
    if not Core.legitNow() then return base end

    -- Inverse in speed, clamped so a very slow body cannot be granted a
    -- physically absurd turn rate and a very fast one is not frozen solid.
    local byspeed = base * (LEGIT_REF_SPEED / math.max(speed, 1))
    byspeed = math.clamp(byspeed, base * 0.35, base * 2.0)

    local ramp = 1
    local rampSec = budget and budget.ramp or T.legitRampSec
    local muzzle = budget and budget.muzzle or T.legitMuzzleDelay
    if rampSec > 0 then
        local since = elapsed - muzzle
        if since < rampSec then
            ramp = math.clamp(since / rampSec, 0, 1)
            -- Smoothstep, not linear: linear ramp-in still starts with a
            -- discontinuity in the SECOND derivative, which shows as a kink.
            ramp = ramp * ramp * (3 - 2 * ramp)
        end
    end

    -- steerEvery > 1 means we skip frames; do not compensate by turning harder.
    -- Turning the same total amount in fewer, bigger steps is exactly the
    -- staircase artefact this is trying to avoid.
    local tierMult = (steerEvery and steerEvery > 1) and (1 / steerEvery) or 1

    return math.max(0.25, byspeed * ramp * tierMult)
end

-- Remember what a mover looked like before we touched it, once per flight, so
-- releaseMover can put it back exactly. Steering used to be a one-way write:
-- an existing BodyVelocity kept our last aim vector and a 1e7 MaxForce forever,
-- and a CsCoreBV we created was never destroyed. That is a live physics driver
-- left attached to a body the GAME still owns. On CHRONO it is a crash: the
-- kit's bodies come back to and re-weld to the caster (Rewinding Blade returns
-- and is recast-blinked to, Temporal Gateway teleports you to marked enemies),
-- and once welded, a 1e7-force mover on the projectile drives the whole
-- character assembly -- the "game bugged out" report, and why cs_core.log shows
-- a lock at ang=0.0 dist=0.0 (player dragged into the target) followed by the
-- engine claiming nothing at all for the next eleven minutes.
local function noteMover(rec, inst, kind)
    if not rec or rec.mover then return end
    rec.mover = { inst = inst, kind = kind }
    if kind == "created" then return end
    pcall(function()
        if kind == "bv" then
            rec.mover.vel = inst.Velocity
            rec.mover.force = inst.MaxForce
        else
            rec.mover.vel = inst.VectorVelocity
            rec.mover.force = inst.MaxAxesForce
        end
    end)
end

local function releaseMover(rec)
    local m = rec and rec.mover
    if not m or not m.inst then return end
    rec.mover = nil
    pcall(function()
        if m.kind == "created" then
            m.inst:Destroy()
        elseif m.inst.Parent then
            if m.kind == "bv" then
                if m.force then m.inst.MaxForce = m.force end
                if m.vel then m.inst.Velocity = m.vel end
            else
                if m.force then m.inst.MaxAxesForce = m.force end
                if m.vel then m.inst.VectorVelocity = m.vel end
            end
        end
    end)
end

-- ensureMover: called every steer frame. Four situations:
--
--  1. BodyVelocity present and no game LV → drive it (legacy, or our CsCoreBV).
--
--  2. LinearVelocity present (inside an Attachment, game path) → drive it.
--     The game creates the Attachment+LV a frame or more AFTER the part appears
--     (0704.lua:698-728), so on the FIRST call we may not find it yet.
--     We MUST use LV_MAX_FORCE (1e9) here -- the game set MaxAxesForce to 1e9
--     (0704.lua:712). Writing our MOVER_MAX_FORCE (1e7) into the game's mover
--     weakens it 100x and lets gravity/drag sag the bolt.
--
--     RelativeTo is never written in 0704.lua:698-728, so it defaults to
--     Enum.ActuatorRelativeTo.World. Writing a world-space vector is correct.
--
--  3. We created a CsCoreBV AND the game's LV now exists → switch movers.
--     This MUST be re-checked every frame: the LV is added mid-flight.
--     Without the switch, both movers fight (1e7 vs 1e9 on the same part),
--     which is the reported "spins in place then flies in a random direction".
--
--  4. Nothing yet → create CsCoreBV as a fallback. Situation 3 will replace it
--     when the game's LV appears.
--
-- `rec` tracks the mover we end up driving so releaseMover restores it.
local function ensureMover(proj, speed, look, rec)
    if not proj or not proj.Parent then return nil end
    pcall(function()
        proj.Anchored = false
        proj.CanCollide = false
    end)
    look = look or proj.CFrame.LookVector

    -- Always check for the game's LinearVelocity first. It may have appeared
    -- AFTER we created a CsCoreBV placeholder on an earlier frame.
    local lv = proj:FindFirstChildWhichIsA("LinearVelocity", true)

    -- Situation 3: we own a CsCoreBV but the real LV appeared -- switch to it.
    local bv = proj:FindFirstChildOfClass("BodyVelocity")
    if bv and bv.Name == "CsCoreBV" and lv then
        -- Destroy our placeholder so the two movers cannot fight.
        if rec then rec.mover = nil end
        pcall(function() bv:Destroy() end)
        bv = nil
        -- Fall through: bv is nil, lv is set, so the lv branch runs next.
    end

    -- Situation 1: BodyVelocity (legacy projectile or our CsCoreBV, no game LV).
    if bv and not lv then
        noteMover(rec, bv, bv.Name == "CsCoreBV" and "created" or "bv")
        bv.Velocity = look * speed
        bv.MaxForce = MOVER_MAX_FORCE
        return bv
    end

    -- Situation 2 (and situation 3 fallthrough): game's LinearVelocity.
    if lv then
        noteMover(rec, lv, "lv")
        pcall(function()
            lv.VectorVelocity = look * speed
            -- Match the game's own MaxAxesForce (0704.lua:712: 1e9 per axis).
            -- Writing MOVER_MAX_FORCE (1e7) would weaken the mover 100x.
            lv.MaxAxesForce = LV_MAX_FORCE
        end)
        return lv
    end

    -- Situation 4: nothing yet (game LV hasn't been created yet this frame).
    -- Create CsCoreBV as a placeholder; situation 3 will replace it next frame.
    local ok, created = pcall(function()
        local n = Instance.new("BodyVelocity")
        n.Name = "CsCoreBV"
        n.Velocity = look * speed
        n.MaxForce = MOVER_MAX_FORCE
        n.Parent = proj
        return n
    end)
    if ok and created then
        noteMover(rec, created, "created")
        return created
    end
    return nil
end

--------------------------------------------------------------------------
-- 7. PROJECTILE FACTS
--------------------------------------------------------------------------

local function projSpeed(proj)
    local v = proj:FindFirstChild("Speed")
    local s = v and tonumber(v.Value) or nil
    if not s or s ~= s or s <= 0 then s = 300 end
    return math.clamp(s, 40, 500)
end

local function projRange(proj)
    local rng = proj:FindFirstChild("Range")
    if rng then
        local r = tonumber(rng.Value)
        if r and r > 0 then return r end
    end
    return 500
end

-- How long we are willing to steer one body.
--
-- Was `range/speed + 1.5`, floored at 2s: a MEDIC attack travels its 60 studs in
-- 0.6s and was given 2 full seconds, so a bolt that had already missed had 1.4s of
-- budget left to loop in. Scaling the margin instead of adding a flat 1.5s keeps
-- long bolts unaffected while giving short ones only a little slack for the lead
-- and the arc.
--
-- This is a backstop, not the main guard -- the closest-approach test in the steer
-- loop should end a missed flight long before the lifetime does.
local function projLifetime(proj)
    local travel = projRange(proj) / projSpeed(proj)
    return math.clamp(travel * 1.35 + 0.25, 0.75, T.maxFlightSec)
end

--------------------------------------------------------------------------
-- 8. REGISTRY
--
-- One table of live bodies. Replaces activeEchoes / tracking / processedAlly
-- in each old module, and is what guarantees cleanup actually runs -- bodies
-- left steering after their hit are why projectiles appeared to linger and
-- flicker on a victim.
--------------------------------------------------------------------------

function Core.register(proj, rec)
    rec = rec or {}
    rec.born = os.clock()
    rec.proj = proj
    S.registry[proj] = rec
    return rec
end

function Core.unregister(proj, why)
    local rec = S.registry[proj]
    if not rec then return end
    S.registry[proj] = nil
    if rec.cleanup then pcall(rec.cleanup, why) end
    if rec.destroyOnRelease and proj and proj.Parent then
        pcall(function() proj:Destroy() end)
    end
end

function Core.activeCount(classKey)
    local n = 0
    -- `proj` cannot be nil here; Lua forbids nil table keys.
    for proj, rec in pairs(S.registry) do
        if not proj.Parent then
            S.registry[proj] = nil
        elseif not classKey or rec.classKey == classKey then
            n = n + 1
        end
    end
    return n
end

-- Sweep: anything whose body is gone, or that outlived its lifetime, is
-- released. Runs on Heartbeat so a missed cleanup path cannot leak.
--
-- Also prunes the damage ledger. Its keys are character Instances and entries
-- are only ever written, so without this it holds a strong reference to every
-- character anyone has respawned as, for the whole session.
local LEDGER_PRUNE_SEC = 30
local lastLedgerPrune = 0

local function sweepRegistry()
    local now = os.clock()
    for proj, rec in pairs(S.registry) do
        if not proj.Parent then
            Core.unregister(proj, "gone")
        elseif rec.expiresAt and now > rec.expiresAt then
            Core.unregister(proj, "expired")
        end
    end

    if now - lastLedgerPrune >= LEDGER_PRUNE_SEC then
        lastLedgerPrune = now
        -- Ally echo bookkeeping is instance-keyed too; prune on the same tick.
        if Core.sweepAllyProcessed then Core.sweepAllyProcessed() end
        sweepCasts()
        for victim, stamp in pairs(S.ledger) do
            -- An entry older than the cooldown can never gate anything again.
            if now - stamp > LEDGER_PRUNE_SEC
                or typeof(victim) ~= "Instance" or not victim.Parent then
                S.ledger[victim] = nil
            end
        end
    end
end

--------------------------------------------------------------------------
-- 9. DAMAGE LEDGER
--
-- reach and heatseek both call ClassModule:Damage with nothing coordinating
-- them, so a target inside reach radius while an echo connects took two
-- independent hits -- and amp multiplied both.
--------------------------------------------------------------------------

function Core.canDamage(victim, cooldown)
    if not victim then return false end
    local now = os.clock()
    local last = S.ledger[victim]
    if last and now - last < (cooldown or T.damageCooldown) then
        return false
    end
    S.ledger[victim] = now
    return true
end

function Core.noteHit(victim)
    Core.stats.hits = Core.stats.hits + 1
    if victim then S.ledger[victim] = os.clock() end
end

--------------------------------------------------------------------------
-- 10. SPAWN — typed wrapper over all 12 CreateProjectile params
--
-- CreateProjectile (0003.lua:2976). The options table (0003.lua:2850) is a
-- generic value-writer, so Speed / Range / Damage / HitCap and friends are all
-- set here, at spawn. There is no other point at which they can be set.
--------------------------------------------------------------------------

local function requireCM()
    if S.cm then return S.cm end
    local ok, m = pcall(function()
        return require(RS:WaitForChild("Modules", 5):WaitForChild("ClassModule", 5))
    end)
    if ok and m then S.cm = m end
    return S.cm
end

Core.requireCM = requireCM

-- Core.spawn{
--   template = "critical",        -- string name or Instance
--   cframe   = cf,
--   color    = nil,
--   charge   = nil,
--   direction= nil,
--   replicate= false,             -- false skips Projectile:FireServer entirely
--   options  = { Speed = 400, Range = 250, HitCap = 1 },
--   asPlayer = allyPlayer,        -- resolves template/skin/colors as them,
--                                 -- and sets Owner = them (0003.lua:2996)
--   unreliable = nil,
--   rawTemplate= nil,             -- skip class resolution
--   parent   = nil,               -- default ClientProjectiles
-- }
--
-- NOTE: asPlayer sets Owner, and the hit resolver is snapshotted at handler
-- start (0463.lua:12). A body spawned asPlayer=ally therefore deals NOTHING on
-- our client -- it is visual only. Damage needs a second body owned by us.
function Core.spawn(a)
    local cm = requireCM()
    if not cm then
        Log.warn("spawn failed: no ClassModule")
        return nil
    end
    local ok, proj = pcall(function()
        return cm:CreateProjectile(
            a.template,
            a.cframe,
            a.color,
            a.charge,
            a.direction,
            a.replicate,
            a.options,
            a.asPlayer,
            a.unreliable,
            a.rawTemplate,
            a.parent
        )
    end)
    if not ok then
        Log.err("spawn error", proj)
        return nil
    end
    return proj
end

--------------------------------------------------------------------------
-- 10a2. HIGH NOON — COWBOY F, a forged hitscan-looking shot
--
-- Fires N bullets that are already POINTED at a locked target, each applying
-- Burn on contact.
--
-- WHY IT AIMS INSTEAD OF HEATSEEKING, which is the whole design:
--
-- "Really fast" and "heatseeking" are mutually exclusive in this engine, and
-- not by accident. steerClampFor scales the turn clamp as 1/Speed, so a
-- hitscan-speed body is granted almost no turning authority -- and it does not
-- get that far anyway, because at 1200 studs/s a 40-stud engagement is over in
-- 0.03s, roughly two frames. legitMuzzleDelay plus the ramp mean zero steered
-- frames in that window. A fast heatseeking bolt IS a straight bolt; steering
-- it would be a no-op wearing a costume.
--
-- So the accuracy is spent at spawn instead: pickTarget picks the lock with the
-- same cone, budget and hittability rules as everything else, and the bullet is
-- created on a CFrame that already looks at them. It travels dead straight,
-- arrives effectively instantly, and there is no curve to notice -- which is
-- both a better hit rate and a more legit picture than a visibly bending
-- tracer.
--
-- The template is the class's OWN bullet. CreateProjectile resolves a string
-- against the caster's class and skin folder (0003.lua:2890), so passing
-- "attack" while playing COWBOY spawns a real cowboy round, correctly skinned.
-- Nothing bespoke, nothing that looks foreign to the kit.
--
-- BURN IS UNPROVEN AND IS TREATED AS SUCH. EffectApply goes through
-- EffectApply:InvokeServer with a password (0003.lua:2444) -- the server decides
-- whether the application is legal, and nothing in the dump proves it accepts
-- one from us against an arbitrary victim. It is ATTEMPTED and the result is
-- logged, never assumed; the damage lands regardless, because that comes from
-- the bullet's own handler. CS_CONSTRAINTS.md 6: being wrong toward the safe
-- path costs a status effect, being wrong the other way would cost the shot.
--------------------------------------------------------------------------
-- DEFAULTS ONLY. There is no `enabled` field here and there must never be one.
--
-- High Noon used to carry its own global switch (`highnoon on`, persisted as
-- S.highNoon, restored at boot). That was a second arming surface for something
-- that is simply part of what COWBOY does, and it produced the exact failure it
-- was supposed to prevent: on any machine that had never run the command -- ie.
-- every copy of dist/cs_portable.lua -- pressing F did nothing and said nothing.
--
-- It is now armed by the class, like every other class behaviour: `hs COWBOY`.
-- The gate in noteCastWindow reads `trig.owner.enabled`, which registerClass
-- forces to false at registration and never restores from disk, so the "must
-- not come up hot on inject" requirement is satisfied by the SAME mechanism
-- that satisfies it for steering, rather than by a rule of its own.
--
-- Per-class overrides live in the class entry (castTrigger.highNoon in
-- cs_classes.lua). Anything absent there falls back to these.
local HIGH_NOON = {
    template = "attack",   -- resolved against the caster's own class folder
    speed    = 1200,       -- hitscan-looking; well past any steerable range
    -- range and cone live in T (highNoonRange / highNoonFovDeg) so they can be
    -- moved with `hstune` mid-match without a rebuild. No copy kept here: a
    -- second value that only sometimes wins is the fallback shape CS_CONSTRAINTS
    -- §5b forbids.
    shots    = 1,          -- bullets per cast
    gapSec   = 0.06,       -- spacing when shots > 1
    -- How far an ally-cast round must get from its caster before it may touch
    -- anything. Its own constant rather than ECHO_CLEAR_STUDS, which is a local
    -- declared ~2300 lines below this point and would read as a nil global here.
    -- Same value, same reason -- keep them in step if either moves.
    clearStuds = 10,
}
Core.highNoon = HIGH_NOON

-- Resolve the effective High Noon config for a class. Field-by-field over the
-- defaults, not `classTable or HIGH_NOON`: a class that overrides one number
-- would otherwise silently lose every field it did not restate.
-- On Core, not a chunk-level `local`: cs_core.lua is at Luau's 200 top-level
-- local ceiling, and adding the 201st makes Potassium refuse the whole engine
-- while luau-compile still reports it clean (HANDOFF_2026-08-01 §2). Measured,
-- not guessed -- this function was written as a local first and the build
-- warning caught it.
function Core.highNoonCfg(cfg)
    local hn = cfg and cfg.castTrigger and cfg.castTrigger.highNoon
    if not hn then return HIGH_NOON end
    return {
        template   = hn.template   or HIGH_NOON.template,
        speed      = hn.speed      or HIGH_NOON.speed,
        shots      = hn.shots      or HIGH_NOON.shots,
        gapSec     = hn.gapSec     or HIGH_NOON.gapSec,
        clearStuds = hn.clearStuds or HIGH_NOON.clearStuds,
    }
end

-- Apply Burn to whoever this bullet hit.
--
-- Bound to the bullet's own Touched rather than to a timer, so a shot that
-- misses applies nothing -- a burn that lands with no bullet arriving is the
-- single most obvious tell this feature could produce.
local function burnOnHit(proj, myChar, casterChar)
    local done = false
    local c = proj.Touched:Connect(function(hit)
        if done or not proj.Parent then return end
        local victim = hit and hit:FindFirstAncestorOfClass("Model")
        if not victim or victim == myChar then return end
        -- Never burn the person whose ability this is. The round is forged at
        -- THEIR muzzle, so they are the first thing it can touch -- and in FFA
        -- nobody carries a Team child, so CheckTeam (0704.lua:233) rates an ally
        -- a perfectly valid victim. Exactly the bug that had ELEMENTALIST echoes
        -- burning the ally they were forged for.
        if casterChar and victim == casterChar then return end
        if not victim:FindFirstChild("HumanoidRootPart") then return end
        -- Mirror the engine's own hittability rules. Applying an effect to
        -- someone the game would refuse to damage is a request the server will
        -- reject anyway, and it is a request nobody legitimate ever makes.
        if not Core.isValidTarget(victim, myChar, nil) then return end
        done = true

        local cm = requireCM()
        if not (cm and cm.EffectApply) then
            Log.warn("high noon: no EffectApply — burn not applied")
            return
        end
        local head = victim:FindFirstChild("Head")
        local fx = game:GetService("ReplicatedStorage"):FindFirstChild("Effects")
        local burn = fx and fx:FindFirstChild("Burn")
        if not (head and burn) then
            Log.warn("high noon: Effects.Burn missing — burn not applied")
            return
        end
        -- UNPROVEN, per the note above. pcall'd because a rejected InvokeServer
        -- must not take the shot down with it.
        local ok, err = pcall(function() cm:EffectApply(victim, burn, head) end)
        logx("cast", ("high noon burn -> %s %s")
            :format(victim.Name, ok and "sent" or ("FAILED " .. tostring(err))))

        -- UPWARD KNOCKBACK — an EXPERIMENT, and it cannot self-verify.
        --
        -- Call shape copied verbatim from the game's own use (0250.lua:36):
        --     ClassModule:EffectApply(victim, "Knockup", victim.Head,
        --                             cf * CFrame.Angles(rad(45), 0, 0), 75)
        -- Effect is the STRING "Knockup" here, not an Effects instance the way
        -- Burn is -- the remote forwards args 2-7 verbatim after the password
        -- (0003.lua:2444), so both forms reach the server and it decides.
        --
        -- READ THIS BEFORE TRUSTING A RESULT: `EffectApply` is task.spawn'd with
        -- an internal pcall and returns NOTHING (0003.lua:2444-2465). There is no
        -- server answer to read, so `sent` below means "the request left this
        -- client" and nothing more. Whether it lands is a VISUAL question -- does
        -- the victim actually pop upward -- and per CS_CONSTRAINTS one
        -- observation is not evidence. Want a streak before believing it.
        --
        -- The game's own call sits inside `if v == LocalPlayer.Character`, i.e.
        -- each client applies effects to ITSELF on being hit. Asking the server
        -- to apply one to somebody else is precisely the unproven part.
        --
        -- Tell, if it does work: Sharpshooter already applies random upward
        -- knockback to a FOCUSED target natively. A knockup on an unfocused one,
        -- or with no bullet arriving, is the most obvious giveaway available --
        -- which is why this is bound to the bullet's Touched, same as the burn,
        -- and never to a timer.
        if T.highNoonKnockup then
            local up = proj.CFrame * CFrame.Angles(math.rad(45), 0, 0)
            local ok2, err2 = pcall(function()
                cm:EffectApply(victim, "Knockup", head, up, T.highNoonKnockupPower)
            end)
            logx("cast", ("high noon knockup -> %s %s (power=%d) — VISUAL CHECK ONLY")
                :format(victim.Name, ok2 and "sent" or ("FAILED " .. tostring(err2)),
                    T.highNoonKnockupPower))
        end
    end)
    -- Instance-keyed connections leak; drop it with the body.
    proj.Destroying:Connect(function() pcall(function() c:Disconnect() end) end)
    task.delay(4, function() pcall(function() c:Disconnect() end) end)
end

-- Fire one aimed bullet. Returns the body, or nil with a reason.
-- Resolve the bullet template from the CASTER's own class folder.
--
-- The string form of `template` is resolved by CreateProjectile against the
-- LOCAL player's class and skin (0003.lua:2890), which is right for our own
-- High Noon and wrong for an ally's: with us on another class, "attack" picked
-- OUR class's bullet and spawned it at the cowboy's muzzle. Same body count,
-- same damage, visibly the wrong projectile -- "not doing exactly what it did
-- for us".
--
-- The marker body carries a SourceObj pointing at its own template, and that
-- template's PARENT is the caster's Projectile folder -- `Projectile`, or
-- `ProjectileWoodland` and friends when they have a skin on (OverrideProjectile,
-- 0704.lua:284). Looking the bullet up in that folder gives their round, in
-- their skin, and it is exactly how forgeAllyEcho already does it.
local function templateFrom(marker, name)
    local so = marker and marker:FindFirstChild("SourceObj")
    local tpl = so and so.Value
    local folder = tpl and tpl.Parent
    if not folder then return nil end
    return folder:FindFirstChild(name)
end

local function highNoonShot(tgt, myChar, fromRoot, template, casterChar, hn)
    hn = hn or HIGH_NOON
    local root = fromRoot or (myChar and myChar:FindFirstChild("HumanoidRootPart"))
    local th = tgt and tgt:FindFirstChild("HumanoidRootPart")
    if not (root and th) then return nil, "no root" end

    -- Spawn at the muzzle, already looking at the target. This is the aiming.
    local from = root.Position
    local cf = CFrame.lookAt(from, th.Position)

    local proj = Core.spawnHit({
        -- An Instance when we resolved one from the caster's folder, with
        -- rawTemplate so CreateProjectile does not re-resolve it against US.
        -- Falls back to the string, which is correct for our own casts.
        template    = template or hn.template,
        rawTemplate = (template ~= nil) or nil,
        cframe      = cf,
        options  = {
            Speed = hn.speed,
            Range = T.highNoonRange,
            -- One target per bullet. Without it a hitscan round can chain
            -- through a crowd, which is neither asked for nor subtle.
            HitCap = 1,
        },
    })
    if not proj then return nil, "spawn failed" end

    -- Tag it IMMEDIATELY, not later. A body carrying Speed/Range/Damage and
    -- owned by us is indistinguishable from one of our own shots, and our
    -- watcher would claim it and put a second steerer on its mover.
    --
    -- Written inline rather than calling markTracked(): that helper is a local
    -- declared about 1300 lines further down, so naming it here would capture a
    -- nil global and fail at runtime, silently, the first time anyone pressed F.
    if not proj:FindFirstChild(CORE_TAG) then
        local tag = Instance.new("BoolValue")
        tag.Name = CORE_TAG
        tag.Value = true
        tag.Parent = proj
    end
    burnOnHit(proj, myChar, casterChar)

    -- An ally's round is born INSIDE them, so it must not be able to hit them on
    -- the way out. Same guard the ally echo carries, and for the same reason:
    -- the body is owned by us and FFA has no Team child, so the game is happy to
    -- let it damage the person we forged it for.
    --
    -- Continuous, not a timed window -- the timed version of this guard armed on
    -- expiry regardless of distance and hit the ally anyway.
    if casterChar and casterChar ~= myChar then
        pcall(function() proj.CanTouch = false end)
        task.spawn(function()
            local live = false
            while proj and proj.Parent do
                RunService.Heartbeat:Wait()
                if not (proj and proj.Parent) then return end
                local r = casterChar and casterChar:FindFirstChild("HumanoidRootPart")
                local clear = true
                if r and r.Parent then
                    clear = (proj.Position - r.Position).Magnitude >= hn.clearStuds
                end
                if clear ~= live then
                    live = clear
                    pcall(function() if proj.Parent then proj.CanTouch = clear end end)
                end
            end
        end)
    end
    return proj
end

-- Entry point. Driven by the CAST MARKER, for us or for an assisted ally.
--
-- `caster` is the player whose High Noon this is. When it is us we shoot from
-- our own muzzle; when it is an ally we shoot from THEIRS, because the shot is
-- theirs conceptually and firing it from our position would look like our gun
-- going off on its own.
--
-- The body is owned by US either way (spawnHit forces asPlayer = nil), because
-- Owner is snapshotted at handler start (0463.lua:12) and only the owner's
-- client resolves the hit. A body owned by the ally would be visual-only.
-- `cfg` is the class that owns the trigger. Passed in by noteCastWindow, which
-- already resolved it; resolved from OUR class when called by hand, which is
-- the only other caller and is always a self-cast.
function Core.fireHighNoon(caster, marker, cfg)
    caster = caster or lp
    local myChar = char()
    if not myChar then return false, "no character" end

    cfg = cfg or S.aliasMap[myClass()]
    if not (cfg and cfg.castTrigger) then
        return false, "current class has no high noon cast"
    end
    -- Armed by the class, never by a switch of its own. Checked here as well as
    -- in noteCastWindow so the manual command cannot bypass what `hs COWBOY`
    -- means -- one arming surface, no back door.
    if not cfg.enabled then
        return false, ("%s is not armed -- `hs %s`"):format(cfg.name or "class", cfg.name or "CLASS")
    end
    local hn = Core.highNoonCfg(cfg)

    local casterChar = (caster == lp) and myChar or (caster and caster.Character)
    local casterRoot = casterChar and casterChar:FindFirstChild("HumanoidRootPart")
    if not casterRoot then return false, "no caster root" end

    -- Their bullet, in their skin. nil for our own casts, where the string form
    -- already resolves correctly -- and nil if the marker has no usable
    -- SourceObj, which falls back to the string rather than refusing the shot.
    local template = templateFrom(marker, hn.template)
    if caster ~= lp and not template then
        logx("cast", ("high noon [%s] — no template from marker, using ours")
            :format(caster.Name))
    end

    -- Same lock the rest of the engine uses -- cone, deviation ceiling, range
    -- cap and every hittability gate. A bespoke target picker here would be a
    -- second oracle to keep in sync, and it would be the one that gets it wrong.
    -- Scanned from the CASTER's muzzle and facing, the same way the ally echo
    -- pre-lock does (ctx.originPos / originLook). Using our own aim for an
    -- ally's cast would pick a target they are not looking at.
    local ctx = nil
    if caster ~= lp then
        ctx = {
            originPos  = casterRoot.Position,
            originLook = casterRoot.CFrame.LookVector,
            allyPlayer = caster,
            allyName   = caster.Name,
            -- A SET keyed by the instance, not the instance itself.
            -- rejectReason does `ctx.exclude[c]`, so a bare Instance here is
            -- indexed with an Instance key and throws
            --   invalid argument #2 (string expected, got Instance)
            -- which pcall swallowed into "high noon error" on every single ally
            -- cast. Same shape the ally echo pre-lock builds (preCtx.exclude).
            exclude    = { [casterChar] = true },
        }
    end

    -- Wider and longer than any steered lock, on purpose. The cone override is
    -- ALSO passed as the ceiling, which is the only place in the engine that is
    -- allowed -- justified where highNoonFovDeg is declared.
    local tgt = Core.pickTarget(T.highNoonRange, myChar, ctx,
        T.highNoonFovDeg, nil, T.highNoonFovDeg)
    if not tgt then
        -- Logged, not silent. The first build swallowed this and the feature
        -- read as "nothing happens when I press F" when it was simply refusing
        -- a shot with nobody in the cone.
        Core.noteReject("high noon: no target")
        logx("cast", ("high noon [%s] — no target in cone"):format(caster.Name))
        return false, "no target in cone"
    end

    local fired = 0
    for i = 1, math.max(1, hn.shots) do
        local proj, why = highNoonShot(tgt, myChar, casterRoot, template, casterChar, hn)
        if proj then
            fired = fired + 1
        elseif why then
            Log.warn("high noon: " .. why)
        end
        if i < hn.shots then task.wait(hn.gapSec) end
    end

    logx("cast", ("high noon [%s] — %d shot(s) at %s speed=%d")
        :format(caster.Name, fired, tgt.Name, hn.speed))
    return fired > 0, ("high noon x%d -> %s"):format(fired, tgt.Name)
end

--------------------------------------------------------------------------
-- 10b. CAPABILITIES + PROBE 2
--
-- The open question from the roadmap: does a projectile spawned with
-- replicate=false still land damage, given it never sent a Projectile:FireServer
-- of its own? It matters because replicate=false is what removes the duplicate
-- bolt on other players' screens (0003.lua:2933), and it is the stock relay
-- path (0097.lua:152) -- but the relay's bodies are visual-only, so the fact
-- that the *call* is exercised every match does not answer whether *our* body,
-- owned by us, gets its Damage accepted.
--
-- Design rule here: the UNPROVEN path is never the default. Until a probe
-- confirms it, every hit body spawns with replicate=nil, which is the stock
-- behaviour we already know works. Being wrong then costs cosmetics (a second
-- bolt on other screens), not damage. If we defaulted the other way, being
-- wrong would silently cost every shot -- exactly the failure mode this whole
-- pass exists to remove.
--
-- Learned state persists so the answer survives a rejoin.
--------------------------------------------------------------------------

local CAPS_FILE = "cs_engine_caps.txt"

Core.caps = {
    -- nil = unknown, true = confirmed working, false = confirmed broken
    nonReplicatedDamage = nil,
    source = "unknown",
    probes = 0,
    confirms = 0,
}

-- Classes named in the state file, applied as they register. Registration
-- happens in cs_classes.lua *after* this file finishes, so the set has to be
-- held and applied in registerClass rather than written straight through.
local pendingEnabled = {}

local function loadCaps()
    if not (isfile and readfile and isfile(CAPS_FILE)) then return end
    local ok, body = pcall(readfile, CAPS_FILE)
    if not ok or type(body) ~= "string" then return end

    local val = body:match("nonReplicatedDamage%s*=%s*(%a+)")
    if val == "true" then
        Core.caps.nonReplicatedDamage = true
        Core.caps.source = "persisted"
    elseif val == "false" then
        Core.caps.nonReplicatedDamage = false
        Core.caps.source = "persisted"
    end

    -- Settings died on every rejoin, which meant re-toggling by hand each time.
    local list = body:match("enabled%s*=%s*([%w_,]*)")
    if list then
        for name in list:gmatch("[%w_]+") do pendingEnabled[name] = true end
    end

    for key, raw in body:gmatch("tune%.(%w+)%s*=%s*([%w%.%-]+)") do
        if T[key] ~= nil then
            local num = tonumber(raw)
            if num then
                T[key] = num
            elseif raw == "true" or raw == "false" then
                T[key] = (raw == "true")
            end
        end
    end
end

local function saveCaps()
    if not writefile then return end
    local v = Core.caps.nonReplicatedDamage

    local on = {}
    for _, name in ipairs(S.classOrder) do
        if S.classes[name] and S.classes[name].enabled then on[#on + 1] = name end
    end

    -- Only tunables that differ from the shipped defaults, so the file stays
    -- readable and a future default change is not silently overridden by a
    -- stale copy of the old value.
    local tuned = {}
    for key, def in pairs(T_DEFAULTS) do
        if T[key] ~= def then
            tuned[#tuned + 1] = ("tune.%s = %s"):format(key, tostring(T[key]))
        end
    end
    table.sort(tuned)

    local body = ("nonReplicatedDamage = %s\nenabled = %s\n%s"):format(
        v == nil and "unknown" or tostring(v),
        table.concat(on, ","),
        #tuned > 0 and (table.concat(tuned, "\n") .. "\n") or "")
    pcall(writefile, CAPS_FILE, body)
end

Core.saveCaps = saveCaps

-- Resolve DamageIndicator by exact reference. NEVER by fuzzy name: remotes.txt
-- carries a `ProjectiIe` homoglyph (capital I) that no game script touches, and
-- substring matching is precisely how you would fire it by accident.
local function damageIndicatorRemote()
    local remotes = RS:FindFirstChild("Remotes")
    if not remotes then return nil end
    local r = remotes:FindFirstChild("DamageIndicator")
    if r and r:IsA("RemoteEvent") then return r end
    return nil
end

-- Pending confirmations: [token] = { amount, hit }
local pendingConfirm = {}

-- A probe can fail for reasons that have nothing to do with replication (a
-- miss, the target going Safe, LOS breaking). Require a run before concluding.
local PROBE_FAIL_THRESHOLD = 3
local failedProbeStreak = 0
local probeSeq = 0

--------------------------------------------------------------------------
-- ECHO TRANSPORT AUTO-TRIAL
--
-- Settles `nonReplicatedDamage` from ORDINARY PLAY instead of a command. The
-- manual probe (Core.runProbe2) has existed since 2026-07-28 and has never
-- once produced a measurement -- the only trace in any log is a single
-- "PROBE2 spawn failed" -- so the capability that removes the ally's duplicate
-- projectile has stayed `unknown` indefinitely. A measurement nobody runs is
-- not a measurement.
--
-- Why this is safe to run live, and the reason it can be automatic at all:
-- the ally's OWN bolt still deals its own damage. Owner is snapshotted on
-- their client at handler start (0463.lua:12), so their shot resolves on their
-- machine no matter what we do. Our echo is bonus damage on top. A test-arm
-- echo that lands nothing costs the bonus on that shot and nothing else --
-- never the ally's actual shot.
--
-- Method: while the capability is unknown, every Nth echo is forged with
-- replicate=false (test arm) and the rest with the stock replicating path
-- (control arm). An echo that closed to within TRIAL_HIT_STUDS of its target
-- is an OPPORTUNITY; a server-confirmed DamageIndicator naming us as dealer
-- during that flight is a CONFIRM.
--
-- The control arm is the whole point. A test arm alone cannot tell "this
-- transport does not deal damage" from "that shot missed" -- which is exactly
-- why runProbe2's negative case was unfalsifiable, and why its 3-strike rule
-- could persist BROKEN on nothing but bad luck. Comparing two arms measured
-- the same way over the same play cancels aim, target quality and hit-window
-- noise, because whatever inflates or deflates one arm does it to both.
local TRIAL_CANARY_EVERY = 2     -- every 2nd echo while undecided
local TRIAL_MIN_OPS      = 6     -- opportunities per arm before deciding
-- 6 -> 12. Measured 2026-07-31: 101 forged echoes yielded THREE opportunities,
-- so the trial could not converge in a full session of play. 6 studs was chosen
-- as "should definitely have hit", but it is tighter than the game's own
-- collision and it threw away almost every usable sample.
--
-- Widening trades a little precision for a trial that actually finishes. It
-- costs nothing in correctness: the comparison is between two arms measured the
-- same way, so a looser threshold adds the same noise to both and cancels. A
-- trial that never decides is worth less than a slightly noisier one that does.
local TRIAL_HIT_STUDS    = 12    -- closest approach that counts as reaching
local TRIAL_MIN_CONTROL  = 0.25  -- control rate below this = our own rig is unreliable
local TRIAL_PASS_RATIO   = 0.60  -- test must reach this fraction of control

local echoTrial = {
    n       = 0,
    test    = { ops = 0, hits = 0 },
    control = { ops = 0, hits = 0 },
}

-- Weak-keyed: an echo that dies takes its entry with it, no sweep needed.
local echoArm = setmetatable({}, { __mode = "k" })

-- When each projectile first appeared on our client, for the `lag` field on
-- echo lines. Weak-keyed for the same reason.
local allySeenAt = setmetatable({}, { __mode = "k" })

-- Rolling echo diagnostics. The point of these is that ONE line in the log
-- answers "is ally assist healthy", instead of it having to be reconstructed
-- by counting `echo forged` lines and eyeballing timestamps.
local echoDiag = { n = 0, lags = {}, forged = 0, rejected = 0 }
local ECHO_DIAG_EVERY = 20

-- Per-ally-class body census.
--
-- Ten of the seventeen registered classes carry allow lists marked UNVERIFIED --
-- convention guesses for kits that are not streamed in the dump. For a class WE
-- arm, the arm-time audit reads the live folder and says which guesses were
-- right. For a class an ALLY is playing there is no such audit and never can be:
-- we cannot enumerate another player's class folder.
--
-- So the only ground truth available is the bodies their casts actually produce.
-- This records every body name seen per ally class and whether our allow list
-- accepted it. A class whose census is all-rejected has a wrong allow list, and
-- the census names the bodies it should have contained -- which is precisely the
-- evidence that has been missing every time an ally class "just does nothing".
local allyCensus = {}

local function noteAllyBody(className, bodyName, accepted)
    local c = allyCensus[className]
    if not c then c = { bodies = {}, n = 0 } ; allyCensus[className] = c end
    local b = c.bodies[bodyName]
    if not b then b = { ok = 0, no = 0 } ; c.bodies[bodyName] = b end
    if accepted then b.ok = b.ok + 1 else b.no = b.no + 1 end
    c.n = c.n + 1
end

-- One line per ally class. Emitted with ECHO DIAG so a single grep answers
-- "is ally assist actually working, and if not, what should allow contain".
local function logAllyCensus()
    for className, c in pairs(allyCensus) do
        local acc, rej, anyOk = {}, {}, false
        for name, b in pairs(c.bodies) do
            if b.ok > 0 then
                acc[#acc + 1] = ("%s x%d"):format(name, b.ok)
                anyOk = true
            else
                rej[#rej + 1] = ("%s x%d"):format(name, b.no)
            end
        end
        table.sort(acc) ; table.sort(rej)
        local line = ("ALLY BODIES [%s] echoed={%s} refused={%s}")
            :format(className,
                #acc > 0 and table.concat(acc, ", ") or "NONE",
                #rej > 0 and table.concat(rej, ", ") or "none")
        if anyOk then
            Log.info(line)
        else
            -- Every body refused: the allow list does not match reality for this
            -- ally's class. Warn, because it is silent in play -- the ally just
            -- gets no assist and nothing says why.
            Log.warn(line .. " — allow list matches NO body this ally fired")
        end
    end
end

local function pct(sorted, p)
    if #sorted == 0 then return -1 end
    local i = math.max(1, math.ceil(#sorted * p))
    return sorted[math.min(i, #sorted)]
end

local function noteEchoDiag(lagMs)
    echoDiag.forged = echoDiag.forged + 1
    if lagMs and lagMs >= 0 then
        echoDiag.lags[#echoDiag.lags + 1] = lagMs
    end
    echoDiag.n = echoDiag.n + 1
    if echoDiag.n < ECHO_DIAG_EVERY then return end
    echoDiag.n = 0
    local s = table.clone(echoDiag.lags)
    table.sort(s)
    Log.info(("ECHO DIAG forged=%d lag p50=%dms p90=%dms max=%dms · %s")
        :format(echoDiag.forged, pct(s, 0.5), pct(s, 0.9), pct(s, 1.0),
            Core.echoTrialStatus()))
    logAllyCensus()
    echoDiag.lags = {}
end

-- Returns replicate value and arm name for the next echo.
local function pickEchoTransport()
    local known = Core.caps.nonReplicatedDamage
    if known == true then return false, nil end   -- proven: always non-replicated
    if known == false then return nil, nil end    -- proven broken: stock path
    echoTrial.n = echoTrial.n + 1
    if echoTrial.n % TRIAL_CANARY_EVERY == 0 then
        return false, "test"
    end
    return nil, "control"
end

local function decideTrial()
    local t, c = echoTrial.test, echoTrial.control
    if t.ops < TRIAL_MIN_OPS or c.ops < TRIAL_MIN_OPS then return end

    local tr = t.hits / t.ops
    local cr = c.hits / c.ops

    -- Control is the yardstick. If the KNOWN-GOOD transport is not landing
    -- either, nothing was measured -- the shots are missing, or targets are
    -- Safe/Challenge-tagged, or we are picking locks the bolts cannot reach.
    -- Reset and keep sampling rather than convict the test arm for it.
    if cr < TRIAL_MIN_CONTROL then
        Log.warn(("echo trial: control only %.0f%% (%d/%d) — rig unreliable, resampling")
            :format(cr * 100, c.hits, c.ops))
        echoTrial.test    = { ops = 0, hits = 0 }
        echoTrial.control = { ops = 0, hits = 0 }
        return
    end

    if tr >= cr * TRIAL_PASS_RATIO then
        Core.caps.nonReplicatedDamage = true
        Core.caps.source = "trial"
        saveCaps()
        Log.info(("echo trial DECIDED: replicate=false WORKS "
            .. "(test %.0f%% %d/%d vs control %.0f%% %d/%d) — "
            .. "echoes now non-replicated; allies stop seeing duplicates")
            :format(tr * 100, t.hits, t.ops, cr * 100, c.hits, c.ops))
    else
        Core.caps.nonReplicatedDamage = false
        Core.caps.source = "trial"
        saveCaps()
        Log.warn(("echo trial DECIDED: replicate=false LANDS NO DAMAGE "
            .. "(test %.0f%% %d/%d vs control %.0f%% %d/%d) — "
            .. "staying on the replicating path; duplicates are unavoidable")
            :format(tr * 100, t.hits, t.ops, cr * 100, c.hits, c.ops))
    end
end

-- Called once per finished echo flight, before any early return.
local function noteTrialFlight(arm, minRange, hitsGained)
    if not arm then return end
    if Core.caps.nonReplicatedDamage ~= nil then return end
    if not minRange or minRange > TRIAL_HIT_STUDS then return end
    local a = echoTrial[arm]
    if not a then return end
    a.ops = a.ops + 1
    if hitsGained > 0 then a.hits = a.hits + 1 end
    decideTrial()
end

function Core.echoTrialStatus()
    local t, c = echoTrial.test, echoTrial.control
    local known = Core.caps.nonReplicatedDamage
    return ("echo transport: %s · trial test %d/%d control %d/%d (need %d each)")
        :format(known == nil and "undecided" or (known and "non-replicated" or "replicating"),
            t.hits, t.ops, c.hits, c.ops, TRIAL_MIN_OPS)
end

-- Boot-time invariant check is registered at the bottom of this file, next to
-- the other one-shot init calls. See Core.auditTunables.
local function watchDamageIndicator()
    local r = damageIndicatorRemote()
    if not r then
        Log.warn("DamageIndicator not found — probe cannot self-confirm")
        return
    end
    conn(r.OnClientEvent, function(payload)
        -- damageIndicator(dealer, victim, amount, kind) -- 0097.lua:259
        local dealer, _victim, amount
        if type(payload) == "table" then
            dealer, _victim, amount = payload[1], payload[2], payload[3]
        else
            dealer, _victim, amount = payload, nil, nil
        end
        if dealer ~= lp and dealer ~= char() then return end
        local n = tonumber(amount)
        if not n then return end

        -- Real, server-confirmed damage by us. This is the only honest source
        -- for the hit counter: counting our own Damage calls would report
        -- attempts, and the panel would claim hits the server never accepted.
        Core.stats.hits = Core.stats.hits + 1
        if typeof(_victim) == "Instance" then S.ledger[_victim] = os.clock() end
        Core.noteHitOutcome(true)

        for token, rec in pairs(pendingConfirm) do
            if math.abs(n - rec.amount) < 0.05 then
                rec.hit = true
                pendingConfirm[token] = nil
                break
            end
        end
    end)
end

-- Probe 2. Spawns ONE body with replicate=false and a fractional damage value
-- so a confirmation cannot be a coincidental real hit, then waits for the
-- server's own DamageIndicator broadcast to name us as dealer.
--
-- Returns: confirmed(bool), detail(string)
function Core.runProbe2(opts)
    opts = opts or {}
    local cm = requireCM()
    if not cm then return false, "no ClassModule" end

    local mc = char()
    local root = mc and mc:FindFirstChild("HumanoidRootPart")
    if not root then return false, "no character" end

    local target = opts.target or Core.pickTarget(nil, mc, nil)
    if not target then return false, "no target in cone — face someone first" end
    local th = target:FindFirstChild("HumanoidRootPart")
    if not th then return false, "target has no HRP" end

    -- Fractional, and distinct from anything the game deals naturally.
    local amount = opts.amount or 3.7
    -- Counter, not os.clock(): two probes in the same frame would collide on a
    -- clock-derived token and the second would read the first's result.
    probeSeq = probeSeq + 1
    local token = "probe" .. probeSeq
    pendingConfirm[token] = { amount = amount, hit = false }

    local dir = (th.Position - root.Position)
    local cf = CFrame.new(root.Position + Vector3.new(0, 2, 0),
        root.Position + Vector3.new(0, 2, 0) + dir)

    -- Resolve a template that ACTUALLY EXISTS for the class being played.
    --
    -- This used to hardcode "attack", and CreateProjectile resolves the name
    -- against the current class's own Projectile folder (0003.lua:2795),
    -- returning nil when it is not there. Live result: "PROBE2 spawn failed --
    -- CreateProjectile returned nil", which reads like the capability failed
    -- when in fact the probe never fired a shot. Classes whose LMB is not
    -- literally named `attack` could never be probed at all.
    local template = opts.template
    if not template then
        local bodies = Core.listClassBodies()
        if bodies then
            for _, b in ipairs(bodies) do
                if b.bolt then template = b.name break end
            end
        end
        template = template or "attack"
    end

    local proj = Core.spawn({
        template = template,
        cframe = cf,
        replicate = false,          -- THE variable under test
        options = {
            Speed = 260,
            Range = math.max(dir.Magnitude + 40, 120),
            Damage = amount,
            HitCap = 1,
        },
    })

    if not proj then
        pendingConfirm[token] = nil
        -- Say WHICH template and what the class actually offers. "returned nil"
        -- alone sent the last run looking for a damage problem when the shot
        -- was never fired. Note this is NOT counted as a failed probe: nothing
        -- was measured, so the streak must not move.
        local bodies = Core.listClassBodies()
        local names = {}
        if bodies then
            for _, b in ipairs(bodies) do
                if b.bolt then names[#names + 1] = b.name end
            end
        end
        local detail = ("PROBE2 spawn failed — class %s has no projectile %q")
            :format(myClass(), tostring(template))
        if #names > 0 then
            detail = detail .. ". Real bolts: " .. table.concat(names, ", ")
        else
            detail = detail .. ". No streamed Projectile folder for this class."
        end
        Log.warn(detail)
        return false, detail
    end

    Core.caps.probes = Core.caps.probes + 1

    -- Claim the body before the watcher can. The probe carries Speed, Range and
    -- Damage and is owned by us, so an enabled class would otherwise classify it
    -- as one of our shots and steer it too -- two steerers fighting over one
    -- BodyVelocity, which would corrupt the very flight the probe is measuring.
    pcall(function()
        local t = Instance.new("BoolValue")
        t.Name = CORE_TAG
        t.Value = true
        t.Parent = proj
    end)

    Log.info(("PROBE2 fired replicate=false dmg=%s target=%s")
        :format(tostring(amount), target.Name))

    -- Steer it in, so the probe tests damage rather than our aim.
    task.spawn(function()
        local stop = os.clock() + 3
        while proj and proj.Parent and os.clock() < stop do
            RunService.Heartbeat:Wait()
            if not (proj and proj.Parent and th and th.Parent) then break end
            pcall(function()
                local d = th.Position - proj.Position
                if d.Magnitude > 1e-3 then ensureMover(proj, 260, d.Unit) end
            end)
        end
    end)

    local deadline = os.clock() + (opts.timeout or 3.5)
    while os.clock() < deadline do
        local rec = pendingConfirm[token]
        if not rec or rec.hit then break end
        RunService.Heartbeat:Wait()
    end

    local confirmed = pendingConfirm[token] == nil
    pendingConfirm[token] = nil

    if confirmed then
        Core.caps.confirms = Core.caps.confirms + 1
        failedProbeStreak = 0
        Core.caps.nonReplicatedDamage = true
        Core.caps.source = "probe"
        saveCaps()
        Log.info("PROBE2 CONFIRMED — replicate=false damage lands; engine will use it")
        return true, "confirmed: non-replicated damage lands"
    end

    -- A single unconfirmed probe is INCONCLUSIVE, not proof of failure. The shot
    -- can miss, the target can go Safe or die mid-flight, LOS can break, they can
    -- walk out of range. Recording "BROKEN" on one miss -- and persisting it
    -- across rejoins -- would permanently disable the better path on bad luck.
    --
    -- Only a run of failures is evidence. Until then the capability stays
    -- unknown, which already means the engine uses the safe path.
    failedProbeStreak = failedProbeStreak + 1
    if failedProbeStreak >= PROBE_FAIL_THRESHOLD then
        Core.caps.nonReplicatedDamage = false
        Core.caps.source = "probe"
        saveCaps()
        Log.warn(("PROBE2 UNCONFIRMED x%d — recording replicate=false as BROKEN")
            :format(failedProbeStreak))
        return false, ("unconfirmed x%d — recorded as broken"):format(failedProbeStreak)
    end

    Log.warn(("PROBE2 UNCONFIRMED (%d/%d) — inconclusive, could be a miss. Run again.")
        :format(failedProbeStreak, PROBE_FAIL_THRESHOLD))
    return false, ("inconclusive %d/%d — could be a miss, run again")
        :format(failedProbeStreak, PROBE_FAIL_THRESHOLD)
end

-- The engine's spawn for bodies that must DEAL damage. Chooses the transport
-- from proven capability, never from optimism.
function Core.spawnHit(a)
    a = a or {}
    -- An explicit trialReplicate overrides the proven-capability default. Only
    -- the echo trial sets it, and only while the capability is unknown -- once
    -- decided, pickEchoTransport stops emitting an arm and this falls through
    -- to the normal rule below.
    if a.trialReplicate ~= nil then
        -- NOT `a.trialReplicate or nil` -- in Lua that folds false to nil, which
        -- is the replicating path, i.e. the exact opposite of what the test arm
        -- asked for. The trial would have silently measured two control arms.
        a.replicate = (a.trialReplicate == false) and false or nil
        a.trialReplicate = nil
    else
        local useNonReplicated = (Core.caps.nonReplicatedDamage == true)
        a.replicate = useNonReplicated and false or nil
    end
    a.asPlayer = nil  -- Owner must be us or our client will not resolve the hit
    return Core.spawn(a), useNonReplicated
end

-- Runtime watchdog. If the non-replicated path was proven once but then stops
-- confirming, revert immediately rather than bleeding shots for a whole match.
local unconfirmedStreak = 0

function Core.noteHitOutcome(confirmed)
    if Core.caps.nonReplicatedDamage ~= true then return end
    if confirmed then
        unconfirmedStreak = 0
        return
    end
    unconfirmedStreak = unconfirmedStreak + 1
    if unconfirmedStreak >= 5 then
        Core.caps.nonReplicatedDamage = false
        Core.caps.source = "watchdog"
        saveCaps()
        unconfirmedStreak = 0
        Log.warn("watchdog: 5 unconfirmed non-replicated hits — reverted to replicating path")
    end
end

function Core.capsSummary()
    local v = Core.caps.nonReplicatedDamage
    return ("replicate=false damage: %s (%s) · probes %d/%d confirmed"):format(
        v == nil and "UNKNOWN" or (v and "WORKS" or "BROKEN"),
        Core.caps.source, Core.caps.confirms, Core.caps.probes)
end

--------------------------------------------------------------------------
-- 11. CLASS REGISTRY
--------------------------------------------------------------------------
-- CAST WINDOWS — "while this ability is active, only steer some of it"
--
-- Built for ROCKETEER Blast Off, and the constraint that forced it: the eight
-- Blast Off rockets and the ordinary LMB rocket are the SAME BODY (`attack1` /
-- `attack2` -- the class has no `critical` template at all), so there is no name
-- to key on and no way to configure the two casts differently by allow list.
--
-- Blast Off launches the player upward and the rockets leave on a steep
-- vertical arc, which is a bad shape to steer: correcting all eight of them
-- toward one target turns a fountain into a funnel, and it is the most visible
-- thing in the kit. Steering a QUARTER of them keeps the assist without
-- flattening the arc, and the ones left alone fly exactly as the game threw
-- them -- which is also the more legit-looking failure.
--
-- How the window is detected: a MARKER body. `criticaleff1` / `criticaleff2`
-- are the CRT slot's VFX and only spawn on a Blast Off cast, so their arrival
-- opens a timed window for that owner. Markers are ordinary bodies we still
-- refuse to steer (the `eff` deny catches them); this only observes them.
--
-- Config shape (engine/cs_classes.lua):
--     castWindow = {
--         markers        = { "criticaleff1", "criticaleff2" },
--         seconds        = 6,
--         closeLockStuds = 48,
--     }
--
-- `closeLockStuds` replaces CLOSE_LOCK_STUDS while the window is open: the
-- close-lock cylinder around the aim line gets fatter, so targets a long way
-- OFF THE AIM LINE -- including well above or below it -- stay acquirable.
--
-- Why the cylinder and not the cone. The cylinder test is `lateral <= studs`,
-- where lateral is perpendicular distance from the aim line in STUDS. That is
-- already the vertical-tolerance knob: a target 30 studs below the aim line is
-- inside a 48-stud cylinder regardless of how extreme the ANGLE gets. Widening
-- the cone instead would buy far less, because at close range the angle to a
-- target below you goes enormous while the lateral offset stays small -- the
-- exact geometry the cylinder exists for.
--
-- It is bounded in studs, so it cannot open into a wide-angle lock at distance
-- the way a raised fov would: at 200 studs, 48 studs of lateral is still only
-- 13.8 degrees.
--
-- Keyed by OWNER, not globally, so an ally's Blast Off widens their acquisition
-- and not yours.
--
-- HISTORY: this replaced a `steerChance` dice roll (25% of rockets steered,
-- rest left alone), on instruction. The dice reduced how OFTEN the bad-looking
-- case happened without changing the case itself; widening acquisition attacks
-- the actual complaint, which is that a hovering Rocketeer's targets sit far
-- off the aim line vertically and were simply never acquired.
local castWin = { byOwner = {}, markers = {}, triggers = {}, firedAt = {}, rng = Random.new() }

-- Registered by registerClass so the lookup is O(1) on a name we see for every
-- single body in the game, not a scan of every class.
local function registerCastWindowMarkers(cfg)
    local cw = cfg.castWindow
    if cw and cw.markers then
        for _, m in ipairs(cw.markers) do
            castWin.markers[string.lower(m)] = cfg
        end
    end
    -- Cast triggers, same lookup shape: O(1) on a name every body in the game
    -- is tested against.
    local ct = cfg.castTrigger
    if ct and ct.markers then
        -- Remember which class owns the trigger, so a same-named body from a
        -- different kit cannot fire it. See noteCastWindow.
        ct.owner = cfg
        for _, m in ipairs(ct.markers) do
            castWin.triggers[string.lower(m)] = ct
        end
    end
end

-- Called for every body that resolves an owner, before class matching.
local function noteCastWindow(proj, owner)
    if not owner then return end
    local name = string.lower(proj.Name)

    -- Marker names are NOT unique across classes, and assuming they were is a
    -- bug this shipped with.
    --
    -- ROCKETEER registers `criticaleff1` as its Blast Off marker. COWBOY also
    -- has a body called `criticaleff1` -- confirmed in its own arm-time audit --
    -- so playing COWBOY and pressing F logged
    --     ROCKETEER window open 6.0s (criticaleff1)
    -- and silently widened COWBOY's close-lock cylinder to 48 studs for six
    -- seconds. Cross-class contamination, invisible except for that one line.
    --
    -- So a marker only counts when the body's own PROVENANCE resolves to the
    -- class that registered it. Core.sourceClassName is resolved through the
    -- Core table rather than the `sourceClassName` local, which is declared
    -- below this function.
    local srcClass = Core.sourceClassName and Core.sourceClassName(proj) or nil
    local function ownedByClass(want)
        -- Provenance when we have it. When SourceObj is unresolvable, fall back
        -- to the caster's own class -- for us that is CurrentClass; for anyone
        -- else we cannot read it, so require provenance rather than guess.
        if srcClass then return Core.aliasMatches(want, srcClass) end
        if owner == lp then return Core.aliasMatches(want, myClass()) end
        return false
    end

    local cfg = castWin.markers[name]
    if cfg and ownedByClass(cfg) then
        local secs = cfg.castWindow.seconds or 5
        castWin.byOwner[owner] = os.clock() + secs
        logx("cast", ("%s window open %.1fs (%s)"):format(cfg.name, secs, proj.Name))
    end

    -- CAST TRIGGERS — a marker body that FIRES something rather than opening a
    -- window. COWBOY is the case: the marker is `criticalimpact`, which arrives
    -- once per SHARPSHOOTER SHOT during the High Noon stance -- so our round
    -- goes out per shot, not once per stance. See the COWBOY entry for why the
    -- stance-entry body (`criticalshow`) was the wrong hook.
    --
    -- This replaced an F-keypress trigger, which was wrong twice over: it fired
    -- on the key rather than on the ability, so a press on cooldown or while
    -- stunned still spawned bullets -- and it could never work for an ALLY,
    -- because we cannot see their keyboard. A marker is owner-stamped and every
    -- player's bodies come through this same watcher, so self and ally are the
    -- same code path with no extra machinery.
    -- The enabled check sits INSIDE the ownership test below, not here. Every
    -- COWBOY on the server emits this body, so testing `enabled` first would
    -- mean the OFF branch (which logs) ran for strangers too.
    local trig = castWin.triggers[name]
    if trig and trig.owner and ownedByClass(trig.owner) then
        -- Only for us or for someone we are actually assisting. Every COWBOY on
        -- the server emits this body, and forging a shot for a stranger's cast
        -- is both pointless and a lot of projectiles.
        local mine = (owner == lp)
        if mine or (Core.allyHeatseekEnabled() and Core.isAllyPlayer(owner)) then
            if not trig.owner.enabled then
                -- SILENT GATE, said out loud. The class is not armed, so the
                -- cast is correctly ignored -- but it used to be ignored in
                -- total silence, which reads as "the script is broken" rather
                -- than "turn the class on". HANDOFF_2026-08-01 §4: a gate with
                -- no name in the log is a multi-session bug.
                --
                -- Scalar on castWin, not a table keyed by owner. Two reasons:
                -- there is at most one caster this can fire for (we are already
                -- inside the self/ally test), and an owner-keyed table here
                -- would hold a strong reference to every player who has cast.
                -- No chunk-level `local` either -- cs_core.lua is at Luau's
                -- 200 top-level-local ceiling (HANDOFF_2026-08-01 §2).
                local now = os.clock()
                if not castWin.hintedAt or (now - castWin.hintedAt) > 30 then
                    castWin.hintedAt = now
                    Log.warn(("high noon: %s cast detected but %s is not armed"
                        .. " -- `hs %s`"):format(proj.Name,
                        trig.owner.name or "the class", trig.owner.name or "CLASS"))
                end
            else
                -- One shot per cast. criticalshow can appear more than once per
                -- High Noon (skin variants each carry their own copy), and
                -- without this a single F would fire a burst per duplicate body.
                local last = castWin.firedAt[owner]
                local now = os.clock()
                if not last or (now - last) > (trig.cooldown or 1.0) then
                    castWin.firedAt[owner] = now
                    task.spawn(function()
                        -- `proj` is the marker body; fireHighNoon reads the
                        -- caster's own bullet template out of it.
                        local ok, why = pcall(Core.fireHighNoon, owner, proj,
                                                      trig.owner)
                        if not ok then Log.err("high noon error", why) end
                    end)
                end
            end
        end
    end
end

-- Is this owner's cast window open right now?
local function castWindowOpen(cfg, owner)
    local cw = cfg and cfg.castWindow
    if not cw or not owner then return nil end
    local until_ = castWin.byOwner[owner]
    if not until_ then return nil end
    if os.clock() > until_ then
        -- Expired. Cleared rather than left to rot: this table is keyed by
        -- Player instances, and an instance-keyed table that is never pruned
        -- holds a strong reference to everyone who has ever cast.
        castWin.byOwner[owner] = nil
        return nil
    end
    return cw
end

-- The close-lock radius to use for this body: the window's while it is open,
-- otherwise nil, meaning the global CLOSE_LOCK_STUDS.
local function castWindowCloseLock(cfg, owner)
    local cw = castWindowOpen(cfg, owner)
    return cw and cw.closeLockStuds or nil
end

-- What the OVERLAY should draw right now. The visualiser has no cfg and no body
-- in hand, so it asks across every registered class: if one of OUR windows is
-- open, the widened cylinder is the one actually in force.
--
-- Drawn at its real size rather than assumed, because a lock volume that
-- silently triples for six seconds is the kind of invisible state that makes
-- the engine feel arbitrary -- the same reason the cone is drawn at the current
-- class's real cap instead of the fallback.
function Core.activeCloseLock()
    for _, name in ipairs(S.classOrder) do
        local cfg = S.classes[name]
        local studs = cfg and castWindowCloseLock(cfg, lp)
        if studs then return studs, cfg.name end
    end
    return nil, nil
end

--------------------------------------------------------------------------

Core.gates = {}

-- Resolve which RS.Classes.<NAME> a projectile came from, by walking up from
-- its SourceObj. Returns nil when the class is not streamed.
local function sourceClassName(proj)
    local so = proj:FindFirstChild("SourceObj")
    local src = so and so.Value
    if not src then return nil end
    local classes = RS:FindFirstChild("Classes")
    if not classes then return nil end
    local n = src
    while n and n ~= RS do
        if n.Parent == classes then return n.Name end
        n = n.Parent
    end
    return nil
end

Core.sourceClassName = sourceClassName

local function projOwner(proj)
    local ov = proj:FindFirstChild("Owner")
    if ov and ov:IsA("ObjectValue") and ov.Value and ov.Value:IsA("Player") then
        return ov.Value
    end
    return nil
end

Core.projOwner = projOwner

local function weldedToCharacter(proj, c)
    if not c or not proj then return false end
    local function touches(part)
        return part and typeof(part) == "Instance" and part:IsDescendantOf(c)
    end
    for _, w in ipairs(proj:GetChildren()) do
        if w:IsA("Weld") or w:IsA("Motor6D") or w:IsA("WeldConstraint") then
            if touches(w.Part0) or touches(w.Part1) then return true end
        end
    end
    local ok, joints = pcall(function() return proj:GetJoints() end)
    if ok and joints then
        for _, w in ipairs(joints) do
            if w:IsA("Weld") or w:IsA("Motor6D") or w:IsA("WeldConstraint") then
                if touches(w.Part0) or touches(w.Part1) then return true end
            end
        end
    end
    return false
end

-- Combat free-bullet markers. Real bullets carry Speed + Range + Damage plus a
-- BodyVelocity (MUSKETEER attack 0463, critical 0473). VFX handlers only ever
-- touch Speed, so a missing Range or Damage is the cheap way to reject them.
local function baseShotReject(part)
    if not part or not part:IsA("BasePart") then return "not basepart" end
    if part:FindFirstChild(CORE_TAG) then return "already tracked" end
    if part:FindFirstChild("CFrameOffset") then return "slash vfx" end
    if part:FindFirstChild("SlashEffectWeld") then return "slash weld" end
    if part:FindFirstChild("PForgeBV") then return "forge body" end
    if not part:FindFirstChild("Speed") then return "no speed" end
    if not part:FindFirstChild("Range") then return "no range (vfx)" end
    if not part:FindFirstChild("Damage") then return "no damage (vfx)" end
    return nil
end

-- Class provenance gate. Works for classes absent from the dump (TRICKSTER and
-- ELEMENTALIST are not streamed -- keyword_index.txt), because it never needs a
-- template name: it accepts when the projectile's SourceObj resolves to one of
-- the class aliases, or when SourceObj is unresolvable but we are playing the
-- class ourselves.
-- Prefix-tolerant alias match. The folder name and the CurrentClass value do
-- not always agree: the chrono folder is CHRONO while everything human-facing
-- says CHRONOS, and registering only the latter silently killed the class --
-- every shot rejected as "class CHRONO", with nothing on screen to say why.
-- Requiring a decent prefix length keeps this from matching unrelated classes.
local function aliasMatches(cfg, name)
    if not name or name == "" then return false end
    if cfg.aliasSet[name] then return true end
    for alias in pairs(cfg.aliasSet) do
        local short = #alias < #name and alias or name
        local long = #alias < #name and name or alias
        if #short >= 5 and long:sub(1, #short) == short then return true end
    end
    return false
end

Core.aliasMatches = aliasMatches

function Core.gates.classProvenance(cfg, proj, ctx)
    local cls = sourceClassName(proj)
    if cls and aliasMatches(cfg, cls) then return nil end
    if cls then return "class " .. cls end
    if aliasMatches(cfg, myClass()) then return nil end
    return "unresolved class"
end

-- Template gate for streamed classes. Matches the part name OR the SourceObj
-- name -- checking SourceObj alone rejected everything for elementalist.
function Core.gates.templates(cfg, proj, ctx)
    local names = cfg.templates
    if not names or #names == 0 then return Core.gates.classProvenance(cfg, proj, ctx) end

    -- If the class IS resolvable and is not ours, reject regardless of the name.
    -- Template substrings are loose ("smolder" would match a similarly-named
    -- projectile from another class), and a name collision must not let one
    -- class claim another's shots. When the class is unresolvable -- the normal
    -- case for unstreamed classes -- fall through to the name match.
    local cls = sourceClassName(proj)
    if cls and not aliasMatches(cfg, cls) then return "class " .. cls end

    local partName = string.lower(proj.Name)
    local so = proj:FindFirstChild("SourceObj")
    local srcName = so and so.Value and string.lower(so.Value.Name) or ""
    for _, want in ipairs(names) do
        local w = string.lower(want)
        if string.find(partName, w, 1, true) or string.find(srcName, w, 1, true) then
            return nil
        end
    end
    return "template mismatch"
end

-- Register a class. Config shape:
--   aliases   = { "SNIPER", "MUSKETEER" }   CurrentClass values that map here
--   accept    = Core.gates.classProvenance  or Core.gates.templates
--   templates = { "fireability2" }          only for the templates gate
--   options   = { HitCap = 1 }              spawn options for bodies we create
--   flight    = { stopWhenReturningToOwner = true }
--   deny      = { "baton", "cosmetic" }     substrings we never touch
function Core.registerClass(name, cfg)
    cfg = cfg or {}
    cfg.name = name
    cfg.aliases = cfg.aliases or { name }
    cfg.aliasSet = {}
    for _, a in ipairs(cfg.aliases) do cfg.aliasSet[a] = true end
    cfg.accept = cfg.accept or Core.gates.classProvenance
    cfg.options = cfg.options or {}
    cfg.flight = cfg.flight or {}
    cfg.deny = cfg.deny or {}
    -- Per-body cone overrides are looked up by lowercased body name, so the keys
    -- are normalised once here rather than trusting every config to be written
    -- in lower case. The ally matcher was case-SENSITIVE while the self matcher
    -- lowercased, and a class heatseeking for you but silently refusing the same
    -- bodies for an ally is the exact bug that cost a session -- the same trap
    -- applies to any name-keyed table.
    if type(cfg.lockFov) == "table" then
        local norm = {}
        for k, v in pairs(cfg.lockFov) do
            if type(k) == "string" then norm[string.lower(k)] = v end
        end
        cfg.lockFov = norm
    end
    registerCastWindowMarkers(cfg)
    -- ALWAYS off at registration. Never restored from the state file.
    --
    -- This used to re-arm whatever was on last session (`pendingEnabled`), and
    -- cs_engine_caps.txt was duly carrying
    -- `enabled = FIGHTER,FROST,GAMBLER,MEDIC,MUSKETEER,SNIPER,WINDDANCER`.
    -- That directly contradicts the standing rule that settings persist and
    -- SWITCHES do not: a script that restores its own toggles comes up hot the
    -- instant you inject into a live match, which is the one moment you least
    -- want it to. Tunables still persist; arming is always a deliberate act.
    cfg.enabled = false
    S.classes[name] = cfg
    for _, a in ipairs(cfg.aliases) do S.aliasMap[a] = cfg end

    S.classOrder = {}
    for n in pairs(S.classes) do S.classOrder[#S.classOrder + 1] = n end
    table.sort(S.classOrder)

    Log.info(("class registered: %s (%d alias)"):format(name, #cfg.aliases))
    return cfg
end

-- BOOT SELF-AUDIT
--
-- Run once after cs_classes.lua finishes registering. It exists because every
-- class-config failure so far has been SILENT: a wrong alias, a missing allow
-- list or a deny that eats its own allow entry all present as "the class just
-- does nothing", which is indistinguishable from "badly tuned" and has burned
-- whole test sessions.
--
-- Reports, not fixes. A config the engine quietly rewrote would be worse.
--------------------------------------------------------------------------
-- TUNABLE INVARIANT AUDIT
--
-- Every rule here was previously enforced by a COMMENT next to the tunable,
-- and the FOV/deviation one was broken twice by retunes that moved both
-- numbers and left zero margin -- silently, because nothing checked. The cost
-- was locks the engine committed to and then abandoned mid-flight, which reads
-- in play as "heatseek is inconsistent" and took a log dig to find.
--
-- A comment cannot fail a build or write a warning. This can. Runs at boot and
-- again after every Core.tune, so a live `hstune` cannot quietly break a
-- relationship between two settings that individually look reasonable.
--
-- Findings are WARNINGS, never refusals: an experiment that trips an invariant
-- on purpose is legitimate, and a tuning tool that argues back is a tuning tool
-- people stop using. The point is that it can never happen unnoticed.
function Core.auditTunables()
    local found = {}
    local function bad(fmt, ...) found[#found + 1] = (fmt):format(...) end

    -- 1. The lock cone must leave the deviation budget real headroom.
    --    pickTarget now clamps this, so the failure mode is no longer a broken
    --    invariant -- it is a lockFovDeg that silently does nothing.
    local ceiling = T.legitMaxTotalDeviationDeg - LOCK_DEV_MARGIN
    -- Judged on the cone actually in force, i.e. AFTER lockFovScale. Auditing
    -- the raw lockFovDeg would warn about a cone nothing ever scans, and worse,
    -- would stay silent when the scale pushed the real cone over the ceiling.
    local restFov = T.lockFovDeg * (T.lockFovScale or 1)
    if restFov > ceiling then
        bad("lockFovDeg %.0f x scale %.2f = %.1f is above the reachable ceiling "
            .. "%.0f (budget %.0f - margin %d) — the cone is clamped to %.0f and "
            .. "raising it further has NO effect",
            T.lockFovDeg, T.lockFovScale or 1, restFov, ceiling,
            T.legitMaxTotalDeviationDeg, LOCK_DEV_MARGIN, ceiling)
    end
    if T.lockFovScale and T.lockFovScale > 1 then
        bad("lockFovScale %.2f is above 1 — it is meant to TIGHTEN the roster's "
            .. "cones; widening every class at once is what the deviation budget "
            .. "exists to prevent", T.lockFovScale)
    end
    if T.softFovMult < 1 then
        bad("softFovMult %.2f is below 1 — the soft retry is NARROWER than the "
            .. "hard cone, so it can never find anything the first pass missed",
            T.softFovMult)
    end

    -- 2. Guidance must actually get a window. muzzle + ramp is dead time at the
    --    START of every flight; if it approaches the bolt's whole travel time the
    --    class is heatseeking on paper only. GAMBLER attack (range 50 speed 100)
    --    is 0.50s of flight against 0.35s of muzzle+ramp -- 70% spent before
    --    guidance has full authority, which is why point-blank shots get nothing.
    local deadTime = T.legitMuzzleDelay + T.legitRampSec
    if deadTime >= 0.30 then
        bad("legitMuzzleDelay + legitRampSec = %.2fs — any bolt whose "
            .. "range/speed is under about %.2fs gets little or no usable "
            .. "guidance. Short-range kits will look inconsistent.",
            deadTime, deadTime / 0.7)
    end

    -- 3. Proportional navigation does not converge below a gain of about 2.
    if PN_GAIN < 2 then
        bad("PN_GAIN %.1f is below 2 — proportional navigation will not "
            .. "converge; bolts will trail the target instead of intercepting",
            PN_GAIN)
    end

    -- 4. A turn clamp at or near zero disables steering without disabling the
    --    feature, which presents as "it locks but never corrects".
    if T.maxSteerDegPerFrame <= 1 then
        bad("maxSteerDegPerFrame %.1f is effectively zero — locks will happen "
            .. "and nothing will steer", T.maxSteerDegPerFrame)
    end

    if #found == 0 then
        logx("boot", ("tunable audit clean — effective lock cone %.1f deg "
            .. "(lockFovDeg %.0f x scale %.2f, boost key widens to %.0f max; "
            .. "budget %.0f, margin %d)"):format(
            math.min(restFov, ceiling), T.lockFovDeg, T.lockFovScale or 1,
            math.min(restFov * (T.lockFovBoostMult or 1), ceiling),
            T.legitMaxTotalDeviationDeg, LOCK_DEV_MARGIN))
    else
        for _, f in ipairs(found) do Log.warn("TUNABLE: " .. f) end
    end
    return found
end

function Core.auditClasses()
    local total, permissive, contradictions = 0, {}, {}
    for _, name in ipairs(S.classOrder) do
        local cfg = S.classes[name]
        total = total + 1

        -- No allow list = class provenance alone, which admits every sub-body of
        -- a cast that carries Speed+Range+Damage. That is the duplicate-projectile
        -- bug in its original form (CHRONO's one LMB emits attack, AttackSpirit,
        -- critical, CritLmb1/2, CritShatter, TrailStart, TrailStop).
        if not cfg.allow or #cfg.allow == 0 then
            permissive[#permissive + 1] = name
        end

        -- deny is substring-matched and runs alongside allow, so a deny string
        -- contained in one of your own allow entries makes that body unclaimable
        -- forever. Nothing in the engine would ever say so.
        if cfg.allow and cfg.deny then
            for _, a in ipairs(cfg.allow) do
                local la = tostring(a):lower()
                for _, d in ipairs(cfg.deny) do
                    local ld = tostring(d):lower()
                    if ld ~= "" and la:find(ld, 1, true) then
                        contradictions[#contradictions + 1] =
                            ("%s: allow '%s' is killed by deny '%s'"):format(name, a, d)
                    end
                end
            end
        end
    end

    Log.info(("classes registered: %d — ally echo: all %d (opt out with allyEcho=false)")
        :format(total, total))

    if #permissive > 0 then
        -- This used to read "will claim every sub-body of a cast", which is a
        -- LIE now and the more dangerous direction to be wrong in: allowMatch
        -- returns false on an empty/missing allow list (it fails closed), so
        -- such a class claims NOTHING. Someone reading the old warning would
        -- hunt a duplicate-projectile bug that cannot happen, while the actual
        -- symptom -- a class that silently does nothing at all -- went unnamed.
        Log.warn(("%d class(es) have NO allow list, so they claim NOTHING and will "
            .. "silently do nothing: %s — play the class and run `bodies <CLASS>` "
            .. "to read its real body names, then fill in `allow`.")
            :format(#permissive, table.concat(permissive, ", ")))
    end
    for _, c in ipairs(contradictions) do
        Log.warn("config contradiction — " .. c)
    end

    return {
        total = total,
        permissive = permissive,
        contradictions = contradictions,
    }
end

function Core.getClass(name) return S.classes[name] end
function Core.classes() return S.classes end

-- Enumerate the REAL projectile bodies of a live class folder.
--
-- Half the roster is not in the dump, so their `allow` lists are naming-
-- convention guesses marked UNVERIFIED -- and a wrong guess means the class
-- silently does nothing. But the folder is right there in ReplicatedStorage at
-- runtime: for whatever class is actually loaded we can just read the truth.
--
-- Skin-aware: OverrideProjectile (0704.lua:284) renames the folder to
-- "Projectile" .. Skin, e.g. ProjectileWoodland, so this PREFIX matches. Asking
-- for an exact "Projectile" child reports "not streamed" for every skinned
-- player -- that mistake has already been made once on the elementalist probe.
function Core.listClassBodies(className)
    className = className or myClass()
    local classes = RS:FindFirstChild("Classes")
    local folder = classes and classes:FindFirstChild(className)
    if not folder then return nil, "class folder not streamed: " .. tostring(className) end

    local out = {}
    for _, sub in ipairs(folder:GetChildren()) do
        if sub.Name:sub(1, 10) == "Projectile" then
            for _, body in ipairs(sub:GetChildren()) do
                local hasSpeed = body:FindFirstChild("Speed") ~= nil
                local hasRange = body:FindFirstChild("Range") ~= nil
                local hasDmg = body:FindFirstChild("Damage") ~= nil
                out[#out + 1] = {
                    name = body.Name,
                    folder = sub.Name,
                    speed = hasSpeed, range = hasRange, damage = hasDmg,
                    -- A real bolt carries all three. Not proof its handler
                    -- delivers damage -- musketeerrifleremove (0478.lua) carries
                    -- all three and destroys itself -- but it is the right
                    -- shortlist to check against an allow list.
                    bolt = hasSpeed and hasRange and hasDmg,
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Cheap staleness check: if this disagrees with what cs_classes.lua ships, the
-- running copy is not the built one.
function Core.classCount()
    local n = 0
    for _ in pairs(S.classes) do n = n + 1 end
    return n
end

function Core.setEnabled(name, on)
    local cfg = S.classes[name]
    if not cfg then return false, "unknown class" end
    cfg.enabled = on and true or false
    saveCaps()
    Log.info(("%s heatseek %s"):format(name, cfg.enabled and "ON" or "OFF"))

    -- Arming a class dumps its LIVE bodies against its allow list, unprompted.
    --
    -- Half the roster ships convention-guessed allow lists marked UNVERIFIED, and
    -- a wrong guess fails SILENTLY -- JAVELIN was armed for 84 seconds and put
    -- not one line in the log, which is indistinguishable from "the class does
    -- nothing" and took a whole round to even notice. The information that
    -- settles it was sitting in RS.Classes the entire time; it just needed
    -- somebody to type `bodies JAVELIN`.
    --
    -- Standing requirement: reconciliation must not depend on the user typing a
    -- diagnostic command. So it runs on arm, costs one folder walk, and writes
    -- under `boot` where the other audit output lives.
    if cfg.enabled then
        local list, err = Core.listClassBodies(name)
        if not list then
            logx("boot", ("%s bodies: %s — cannot verify allow list"):format(name, tostring(err)))
        else
            local allowed = {}
            for _, n in ipairs(cfg.allow or {}) do allowed[string.lower(n)] = true end
            local bolts, matched = {}, 0
            for _, b in ipairs(list) do
                if b.bolt then
                    local hit = allowed[string.lower(b.name)]
                    if hit then matched = matched + 1 end
                    bolts[#bolts + 1] = b.name .. (hit and "*" or "")
                end
            end
            -- Only BOLT bodies (Speed+Range+Damage) are listed: a name the engine
            -- could never claim anyway is noise, and the whole point is to make
            -- the one line that matters findable.
            logx("boot", ("%s bodies: %d bolt(s) [%s] — %d in allow (* = allowed)")
                :format(name, #bolts, table.concat(bolts, ", "), matched))
            if matched == 0 then
                Log.warn(("%s: allow list matches NONE of the live bolt bodies — "
                    .. "this class will silently do nothing"):format(name))
            end
        end
    end
    return true
end

local function denyMatch(cfg, proj)
    local n = string.lower(proj.Name)
    for _, d in ipairs(cfg.deny) do
        if string.find(n, string.lower(d), 1, true) then return d end
    end
    return nil
end

-- Template allowlist. Without one, class provenance accepts EVERY part the
-- class emits that happens to carry Speed + Range + Damage -- and a single cast
-- emits several: chrono's LMB produces attack, AttackSpirit, critical,
-- CritLmb1/2 and more. Steering all of them independently is what showed up as
-- "duplicate projectiles doing really weird stuff".
--
-- The retired modules each had one of these (chrono: LMB_TEMPLATES = {attack},
-- elementalist: fireability2). Porting the class configs dropped it, and this
-- restores it. Classes with no `allow` keep the permissive behaviour their old
-- module had.
-- EXACT match, deliberately. Prefix matching would let "attack" also admit
-- attackSpirit, attackEff1 and attackWarriorVFX -- the exact bodies the
-- allowlist exists to keep out.
local function allowMatch(cfg, proj)
    -- A class with no allow list claims EVERY sub-body of a cast that carries
    -- Speed+Range+Damage, which is the duplicate-projectile bug in its original
    -- form. That permissive behaviour existed only to match what the retired
    -- per-class modules did; those are gone, every registered class has an allow
    -- list, and the boot audit reports it if one does not.
    --
    -- So it now refuses instead of admitting everything. Failing closed means a
    -- misconfigured class does nothing and says why; failing open means it steers
    -- VFX and welded bodies. CS_CONSTRAINTS.md: the unproven path is never the
    -- default.
    if not cfg.allow or #cfg.allow == 0 then return false end
    local n = string.lower(proj.Name)
    for _, a in ipairs(cfg.allow) do
        if n == string.lower(a) then return true end
    end
    return false
end

-- Which registered class, if any, wants this projectile.
-- Body names we have already reported as "ours, but not a bolt". Bounded by the
-- number of distinct body names the game has, and only ever written to once per
-- name, so it cannot grow with play time.
local seenSelfNonBolt = {}

-- Same bound and the same once-per-name rule, for bodies of ours that ARE bolts
-- but no class claimed. See the SELF BODY census at the end of classify().
local seenSelfUnclaimed = {}

-- Cheap because the caller only reaches it for a body name it has never seen
-- before -- at most once per distinct name for the whole session.
local function anyClassEnabled()
    for _, name in ipairs(S.classOrder) do
        local cfg = S.classes[name]
        if cfg and cfg.enabled then return true end
    end
    return false
end

local function classify(proj)
    local reject = baseShotReject(proj)
    if reject then
        -- Name it, ONCE, if it was ours and something was armed.
        --
        -- This is the hole JAVELIN fell through. `baseShotReject` collapses every
        -- body in the game to "no speed" / "no range (vfx)" / "no damage (vfx)"
        -- with no name and no owner, and those counters are shared across every
        -- player on the server -- so a class of ours that emits a body missing one
        -- of the three children produces a log absolutely indistinguishable from
        -- one where we simply never fired. Zero lines, nothing to grep, nothing to
        -- act on.
        --
        -- The owner lookup is one FindFirstChild and only runs until the name has
        -- been seen once, so this stays off the hot path in steady state.
        if reject ~= "already tracked" and reject ~= "forge body"
            and not seenSelfNonBolt[proj.Name] and anyClassEnabled()
            and projOwner(proj) == lp then
            seenSelfNonBolt[proj.Name] = true
            logx("reject", ("self body '%s' is not steerable: %s (Speed=%s Range=%s Damage=%s)")
                :format(proj.Name, reject,
                    tostring(proj:FindFirstChild("Speed") ~= nil),
                    tostring(proj:FindFirstChild("Range") ~= nil),
                    tostring(proj:FindFirstChild("Damage") ~= nil)))
        end
        return nil, reject
    end

    local owner = projOwner(proj)
    if owner ~= lp then
        return nil, owner and ("owner " .. owner.Name) or "owner unset"
    end
    if weldedToCharacter(proj, char()) then return nil, "welded" end

    -- Why the last enabled class refused it. Reported instead of a flat
    -- "no class claim", which hid the actual reason -- that opacity is how the
    -- CHRONO/CHRONOS alias mismatch survived a whole session.
    local lastWhy = nil

    -- Sorted, not pairs(): if two classes could both claim a projectile, hash
    -- order would decide it differently between sessions and the resulting
    -- "sometimes it picks the wrong class" is near-impossible to reproduce.
    -- Attribute the refusal to the class we are ACTUALLY PLAYING, not to
    -- whichever class happens to sort last.
    --
    -- `lastWhy` used to be overwritten by every enabled class in turn, so with
    -- armAll on (all classes enabled, the default since 2026-07-31) the message
    -- always came from the alphabetically last one. A NINJA body the engine
    -- could not claim was logged as `not WINDDANCER bolt (critical1)` -- naming
    -- a class the user was not playing, for a body it has no opinion about. That
    -- line is the ONLY place an unclaimed body's real name is ever printed, and
    -- it was pointing at the wrong class, which is exactly how NINJA's F looked
    -- like "F does nothing" instead of "F is called critical1".
    --
    -- The class being played is the only one whose refusal is diagnostic. Its
    -- message wins outright; the others still fill in when we are playing
    -- something unregistered, so nothing goes silent.
    local playing = myClass()
    local haveMine = false

    for _, name in ipairs(S.classOrder) do
        local cfg = S.classes[name]
        if cfg and cfg.enabled then
            local mine = aliasMatches(cfg, playing)
            -- Once the played class has spoken, no later class may overwrite it.
            local keep = mine or not haveMine
            if mine then haveMine = true end
            if not allowMatch(cfg, proj) then
                if keep then lastWhy = "not " .. cfg.name .. " bolt (" .. proj.Name .. ")" end
            else
                local d = denyMatch(cfg, proj)
                if d then
                    if keep then lastWhy = "denied " .. d end
                else
                    local why = cfg.accept(cfg, proj, nil)
                    if not why then return cfg, nil end
                    if keep then lastWhy = why end
                end
            end
        end
    end
    -- SELF-SIDE BODY CENSUS. The ally path prints `ALLY BODIES [CLASS]
    -- echoed={...} refused={...}` -- the line that proved the TRICKSTER knife was
    -- being refused every cast. The self path had no equivalent: an unclaimed
    -- body of ours printed its NAME and nothing about what it actually is.
    --
    -- The name on its own cannot separate a bullet from a body that is PLACED.
    -- HUNTER's `ability2trap` / `ability2landed` carry Damage, Speed and Range
    -- exactly like a bolt, and steering a body whose job is to land moves where
    -- it lands (the SHROOM seed failure). The VALUES separate them cleanly: a
    -- bullet reads a real Speed with a Range in the tens or hundreds, while a
    -- trap, a landing shockwave or a leap body reads Speed=0 or Range=0.
    --
    -- Once per body name, and only for bodies that are OURS (owner == lp was
    -- established above) and survived baseShotReject, so it stays off the hot
    -- path and cannot be filled by other players' projectiles.
    if lastWhy and not seenSelfUnclaimed[proj.Name] and anyClassEnabled() then
        seenSelfUnclaimed[proj.Name] = true
        local function num(n)
            local v = proj:FindFirstChild(n)
            return (v and tostring(v.Value)) or "-"
        end
        logx("reject", ("SELF BODY '%s' unclaimed: %s (Speed=%s Range=%s Damage=%s%s)")
            :format(proj.Name, lastWhy, num("Speed"), num("Range"), num("Damage"),
                proj.Anchored and " ANCHORED" or ""))
    end

    return nil, lastWhy or "no class enabled"
end

--------------------------------------------------------------------------
-- 12. WATCHER + DISPATCH
--------------------------------------------------------------------------

local function markTracked(proj)
    if proj:FindFirstChild(CORE_TAG) then return end
    local t = Instance.new("BoolValue")
    t.Name = CORE_TAG
    t.Value = true
    t.Parent = proj
end

-- Owner and SourceObj are written a few frames after the part appears, so
-- classification has to wait or every shot reads as "owner unset".
-- Poll, do not sleep.
--
-- This used to burn CLASSIFY_HEARTBEATS frames unconditionally and THEN wait up
-- to OWNER_WAIT_SEC more, whether or not the children had already streamed in.
-- On an ally's relayed bolt that is the worst case for both: their body arrives
-- with Owner frequently still nil, so the full ~250ms could stack on top of the
-- 3 fixed frames and network RTT before we even began forging the echo. It is
-- the "your projectile always comes out noticeably after mine" the allies
-- report -- and unlike RTT, this part is ours to give back.
--
-- Same ceilings, now as timeouts rather than floors: return the instant the
-- body is actually classifiable, which is usually frame one.
local function waitForClassify(proj)
    for _ = 1, CLASSIFY_HEARTBEATS do
        RunService.Heartbeat:Wait()
        if not (S.alive and proj and proj.Parent) then return false end
        if proj:FindFirstChild("Speed") and proj:FindFirstChild("Range")
            and proj:FindFirstChild("Damage") then
            break
        end
    end
    local ov = proj:FindFirstChild("Owner")
    if ov and ov:IsA("ObjectValue") and ov.Value == nil then
        local deadline = os.clock() + OWNER_WAIT_SEC
        while os.clock() < deadline and S.alive and proj.Parent do
            if ov.Value ~= nil then break end
            RunService.Heartbeat:Wait()
        end
    end
    return proj and proj.Parent ~= nil
end

-- ---------------------------------------------------------------------------
-- FLIGHT TELEMETRY helpers (JOB 2)
--
-- Accumulated per-flight on the `rec` record (no instance-keyed tables).
-- Written once at flight end. All scalars — no allocations inside the loop.
--
-- Legit score formula (0–100, lower = more suspicious):
--   base 100
--   – 25  if maxTurnDeg > 60   (bolt curved more than 60° total)
--   – 20  if clampHits / frames > 0.5  (clamp was hit more than half the frames)
--   – 20  if maxFrameTurn >= maxSteerDegPerFrame  (was pinned at cap)
--   – 10  if firstSteer <= 30ms  (instant correction off the muzzle)
--   – 10  if outcome == "no target"  (aborted)
-- Thresholds are a judgement call, not measured from game data.
-- ---------------------------------------------------------------------------
local function initFlightTelem(rec, cfg)
    -- All telemetry on rec directly — cleaned up with rec, no leak.
    rec.tl = {
        frames      = 0,    -- frames where a heading was actually written
        -- Frames where the guidance block RAN, whether or not it commanded a
        -- correction. Proportional navigation deliberately goes quiet once the
        -- bolt is on an intercept course, so frames==0 alone cannot tell
        -- "guidance was never reached" from "guidance had nothing to correct" --
        -- and only the first is a bug. Reporting a well-guided bolt as UNSTEERED
        -- is the same class of mistake as scoring it 100(A) for never steering.
        evalFrames  = 0,
        clampHits   = 0,    -- frames where maxSteerDegPerFrame was the binding limit
        maxFrameTurn= 0,    -- largest actual turn in one frame (deg)
        totalTurn   = 0,    -- sum of per-frame turns (deg)
        aimDirInit  = nil,  -- unit vector of first steering aim, for angular deviation
        firstSteerAt= nil,  -- os.clock() of the first steer input, wall clock
        spawnAt     = os.clock(),
        classKey    = cfg.name,
        castId      = nil,      -- filled by steer(); groups the flight with its cast
        -- The body name. Without it a FLIGHT line names only the CLASS, so an
        -- outcome that affects one body of a kit is invisible: 27 ELEMENTALIST
        -- flights ended "welded" and the log could not say which of
        -- fireattack1 / fireattack2 / fireability2 was responsible.
        bodyName    = nil,
        freezeWhy   = nil,
        devMax      = 0,
        launchDir   = nil,
        -- Captured at spawn for the REACH learner. Read here rather than at
        -- flight end because the body is frequently already destroyed by then.
        boltSpeed   = nil,
        boltRange   = nil,
    }
end

local function telemSteerFrame(rec, current, desired, clampDeg)
    local tl = rec.tl
    if not tl then return end
    local dot = math.clamp(current.Unit:Dot(desired.Unit), -1, 1)
    local frameDeg = math.deg(math.acos(dot))
    tl.frames = tl.frames + 1
    tl.totalTurn = tl.totalTurn + frameDeg
    if frameDeg > tl.maxFrameTurn then tl.maxFrameTurn = frameDeg end
    if frameDeg >= clampDeg - 0.01 then tl.clampHits = tl.clampHits + 1 end
    if not tl.aimDirInit and desired.Magnitude > 1e-6 then
        tl.aimDirInit = desired.Unit
        -- Wall clock, not a fraction of elapsed time. This number is the whole
        -- point of the field: instant correction off the muzzle is the most
        -- visible tell there is, and a derived approximation of it would report
        -- a plausible value that is not the measurement.
        tl.firstSteerAt = os.clock()
    end
end

-- Session-wide legitness aggregate.
--
-- One FLIGHT line per bolt is the right grain for debugging a single shot and
-- the wrong grain for the question that actually matters: does the heatseek look
-- legit? Nobody reads four hundred lines. This accumulates the same measurements
-- so `legit` can answer it in one screen, and so a tuning change can be compared
-- against the run before it instead of argued about.
Core.legitStats = {
    flights = 0,
    scoreSum = 0,
    worst = nil,            -- { score, class, why }
    grades = { A = 0, B = 0, C = 0, D = 0, F = 0 },
    -- Counts of each individual tell, so the report says WHICH one is costing
    -- the score rather than just that the score is low.
    tells = {
        earlySteer = 0,     -- corrected before the muzzle delay should have allowed
        overDeviated = 0,   -- heading moved more than the budget
        clampPinned = 0,    -- sat at the turn limit most of the flight
        terminalHoming = 0, -- still correcting inside the freeze radius
    },
    frozenDev = 0,          -- flights that spent their deviation budget
    frozenTerminal = 0,     -- flights that froze on approach (this is GOOD)

    -- Flights that recorded ZERO steer frames, counted separately and never
    -- scored.
    --
    -- These used to score 100(A), because the score measures visible tells and a
    -- bolt that never steers has none. So the metric reported a perfect grade for
    -- complete failure -- 99 of 157 live ally flights, every one an A, while the
    -- user was reporting that tracking did not work at all. A diagnostic that
    -- cannot distinguish "flawless" from "did nothing" is worse than no
    -- diagnostic. They are excluded from the average and reported on their own
    -- line, with the outcome that killed them.
    unsteered = 0,
    unsteeredWhy = {},      -- [outcome] = count

    -- Flights where guidance ran and correctly commanded nothing.
    onCourse = 0,

    -- Per-class rows for the report. Every structural bug this session was one
    -- class's constant biting another class's geometry (lockCap->MEDIC,
    -- lock margin->JESTER, LOS->FROST): a pooled average hides exactly that.
    byClass = {},   -- [classKey] = { flights, scoreSum, frozenDev, unsteered }
}

function Core.resetLegitStats()
    Core.legitStats.flights = 0
    Core.legitStats.scoreSum = 0
    Core.legitStats.worst = nil
    Core.legitStats.byClass = {}
    for k in pairs(Core.legitStats.grades) do Core.legitStats.grades[k] = 0 end
    for k in pairs(Core.legitStats.tells) do Core.legitStats.tells[k] = 0 end
    Core.legitStats.frozenDev = 0
    Core.legitStats.frozenTerminal = 0
    Core.legitStats.unsteered = 0
    Core.legitStats.unsteeredWhy = {}
    Core.legitStats.onCourse = 0
    return true
end

function Core.legitReport()
    local L = Core.legitStats

    -- Reported before the score, because it invalidates it. A run that is mostly
    -- unsteered flights has no legitness result to discuss -- the heatseek is not
    -- working, which is a different problem and a more urgent one.
    if L.unsteered > 0 then
        local whys = {}
        for why, n in pairs(L.unsteeredWhy) do
            whys[#whys + 1] = ("%s x%d"):format(why, n)
        end
        table.sort(whys)
        local total = L.flights + L.unsteered
        Log.warn(("LEGIT %d of %d flights UNGUIDED (%.0f%%) -- %s")
            :format(L.unsteered, total, L.unsteered / total * 100,
                table.concat(whys, ", ")))
        if L.unsteered > L.flights then
            Log.warn("LEGIT the heatseek is mostly not running. Fix that before "
                .. "tuning appearance -- see cs-diagnose step 3.")
        end
    end

    if (L.onCourse or 0) > 0 then
        Log.info(("LEGIT %d flights needed no correction (already on course) -- this is PN working")
            :format(L.onCourse))
    end

    if L.flights == 0 then
        if L.unsteered == 0 and (L.onCourse or 0) == 0 then
            Log.info("LEGIT no flights recorded yet -- arm a class and fire")
        end
        return L
    end
    local avg = L.scoreSum / L.flights
    Log.info(("LEGIT %d flights - avg=%.1f - A=%d B=%d C=%d D=%d F=%d")
        :format(L.flights, avg, L.grades.A, L.grades.B, L.grades.C,
            L.grades.D, L.grades.F))
    Log.info(("LEGIT tells: earlySteer=%d overDeviated=%d clampPinned=%d terminalHoming=%d")
        :format(L.tells.earlySteer, L.tells.overDeviated,
            L.tells.clampPinned, L.tells.terminalHoming))
    Log.info(("LEGIT budget: %d stopped on deviation, %d froze on approach, %d stopped after missing (all intended)")
        :format(L.frozenDev, L.frozenTerminal, L.frozenMiss or 0))

    -- Per class, worst first. The pooled average has hidden a broken class
    -- behind healthy ones every time (JESTER at 61% froze=dev inside an
    -- acceptable global number). >30% of a class's flights dying on the budget
    -- names itself.
    do
        local rows = {}
        for ck, r in pairs(L.byClass) do rows[#rows + 1] = { ck = ck, r = r } end
        table.sort(rows, function(a, b)
            local fa = a.r.flights > 0 and a.r.frozenDev / a.r.flights or 0
            local fb = b.r.flights > 0 and b.r.frozenDev / b.r.flights or 0
            return fa > fb
        end)
        for _, e in ipairs(rows) do
            local r = e.r
            local devPct = r.flights > 0 and (r.frozenDev / r.flights * 100) or 0
            local mark = devPct > 30 and "  <-- CHECK" or ""
            Log.info(("LEGIT   %-12s flights=%d avg=%.0f froze=dev %.0f%%%s")
                :format(e.ck, r.flights, r.scoreSum / math.max(r.flights, 1), devPct, mark))
        end
    end

    -- SYMPTOM DETECTOR, not a tunable check.
    --
    -- Deviation freezes are individually legitimate -- a badly aimed shot is
    -- SUPPOSED to stop being rescued. But when a large share of guided flights
    -- end that way, the engine is systematically committing to targets it cannot
    -- reach, and that is a geometry fault rather than bad aim: the lock cone is
    -- writing cheques the deviation budget cannot cash.
    --
    -- Stated as a ratio deliberately. The FOV/budget bug was found by hand from
    -- 2 dev-freezes in 5 guided flights, and only because someone happened to
    -- cross-reference lock angles against the budget in a log. This fires on the
    -- same pattern under ANY future numbers -- different cone, different budget,
    -- different class -- without anyone having to notice.
    local guided = L.flights - (L.unsteered or 0)
    if guided >= 8 and L.frozenDev / guided > 0.20 then
        Log.warn(("LEGIT FAULT: %d of %d guided flights (%.0f%%) died on the "
            .. "deviation budget. That is lock geometry, not aim — the cone is "
            .. "acquiring targets the budget cannot reach. Effective cone is "
            .. "%.0f deg against a %.0f deg budget; lower lockFovDeg or raise "
            .. "LOCK_DEV_MARGIN.")
            :format(L.frozenDev, guided, L.frozenDev / guided * 100,
                math.min(T.lockFovDeg * (T.lockFovScale or 1),
                    T.legitMaxTotalDeviationDeg - LOCK_DEV_MARGIN),
                T.legitMaxTotalDeviationDeg))
    end
    if L.worst then
        Log.info(("LEGIT worst: %d [%s] %s")
            :format(L.worst.score, tostring(L.worst.class), tostring(L.worst.why)))
    end
    Log.info(("LEGIT settings: muzzleDelay=%.2fs ramp=%.2fs devBudget=%ddeg terminalFreeze=%dstuds lead=%.2fs refTurn=%.1fdeg/frm legitMode=%s")
        :format(T.legitMuzzleDelay, T.legitRampSec, T.legitMaxTotalDeviationDeg,
            T.legitTerminalFreezeStuds, T.legitMaxLeadSec,
            T.maxSteerDegPerFrame, tostring(T.legitMode)))
    return L
end

local function telemFlightEnd(rec, proj, outcome)
    local tl = rec.tl
    if not tl then return end

    -- BEFORE the unsteered early-return below. A test-arm echo that lands no
    -- damage often ends UNGUIDED or frozen, and returning early would drop
    -- exactly the flights the trial most needs to count -- biasing the sample
    -- toward whichever arm happens to fly prettily.
    if tl.trialArm then
        noteTrialFlight(tl.trialArm, tl.minRange,
            Core.stats.hits - (tl.hits0 or Core.stats.hits))
        tl.trialArm = nil   -- idempotent: several paths call telemFlightEnd
    end

    local elapsed = os.clock() - tl.spawnAt

    -- Record how far this body actually got, but ONLY on natural expiry. Any
    -- other outcome ended the flight early and says nothing about its reach.
    -- Distance is speed x time rather than a position delta on purpose: the
    -- body may already be gone by the time we are called.
    if outcome == "flight end" and tl.boltSpeed and tl.boltSpeed > 0 then
        local flew = tl.boltSpeed * elapsed
        if noteObservedReach(tl.classKey, tl.bodyName, flew) then
            logx("lock", ("REACH learned: %s/%s flies %.0f studs (declared Range=%s) "
                .. "— lock cap for it is now %.0f")
                :format(tostring(tl.classKey or "?"),
                    tostring(tl.bodyName), flew, tostring(tl.boltRange or "?"),
                    flew * 1.1))
        end
    end
    local firstSteerMs = tl.firstSteerAt
        and math.floor((tl.firstSteerAt - tl.spawnAt) * 1000)
        or -1
    local clampPct = tl.frames > 0
        and math.floor(tl.clampHits / tl.frames * 100) or 0

    -- Deviation from where the player actually aimed.
    --
    -- Measured against launchDir -- the bolt's real travel direction once the
    -- muzzle delay expired -- not against the first frame's DESIRED direction.
    -- The old version compared against aimDirInit, which is where we WANTED the
    -- bolt to go, so a shot that was corrected hard immediately scored as barely
    -- deviating at all. It was measuring the wrong angle.
    local aimDev = tl.devMax or 0
    if tl.launchDir and proj and proj.Parent then
        local alv = proj.AssemblyLinearVelocity
        if alv and alv.Magnitude > 1 then
            local d = math.clamp(tl.launchDir:Dot(alv.Unit), -1, 1)
            local final = math.deg(math.acos(d))
            if final > aimDev then aimDev = final end
        end
    end

    -- LEGIT SCORE, 0-100, lower = more likely to get called out.
    --
    -- Scored against the five tells the tunables exist for, and against the
    -- engine's OWN configured limits rather than fixed numbers -- so tightening a
    -- knob raises the bar it is graded against, and the metric cannot be improved
    -- by loosening the thing it measures.
    local L = Core.legitStats

    -- A flight with no steer frames is not a legitness measurement at all. Count
    -- it, name what killed it, and do not grade it. See legitStats.unsteered.
    if (tl.evalFrames or 0) == 0 then
        -- Guidance never ran at all: the flight ended inside the muzzle delay, or
        -- was frozen, or died on its first frames. This is the real failure.
        L.unsteered = L.unsteered + 1
        L.unsteeredWhy[outcome] = (L.unsteeredWhy[outcome] or 0) + 1
        logx("flight", ("#%s FLIGHT [%s/%s] %s t=%.2fs UNGUIDED (muzzle=%.2fs term=%.1f studs)")
            :format(tostring(tl.castId or "?"), tl.classKey,
                tostring(tl.bodyName or "?"), outcome, elapsed,
                tl.budget and tl.budget.muzzle or -1,
                tl.budget and tl.budget.terminal or -1))
        return
    end

    if tl.frames == 0 then
        -- Guidance ran and commanded nothing. That is proportional navigation
        -- working: the line of sight was not rotating, so the bolt was already on
        -- an intercept course. Logged as a clean pass, not a failure.
        L.onCourse = (L.onCourse or 0) + 1
        logx("flight", ("#%s FLIGHT [%s/%s] %s t=%.2fs eval=%d ON-COURSE (no correction needed)")
            :format(tostring(tl.castId or "?"), tl.classKey,
                tostring(tl.bodyName or "?"), outcome, elapsed,
                tl.evalFrames))
        return
    end

    local score = 100
    local worst = {}

    -- (1) Corrected too early. The muzzle delay should make this impossible, so
    -- if it fires, the gate is not working -- weight it heavily.
    local budgetMuzzle = (tl.budget and tl.budget.muzzle) or T.legitMuzzleDelay
    local minFirstSteerMs = T.legitMode and (budgetMuzzle * 1000 * 0.8) or 30
    if firstSteerMs >= 0 and firstSteerMs < minFirstSteerMs then
        score = score - 30
        L.tells.earlySteer = L.tells.earlySteer + 1
        worst[#worst + 1] = ("steered at %dms"):format(firstSteerMs)
    end

    -- (2) Curved too far in total.
    local devBudget = tl.devBudget or T.legitMaxTotalDeviationDeg
    if aimDev > devBudget then
        score = score - 25
        L.tells.overDeviated = L.tells.overDeviated + 1
        worst[#worst + 1] = ("deviated %.0fdeg (budget %ddeg)"):format(aimDev, devBudget)
    elseif aimDev > devBudget * 0.7 then
        score = score - 10
    end

    -- (3) Pinned at the turn limit for most of the flight: the arc was limited by
    -- our clamp rather than by the geometry, which means it wanted to turn harder
    -- than anything thrown by hand would.
    if clampPct > 50 then
        score = score - 20
        L.tells.clampPinned = L.tells.clampPinned + 1
        worst[#worst + 1] = ("clamped %d%% of frames"):format(clampPct)
    elseif clampPct > 25 then
        score = score - 8
    end

    -- (4) Still correcting on approach. The terminal freeze should prevent it, so
    -- only count it when the bolt actually got close enough for that to be
    -- visible -- a body that expired in mid-air never did.
    local budgetTerminal = (tl.budget and tl.budget.terminal) or T.legitTerminalFreezeStuds
    if T.legitMode and budgetTerminal > 0
        and tl.freezeWhy == nil
        and (outcome == "gone" or outcome == "flight end") then
        score = score - 10
        L.tells.terminalHoming = L.tells.terminalHoming + 1
    end

    -- Aborted flights are not a legitness problem, but they ARE a wasted body on
    -- screen, so they still cost a little.
    if outcome == "no target" then score = score - 10 end

    score = math.max(0, math.min(100, score))
    local grade = score >= 80 and "A" or score >= 60 and "B"
        or score >= 40 and "C" or score >= 20 and "D" or "F"

    L.flights = L.flights + 1
    L.scoreSum = L.scoreSum + score
    L.grades[grade] = (L.grades[grade] or 0) + 1
    if not L.worst or score < L.worst.score then
        L.worst = {
            score = score,
            class = tl.classKey,
            why = #worst > 0 and table.concat(worst, ", ") or outcome,
        }
    end
    local fw = tl.freezeWhy
    if fw then
        if fw == "terminal" then
            L.frozenTerminal = L.frozenTerminal + 1
        elseif fw:sub(1, 6) == "missed" then
            L.frozenMiss = (L.frozenMiss or 0) + 1
        else
            L.frozenDev = L.frozenDev + 1
        end
    end
    local ck = tl.classKey or "?"
    local row = L.byClass[ck]
    if not row then
        row = { flights = 0, scoreSum = 0, frozenDev = 0, unsteered = 0 }
        L.byClass[ck] = row
    end
    row.flights = row.flights + 1
    row.scoreSum = row.scoreSum + score
    if fw and fw ~= "terminal" and fw:sub(1, 6) ~= "missed" then
        row.frozenDev = row.frozenDev + 1
    end

    -- Mid-flight retargeting exists in exactly one case now -- a single re-pick
    -- when the locked target dies (see the `target invalid` branch) -- and it
    -- logs its own `re-pick ->` line there, where it happens. Still no
    -- `switches` column here: it would read 0 on almost every row, and a column
    -- that is almost always zero reads as "measured and fine" when it is noise.
    logx("flight", ("#%s FLIGHT [%s/%s] %s t=%.2fs frm=%d turn=%.0f dev=%.0f/%d max/frm=%.1f clamp=%d%% firstSteer=%dms froze=%s - legit=%d(%s)")
        :format(tostring(tl.castId or "?"), tl.classKey, tostring(tl.bodyName or "?"), outcome,
            elapsed, tl.frames,
            tl.totalTurn, aimDev, devBudget,
            tl.maxFrameTurn, clampPct,
            firstSteerMs,
            tostring(fw or "no"),
            score, grade))
end

-- `ctx` is optional and carries per-shot targeting exclusions. Ally echoes pass
-- the shooter's character in it: an echo spawns at the ally's muzzle, so without
-- the exclusion the nearest valid body in the cone is frequently the ally who
-- just fired it. Everything else about the flight is identical, which is the
-- entire point of routing ally echoes through this function instead of a second
-- copy of it -- the weld guard, the mover restore, the turn clamp and the
-- FLIGHT telemetry all apply to ally bolts for free.
local function steer(proj, cfg, ctx)
    markTracked(proj)

    -- Stamp the cast. Every line for this flight carries the same #id, so all the
    -- bodies of one keypress read as one group -- and a cast whose claim count
    -- goes above one is the duplicate-projectile bug, reported here rather than
    -- left for somebody to spot by comparing timestamps.
    local castOwner = ctx and ctx.allyPlayer or nil
    local castId, claimN, castRec, dupKind = castFor(castOwner, proj.Name)
    local who = castOwner and (" (ally " .. tostring(castOwner.Name) .. ")") or " (self)"
    -- Remembered so the cone overlay can be drawn at the range the CURRENT class
    -- actually has, instead of the 170-stud fallback. Drawing a 170-stud cone for
    -- a 50-stud chip is not a cosmetic problem: it shows targets as lockable that
    -- the bolt can never reach, which is the single biggest reject bucket.
    S.lastBoltRange = projRange(proj)
    -- Same reason as the range above: with per-body cone overrides the drawn
    -- cone must be THIS body's cone, or the overlay shows ARCHER's wide Q cone
    -- while the click is actually locking on a much stricter one.
    S.lastBoltFov = lockFovFor(cfg, proj)
    logx("claim", ("#%d claim %s [%s]%s speed=%.0f range=%.0f")
        :format(castId, proj.Name, cfg.name,
            ctx and ctx.allyName and (" echo<-" .. ctx.allyName) or "",
            projSpeed(proj), projRange(proj)))

    if dupKind == "distinct" then
        -- The actionable one. Several DIFFERENT bodies from one cast means the
        -- class is claiming sub-bodies it should not: tighten `allow`.
        logwarn("cast", ("#%d DUPLICATE — %d different bodies in one burst: %s%s "
            .. "-> `allow` for %s is too loose")
            :format(castId, castRec.burst, table.concat(castRec.names, ", "),
                who, cfg.name))
    elseif dupKind == "volley" then
        -- Expected on multi-bolt kits. Info, not a warning.
        logx("cast", ("#%d volley — %s x%d in one burst%s")
            :format(castId, proj.Name, castRec.seen[proj.Name] or 1, who))
    end

    local lifetime = projLifetime(proj)
    local rec
    rec = Core.register(proj, {
        classKey = cfg.name,
        expiresAt = os.clock() + lifetime,
        -- An echo is a body WE created. If its flight ends for ANY reason --
        -- no target, LOS lost, target invalid, expiry -- it must not be left
        -- in the world. A self bolt is the game's own body and we must never
        -- destroy it; an echo has no reason to exist once we stop steering it,
        -- and leaving it behind is a visible second projectile.
        destroyOnRelease = (ctx and ctx.isEcho) or nil,
        -- Runs on EVERY release path (gone / expired / welded / no target /
        -- error / flight end), because every one of them used to leak the mover.
        cleanup = function() releaseMover(rec) end,
    })
    initFlightTelem(rec, cfg)
    rec.tl.castId = castId
    rec.tl.bodyName = proj.Name
    rec.tl.boltSpeed = projSpeed(proj)
    rec.tl.boltRange = projRange(proj)
    -- Recorded per flight so the GRADE is measured against the budget this body
    -- actually had. Without it a body with a raised lockDev is scored against
    -- the global 55, reported as "deviated 62deg (budget 55deg)", and dragged to
    -- a B for spending exactly what it was allowed -- the metric contradicting
    -- the config. legitStats reads tl, not cfg, so it has to travel on the record.
    rec.tl.devBudget = Core.lockDevFor(cfg, proj)
    -- Echo-transport trial bookkeeping. hits0 is the server-confirmed hit
    -- counter at launch: Core.stats.hits only moves on a DamageIndicator that
    -- named US as dealer (see watchDamageIndicator), so the delta over this
    -- flight is server truth, not our own optimism about what we hit.
    rec.tl.trialArm = echoArm[proj]
    rec.tl.hits0 = Core.stats.hits
    rec.tl.budget = nil    -- set below, once speed/range are known

    -- Frost E pins orientation with AngularVelocity (0373.lua:30), so
    -- LookVector is not travel direction. Ally echoes already carry the
    -- bolt heading in ctx.originLook from tryAllyEcho.
    local initLook = proj.CFrame.LookVector
    if ctx and ctx.originLook and ctx.originLook.Magnitude > 1e-3 then
        initLook = ctx.originLook.Unit
    end

    local hasMover = proj:FindFirstChildOfClass("BodyVelocity")
        or proj:FindFirstChildWhichIsA("LinearVelocity", true)
    -- Echo handlers attach BV a frame late; do not burn MOVER_WAIT on a
    -- speed-100 / 2-stud cleave whose whole flight is ~20ms.
    if ctx and ctx.isEcho and not hasMover then
        ensureMover(proj, projSpeed(proj), initLook, rec)
        hasMover = proj:FindFirstChildOfClass("BodyVelocity")
            or proj:FindFirstChildWhichIsA("LinearVelocity", true)
    end
    if not hasMover then
        for _ = 1, MOVER_WAIT_HEARTBEATS do
            RunService.Heartbeat:Wait()
            if not (S.alive and proj and proj.Parent) then
                telemFlightEnd(rec, proj, "gone early")
                Core.unregister(proj, "gone early")
                return
            end
        end
    end

    local mc = char()
    if weldedToCharacter(proj, mc) then
        telemFlightEnd(rec, proj, "welded")
        Core.unregister(proj, "welded")
        return
    end

    local speed = projSpeed(proj)
    ensureMover(proj, speed, initLook, rec)

    -- Speed is passed so the lock margin can size itself against THIS bolt --
    -- a slow body must lock a tighter cone than a fast one or it spends the
    -- whole deviation budget getting there. See pickTarget.
    -- Drone/turret bodies: search from where the BODY is and where it is going,
    -- not from the player's root and camera. Only applied when no ctx already
    -- carries an origin (an ally echo's origin is the ALLY's muzzle and is
    -- already correct). See lockFromBody.
    local lockCtx = ctx
    if not (ctx and ctx.originPos) and Core.lockFromBody(cfg, proj)
        and initLook and initLook.Magnitude > 1e-3 then
        lockCtx = { originPos = proj.Position, originLook = initLook.Unit }
        logx("lock", ("#%d %s origin from body @%.0f studs from me")
            :format(castId, proj.Name,
                (mc and mc:FindFirstChild("HumanoidRootPart"))
                    and (proj.Position - mc.HumanoidRootPart.Position).Magnitude or -1))
    end
    local tgt = Core.pickTarget(reachFor(cfg, proj, projRange(proj)), mc, lockCtx, lockFovFor(cfg, proj),
        castWindowCloseLock(cfg, ctx and ctx.allyPlayer or lp), nil, projSpeed(proj),
        Core.lockDevFor(cfg, proj))
    if not tgt then
        telemFlightEnd(rec, proj, "no target")
        Core.unregister(proj, "no target")
        return
    end
    rec.target = tgt

    local stop = os.clock() + lifetime
    local lastLos = 0
    -- Furthest the body has TRAVELLED from where it spawned. The boomerang
    -- check below arms on this, not on distance-from-me.
    --
    -- It used to arm on distance from my own root, which is correct only when I
    -- am the thrower. An ALLY echo spawns at the ally's muzzle -- routinely 100+
    -- studs away -- so the arm condition was already satisfied on frame one, and
    -- the flight aborted as "returned to owner" the moment the bolt flew
    -- anywhere near me. For SWORDMANCER, whose whole ATK is returning swords,
    -- that killed the class for allies outright, and now that echoes are
    -- destroyed on release it would show up as bolts simply vanishing.
    local spawnPos = proj.Position
    local maxTravel = 0

    -- LEGITNESS + PERF state for this flight.
    local flightStart = os.clock()
    local frame = 0
    -- Direction the bolt was actually travelling when steering began -- i.e.
    -- where the player aimed. The deviation budget is measured from this, not
    -- from the first frame's velocity, which is still settling.
    local launchDir = nil
    -- Once set, the bolt flies straight for the rest of the flight. Set by the
    -- deviation budget and by the terminal freeze; never cleared, because a bolt
    -- that stops correcting and then starts again is worse than either.
    -- 1 = full authority, 0 = fully handed back. Driven by the return fade band
    -- above; a function-local, so it costs nothing against the chunk's 200.
    local returnFade = 1
    local steerFrozen = false
    local repicked = false
    local freezeWhy = nil
    -- Guidance state. losPrev is the previous line-of-sight unit vector, which is
    -- what proportional navigation differentiates. There is deliberately no
    -- smoothed-heading term -- see the note at the steering write.
    local losPrev = nil
    -- Closest approach tracking.
    --
    -- Range to the target falls, reaches a minimum, then rises. Once it is rising
    -- the shot has missed, and every further correction is guidance trying to turn
    -- around and come back -- which is a loop, not a projectile. This is the test
    -- that was missing: PN happily kept steering after the miss, LOS kept rotating
    -- (the other way now), and the bolt orbited until its lifetime ran out.
    --
    -- Live evidence: MEDIC attack is range=60 speed=100, so 0.6s of travel, and
    -- flights were reaching t=1.75s with frm=290 and froze=no. Nearly three times
    -- their range, still turning. That is the "curves up and around the player".
    local minRange = math.huge
    local openingFrames = 0
    -- Perf tier is read once per flight rather than every frame: a tier change
    -- mid-flight would alter the arc's shape halfway through, which is visible.
    local tier = Core.perfTier()
    local steerEvery = tier.steerEvery or 1
    local losRecheck = T.losRecheckSec * (tier.los or 1)
    -- Scaled to this bolt AND to this engagement. A 30-stud bolt and a 500-stud
    -- bolt cannot share absolute timings, and a 210-stud arrow fired at someone
    -- 18 studs away is not a 210-stud shot -- see legitBudget().
    --
    -- Measured here rather than passed in because the distance that matters is
    -- from the BODY to the target at the moment the flight starts: an ally echo
    -- is forged at their muzzle, not ours, so our own position would be wrong.
    -- Falls back to nominal range when the target has no root yet, which gives
    -- exactly the old behaviour.
    local engageDist = nil
    do
        local th0 = tgt and tgt:FindFirstChild("HumanoidRootPart")
        if th0 then engageDist = (th0.Position - proj.Position).Magnitude end
    end
    -- Frostbite Cleave locks at ~2-7 studs. Terminal freeze at 25% of that
    -- ends guidance after one or two frames (turn=1-16, froze=terminal, no
    -- visible curve). Sub-12-stud shots are over before a freeze reads legit.
    local shortEngage = engageDist and engageDist < 12
    local budget = legitBudget(projSpeed(proj), projRange(proj), engageDist)
    if rec.tl then rec.tl.budget = budget end

    local outcome = "flight end"
    while S.alive and proj and proj.Parent and os.clock() < stop do
        -- `cfg.enabled` is the SELF heatseek toggle. Ally echoes have their own
        -- switch and must not be gated on it: the ally's class is whatever they
        -- chose to play, and requiring you to also enable that class for
        -- yourself is nonsense. Getting this wrong abandoned 276 of 447 echoes
        -- one frame after forging them, each one left flying as an unsteered
        -- body -- which is exactly the "duplicate projectiles" report.
        if not cfg.enabled and not (ctx and ctx.isEcho) then
            outcome = "disabled" ; break
        end

        -- Re-read our character every frame. Dying or respawning mid-flight
        -- replaces the model, and a captured handle would leave every
        -- subsequent validity and LOS check running against a dead character.
        mc = char()
        if not mc then outcome = "no char" ; break end

        if weldedToCharacter(proj, mc) then outcome = "welded" ; break end
        if not Core.isValidTarget(tgt, mc, ctx) then
            -- Target died mid-flight. Re-pick ONCE, from the BOLT's own position
            -- and heading -- not the player's, the bolt is the thing flying --
            -- and only while enough flight remains to matter. 7 `target invalid`
            -- flights last session were bolts coasting at a corpse.
            local rr = projRange(proj)
            local travelled = (proj.Position - spawnPos).Magnitude
            local remain = (rr and rr > 0) and (rr - travelled) or 0
            if not repicked and not steerFrozen and remain > 15 then
                repicked = true
                local alv = proj.AssemblyLinearVelocity
                local rctx = {
                    originPos  = proj.Position,
                    originLook = (alv and alv.Magnitude > 1) and alv.Unit
                        or proj.CFrame.LookVector,
                    exclude    = ctx and ctx.exclude,
                    allyPlayer = ctx and ctx.allyPlayer,
                    allyName   = ctx and ctx.allyName,
                }
                local nt = Core.pickTarget(remain, mc, rctx, nil, nil, nil, projSpeed(proj))
                if nt and nt ~= tgt then
                    tgt = nt
                    logx("flight", ("#%s re-pick -> %s (%.0f studs of flight left)")
                        :format(tostring(rec.tl and rec.tl.castId or "?"), nt.Name, remain))
                end
            end
            if not Core.isValidTarget(tgt, mc, ctx) then outcome = "target invalid" ; break end
        end

        local th = tgt:FindFirstChild("HumanoidRootPart")
        if not th or not th.Parent then outcome = "target invalid" ; break end

        -- Card Trick boomerangs back to the thrower; steering it home is both
        -- pointless and visibly wrong (0566.lua:2476). Only treat closeness as
        -- "returning" once it has actually gone out first.
        if cfg.flight.stopWhenReturningToOwner and mc then
            -- The body comes home to whoever OWNS it. An echo is owned by us,
            -- so our root is the right homing reference even though the echo
            -- was born at the ally's muzzle -- but the ARM condition has to be
            -- travel, or the ally's distance from us satisfies it instantly.
            local root = mc:FindFirstChild("HumanoidRootPart")
            if root then
                local travelled = (proj.Position - spawnPos).Magnitude
                if travelled > maxTravel then maxTravel = travelled end
                local d = (proj.Position - root.Position).Magnitude
                if maxTravel > RETURN_ARM_DIST and d < RETURN_TRIP_DIST then
                    outcome = "returned to owner" ; break
                end
                -- SMOOTH HANDOVER, not a cliff.
                --
                -- The line above ends the flight the instant the ball is inside
                -- RETURN_TRIP_DIST. Up to that frame we steered at full
                -- authority; on it, we stop dead. The game's own return script
                -- then takes a body that was being actively turned and yanks it
                -- onto its own path -- a visible kink at exactly the moment the
                -- ball is closest to the player and most watched. That is the
                -- "sketchy return" report.
                --
                -- So authority fades to zero across the band between the arm
                -- distance and the trip distance, and the game's path takes over
                -- a body that is already coasting. Nothing about WHEN the flight
                -- ends changes -- only how much we are still contributing when
                -- it does.
                local fadeAt = T.legitReturnFadeStuds or 20
                if maxTravel > RETURN_ARM_DIST and d < fadeAt then
                    local span = math.max(fadeAt - RETURN_TRIP_DIST, 1e-3)
                    returnFade = math.clamp((d - RETURN_TRIP_DIST) / span, 0, 1)
                else
                    returnFade = 1
                end
            end
        end

        local now = os.clock()
        -- LOS is not armed until the body has actually left where it was born.
        --
        -- "Is it clear from here" fires on frame one, and on frame one the body is
        -- still inside the thrower -- so this needs a travel arm exactly like the
        -- boomerang guard does. Excluding the shooter (above) fixes the ally case;
        -- this also covers a self bolt launched from inside cover, our own weapon
        -- model, or a body the game has not finished parenting.
        -- ...and it DISARMS again on short approach, for the same reason it
        -- arms late: a bolt a few studs from its target has already arrived.
        --
        -- The abort exists to drop a bolt flying at somebody behind a wall. At
        -- point-blank it stops doing that job and starts eating good shots --
        -- the target's own body, the caster's weapon model, and a cleave's VFX
        -- are all between two things that are practically touching.
        --
        -- This is the short-range bug shape AGAIN: LOS_ARM_STUDS is 8 and the
        -- recheck is every 0.1s, both sized for long bolts. FROST's E is
        -- range=35 speed=100 -- a 0.35s flight that gets about three checks, so
        -- one transient blocker ends it. Measured: 8 of 11 ally echoes died
        -- `lost LOS`, one of them `froze=missed at 2 studs`, i.e. aborted on top
        -- of the target. Same family as the lockCap and legit-budget bugs: a
        -- constant tuned on 500-stud kits applied to a 35-stud one.
        local travelledNow = (proj.Position - spawnPos).Magnitude
        local nearTarget = false
        do
            local th2 = tgt:FindFirstChild("HumanoidRootPart")
            if th2 then
                nearTarget = (th2.Position - proj.Position).Magnitude <= LOS_ARM_STUDS
            end
        end
        if T.requireLos and travelledNow >= LOS_ARM_STUDS and not nearTarget
            and now - lastLos >= losRecheck then
            lastLos = now
            if not Core.hasClearLos(proj.Position, tgt, mc, ctx) then
                outcome = "lost LOS" ; break
            end
        end

        local dt = RunService.Heartbeat:Wait()
        if not (S.alive and proj.Parent) then outcome = "gone" ; break end

        frame = frame + 1

        -- LEGITNESS gate 1: fly straight out of the muzzle.
        --
        -- Nothing a player throws changes direction in its first few frames, so a
        -- correction that begins immediately is the most visible tell there is --
        -- and it is the one the FLIGHT telemetry kept scoring against us
        -- (firstSteer values in single-digit milliseconds). The bolt now leaves
        -- along the direction actually aimed and only then starts to correct.
        -- FLIGHT HAS NOT STARTED YET: the body is still on its owner.
        --
        -- `steerAfterOwnerStuds` exists for kits where ONE body name covers two
        -- phases: a thing the player is standing on or holding, and the same
        -- thing once thrown. JESTER's Q is the case it was built for -- Bouncy
        -- Ball summons `ability1`, the player BOUNCES ON IT up to three times,
        -- and a recast kicks that same body. Steering it during the first phase
        -- drives a part the player is standing on, which drives the player.
        --
        -- Continuous, re-evaluated every frame -- never a one-shot arm. The
        -- CanTouch guard was a one-shot window ("poll until clear OR 0.6s, then
        -- arm regardless") and "never separates" is exactly the case that had to
        -- be caught, so the safety valve vented into the failure it guarded.
        --
        -- While ridden the flight BASELINES are reset rather than merely
        -- skipping the steer. The flight genuinely begins at the kick, so the
        -- muzzle delay, the LOS travel arm, the deviation budget and the
        -- boomerang guard must all measure from there. Without the reset the
        -- ball accumulates travel while the player bounces around on it, and
        -- `stopWhenReturningToOwner` -- which arms on travel and fires on
        -- closeness -- would end the flight as "returned to owner" before the
        -- kick ever happened.
        -- PER BODY. This was read straight off cfg.flight, which is class-wide,
        -- so JESTER's 12-stud ride gate also held its m1 unsteered for the first
        -- 12 studs of every bolt -- and while `ridden` is true the flight
        -- baselines below are RESET every frame, so the m1's guided window kept
        -- restarting. Measured: JESTER firstSteer averaged 172ms across 11
        -- flights this session and 173ms across 205 in the previous one, against
        -- 26-36ms for every other class. It was the only class with this flag.
        -- That is HANDOFF_2026-08-01 open item 7, and this is the cause.
        local ridden = false
        local rideStuds = Core.steerAfterOwnerStudsFor(cfg, proj)
        if rideStuds and mc then
            local oroot = mc:FindFirstChild("HumanoidRootPart")
            if oroot then
                ridden = (proj.Position - oroot.Position).Magnitude < rideStuds
            end
        end

        local sinceSpawn = now - flightStart
        if ridden then
            spawnPos = proj.Position
            maxTravel = 0
            flightStart = now
            lastLos = now
        elseif Core.legitNow() and sinceSpawn < budget.muzzle then
            -- Deliberately no `continue`-equivalent skip of the mover: we do not
            -- touch the mover at all during the delay, so the body flies exactly
            -- as the game launched it.
        elseif steerEvery > 1 and (frame % steerEvery) ~= 0 then
            -- Perf tier is skipping this frame. steerClampFor already scales the
            -- clamp down to match, so the arc keeps the same shape.
        elseif steerFrozen then
            -- Deviation budget spent or terminal freeze -- flying straight.
        else
            local tSteer = perfBegin()
            pcall(function()
                -- Re-checked here, not only at the top of the loop: the weld can be
                -- created during the Heartbeat wait above, and writing a mover to an
                -- already-welded body is what drives the character, not the bolt.
                if weldedToCharacter(proj, mc) then return end
                local sp = projSpeed(proj)
                local pos = proj.Position

                -- LEGITNESS gate 4: stop correcting near the target.
                --
                -- Terminal-phase adjustments are what read as magnetic to somebody
                -- watching -- the bolt appears to lock on at the last moment. By
                -- this range the shot has already either worked or not, so the
                -- last few studs are flown straight.
                -- Only after steering has actually begun. An echo forged near the
                -- target would otherwise latch the freeze on its first frame and
                -- never steer at all -- which is what `froze=terminal` alongside
                -- `frm=0` in the live log was.
                local toTgt = (th.Position - pos).Magnitude
                -- The freeze radius is a fraction of THIS shot's approach, not a
                -- flat number of studs.
                --
                -- Measured 2026-07-31: MEDIC `critical` (speed=220 range=200)
                -- fired at a target about 15 studs away wrote frm=2 and frm=7,
                -- dev=0 and dev=3, then froze=terminal. A flat 10-stud radius
                -- was most of the engagement, so the bolt was frozen almost the
                -- instant guidance started and never corrected at all. It read
                -- as "F is not quite heatseeking" -- and it was not.
                --
                -- Absolute distances do not survive contact with different
                -- ranges and engagement distances, exactly as the flat muzzle
                -- and ramp did not. Freezing in the last quarter of the approach
                -- keeps the tell it exists for -- no last-moment magnetic snap --
                -- while a short engagement still gets three quarters of its
                -- flight guided.
                if not rec.tl.initialDist and launchDir then
                    rec.tl.initialDist = toTgt
                end
                local termR = budget.terminal
                if rec.tl.initialDist then
                    termR = math.min(termR, rec.tl.initialDist * 0.25)
                end
                if Core.legitNow() and launchDir and toTgt <= termR and not shortEngage then
                    steerFrozen = true
                    freezeWhy = "terminal"
                    return
                end

                local aimAt = leadPoint(th, pos, sp)
                local delta = aimAt - pos
                if delta.Magnitude < 1e-3 then return end

                -- Derive the current travel direction from the most reliable source.
                --
                -- For LinearVelocity-driven projectiles (Frost E etc.), there is no
                -- BodyVelocity to read, so `mover and mover.Velocity` is nil and we
                -- used to fall back to CFrame.LookVector.  But the game's
                -- AngularVelocity constraint (0704.lua:716-719) pins the part's
                -- ORIENTATION to zero rotation, so LookVector never tracks the
                -- direction of travel -- it is just a fixed forward axis.
                -- clampSteer was then computing a turn from a bogus baseline every
                -- frame, which wanders.
                --
                -- Fix: prefer AssemblyLinearVelocity (the actual motion of the part
                -- in the physics simulation), then the tracked mover's own velocity
                -- vector, and only fall back to LookVector when both are useless.
                local alv = proj.AssemblyLinearVelocity
                local current
                if alv and alv.Magnitude > 1 then
                    current = alv
                else
                    local bv = proj:FindFirstChildOfClass("BodyVelocity")
                    local bvVel = bv and bv.Velocity
                    if bvVel and bvVel.Magnitude > 1 then
                        current = bvVel
                    else
                        local lv = proj:FindFirstChildWhichIsA("LinearVelocity", true)
                        local lvVel = lv and lv.VectorVelocity
                        if lvVel and lvVel.Magnitude > 1 then
                            current = lvVel
                        else
                            current = proj.CFrame.LookVector
                        end
                    end
                end

                -- LEGITNESS gate 2: total deviation budget.
                --
                -- The strongest single lever, and the one that keeps this looking
                -- like good aim instead of software. `launchDir` is the direction
                -- the bolt was ACTUALLY travelling once the muzzle delay expired
                -- -- i.e. where the player aimed. Once the heading has moved
                -- legitMaxTotalDeviationDeg away from that, steering stops for the
                -- rest of the flight.
                --
                -- The consequence is deliberate: a badly aimed shot misses, exactly
                -- as it would have. Curving a bolt 90 degrees to rescue a shot
                -- nobody aimed is unmistakable however gently it is done.
                -- THE BODY REVERSED. Stop steering; this is the game's path now.
                --
                -- Some bodies are moved by the GAME as well as by us: a juggling
                -- ball that returns, a ball that bounces, anything with an arc.
                -- Once its actual travel direction has swung past 90 degrees
                -- from launch it is no longer going where it was thrown, and
                -- every correction we add is fighting a script that will win.
                --
                -- Measured on JESTER, which is both: `turn=145-152` degrees of
                -- total heading change against `clamp=3-10%` -- almost none of
                -- that rotation was ours -- and devMax reaching 65, 88, 122 and
                -- 166 degrees on a 55 budget. `stopWhenReturningToOwner` never
                -- fired once across the session (0 `returned to owner`), because
                -- it needs the body to come within 8 studs of the thrower and
                -- these flights ended on LOS or a dead target first.
                --
                -- Reversal needs no distance thresholds and no owner reference,
                -- which is why it catches what the proximity guard misses. This
                -- is the "tracks, then goes upwards" report: the ball turns for
                -- home or bounces, and we were still steering it.
                if launchDir and current.Magnitude > 1e-6
                    and launchDir:Dot(current.Unit) < 0 then
                    steerFrozen = true
                    freezeWhy = "reversed"
                    return
                end

                if current.Magnitude > 1e-6 then
                    if not launchDir then
                        launchDir = current.Unit
                        -- Recorded on the telemetry record so the FLIGHT line can
                        -- report deviation from where the player actually aimed,
                        -- rather than from the first frame's desired direction --
                        -- which is the direction we WANTED, not the one thrown.
                        if rec.tl then rec.tl.launchDir = launchDir end
                    else
                        local dev = math.deg(math.acos(
                            math.clamp(launchDir:Dot(current.Unit), -1, 1)))
                        -- devMax STOPS at the freeze. Past that point we are
                        -- not steering, so anything the heading does next is the
                        -- GAME moving the body -- and for a boomerang that is a
                        -- full turn for home.
                        --
                        -- This is what digest section 6 has been reporting all
                        -- along. Measured: `dev=158/55 turn=30 froze=dev 30°`
                        -- -- our total contribution was 30 degrees, the freeze
                        -- fired correctly, and the 158 is JESTER's m1 flying
                        -- back to the thrower afterwards. Section 6 was never
                        -- showing a clamp leak (HANDOFF_2026-08-01 open item 6);
                        -- it was showing the return leg of bodies we had already
                        -- let go of. Recording it as deviation WE spent made
                        -- every returning body look like a runaway.
                        if rec.tl and not steerFrozen
                            and dev > (rec.tl.devMax or 0) then
                            rec.tl.devMax = dev
                        end
                        -- Freeze AT the budget, no reserve.
                        --
                        -- A reserve of one frame's turn was tried and it was a
                        -- bad trade: steerClampFor scales inversely with speed,
                        -- so on a speed-70 bolt one frame is ~26 degrees and the
                        -- reserve retired 45% of the budget. Measured on the
                        -- build that shipped it: `froze=dev 30°` against 55, and
                        -- `froze=dev 52°` against 78 -- the Q ball stopping at
                        -- two thirds of a budget that had just been raised
                        -- specifically to let it track. Reported, correctly, as
                        -- "didn't feel a difference".
                        --
                        -- No reserve is needed: clampSteer(launchDir, look,
                        -- budget) below already bounds the heading actually
                        -- WRITTEN to the budget, every frame. The reserve was
                        -- guarding against an overshoot that the clamp prevents
                        -- and the telemetry was only appearing to show.
                        if Core.legitNow()
                            and dev >= Core.lockDevFor(cfg, proj) then
                            steerFrozen = true
                            freezeWhy = ("dev %.0f°"):format(dev)
                            return
                        end
                    end
                end

                -- Proportional navigation. `delta.Unit` -- point straight at the
                -- target -- is pure pursuit and orbits by construction; see
                -- proNavHeading(). PN needs two consecutive line-of-sight samples,
                -- so the first steered frame only records one and holds heading,
                -- which is the correct thing to do anyway.
                local los = delta.Unit
                if rec.tl then rec.tl.evalFrames = rec.tl.evalFrames + 1 end

                -- Closest approach. Hysteresis on both count and distance so a
                -- jittering root or one noisy frame cannot end a good flight.
                -- The freeze does not arm until the ramp has finished handing the
                -- bolt its authority. minRange keeps updating from the first
                -- guided frame either way -- only the verdict waits.
                --
                -- This guard was killing good flights before they could start.
                -- steerClampFor() eases authority in over budget.ramp and floors
                -- at 0.25 deg/frame, so for the first ~0.25s after the muzzle delay
                -- the bolt can barely turn at all. The miss test, armed from the
                -- first guided frame, only needs the range to open by 3 studs for
                -- 4 consecutive frames -- at speed 250 that is about 25ms. So any
                -- bolt whose geometry was not ALREADY closing got declared a miss
                -- roughly 25ms into a 250ms ramp, before guidance had the authority
                -- to close anything. It is not measuring a miss, it is measuring
                -- the ramp.
                --
                -- Live, on the 16:50 build, MUSKETEER ally echoes: #68 frm=4
                -- max/frm=0.3 clamp=100% froze=missed, #73 frm=5 froze=missed --
                -- four and five steered frames of a ~130-frame flight, at 3% of
                -- the eventual clamp, then frozen for good. #75 got 26 frames and
                -- reached max/frm=9.2. Whether a flight lived or died came down to
                -- which way the range happened to be moving during the ramp, which
                -- is exactly the inconsistency reported on SNIPER.
                --
                -- Same failure this codebase has now hit three times: a guard that
                -- arms before the thing it guards has begun. The boomerang guard
                -- arms on distance travelled, LOS arms on LOS_ARM_STUDS, the
                -- terminal freeze waits for launchDir. This one waits for the ramp.
                if toTgt < minRange then
                    minRange = toTgt
                    rec.tl.minRange = minRange
                    openingFrames = 0
                elseif toTgt > minRange + MISS_OPEN_STUDS
                    and sinceSpawn >= budget.muzzle + budget.ramp then
                    openingFrames = openingFrames + 1
                    if openingFrames >= MISS_OPEN_FRAMES then
                        steerFrozen = true
                        freezeWhy = ("missed at %.0f studs"):format(minRange)
                        return
                    end
                end
                local desired = proNavHeading(current.Unit, los, losPrev, dt)
                losPrev = los

                if not desired then
                    -- No correction needed: either the first sample, or the line
                    -- of sight has stopped rotating because we are already on an
                    -- intercept course. Coast. This is the frame pure pursuit
                    -- would have spent still turning.
                    return
                end

                local clampDeg = steerClampFor(sp, sinceSpawn, steerEvery, budget)
                -- Fades our turn rate out as a boomerang comes home, so the
                -- game's return script takes over a coasting body rather than a
                -- turning one. 1 for every body that is not returning.
                clampDeg = clampDeg * returnFade
                -- FRAME-RATE NORMALISED. The clamp is named per-FRAME and was
                -- applied per frame, so the real turn rate scaled with fps:
                -- 20 deg/frame for a speed-100 bolt is ~1200 deg/s at 60fps and
                -- ~2400 at 120 -- a 4-stud turn radius, which is the "snaps to
                -- the side" report (FROST E, self AND ally: turn=55-76 in 6-9
                -- corrections with clamp=0%, i.e. never limited). The tunable
                -- keeps its documented meaning exactly at 60fps; other frame
                -- rates now produce the same ARC instead of the same per-frame
                -- step. Bounded so a single hitched frame cannot grant one
                -- giant correction.
                clampDeg = clampDeg * math.clamp(dt * 60, 0.25, 2.5)
                local look = clampSteer(current, desired, clampDeg)

                -- The budget is a CEILING, not a tripwire. Clamp to it.
                --
                -- Gate 2 above only *detects* an overrun: it reads the heading at
                -- the top of the frame and freezes once it is already past the
                -- budget. The command issued in between can carry it well past,
                -- and the overshoot is one frame of clampDeg -- which scales as
                -- 1/Speed, so it is small on a fast bolt and enormous on a slow
                -- one. Measured on JESTER (speed=70): dev=62/55, 58/55, 61/55,
                -- and one flight at dev=112/55, twice the budget it was supposedly
                -- held to. The budget's whole job is that the bolt visibly stops
                -- curving at a known angle, and a 112-degree hook is the exact
                -- tell it exists to prevent.
                --
                -- Reuses clampSteer against launchDir, so "never more than the
                -- budget away from where the player aimed" is enforced on the
                -- value actually written, once, in one place.
                if launchDir and Core.legitNow() then
                    look = clampSteer(launchDir, look, Core.lockDevFor(cfg, proj))
                end

                -- NO output filter here. This is deliberate and it must stay that
                -- way -- an absolute-heading low-pass was tried and it silently
                -- destroyed the guidance.
                --
                -- The version that was here did
                --     look = smoothDir:Lerp(look, dt / 0.08)
                -- easing the APPLIED heading toward the commanded one. At the
                -- observed ~166fps that is dt/tau = 0.0060/0.08 = 7.5%, so only a
                -- fourteenth of each command survived. Worse, `current` (the real
                -- travel direction) then follows the filtered heading, so the next
                -- frame's command is computed from an already-lagging baseline:
                -- effective navigation gain collapsed from 3 to about 0.22, far
                -- under the ~2 that proportional navigation needs to converge at
                -- all.
                --
                -- The symptom was a bolt that looked flawless and hit nothing --
                -- dev=1-5 degrees out of a 30 degree budget, max/frm=0.2 degrees
                -- against a ~10 degree clamp, missing by a consistent 11-15 studs.
                -- Roughly 2% of the available authority, which reads as "too legit"
                -- because it is barely steering.
                --
                -- No filter is needed: proportional navigation output is smooth by
                -- construction (that is the whole reason for using it), and
                -- clampSteer already bounds how fast the heading may move. Smoothing
                -- on top of both only removes authority.

                -- Telemetry: measure turn cost BEFORE writing it, no extra allocs.
                telemSteerFrame(rec, current, look, clampDeg)
                ensureMover(proj, sp, look, rec)
            end)
            perfEnd("steer", tSteer)

            -- A FROZEN MISS MUST FALL. This is the "curves over someone, then
            -- goes upwards and never comes down" report, and it is not the
            -- guidance -- it is what happens AFTER the guidance stops.
            --
            -- Our CsCoreBV is a BodyVelocity: it holds the last written
            -- velocity forever and fully counteracts gravity. When a flight
            -- freezes on `dev`, `missed` or `reversed`, the last command was
            -- often pitched UP (climbing at a lead point or an airborne
            -- target), so the bolt sails on that exact climbing line, flat out,
            -- weightless, until its lifetime expires -- passing over the
            -- target's head on a rail. Measured: turn=86-111 with clamp=0-9%
            -- and post-freeze tails of 0.5-1.6s, i.e. most of the visible
            -- weirdness happens after we stopped steering.
            --
            -- Releasing OUR mover hands the body back to plain physics, so the
            -- miss falls on a ballistic arc -- which is what a real missed
            -- throw does. Only `kind == "created"` is released: a game-owned
            -- mover keeps being driven by the game's own handler, and
            -- releaseMover would rewrite it with a stale velocity.
            -- `terminal` keeps the mover: that freeze happens on top of the
            -- target, and the straight line IS the hit.
            if steerFrozen and not rec.moverReleased
                and freezeWhy and freezeWhy ~= "terminal" then
                rec.moverReleased = true
                if rec.mover and rec.mover.kind == "created" then
                    releaseMover(rec)
                end
            end
        end
    end

    if freezeWhy and rec.tl then rec.tl.freezeWhy = freezeWhy end

    telemFlightEnd(rec, proj, outcome)
    Core.unregister(proj, outcome)
end

--------------------------------------------------------------------------
-- 12b. ALLY ECHO
--
-- Ally heatseek used to be three archived per-class modules totalling 5287
-- lines -- musketeer, elementalist, trickster -- each carrying its own copy of
-- the target pipeline, lock scoring, steering, movers and cleanup. Only three
-- classes were ever supported, so RECON ally assist did not "break": it never
-- existed. Registering a class gave you self heatseek and nothing else.
--
-- This is the port. It is small because it is a FORGE, not a second engine:
-- the echo is steered by the same steer() every self bolt uses, so it inherits
-- the weld guard, the mover save/restore, the turn clamp and the FLIGHT
-- telemetry -- none of which the archived modules had. Registering a class now
-- gets you both sides.
--
-- Why an echo body exists at all: Owner is snapshotted as an upvalue when the
-- projectile handler starts (0463.lua:12), so a body spawned as the ally is
-- visual-only on our client and can never resolve a hit for us. To contribute
-- damage we must own a body. We spawn one from the same template, steer ours,
-- and hide theirs.
--------------------------------------------------------------------------

local ECHO_TAG = "CsAllyEcho"
local ECHO_MAX_ACTIVE_DEFAULT = 16
local ECHO_MAX_LIFE = 1.75      -- pierce ghosts outlive their hit; hard ceiling
-- How far an echo must get from the ally who "fired" it before its collision is
-- switched on. A character is about 5 studs across, so 10 clears their hitbox
-- with margin for them moving into it.
--
-- Replaces ECHO_CANTOUCH_FRAMES, which was a frame count standing in for this
-- and let allies damage themselves with their own assist.
local ECHO_CLEAR_STUDS = 10
local ECHO_SPAWN_FORWARD_DEFAULT = 2

-- Per-cast echo budget.
--
-- `processed` already stops us echoing the SAME body twice. It does nothing
-- about one cast emitting several DIFFERENT bodies, which is the normal case:
-- GHOST's Pulse Rifle is five bullets per press (0566.lua:1067), ELEMENTALIST's
-- Smolder is five bolts, and any class whose allow list holds more than one name
-- can emit several at once. Each one is a separate Instance, so each passed the
-- guard and forged its own echo -- one keypress, five extra owned bodies, five
-- steer coroutines, five movers.
--
-- That is the second half of the duplicate-projectile report and it is also the
-- FPS problem: with two allies it scales to ten. The budget caps how many
-- echoes one ally's cast may forge inside a short window. It does not try to
-- identify the cast (there is no cast id on the wire) -- a window plus a count
-- is enough, and it degrades honestly: the first N bolts of a volley get echoes
-- and the rest fly as the game made them.
local ECHO_CAST_WINDOW = 0.30   -- bodies this close together are one cast
local ECHO_MAX_PER_CAST = 2

local ally = {
    echoEnabled = false,        -- boots OFF, like every other toggle
    heatseek = true,            -- steer echoes once forged
    hideAllyBolt = true,
    maxActive = ECHO_MAX_ACTIVE_DEFAULT,
    maxPerCast = ECHO_MAX_PER_CAST,
    castWindow = ECHO_CAST_WINDOW,
    spawnForward = ECHO_SPAWN_FORWARD_DEFAULT,
    raw = "",
    names = {},                 -- lowercased name list, parsed from raw
    processed = {},             -- [sourceProj] = true, single-process guard
    active = {},                -- [echoProj] = true, for the cap
    activeN = 0,
    activeBy = {},              -- [Player] = live echo count, for fair share
    cast = {},                  -- [Player] = { at = clock, n = forged }
}

Core.ally = ally

-- Names only. The user picks PLAYERS; the class is detected from the bolt's own
-- SourceObj provenance (CS_CONSTRAINTS.md -- never a per-class ally picker).
function Core.setAllyNames(raw)
    ally.raw = tostring(raw or "")
    local out = {}
    for tok in ally.raw:gmatch("[^,;]+") do
        tok = tok:match("^%s*(.-)%s*$")
        if tok ~= "" then out[#out + 1] = tok:lower() end
    end
    ally.names = out
    return #out
end

-- Prefix match, so "zoey" resolves "zoeyzplayz10". A typo'd token that matches
-- nobody is reported by Core.allyStatus rather than failing silently -- an
-- unresolved ally name has already cost a whole test session.
function Core.isAllyPlayer(p)
    if not p or #ally.names == 0 then return false end
    local n = p.Name:lower()
    local d = (p.DisplayName or ""):lower()
    for _, want in ipairs(ally.names) do
        if n == want or d == want then return true end
        if #want >= 3 and (n:sub(1, #want) == want or d:sub(1, #want) == want) then
            return true
        end
    end
    return false
end

-- What class is this player playing right now? Same read as myClass(), just for
-- somebody else's character. Used to answer "which of my allies is on a class we
-- actually support" without the user having to ask them.
function Core.playerClass(p)
    local c = p and p.Character
    local cc = c and c:FindFirstChild("CurrentClass")
    local v = cc and cc.Value
    if not v or v == "" then return nil end
    return tostring(v)
end

-- Is the class this player is on registered, and will its bolts be echoed?
-- Returns the resolved config name, or nil plus a reason.
function Core.allyClassSupport(p)
    local cls = Core.playerClass(p)
    if not cls then return nil, "class unknown (out of match or not spawned)" end
    local cfg = S.aliasMap[cls] or S.classes[cls]
    if not cfg then return nil, cls .. " not registered" end
    if cfg.allyEcho == false then return nil, cfg.name .. " opted out" end
    return cfg.name
end

function Core.allyStatus()
    local resolved, unresolved = {}, {}
    -- Per-ally detected class, so the UI can say WHICH class each ally is on
    -- instead of a bare name list. "ally assist is on" and "ally assist is on and
    -- will do nothing because they are playing a class we do not support" looked
    -- identical before this.
    local classes, supported, unsupported = {}, {}, {}
    for _, want in ipairs(ally.names) do
        local hit = nil
        for _, p in ipairs(Players:GetPlayers()) do
            local n, d = p.Name:lower(), (p.DisplayName or ""):lower()
            if n == want or d == want
                or (#want >= 3 and (n:sub(1, #want) == want or d:sub(1, #want) == want)) then
                hit = p
                break
            end
        end
        if hit then
            resolved[#resolved + 1] = hit.Name
            local ok, why = Core.allyClassSupport(hit)
            classes[hit.Name] = ok or ("?" .. (why and (" " .. why) or ""))
            if ok then
                supported[#supported + 1] = hit.Name .. "=" .. ok
            else
                unsupported[#unsupported + 1] = hit.Name .. "=" .. tostring(why)
            end
        else
            unresolved[#unresolved + 1] = want
        end
    end
    return {
        raw = ally.raw,
        resolved = resolved,
        unresolved = unresolved,
        classes = classes,          -- [Player.Name] = CLASS or "? <reason>"
        supported = supported,      -- "name=CLASS", echo will fire
        unsupported = unsupported,  -- "name=reason", echo will not fire
        echo = ally.echoEnabled,
        heatseek = ally.heatseek,
        hideBolt = ally.hideAllyBolt,
        active = ally.activeN,
        activeBy = ally.activeBy,
        maxActive = ally.maxActive,
        maxPerCast = ally.maxPerCast,
    }
end

function Core.setAllyEchoEnabled(on)
    ally.echoEnabled = on and true or false
    logx("cfg", "ally echo " .. (ally.echoEnabled and "ON" or "OFF"))
    return ally.echoEnabled
end
function Core.setAllyHeatseekEnabled(on) ally.heatseek = on and true or false; return ally.heatseek end
-- Read through a function, not the `ally` local, so callers ABOVE that local's
-- declaration can still ask. noteCastWindow is one -- it sits ~1500 lines
-- earlier and would otherwise index a nil global at runtime.
function Core.allyHeatseekEnabled() return ally.heatseek and true or false end
function Core.setHideAllyBolt(on) ally.hideAllyBolt = on and true or false; return ally.hideAllyBolt end
function Core.setMaxActiveEchoes(n) ally.maxActive = math.clamp(tonumber(n) or ECHO_MAX_ACTIVE_DEFAULT, 1, 64); return ally.maxActive end
function Core.setAllySpawnForward(n) ally.spawnForward = math.clamp(tonumber(n) or ECHO_SPAWN_FORWARD_DEFAULT, 0, 20); return ally.spawnForward end
-- 1 = one echo per cast, whatever the kit. Raise it for multi-bolt kits
-- (GHOST's five-bullet Pulse Rifle, ELEMENTALIST's Smolder) at the cost of more
-- owned bodies in the air.
function Core.setMaxEchoesPerCast(n) ally.maxPerCast = math.clamp(tonumber(n) or ECHO_MAX_PER_CAST, 1, 8); return ally.maxPerCast end

-- Match an ally bolt against the class config. `allyAllow`/`allyDeny` fall back
-- to the self lists, so a class gets ally support with no extra config -- but
-- can diverge where the kits genuinely differ.
local function allyBoltMatches(cfg, proj)
    local allowList = cfg.allyAllow or cfg.allow
    local denyList = cfg.allyDeny or cfg.deny
    local name = proj.Name
    local lower = name:lower()
    if denyList then
        for _, d in ipairs(denyList) do
            if lower:find(tostring(d):lower(), 1, true) then return false, "denied " .. d end
        end
    end
    if allowList and #allowList > 0 then
        for _, a in ipairs(allowList) do
            -- Case-insensitive, matching allowMatch() on the self path.
            --
            -- This was `name == a`, a raw case-SENSITIVE compare, while the self
            -- path lowercased both sides. Every allow list in cs_classes.lua is
            -- written lowercase, and real body names are not consistently so
            -- (the CHRONO cast alone emits AttackSpirit, CritLmb1, TrailStart).
            -- So a class could heatseek perfectly for me and silently refuse
            -- every one of the same bodies for an ally -- a class that "says it
            -- has heatseeking" in the UI and does not have it for allies. The
            -- two matchers must not be allowed to disagree.
            if lower == tostring(a):lower() then return true end
        end
        return false, "not an echo bolt (" .. name .. ")"
    end
    -- No allowlist: refuse, same as the self path. See allowMatch().
    return false, "no allow list for " .. tostring(cfg.name)
end

-- Which registered class does this ally bolt belong to? Provenance only.
local function allyClassFor(proj)
    local srcClass = sourceClassName(proj)
    if not srcClass then return nil, "source class unresolved" end
    local cfg = S.aliasMap[srcClass] or S.classes[srcClass]
    if not cfg then return nil, "class " .. srcClass .. " not registered" end
    if cfg.allyEcho == false then return nil, cfg.name .. " opted out of ally echo" end
    return cfg
end

local function untrackEcho(echo)
    local owner = ally.active[echo]
    if owner then
        ally.active[echo] = nil
        ally.activeN = math.max(0, ally.activeN - 1)
        -- Per-ally count, so one ally spraying cannot consume the whole global cap
        -- and starve the other. The value is always the owning Player.
        if ally.activeBy[owner] then
            ally.activeBy[owner] = math.max(0, ally.activeBy[owner] - 1)
            if ally.activeBy[owner] == 0 then ally.activeBy[owner] = nil end
        end
    end
end

-- How many echoes this ally may have in the air at once. With one ally it is the
-- whole cap; with two it is half each. Without this the global cap is
-- first-come-first-served and the louder ally takes all of it.
local function allyShare()
    local n = #ally.names
    if n <= 1 then return ally.maxActive end
    return math.max(1, math.floor(ally.maxActive / n))
end

-- Returns nil when the cast may forge, or a reject reason.
local function castBudget(owner)
    local now = os.clock()
    local c = ally.cast[owner]
    if not c or (now - c.at) > ally.castWindow then
        ally.cast[owner] = { at = now, n = 1 }
        return nil
    end
    if c.n >= ally.maxPerCast then
        return ("cast budget %d/%d"):format(c.n, ally.maxPerCast)
    end
    c.n = c.n + 1
    return nil
end

-- Idempotent. Several cleanup paths (Destroying, AncestryChanged, lifetime,
-- first hit) all fire for the same body; without the flag this Destroys
-- repeatedly and spams the log through pcall.
local function cleanupEcho(echo, why)
    if not echo then return end
    local rec = S.registry[echo]
    if rec then
        if rec.echoCleaned then return end
        rec.echoCleaned = true
    end
    untrackEcho(echo)
    Core.unregister(echo, why or "echo cleanup")
    pcall(function() if echo.Parent then echo:Destroy() end end)
    logx("echo", ("echo cleanup (%s) active=%d/%d")
        :format(tostring(why or "unspecified"), ally.activeN, ally.maxActive))
end

-- Hide AND destroy the ally's original bolt.
--
-- The destroy is not optional and leaving it out is what produced the
-- duplicate-projectile report for ally heatseek. Transparency only silences
-- BaseParts: a projectile's visible tail is ParticleEmitters, Trails and Beams,
-- none of which are BaseParts and none of which care about Transparency. So the
-- ally's bolt kept flying its own straight path, fully visible as a trail,
-- right next to the echo we were steering -- two projectiles from one shot.
--
-- It also kept its own collision/damage behaviour on other clients. The
-- archived module destroyed it on a deferred frame for exactly these reasons;
-- the port hid it and stopped there. This restores the destroy.
--
-- Deferred rather than immediate: the body is mid-handler when we get here, and
-- destroying it out from under its own ProjectileHandler on the same frame
-- makes that handler error.
local function hideBolt(src)
    if not (ally.hideAllyBolt and src and src.Parent) then return end
    pcall(function()
        for _, d in ipairs(src:GetDescendants()) do
            if d:IsA("BasePart") then
                d.Transparency = 1
                d.CanCollide = false
                d.CanTouch = false
            elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") then
                -- Killed explicitly: these are the actually-visible parts of a
                -- bolt and they survive any amount of Transparency.
                d.Enabled = false
            end
        end
        if src:IsA("BasePart") then
            src.Transparency = 1
            src.CanCollide = false
            src.CanTouch = false
        end
    end)
    task.defer(function()
        pcall(function()
            if src and src.Parent then src:Destroy() end
        end)
    end)
end

-- Ally-echo cosmetics. FROST ability2 (0373.lua) sets Transparency=1 and
-- attaches ability2model1/2 via GetProjectile(Owner.Character). Owner of our
-- echo is US, so that resolves OUR class folder — models never attach.
-- Result: FLIGHT lines show real steering on an invisible Union while the
-- user only sees the ally's straight cleave (then hideBolt). Clone the
-- template-folder model siblings (or the ally bolt's already-attached ones)
-- and weld them to the echo. Last resort: un-hide the body itself.
local function attachEchoCosmetics(echo, template, src)
    if not (echo and echo.Parent) then return end
    pcall(function()
        local function weldClone(part)
            if not (part and part:IsA("BasePart")) then return false end
            local clone = part:Clone()
            for _, c in ipairs(clone:GetChildren()) do
                if c:IsA("Weld") or c:IsA("WeldConstraint") or c:IsA("Motor6D") then
                    c:Destroy()
                end
            end
            clone.Anchored = false
            clone.CanCollide = false
            clone.CanTouch = false
            clone.Massless = true
            clone.CFrame = echo.CFrame
            clone.Parent = echo
            local w = Instance.new("WeldConstraint")
            w.Part0 = echo
            w.Part1 = clone
            w.Parent = clone
            return true
        end

        local added = 0
        local folder = template and template.Parent
        local base = template and template.Name
        if folder and base then
            local prefix = base .. "model"
            for _, sib in ipairs(folder:GetChildren()) do
                if sib.Name:sub(1, #prefix) == prefix then
                    if weldClone(sib) then added = added + 1 end
                end
            end
        end
        if added == 0 and src then
            for _, ch in ipairs(src:GetChildren()) do
                if ch:IsA("BasePart") and ch.Name:lower():find("model", 1, true) then
                    if weldClone(ch) then added = added + 1 end
                end
            end
        end
        if added == 0 and echo:IsA("BasePart") and echo.Transparency >= 0.99 then
            echo.Transparency = 0.15
            logx("echo", "echo cosmetics: no models — unhid body " .. tostring(echo.Name))
        elseif added > 0 then
            logx("echo", ("echo cosmetics: welded %d model(s) onto %s"):format(added, tostring(echo.Name)))
        end
    end)
end

local function forgeAllyEcho(src, allyPlayer, cfg, preTgt)
    -- preTgt: the pre-lock's chosen target, used ONLY by the point-blank
    -- CanTouch exception below. nil when pre-lock is disabled; the exception
    -- then simply never fires and the plain clear-distance rule stands.
    local function tgtRoot()
        local c = preTgt
        return c and c.Parent and c:FindFirstChild("HumanoidRootPart") or nil
    end
    if ally.activeN >= ally.maxActive then
        Core.noteReject("echo cap reached")
        return nil
    end
    local mine = ally.activeBy[allyPlayer] or 0
    if mine >= allyShare() then
        Core.noteReject("echo per-ally cap")
        return nil
    end

    local so = src:FindFirstChild("SourceObj")
    local template = so and so.Value
    if not template then
        Core.noteReject("echo: no SourceObj template")
        return nil
    end

    -- Spawn just ahead of the ally's bolt so the echo does not begin inside
    -- their character.
    local cf = src.CFrame
    if ally.spawnForward > 0 then
        cf = cf * CFrame.new(0, 0, -ally.spawnForward)
    end

    -- HitCap: force 1 for ordinary bolts so one echo cannot chain through a
    -- crowd, but INHERIT the ally bolt's own cap when it has one. Forcing 1
    -- unconditionally is what made MUSKETEER's F feel weak -- Firing Squad's
    -- `critical` is designed to pierce until HitCap is spent (0473.lua:89), and
    -- capping it at 1 turns a multi-hit ability into a single-hit one.
    local opts = {}
    if cfg.options then
        for k, v in pairs(cfg.options) do opts[k] = v end
    end
    local srcCap = src:FindFirstChild("HitCap")
    local capVal = srcCap and tonumber(srcCap.Value) or nil
    opts.HitCap = (capVal and capVal > 0) and capVal or 1

    local repl, arm = pickEchoTransport()
    local echo = Core.spawnHit({
        template = template,
        cframe = cf,
        rawTemplate = true,
        options = opts,
        trialReplicate = repl,
    })
    if not echo then return nil end
    if arm then echoArm[echo] = arm end

    -- Tag BEFORE any yield. The echo carries Speed/Range/Damage and is owned by
    -- us, which is exactly what classify() looks for -- untagged, our own
    -- watcher re-ingests it and a second steerer fights this one over one mover.
    markTracked(echo)
    pcall(function()
        local t = Instance.new("BoolValue")
        t.Name = ECHO_TAG
        t.Value = true
        t.Parent = echo
    end)

    -- Before hideBolt destroys the ally's visible models — attach cosmetics
    -- onto OUR echo. See attachEchoCosmetics (FROST Transparency=1 trap).
    attachEchoCosmetics(echo, template, src)

    -- Value is the OWNER, not `true`: untrackEcho needs it to decrement the
    -- per-ally count, and a boolean there made fair-share bookkeeping impossible.
    ally.active[echo] = allyPlayer
    ally.activeN = ally.activeN + 1
    ally.activeBy[allyPlayer] = (ally.activeBy[allyPlayer] or 0) + 1

    -- The echo starts at the ally's muzzle, so Touched fires against their own
    -- parts on frame one without this.
    -- Collision stays off until the echo is physically CLEAR OF THE ALLY, not
    -- for a fixed number of frames.
    --
    -- Reported live 2026-07-31: allies were being hit by the echoes forged for
    -- them. The echo is owned by US, and in FFA nobody carries a Team child, so
    -- CheckTeam (0704.lua:233) rates our ally a perfectly valid victim. We spawn
    -- the body at their muzzle and used to re-enable CanTouch after three
    -- heartbeats -- about 20ms, during which a speed-250 bolt has moved roughly
    -- five studs and is still inside their own hitbox.
    --
    -- Targeting was never the problem: tryAllyEcho already passes the shooter in
    -- ctx.exclude, which is the `excluded` reject in the histogram. This is
    -- purely physical contact on the way out.
    --
    -- Distance-gated, because that is the actual condition. The frame count was
    -- a proxy for it that fails the instant the bolt is slow, the ally is
    -- moving, or the frame rate dips.
    -- CONTINUOUS, not a one-shot window. This is the second fix to the same bug
    -- and the first one had the hole in it.
    --
    -- The previous version polled until the echo was ECHO_CLEAR_STUDS away OR a
    -- 0.6s deadline expired, then armed CanTouch unconditionally. The deadline
    -- was meant as a safety valve so a bolt that never separates still becomes
    -- live -- but "never separates" is precisely the case where arming it hits
    -- the ally, so the valve vented into the failure it was guarding.
    --
    -- Reported live 2026-07-31: ELEMENTALIST's E still hitting the ally it was
    -- forged for. That bolt is slow and the caster tends to move with it, so it
    -- reached 0.6s while still inside their own hitbox EVERY time -- the one
    -- path where the guard reduced to "wait 0.6s then hit them anyway".
    --
    -- So the rule is now stated directly and enforced for the whole flight:
    -- the echo is touchable exactly when it is clear of the ally. If it comes
    -- back -- a boomerang returning, the ally running after it -- it goes
    -- untouchable again rather than staying armed because of something that
    -- happened in the first 600ms.
    --
    -- Cost of getting it wrong in the safe direction: a bolt that hugs its
    -- caster deals no damage to anyone while it does so. That is correct. The
    -- alternative is damaging the person we forged it for, which is worse than
    -- a missed hit and is what was actually being reported.
    --
    -- Why not a collision group: the echo must still collide normally with
    -- everyone else, and group membership is global state shared with whatever
    -- else the executor is doing. A per-body property we already own is the
    -- smaller mechanism.
    pcall(function() echo.CanTouch = false end)
    task.spawn(function()
        local live = false
        while echo and echo.Parent do
            RunService.Heartbeat:Wait()
            if not (echo and echo.Parent) then return end

            -- Re-read every iteration: the ally can die and respawn mid-flight,
            -- and a captured root would leave this comparing against a corpse.
            local allyChar = allyPlayer and allyPlayer.Character
            local allyRoot = allyChar and allyChar:FindFirstChild("HumanoidRootPart")

            local clear
            if not (allyRoot and allyRoot.Parent) then
                -- No ally body to hit. Nothing to protect, so stop suppressing.
                clear = true
            else
                local dAlly = (echo.Position - allyRoot.Position).Magnitude
                clear = dAlly >= ECHO_CLEAR_STUDS
                -- POINT-BLANK EXCEPTION, and it is what made FROST's E dead for
                -- allies. A cleave is cast at somebody standing ON the ally --
                -- measured locks at dist=1.4 / 3.1 / 6.1 studs from the muzzle.
                -- The whole engagement fits inside ECHO_CLEAR_STUDS, so the echo
                -- could NEVER become touchable: every close-range cleave flew
                -- through its target disarmed and logged `missed at 2 studs`.
                -- The guard was built against a bolt hitting the person it was
                -- forged for; at 10 studs it was instead guaranteeing every
                -- sub-10-stud kit does nothing for allies, silently.
                --
                -- Rule: touchable when the TARGET is closer than the ally. The
                -- guard's actual job -- "do not hit the ally on the way out" --
                -- is preserved exactly: while the ally is the nearer body the
                -- echo stays disarmed, and the moment the bolt is closer to the
                -- enemy than to its caster, hitting the ally is no longer the
                -- likelier outcome. Re-evaluated every frame like the rest, so
                -- it disarms again if geometry flips back.
                if not clear then
                    local tr = tgtRoot()
                    if tr then
                        local dTgt = (echo.Position - tr.Position).Magnitude
                        -- Nearer to target than ally, OR already inside a
                        -- character-width of the lock — FROST cleaves often
                        -- never get dTarget < dAlly while still overlapping
                        -- the victim (muzzle-forward spawn keeps ally close).
                        clear = dTgt < dAlly or dTgt <= 4
                    end
                end
            end

            if clear ~= live then
                live = clear
                pcall(function()
                    if echo.Parent then echo.CanTouch = clear end
                end)
            end
        end
    end)

    -- Hard lifetime ceiling: a pierced body can outlive its hit and keep
    -- steering past dead targets.
    -- Life scaled to the bolt's own flight, not the flat ceiling. FROST's E is
    -- range=35 speed=100 = 0.35s of real flight, and echoes were living 0.76s+
    -- -- twice the body's own range -- so a missed cleave kept flying far past
    -- where the class's bolt can exist. Same disease as projLifetime pre-fix.
    -- 1.4x for lead and a curved path; ECHO_MAX_LIFE stays the hard ceiling.
    --
    -- Reach, not declared Range, and the same floor the self path gets. Sizing
    -- this off `Range` alone made the echo the ONLY place §3's lesson was not
    -- applied: FROST E declares 35 at speed 100, so every ally echo was killed
    -- at 0.49s -- about 49 studs -- while the bolt's real reach is 76 and the
    -- self flight (projLifetime, floored at 0.75s) ran the full 0.76s. That is
    -- exactly "FROST E works for me but not for allies": the echo expired in
    -- mid-air short of the lock, every time, and logged `gone`.
    local life = ECHO_MAX_LIFE
    local esp = projSpeed(echo)
    local ern = reachFor(cfg, echo, projRange(echo))
    if esp and ern and esp > 0 and ern > 0 then
        life = math.clamp((ern / esp) * 1.35 + 0.25, 0.75, ECHO_MAX_LIFE)
    end
    task.delay(life, function() cleanupEcho(echo, "echo lifetime") end)
    pcall(function()
        echo.Destroying:Connect(function() untrackEcho(echo) end)
    end)

    -- Mark the cast as having produced an echo, so its later siblings know they
    -- are siblings of a steered bolt and can be hidden rather than left flying.
    local crec = ally.cast[allyPlayer]
    if crec then crec.forged = (crec.forged or 0) + 1 end

    hideBolt(src)
    -- lag = how long WE took, from the ally's body appearing on our client to
    -- the echo existing. Excludes network RTT, which we cannot see or fix, so
    -- this number is purely our own contribution to the delay allies notice.
    local seen = allySeenAt[src]
    local lagMs = seen and math.floor((os.clock() - seen) * 1000) or -1
    logx("echo", ("echo forged %s <- %s [%s] active=%d/%d (this ally %d)%s lag=%dms")
        :format(src.Name, allyPlayer.Name, cfg.name,
            ally.activeN, ally.maxActive, ally.activeBy[allyPlayer] or 0,
            arm and (" arm=" .. arm) or "", lagMs))
    noteEchoDiag(lagMs)
    return echo
end

-- Entry point from the watcher for a body owned by someone else.
local function tryAllyEcho(inst)
    if not (ally.echoEnabled and S.alive) then return end
    if ally.processed[inst] then return end

    local owner = projOwner(inst)
    if not owner or owner == lp then return end
    if not Core.isAllyPlayer(owner) then return end

    local cfg, why = allyClassFor(inst)
    if not cfg then
        if why then Core.noteReject("echo: " .. why) end
        return
    end
    local ok, denyWhy = allyBoltMatches(cfg, inst)
    -- Census BEFORE the return, so refused bodies are recorded too. The refused
    -- set is the more useful half: it is the list of names the allow list should
    -- probably have contained.
    noteAllyBody(cfg.name, inst.Name, ok and true or false)
    if not ok then
        Core.noteReject("echo: " .. (denyWhy or "not an echo bolt"))
        return
    end

    ally.processed[inst] = true

    -- Budget the cast before doing any work for it. Checked here rather than in
    -- forgeAllyEcho so it also skips the pre-lock scan below -- that scan is the
    -- expensive part (it enumerates candidates and raycasts), and running it for
    -- bolts we have already decided not to echo is pure frame time.
    local budgetWhy = castBudget(owner)
    if budgetWhy then
        Core.noteReject("echo: " .. budgetWhy)
        -- Hide the SIBLINGS of a cast we already echoed.
        --
        -- hideBolt used to run only on a successful forge, so on a multi-bolt kit
        -- (MUSKETEER Firing Squad) we destroyed the two bodies we echoed and left
        -- the rest of the cast flying, fully visible, straight, alongside the
        -- steered ones. On OUR screen that is the duplicate-projectile report.
        --
        -- Only when this cast has actually forged something. A cast that echoed
        -- nothing at all must keep its bodies -- see the `no target at forge
        -- time` path, which deliberately leaves the ally's own bolt to do its
        -- job rather than deleting a shot and replacing it with nothing.
        local c = ally.cast[owner]
        if c and (c.forged or 0) > 0 then hideBolt(inst) end
        return
    end

    -- Pre-lock BEFORE forging. 131 of 447 echoes in the last session were
    -- spawned and then immediately released with "no target" -- each one a body
    -- that popped into the world and vanished for no benefit. If there is
    -- nothing to steer at, the correct number of extra projectiles is zero:
    -- the ally's own bolt already does its job.
    local allyChar = owner.Character
    -- allyPlayer, not just allyName: the cast id is keyed by the Player so every
    -- body of one ally's keypress groups together in the log, and a name string
    -- cannot be used as a stable table key across respawns.
    -- Aim from the ALLY's bolt, not from my camera. See aimOrigin().
    local srcLook = inst.CFrame.LookVector
    local srcVel = inst.AssemblyLinearVelocity
    if srcVel and srcVel.Magnitude > 1 then
        -- Travel direction beats LookVector: the game pins projectile orientation
        -- with an AngularVelocity constraint (0704.lua:716-719), so LookVector is
        -- a fixed axis that need not point along the flight at all.
        srcLook = srcVel.Unit
    end
    local preCtx = {
        allyName = owner.Name,
        allyPlayer = owner,
        isEcho = true,
        originPos = inst.Position,
        originLook = srcLook,
    }
    if allyChar then preCtx.exclude = { [allyChar] = true } end

    -- Declared here, not inside the branch: forgeAllyEcho's point-blank
    -- CanTouch exception needs it, and a `local` inside the if-block would be
    -- a nil global at the call site -- the declaration-order trap, again.
    local preTgt = nil

    if ally.heatseek then
        local mc = char()
        -- The ALLY BOLT's own range, not nil.
        --
        -- Passing nil fell through to T.lockRange (170), so the pre-lock scan
        -- for an ally's MUSKETEER `critical` (range=400, cap 440) only looked
        -- 170 studs and refused every target past that -- reported as
        -- `echo: no target at forge time`, which reads like "nothing to shoot"
        -- rather than "we did not look". Short-range ally kits were unaffected,
        -- which is why it stayed hidden.
        --
        -- The echo inherits the source bolt's Speed/Range, so the source's range
        -- is exactly the right cap for it.
        preTgt = Core.pickTarget(reachFor(cfg, inst, projRange(inst)), mc, preCtx,
            lockFovFor(cfg, inst),
            castWindowCloseLock(cfg, owner), nil, projSpeed(inst))
        if not preTgt then
            Core.noteReject("echo: no target at forge time")
            return
        end
    end

    local echo = forgeAllyEcho(inst, owner, cfg, preTgt)
    if not echo then return end

    if not ally.heatseek then return end

    -- Exclude the shooter: the echo spawns at their muzzle, so they are
    -- routinely the closest valid body in the cone. Reuses the pre-lock ctx.
    local ctx = preCtx

    task.spawn(function()
        local okS, err = pcall(steer, echo, cfg, ctx)
        if not okS then
            Log.err("ally echo steer error", err)
            cleanupEcho(echo, "error")
        end
    end)
end

-- `processed` is keyed by Instance and would otherwise hold a strong reference
-- to every ally bolt seen this session.
local function sweepAllyProcessed()
    for src in pairs(ally.processed) do
        if not src.Parent then ally.processed[src] = nil end
    end
    for echo in pairs(ally.active) do
        if not echo.Parent then untrackEcho(echo) end
    end
    -- cast/activeBy are Player-keyed and would otherwise hold a reference to
    -- everyone who has ever been named an ally in this session.
    local now = os.clock()
    for p, c in pairs(ally.cast) do
        if not p.Parent or (now - c.at) > 30 then ally.cast[p] = nil end
    end
    for p in pairs(ally.activeBy) do
        if not p.Parent then ally.activeBy[p] = nil end
    end
end

Core.sweepAllyProcessed = sweepAllyProcessed

local function onProjectileAdded(inst)
    if not S.alive then return end
    if not inst:IsA("BasePart") then return end
    -- Stamped before the defer, so `lag` measures everything we do including
    -- the defer and the classify wait -- not just the part after them.
    allySeenAt[inst] = os.clock()
    task.defer(function()
        if not (S.alive and inst.Parent) then return end
        if S.registry[inst] then return end
        if not waitForClassify(inst) then return end

        -- Observed for EVERY body, before class matching, because the marker is
        -- a body we deliberately refuse to steer -- classify() would reject it
        -- and return before we ever saw it. Owner is resolved by now; that is
        -- what waitForClassify was for.
        noteCastWindow(inst, projOwner(inst))

        local cfg, why = classify(inst)
        if not cfg then
            -- Not ours. Before writing it off, it may be an ally's bolt we
            -- should echo. classify() rejects on `owner <name>` for exactly
            -- these, so this is the natural place to branch.
            local okAlly = pcall(tryAllyEcho, inst)
            if not okAlly then Log.err("ally echo error", inst.Name) end
            if why then Core.noteReject(why) end
            return
        end
        task.spawn(function()
            local ok, err = pcall(steer, inst, cfg)
            if not ok then
                Log.err("steer error", err)
                Core.unregister(inst, "error")
            end
        end)
    end)
end

-- Attach to a ClientProjectiles folder. Re-attachable: the folder is destroyed
-- and recreated between matches, and the old per-toggle modules never noticed
-- because each toggle re-injected them. The engine loads once at boot, so
-- without re-acquiring, its watcher would die at the first match transition and
-- heatseek would silently stop working for the rest of the session.
local watchedFolder = nil
local folderConn = nil

local function attachTo(folder)
    if not folder or folder == watchedFolder then return end
    if folderConn then
        pcall(function() folderConn:Disconnect() end)
        folderConn = nil
    end
    watchedFolder = folder
    folderConn = folder.ChildAdded:Connect(onProjectileAdded)
    table.insert(S.conns, folderConn)
    for _, ch in ipairs(folder:GetChildren()) do onProjectileAdded(ch) end
    Log.info("armed — watching ClientProjectiles")
end

-- NOTE: must never block. This runs inside loadstring() inside cs_admin's boot,
-- so a WaitForChild here would stall the whole panel -- for up to a minute if
-- injected outside a match, with no UI on screen to explain why.
local function watch()
    attachTo(workspace:FindFirstChild("ClientProjectiles"))

    conn(workspace.ChildAdded, function(ch)
        if ch.Name == "ClientProjectiles" then attachTo(ch) end
    end)

    if not watchedFolder then
        Log.info("ClientProjectiles not present yet — will attach when it appears")
    end
end

--------------------------------------------------------------------------
-- 13. TELEMETRY
--
-- The reject histogram is the single most valuable diagnostic: "outOfRange=13"
-- diagnosed the range-cap bug instantly, but only by reading a log file after
-- the fact. Kept in memory so the panel can render it live.
--------------------------------------------------------------------------

Core.stats = {
    locks = 0,
    hits = 0,
    noLosLocks = 0,
    rejects = {},
    lastReject = nil,
}

-- Rejects go to the LOG as well as the panel histogram.
--
-- They used to live only in the in-memory histogram, which meant a class that
-- was armed and still doing nothing produced a completely silent log -- and
-- "wrong body name" was indistinguishable from "toggle off" without opening the
-- panel mid-fight. Since half the roster is unstreamed and ships with
-- convention-guessed `allow` lists, "the name is wrong" is the single most
-- likely failure, and the reject line is the thing that names the real body.
--
-- Rate limited by reason: the first occurrence is logged immediately, then
-- every 25th. This runs per rejected body in a busy match, so unconditional
-- logging would bury the log in `owner <name>` lines from every other player.
local REJECT_LOG_EVERY = 25

function Core.noteReject(why)
    if not why then return end
    local n = (Core.stats.rejects[why] or 0) + 1
    Core.stats.rejects[why] = n
    Core.stats.lastReject = why
    if n == 1 or n % REJECT_LOG_EVERY == 0 then
        logx("reject", ("reject: %s%s"):format(why, n > 1 and (" x" .. n) or ""))
    end
end

function Core.resetStats()
    Core.stats.locks = 0
    Core.stats.hits = 0
    Core.stats.noLosLocks = 0
    Core.stats.rejects = {}
    Core.stats.lastReject = nil
end

-- Reject reasons sorted by count, most frequent first.
function Core.topRejects(n)
    local list = {}
    for why, count in pairs(Core.stats.rejects) do
        list[#list + 1] = { why = why, count = count }
    end
    table.sort(list, function(a, b) return a.count > b.count end)
    if n then
        while #list > n do table.remove(list) end
    end
    return list
end

function Core.getStatus()
    local on = {}
    for name, cfg in pairs(S.classes) do
        if cfg.enabled then on[#on + 1] = name end
    end
    table.sort(on)
    return {
        alive = S.alive,
        enabledClasses = on,
        active = Core.activeCount(),
        locks = Core.stats.locks,
        hits = Core.stats.hits,
        noLosLocks = Core.stats.noLosLocks,
        lastReject = Core.stats.lastReject,
        myClass = myClass(),
    }
end

--------------------------------------------------------------------------
-- 14. LEARN MODE
--
-- Passive-only observer. Records every projectile from every player, keyed by
-- the owner's CurrentClass. Never steers. The existing heatseek watcher is
-- completely unaffected: learn mode runs a SEPARATE ChildAdded listener that
-- only writes scalars into a summary table.
--
-- Data model (per class, per body name):
--   count, speed (min/max/sum), range (min/max/sum), damage (min/max/sum),
--   travelled (yes count, no count), welded (yes/no), anchored (yes/no),
--   hrpPinned (yes/no), returned (yes/no), lifetimeSum, lifetimeCount,
--   volleyGaps (sum of inter-body times within one cast).
--
-- Instance-keyed state: only `learnActive` (body → record). Pruned every
-- sweep and torn down on disable/destroy.
--------------------------------------------------------------------------

local learn = {
    enabled = false,
    startedAt = nil,
    jobId = nil,
    -- [className] = { [bodyName] = summary }
    classes = {},
    -- instance-keyed: body → { born, ownerRoot, spawnPos, maxDist, ... }
    -- Pruned every Heartbeat sweep. MUST be cleared on disable/destroy.
    active = {},
    -- [className] = last body spawn os.clock(), for volley gap measurement
    lastSpawn = {},
    folderConn = nil,
}

local LEARN_SAMPLE_HZ = 5        -- sample displacement N times per second
local LEARN_SAMPLE_DT = 1 / LEARN_SAMPLE_HZ
local LEARN_MAX_TRACK_SEC = 12    -- hard ceiling on tracking one body
local LEARN_PIN_THRESHOLD = 3     -- studs: if body stays within this of a char HRP, it is pinned
local LEARN_PIN_MIN_SAMPLES = 5
local LEARN_TRAVEL_THRESHOLD = 8  -- studs: body must move this far from spawn to count as "travelled"
local LEARN_RETURN_ARM_DIST = 20
local LEARN_RETURN_TRIP_DIST = 6

local function learnEnsureSummary(className, bodyName)
    local cls = learn.classes[className]
    if not cls then
        cls = {}
        learn.classes[className] = cls
    end
    local s = cls[bodyName]
    if not s then
        s = {
            count = 0,
            speedMin = math.huge, speedMax = -math.huge, speedSum = 0, speedN = 0,
            rangeMin = math.huge, rangeMax = -math.huge, rangeSum = 0, rangeN = 0,
            dmgMin = math.huge, dmgMax = -math.huge, dmgSum = 0, dmgN = 0,
            travelledYes = 0, travelledNo = 0,
            weldedYes = 0, weldedNo = 0,
            anchoredYes = 0, anchoredNo = 0,
            anchoredFlipYes = 0, anchoredAtBirthYes = 0,
            hrpPinnedYes = 0, hrpPinnedNo = 0,
            returnedYes = 0, returnedNo = 0,
            lifetimeSum = 0, lifetimeN = 0,
            volleyGapSum = 0, volleyGapN = 0,
        }
        cls[bodyName] = s
    end
    return s
end

local function learnRecordVal(s, prefix, val)
    if not val then return end
    s[prefix .. "N"] = s[prefix .. "N"] + 1
    s[prefix .. "Sum"] = s[prefix .. "Sum"] + val
    if val < s[prefix .. "Min"] then s[prefix .. "Min"] = val end
    if val > s[prefix .. "Max"] then s[prefix .. "Max"] = val end
end

-- Resolve the owner's CurrentClass at the moment the body appears.
local function ownerClassName(proj)
    local owner = projOwner(proj)
    if not owner then return nil, nil end
    local c = owner.Character
    local cc = c and c:FindFirstChild("CurrentClass")
    return cc and cc.Value or nil, owner, c
end

-- Weld check that works on any character, not just ours.
local function weldedToAnyCharacter(proj)
    for _, p in ipairs(Players:GetPlayers()) do
        local c = p.Character
        if c and weldedToCharacter(proj, c) then return true end
    end
    return false
end

-- Is a body HRP-pinned? Sample its distance to the nearest player's HRP over
-- time. If it stays within LEARN_PIN_THRESHOLD for LEARN_PIN_MIN_SAMPLES
-- consecutive samples, it is pinned.
local function learnTrackBody(proj, rec)
    -- Called in a task.spawn per body. Samples at LEARN_SAMPLE_HZ.
    local born = os.clock()
    local spawnPos = proj.Position
    rec.spawnPos = spawnPos
    rec.maxDist = 0
    rec.maxOwnerDist = 0
    rec.anchoredEver = proj.Anchored
    rec.anchoredInit = proj.Anchored
    rec.pinSamples = 0
    rec.pinConsec = 0
    rec.pinMax = 0
    rec.returned = false
    rec.samples = 0
    rec.weldedEver = false
    rec.travelledDist = 0

    while S.alive and learn.enabled and proj and proj.Parent do
        task.wait(LEARN_SAMPLE_DT)
        if not (proj and proj.Parent) then break end
        if os.clock() - born > LEARN_MAX_TRACK_SEC then break end

        rec.samples = rec.samples + 1
        local pos = proj.Position

        -- Displacement from spawn
        local dist = (pos - spawnPos).Magnitude
        if dist > rec.maxDist then rec.maxDist = dist end
        rec.travelledDist = dist

        -- Anchored flip
        if proj.Anchored and not rec.anchoredInit then
            rec.anchoredEver = true
        end

        -- Weld check (any character)
        if not rec.weldedEver and weldedToAnyCharacter(proj) then
            rec.weldedEver = true
        end

        -- HRP-pin: distance to nearest player HRP
        local minCharDist = math.huge
        for _, p in ipairs(Players:GetPlayers()) do
            local c = p.Character
            local hrp = c and c:FindFirstChild("HumanoidRootPart")
            if hrp then
                local d = (pos - hrp.Position).Magnitude
                if d < minCharDist then minCharDist = d end
            end
        end
        if minCharDist <= LEARN_PIN_THRESHOLD then
            rec.pinConsec = rec.pinConsec + 1
        else
            rec.pinConsec = 0
        end
        if rec.pinConsec > rec.pinMax then rec.pinMax = rec.pinConsec end

        -- Return-to-owner detection
        if rec.ownerRoot then
            local ok2, opos = pcall(function() return rec.ownerRoot.Position end)
            if ok2 and opos then
                local ownerDist = (pos - opos).Magnitude
                if ownerDist > rec.maxOwnerDist then rec.maxOwnerDist = ownerDist end
                if rec.maxOwnerDist > LEARN_RETURN_ARM_DIST and ownerDist < LEARN_RETURN_TRIP_DIST then
                    rec.returned = true
                end
            end
        end
    end

    -- Body gone or tracking ended. Finalize into summary.
    rec.lifetime = os.clock() - born
    rec.done = true
end

local function learnFinalize(rec)
    if not rec or not rec.className or not rec.bodyName then return end
    local s = learnEnsureSummary(rec.className, rec.bodyName)
    s.count = s.count + 1

    learnRecordVal(s, "speed", rec.speedVal)
    learnRecordVal(s, "range", rec.rangeVal)
    learnRecordVal(s, "dmg", rec.dmgVal)

    if rec.done then
        if rec.maxDist and rec.maxDist >= LEARN_TRAVEL_THRESHOLD then
            s.travelledYes = s.travelledYes + 1
        else
            s.travelledNo = s.travelledNo + 1
        end

        if rec.weldedEver then s.weldedYes = s.weldedYes + 1
        else s.weldedNo = s.weldedNo + 1 end

        if rec.anchoredEver then s.anchoredYes = s.anchoredYes + 1
        else s.anchoredNo = s.anchoredNo + 1 end

        -- Anchored from birth = a marker/turret body that never flies.
        -- Anchored later = the game's own DestroyProjectile firing on impact.
        -- These mean opposite things and must be counted apart.
        s.anchoredAtBirthYes = s.anchoredAtBirthYes or 0
        if rec.anchoredInit then
            s.anchoredAtBirthYes = s.anchoredAtBirthYes + 1
        elseif rec.anchoredEver then
            s.anchoredFlipYes = s.anchoredFlipYes + 1
        end

        if rec.pinMax >= LEARN_PIN_MIN_SAMPLES then
            s.hrpPinnedYes = s.hrpPinnedYes + 1
        else
            s.hrpPinnedNo = s.hrpPinnedNo + 1
        end

        if rec.returned then s.returnedYes = s.returnedYes + 1
        else s.returnedNo = s.returnedNo + 1 end

        if rec.lifetime then
            s.lifetimeSum = s.lifetimeSum + rec.lifetime
            s.lifetimeN = s.lifetimeN + 1
        end
    end
end

-- Sweep learn.active, finalize done bodies, prune gone ones.
local function learnSweep()
    if not learn.enabled then return end
    for body, rec in pairs(learn.active) do
        if not body.Parent then
            if not rec.done then
                rec.done = true
                rec.lifetime = os.clock() - rec.born
                -- Finalize displacement from what we have
                pcall(function()
                    if rec.spawnPos then
                        rec.maxDist = rec.maxDist or 0
                    end
                end)
            end
            learnFinalize(rec)
            learn.active[body] = nil
        elseif rec.done then
            learnFinalize(rec)
            learn.active[body] = nil
        end
    end
end

local function onLearnProjectile(inst)
    if not (S.alive and learn.enabled) then return end
    if not inst:IsA("BasePart") then return end

    task.defer(function()
        -- Wait for owner/SourceObj to populate (same timing as the main watcher)
        for _ = 1, CLASSIFY_HEARTBEATS do
            RunService.Heartbeat:Wait()
            if not (S.alive and learn.enabled and inst and inst.Parent) then return end
        end
        local ov = inst:FindFirstChild("Owner")
        if ov and ov:IsA("ObjectValue") and ov.Value == nil then
            local deadline = os.clock() + OWNER_WAIT_SEC
            while os.clock() < deadline and S.alive and inst.Parent do
                if ov.Value ~= nil then break end
                RunService.Heartbeat:Wait()
            end
        end
        if not (inst and inst.Parent and learn.enabled) then return end

        local className, owner, ownerChar = ownerClassName(inst)
        if not className or className == "" then return end

        local bodyName = inst.Name

        -- Read Speed/Range/Damage children
        local sv = inst:FindFirstChild("Speed")
        local rv = inst:FindFirstChild("Range")
        local dv = inst:FindFirstChild("Damage")
        local speedVal = sv and tonumber(sv.Value) or nil
        local rangeVal = rv and tonumber(rv.Value) or nil
        local dmgVal = dv and tonumber(dv.Value) or nil

        -- Owner's HRP for return-to-owner tracking
        local ownerRoot = ownerChar and ownerChar:FindFirstChild("HumanoidRootPart") or nil

        -- Volley gap: time between consecutive bodies of same class
        local now = os.clock()
        local gap = nil
        local lastT = learn.lastSpawn[className]
        if lastT and (now - lastT) < 2.0 then
            gap = now - lastT
        end
        learn.lastSpawn[className] = now

        if gap then
            local s = learnEnsureSummary(className, bodyName)
            s.volleyGapSum = s.volleyGapSum + gap
            s.volleyGapN = s.volleyGapN + 1
        end

        local rec = {
            born = now,
            className = className,
            bodyName = bodyName,
            speedVal = speedVal,
            rangeVal = rangeVal,
            dmgVal = dmgVal,
            ownerRoot = ownerRoot,
            done = false,
        }
        learn.active[inst] = rec

        task.spawn(function()
            local ok, err = pcall(learnTrackBody, inst, rec)
            if not ok then
                Log.err("learn track error", err)
                rec.done = true
            end
        end)
    end)
end

local learnFolderConn = nil
local learnWatchedFolder = nil

local function learnAttachTo(folder)
    if not folder or folder == learnWatchedFolder then return end
    if learnFolderConn then
        pcall(function() learnFolderConn:Disconnect() end)
        learnFolderConn = nil
    end
    learnWatchedFolder = folder
    learnFolderConn = folder.ChildAdded:Connect(onLearnProjectile)
    table.insert(S.conns, learnFolderConn)
    Log.info("learn mode: attached to ClientProjectiles")
end

function Core.learnEnable()
    if learn.enabled then return false, "already on" end
    learn.enabled = true
    learn.startedAt = os.clock()
    -- Try to capture the JobId for the output header
    pcall(function()
        learn.jobId = game.JobId ~= "" and game.JobId or nil
    end)

    -- Attach to ClientProjectiles (same pattern as the main watcher)
    learnAttachTo(workspace:FindFirstChild("ClientProjectiles"))
    if not learnWatchedFolder then
        -- Will attach when it appears
        conn(workspace.ChildAdded, function(ch)
            if ch.Name == "ClientProjectiles" and learn.enabled then
                learnAttachTo(ch)
            end
        end)
    end

    Log.info("learn mode ON")
    return true, "learn mode ON — observing all players' projectiles"
end

function Core.learnDisable()
    if not learn.enabled then return false, "already off" end
    learn.enabled = false
    -- Finalize any still-active bodies
    for body, rec in pairs(learn.active) do
        if not rec.done then
            rec.done = true
            rec.lifetime = os.clock() - rec.born
        end
        learnFinalize(rec)
    end
    table.clear(learn.active)
    table.clear(learn.lastSpawn)
    if learnFolderConn then
        pcall(function() learnFolderConn:Disconnect() end)
        learnFolderConn = nil
    end
    learnWatchedFolder = nil
    Log.info("learn mode OFF")
    return true, "learn mode OFF"
end

function Core.learnStatus()
    if not learn.enabled then
        local nClasses = 0
        for _ in pairs(learn.classes) do nClasses = nClasses + 1 end
        if nClasses == 0 then
            return "learn mode OFF (no data captured)"
        end
        return ("learn mode OFF — %d classes captured, use 'hslearn dump' to export"):format(nClasses)
    end
    local elapsed = os.clock() - (learn.startedAt or os.clock())
    local nClasses, nBodies, nActive = 0, 0, 0
    for _, cls in pairs(learn.classes) do
        nClasses = nClasses + 1
        for _ in pairs(cls) do nBodies = nBodies + 1 end
    end
    for _ in pairs(learn.active) do nActive = nActive + 1 end
    return ("learn mode ON · %.0fs · %d classes · %d body types · %d tracking")
        :format(elapsed, nClasses, nBodies, nActive)
end

-- Classification logic: from measured facts, propose allow/deny/flight.
local function classifyBody(bodyName, s)
    local hasSpeed = s.speedN > 0
    local hasRange = s.rangeN > 0
    local hasDmg = s.dmgN > 0
    local travels = s.travelledYes > s.travelledNo

    -- Welding is the crash vector (RECON C4 0564.lua:79-97, FROST attack
    -- 0409.lua:23). ONE observation is enough to disqualify forever: being wrong
    -- toward "safe" costs a bolt we could have steered, being wrong the other
    -- way drove the user's character across the map.
    local welds = s.weldedYes > 0

    -- Anchoring is NOT symmetric with welding, and treating it as such was
    -- silently fatal. The game's standard hit path calls DestroyProjectile,
    -- which sets Anchored = true on impact -- so every bolt that actually LANDS
    -- ends its life anchored. Counting any anchor at all would deny precisely
    -- the bodies that work, and the better the bolt the more certainly it gets
    -- denied. Only a body anchored from BIRTH is a marker/turret (the
    -- PROGRAMMER Return Zero anchor, 0129.lua:57); a late flip is a hit.
    local anchors = s.anchoredAtBirthYes and s.anchoredAtBirthYes > 0 or false

    -- Pin and travel are MAJORITY tests, not any-hit tests. A bolt that flies
    -- close alongside someone for a second reads as pinned once in a while;
    -- one such sample in fifty casts must not permanently deny a real bolt.
    local pins = s.hrpPinnedYes > s.hrpPinnedNo
    local returns = s.returnedYes > 0

    -- One sighting is an anecdote. Emitting `allow` off a single observation is
    -- how a fluke becomes a config line -- the low-confidence section exists
    -- precisely so these get reported rather than proposed.
    if s.count < 2 then
        return "unsure", "seen only " .. tostring(s.count) .. " time(s)"
    end

    -- Propose allow if: travels AND has Speed+Range+Damage AND never welds,
    -- is not born anchored, and is not usually pinned to a character.
    if hasSpeed and hasRange and hasDmg and travels and not welds and not anchors and not pins then
        return "allow", nil
    end

    -- Build deny reason from measured facts
    local reasons = {}
    if welds then reasons[#reasons + 1] = "welds-to-character" end
    if anchors then reasons[#reasons + 1] = "anchored-at-spawn" end
    if pins then reasons[#reasons + 1] = "hrp-pinned" end
    if not travels then reasons[#reasons + 1] = "does-not-travel" end
    if not hasSpeed then reasons[#reasons + 1] = "no-Speed-child" end
    if not hasRange then reasons[#reasons + 1] = "no-Range-child" end
    if not hasDmg then reasons[#reasons + 1] = "no-Damage-child" end

    return "deny", table.concat(reasons, ", ")
end

function Core.learnDump()
    local nClasses = 0
    for _ in pairs(learn.classes) do nClasses = nClasses + 1 end
    if nClasses == 0 then
        return false, "no data captured — run 'hslearn on' in a match first"
    end

    local elapsed = learn.startedAt and (os.clock() - learn.startedAt) or 0
    local lines = {}

    -- Header
    lines[#lines + 1] = "-- ========================================================"
    lines[#lines + 1] = "--  HEATSEEK LEARN MODE — candidate configs"
    lines[#lines + 1] = ("--  Captured: %.0fs"):format(elapsed)
    lines[#lines + 1] = ("--  JobId: %s"):format(learn.jobId or "unknown")
    lines[#lines + 1] = ("--  Date: %s"):format(os.date("%Y-%m-%d %H:%M:%S"))
    lines[#lines + 1] = "--"
    lines[#lines + 1] = "--  MEASURED = directly observed   INFERRED = derived from observations"
    lines[#lines + 1] = "--  Review before registering. This file is NOT auto-loaded."
    lines[#lines + 1] = "-- ========================================================"
    lines[#lines + 1] = ""

    -- Sort classes for deterministic output
    local classNames = {}
    for name in pairs(learn.classes) do classNames[#classNames + 1] = name end
    table.sort(classNames)

    local lowConfidence = {}

    for _, className in ipairs(classNames) do
        local cls = learn.classes[className]
        local bodyNames = {}
        for bn in pairs(cls) do bodyNames[#bodyNames + 1] = bn end
        table.sort(bodyNames)

        -- Classify each body
        local allowBodies = {}
        local denyBodies = {}
        local unsureBodies = {}
        local hasReturn = false
        local flightLines = {}

        for _, bn in ipairs(bodyNames) do
            local s = cls[bn]

            if s.count < 3 then
                lowConfidence[#lowConfidence + 1] = ("[%s] %s — seen %d time(s)")
                    :format(className, bn, s.count)
            end

            local verdict, reason = classifyBody(bn, s)

            -- Build evidence comment
            local ev = {}
            ev[#ev + 1] = ("seen=%d"):format(s.count)
            if s.speedN > 0 then
                ev[#ev + 1] = ("speed=%.0f..%.0f"):format(s.speedMin, s.speedMax)
            end
            if s.rangeN > 0 then
                ev[#ev + 1] = ("range=%.0f..%.0f"):format(s.rangeMin, s.rangeMax)
            end
            if s.dmgN > 0 then
                ev[#ev + 1] = ("dmg=%.0f..%.0f"):format(s.dmgMin, s.dmgMax)
            end
            if s.travelledYes > 0 or s.travelledNo > 0 then
                ev[#ev + 1] = ("travels=%d/%d"):format(
                    s.travelledYes, s.travelledYes + s.travelledNo)
            end
            if s.weldedYes > 0 then ev[#ev + 1] = "WELDS" end
            -- Spelled out separately: "anchored at spawn" disqualifies a body,
            -- "anchored later" is just the game's hit path and is expected.
            if (s.anchoredAtBirthYes or 0) > 0 then
                ev[#ev + 1] = ("ANCHORED-AT-SPAWN=%d"):format(s.anchoredAtBirthYes)
            end
            if (s.anchoredFlipYes or 0) > 0 then
                ev[#ev + 1] = ("anchored-on-hit=%d"):format(s.anchoredFlipYes)
            end
            if s.hrpPinnedYes > 0 then ev[#ev + 1] = "HRP-PINNED" end
            if s.returnedYes > 0 then
                ev[#ev + 1] = ("returns=%d/%d"):format(
                    s.returnedYes, s.returnedYes + s.returnedNo)
                hasReturn = true
            end
            if s.lifetimeN > 0 then
                ev[#ev + 1] = ("life=%.1fs"):format(s.lifetimeSum / s.lifetimeN)
            end
            if s.volleyGapN > 0 then
                ev[#ev + 1] = ("volleyGap=%.2fs"):format(s.volleyGapSum / s.volleyGapN)
            end

            local evStr = table.concat(ev, " ")
            local measTag = "MEASURED"

            if verdict == "allow" then
                allowBodies[#allowBodies + 1] = {
                    name = bn,
                    comment = ("-- %s: %s"):format(measTag, evStr),
                }
            elseif verdict == "unsure" then
                -- NOT into deny. `deny` is a SUBSTRING blocklist, so parking an
                -- under-observed name there can silently kill an unrelated body
                -- that merely contains the string. Undecided means undecided:
                -- report it and let the next capture settle it.
                unsureBodies[#unsureBodies + 1] = {
                    name = bn,
                    comment = ("-- UNDECIDED (%s): %s"):format(reason or "?", evStr),
                }
            else
                denyBodies[#denyBodies + 1] = {
                    name = bn,
                    comment = ("-- %s deny (%s): %s"):format(measTag, reason or "?", evStr),
                }
            end
        end

        -- Build registerClass block
        lines[#lines + 1] = ("-- CLASS: %s (%d body types observed)")
            :format(className, #bodyNames)
        lines[#lines + 1] = ("Core.registerClass(%q, {"):format(className)
        lines[#lines + 1] = ("    aliases  = { %q },"):format(className)
        lines[#lines + 1] = "    accept   = Core.gates.classProvenance,"

        if #allowBodies > 0 then
            local names = {}
            for _, b in ipairs(allowBodies) do names[#names + 1] = string.format("%q", b.name) end
            lines[#lines + 1] = ("    allow    = { %s },"):format(table.concat(names, ", "))
            for _, b in ipairs(allowBodies) do
                lines[#lines + 1] = "        " .. b.comment
            end
        else
            lines[#lines + 1] = "    -- INFERRED: no bodies qualified for allow (all denied)"
            lines[#lines + 1] = "    allow    = {},"
        end

        if #denyBodies > 0 then
            local names = {}
            for _, b in ipairs(denyBodies) do names[#names + 1] = string.format("%q", b.name) end
            lines[#lines + 1] = ("    deny     = { %s },"):format(table.concat(names, ", "))
            for _, b in ipairs(denyBodies) do
                lines[#lines + 1] = "        " .. b.comment
            end
        end

        if #unsureBodies > 0 then
            -- Emitted as commented-out candidates, INSIDE the block where they
            -- would go, so the decision is in front of you at the moment you
            -- review the class rather than buried in a footer.
            lines[#lines + 1] = "    -- UNDECIDED — too few sightings to classify. Capture again, then"
            lines[#lines + 1] = "    -- move each of these into allow or deny by hand. Left out of BOTH"
            lines[#lines + 1] = "    -- on purpose: deny is substring-matched and would over-reach."
            for _, b in ipairs(unsureBodies) do
                lines[#lines + 1] = ("    --   %q  %s"):format(b.name, b.comment)
            end
        end

        if hasReturn then
            lines[#lines + 1] = "    flight   = { stopWhenReturningToOwner = true },  -- MEASURED: return observed"
        end

        lines[#lines + 1] = "})"
        lines[#lines + 1] = ""
    end

    -- Low-confidence section
    if #lowConfidence > 0 then
        lines[#lines + 1] = "-- ========================================================"
        lines[#lines + 1] = "--  LOW CONFIDENCE (seen < 3 times — may be noise)"
        lines[#lines + 1] = "-- ========================================================"
        for _, msg in ipairs(lowConfidence) do
            lines[#lines + 1] = "--  " .. msg
        end
        lines[#lines + 1] = ""
    end

    local body = table.concat(lines, "\n")
    local outFile = "cs_learn_candidates.lua"
    local ok = pcall(writefile, outFile, body)
    if not ok then
        return false, "writefile failed for " .. outFile
    end

    Log.info(("learn dump: %d classes, %d lines -> %s"):format(nClasses, #lines, outFile))
    return true, ("wrote %d classes to %s"):format(nClasses, outFile)
end

-- Clear all captured data.
function Core.learnReset()
    table.clear(learn.classes)
    table.clear(learn.active)
    table.clear(learn.lastSpawn)
    learn.startedAt = nil
    learn.jobId = nil
    Log.info("learn data cleared")
    return true, "learn data cleared"
end

-- Expose for the sweep loop
local function learnSweepHook()
    if learn.enabled then learnSweep() end
end

--------------------------------------------------------------------------
-- 15. PUBLIC API
--------------------------------------------------------------------------

Core.T = T
Core.S = S
Core.Log = Log
Core.char = char
Core.myClass = myClass

function Core.tune(key, value)
    if T[key] == nil then return false, "unknown tunable" end

    -- Type-match the existing value. `hstune lockFovDeg wide` used to store the
    -- string, and every later comparison against it errored or silently
    -- misbehaved somewhere deep in the steer loop.
    if type(T[key]) ~= type(value) then
        return false, ("%s expects a %s"):format(key, type(T[key]))
    end

    local prev = T[key]
    T[key] = value

    -- Re-audit AFTER the write. Tunables constrain each other -- the cone
    -- against the deviation budget, muzzle+ramp against flight time -- and a
    -- value that is fine alone can break a pair. This is the check that was
    -- missing when the FOV/budget margin got squeezed to 0.3 degrees across two
    -- separate retunes, each of which looked reasonable in isolation.
    local found = Core.auditTunables()
    saveCaps()
    if #found > 0 then
        return true, ("%s %s -> %s · %d invariant warning(s), see log")
            :format(key, tostring(prev), tostring(value), #found)
    end
    return true
end

--------------------------------------------------------------------------
-- VISUAL DEBUG — draw what the engine is actually doing
--
-- Exists because describing lock geometry in words does not work. The close-
-- range blind spot (a target 3 studs to the side being 31 deg off at 5 studs
-- and refused `out of cone`) was invisible in the log -- it reads as an
-- ordinary `out of cone` reject, identical to a target genuinely behind you --
-- and was only found because it was noticed in play and described out loud.
--
-- Drawn with LineHandleAdornment rather than a cone mesh: lines are exact,
-- render on top, need no part, and the geometry is computed here rather than
-- depending on how a given adornment orients itself.
--
-- The cone comes out of the CHARACTER along the character's facing, not out of
-- the camera. That is not a drawing choice -- it is what aimOrigin() returns and
-- what the game itself launches along (see the helper survey there). Orbiting
-- the camera with right-click-drag does not move the cone, because it does not
-- move where your bolts go either.
--
-- What you see:
--   WHITE   the aim ray -- where the engine thinks you are pointing
--   BLUE    the cone surface: rings at 25/50/75/100% of the bolt's real reach,
--           joined by rails. The heavy outer ring is the edge of what can be
--           locked at all. OCCLUDED by the world, on purpose -- see visLine.
--   GREEN   the close-lock cylinder (CLOSE_LOCK_STUDS around the aim line)
--   YELLOW  a lockable candidate -- drawn from their feet up
--   GREY    a candidate the cone refuses -- informational, deliberately quiet
--   RED     THE TRACK LINE: a live bolt to the target it has locked. Heaviest
--           line drawn, pure saturated red, always on top. Red means this and
--           nothing else.
--
-- Everything is drawn at the CURRENT class's real lockCap, learned from the last
-- claim, so the picture changes size when you switch class. That is correct and
-- is the point: PHANTOM's 40-stud sawblade and its 50-stud shotgun form draw
-- visibly different cones, which is exactly the difference that read as "the
-- normal E is not heatseeking".
--------------------------------------------------------------------------
local vis = { on = false, folder = nil, conn = nil, pool = {}, used = 0 }

-- `onTop` is the depth cue, and it is the whole reason the overlay used to look
-- like a flat sticker instead of geometry sitting in the world.
--
-- Every line was AlwaysOnTop, so nothing ever occluded anything: a rim segment
-- behind a wall drew exactly as brightly as one in front of your face, and with
-- no occlusion the eye has no depth information at all. Twelve rays leaving one
-- point then read as a 2D starburst no matter how they are coloured.
--
-- So the cone SURFACE now draws occluded (onTop = false) -- walls and floors cut
-- it, which is what makes it read as a solid shape in the world -- while the
-- things you must never lose track of (the aim ray, candidate pips, bolt links)
-- stay on top deliberately. Depth for the shape, visibility for the data.
local function visLine(from, to, color, thickness, onTop)
    local n = vis.used + 1
    vis.used = n
    local a = vis.pool[n]
    if not a then
        a = Instance.new("LineHandleAdornment")
        a.Adornee = workspace.Terrain
        a.ZIndex = 5
        a.Parent = vis.folder
        vis.pool[n] = a
    end
    -- Set every frame, not just on creation: the pool is shared between the
    -- occluded and on-top passes, so a recycled adornment carries the previous
    -- frame's setting otherwise.
    a.AlwaysOnTop = onTop and true or false
    local d = to - from
    local len = d.Magnitude
    if len < 1e-3 then a.Visible = false ; return end
    a.Length = len
    a.Thickness = thickness or 2
    a.Color3 = color
    a.CFrame = CFrame.lookAt(from, to)
    a.Visible = true
end

function Core.setVisualDebug(on)
    on = on and true or false
    if on == vis.on then return vis.on end
    vis.on = on

    if not on then
        if vis.conn then pcall(function() vis.conn:Disconnect() end) ; vis.conn = nil end
        if vis.folder then pcall(function() vis.folder:Destroy() end) ; vis.folder = nil end
        vis.pool, vis.used = {}, 0
        return false
    end

    local visParent = (gethui and gethui()) or game:GetService("CoreGui")

    -- Destroy any PREVIOUS overlay before drawing a new one.
    --
    -- The adornments live in CoreGui, outside our own instance tree, so nothing
    -- collects them for us -- Core.destroy is the only thing that ever removes
    -- them. If a teardown is missed or races a hot reload, the old folder simply
    -- stays there, frozen at whatever positions it last drew, while the new
    -- engine draws a second one that tracks you correctly. Reported exactly that
    -- way: "the cone will be left in the map while the same one follows me".
    --
    -- Persisting coneVis is what made this reachable: the overlay is now
    -- recreated on every single hot reload rather than only when you type the
    -- command, so any teardown gap gets hit constantly instead of never.
    --
    -- Swept by NAME rather than by our own handle, deliberately. A handle only
    -- knows about folders THIS module made, and the orphan by definition belongs
    -- to a module instance that is already gone. Same lesson as
    -- purgeRetiredModules: deleting the loader does not stop what is already
    -- running.
    for _, ch in ipairs(visParent:GetChildren()) do
        if ch.Name == "CsVisualDebug" then
            pcall(function() ch:Destroy() end)
        end
    end
    -- The pool indexes the old folder's adornments; keeping it would hand out
    -- destroyed instances whose .Visible writes go nowhere, and the overlay
    -- would silently draw fewer and fewer lines each reload.
    vis.pool, vis.used = {}, 0

    vis.folder = Instance.new("Folder")
    vis.folder.Name = "CsVisualDebug"
    vis.folder.Parent = visParent

    local WHITE  = Color3.fromRGB(255, 255, 255)
    local BLUE   = Color3.fromRGB(0, 170, 255)
    local GREEN  = Color3.fromRGB(0, 255, 140)
    local YELLOW = Color3.fromRGB(255, 220, 0)
    -- Refused candidates were RED. Red now belongs to the TRACK line and nothing
    -- else, so "red" answers exactly one question -- which bolt is chasing whom.
    -- Refused is grey because it is the ignore-me category: it needs to be
    -- readable, not attention-grabbing, and it was competing with the one line
    -- that actually matters.
    local GREY   = Color3.fromRGB(130, 130, 140)
    -- Pure saturated red, deliberately not the old (255,60,60) wash. This is the
    -- single most important thing the overlay draws.
    local TRACK  = Color3.fromRGB(255, 0, 0)

    vis.conn = RunService.RenderStepped:Connect(function()
        if not (vis.on and vis.folder) then return end
        -- Hide-then-reuse rather than rebuild: creating and destroying ~30
        -- instances every frame is exactly the kind of per-frame allocation the
        -- logger lag fix existed to remove.
        for i = 1, vis.used do
            local a = vis.pool[i]
            if a then a.Visible = false end
        end
        vis.used = 0

        local ok = pcall(function()
            local origin, look = aimOrigin(nil)
            if not origin or not look then return end
            look = look.Unit

            -- Same clamp pickTarget applies, so what is drawn is what is used.
            local ceiling = T.legitMaxTotalDeviationDeg - LOCK_DEV_MARGIN
            -- The cone of the bolt you last threw, including a per-body override
            -- (ARCHER's click is much stricter than its Q). Falls back to the
            -- global tunable when the class has no opinion.
            -- Scaled by the SAME helper pickTarget uses, so the drawn cone is
            -- the cone that actually locks -- including while the boost key is
            -- held. The overlay redraws every frame, so holding the key widens
            -- the picture live. A cone drawn wider than the one being scanned
            -- would be worse than no overlay: it would explain a refusal that
            -- never happened.
            local fov = math.min((S.lastBoltFov or T.lockFovDeg) * Core.fovScaleNow(),
                ceiling)
            -- The REAL reach of the class you are holding, not the fallback.
            local len = lockCap(S.lastBoltRange)

            local upRef = math.abs(look.Y) > 0.99
                and Vector3.new(1, 0, 0) or Vector3.new(0, 1, 0)
            local right = look:Cross(upRef).Unit
            local upv = right:Cross(look).Unit

            -- Aim ray stays ON TOP and heavy. It is the one line you must be
            -- able to find instantly, including through a wall.
            visLine(origin, origin + look * len, WHITE, 5, true)

            -- The cone as a WIREFRAME SURFACE, not a starburst.
            --
            -- One rim at max range gave the shape no depth: a single distant
            -- ring plus spokes back to a point is the same picture whether the
            -- cone is 40 studs long or 400, so "how far does this actually
            -- reach" was unanswerable from the drawing. That was the complaint.
            --
            -- Now: rings at 25 / 50 / 75 / 100% of the real cap, joined by
            -- longitudinal rails. Rings give distance, rails give the surface,
            -- and because both draw OCCLUDED the world cuts them -- a ring
            -- crossing a wall is the strongest depth cue available and costs
            -- nothing to compute.
            local rad = math.rad(fov)
            local SEGMENTS = 12
            local RINGS = { 0.25, 0.5, 0.75, 1.0 }

            -- Radial unit vectors, computed once and shared by every ring
            -- instead of recomputing sin/cos per ring per segment.
            local radial = {}
            for i = 1, SEGMENTS do
                local th = ((i - 1) / SEGMENTS) * math.pi * 2
                radial[i] = right * math.cos(th) + upv * math.sin(th)
            end

            local prevRing = nil
            for r, frac in ipairs(RINGS) do
                local rlen = len * frac
                local ring = {}
                for i = 1, SEGMENTS do
                    local dir = (look * math.cos(rad) + radial[i] * math.sin(rad)).Unit
                    ring[i] = origin + dir * rlen
                end
                -- The ring itself. The outermost one is heavier because it is
                -- the actual edge of the engine's reach -- past it, nothing is
                -- lockable at all.
                local edge = (frac == 1.0)
                for i = 1, SEGMENTS do
                    visLine(ring[i], ring[i % SEGMENTS + 1], BLUE, edge and 4 or 2, false)
                end
                -- Longitudinal rails, every third point. Connecting ring to ring
                -- rather than drawing rays from the origin is what turns this
                -- from a starburst into a surface you can read the length of.
                local from = prevRing or nil
                for i = 1, SEGMENTS, 3 do
                    visLine(from and from[i] or origin, ring[i], BLUE, 1, false)
                end
                prevRing = ring
            end

            -- Close-lock cylinder: four rails parallel to the aim line at
            -- CLOSE_LOCK_STUDS. Anything inside these is lockable no matter how
            -- wide its ANGLE is -- which is the whole point of the rule.
            -- Occluded like the cone, and capped with a ring so its END is
            -- visible too rather than fading into the distance.
            local cylLen = math.min(len, 60)
            -- The radius actually in force, which a cast window may have widened
            -- (ROCKETEER Blast Off). Shown at real size so the change is visible.
            local closeR = Core.activeCloseLock() or CLOSE_LOCK_STUDS
            local capRing = {}
            for i = 1, SEGMENTS do
                local off = radial[i] * closeR
                capRing[i] = origin + off + look * cylLen
                if (i - 1) % 3 == 0 then
                    visLine(origin + off, capRing[i], GREEN, 2, false)
                end
            end
            for i = 1, SEGMENTS do
                visLine(capRing[i], capRing[i % SEGMENTS + 1], GREEN, 2, false)
            end

            -- Candidates, coloured by whether the cone would take them.
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= lp and p.Character then
                    local hrp = p.Character:FindFirstChild("HumanoidRootPart")
                    if hrp then
                        local d = hrp.Position - origin
                        local dist = d.Magnitude
                        -- Judged against the CURRENT bolt's cap. Using the
                        -- fallback here painted people yellow that GAMBLER's
                        -- 50-stud chip could never have reached.
                        if dist > 0.5 and dist <= len then
                            local ang = math.deg(math.acos(
                                math.clamp(look:Dot(d.Unit), -1, 1)))
                            local lateral = math.sin(math.rad(ang)) * dist
                            local inCone = ang <= fov
                                -- Same ceiling scanCone applies, or the
                                -- overlay paints an overhead target yellow that
                                -- the lock will refuse.
                                or (lateral <= closeR and ang <= ceiling)
                            -- ON TOP: whether someone is lockable is the answer
                            -- you are looking for, and it must not be hidden by
                            -- the wall they are standing behind.
                            --
                            -- Drawn from the GROUND up through the target rather
                            -- than upward from the root. A pip floating at chest
                            -- height has no contact with the world and reads as
                            -- another screen-space mark; one that starts at their
                            -- feet is visibly attached to where they stand.
                            local foot = hrp.Position - Vector3.new(0, 3, 0)
                            visLine(foot, foot + Vector3.new(0, 9, 0),
                                inCone and YELLOW or GREY, inCone and 5 or 2, true)
                        end
                    end
                end
            end

            -- Live bolts and what each has locked.
            for proj, rec in pairs(S.registry) do
                if typeof(proj) == "Instance" and proj.Parent and rec.target then
                    local th = rec.target:FindFirstChild("HumanoidRootPart")
                    if th then
                        -- The TRACK line: this bolt has locked that target.
                        -- Heaviest line on screen and always on top, because it
                        -- is the one thing you are actually watching for -- at
                        -- thickness 3 in orange it was getting lost against the
                        -- cone rim and the candidate pips.
                        visLine(proj.Position, th.Position, TRACK, 8, true)
                    end
                end
            end
        end)
        if not ok then Core.setVisualDebug(false) end
    end)

    return true
end

function Core.visualDebugOn() return vis.on end

-- ==========================================================
-- CONE WIDTH: the universal scale and the hold-to-widen key.
--
-- One helper, called by BOTH the lock scan (pickTarget) and the on-screen cone
-- (the visual overlay). Anything that wants to know how wide the cone is asks
-- here. The two used to read T.lockFovDeg independently, and the moment a scale
-- existed that would have meant a drawn cone that disagreed with the scanned
-- one -- an overlay that lies is worse than none, because it explains refusals
-- that never happened.
--
-- WHY THE BOOST CANNOT SIMPLY BE +50%: pickTarget clamps every cone to
-- `legitMaxTotalDeviationDeg - LOCK_DEV_MARGIN` (55 - 6 = 49 deg), because a
-- lock the steering budget cannot turn to is a bolt that curves to its cap,
-- freezes and flies past -- a miss manufactured at lock time. With the scale at
-- 0.75 the resting cone is 36.75 deg and the boost asks for 55.1, so what you
-- actually get while holding is 49 -- the widest cone the bolt can reach, and
-- about +33%. Raising the ceiling means raising the deviation budget, which is
-- the legitness knob CS_CONSTRAINTS protects. Not done here, and not silently.
--
-- MOUSE SIDE BUTTONS ARE NOT AVAILABLE, and this was checked rather than
-- assumed. Roblox's Enum.UserInputType has MouseButton1/2/3 and nothing for
-- XBUTTON1/2, and the executor's Input library is output-only (keypress,
-- mouse1click, isrbxactive -- it simulates input, it cannot read key state).
-- So there is no path to a side button from in here. LeftAlt is the bind. To
-- get the side-button feel, remap the side button to LeftAlt in the mouse's own
-- driver software -- the game then sees a real LeftAlt and this works unchanged.
-- ==========================================================
Core.fovBoostHeld = false    -- LeftAlt, momentary
Core.fovBoostSticky = false  -- MAIN panel toggle, persistent

-- OVERRIDE MODE. True while the key is held OR the panel toggle is on.
--
-- Read this before changing anything that calls it. While it is true the engine
-- deliberately stops behaving legitimately: the cone opens past the deviation
-- ceiling and every legitness gate in the flight loop is suspended. That is the
-- point of the mode and it is the user's explicit call, but it inverts the
-- standing rule in CS_CONSTRAINTS ("legitness beats hit rate"), so it must stay
-- something you actively hold or actively switch on -- never a default, never
-- persisted ON across an inject.
function Core.overrideActive()
    return Core.fovBoostHeld or Core.fovBoostSticky
end

-- The single legitness gate for the FLIGHT path. Every behavioural check that
-- used to read T.legitMode directly now asks here, so the mode cannot be half
-- applied -- which is exactly how a bolt ends up with no muzzle delay but a
-- live deviation freeze, i.e. snapping instantly and then giving up.
--
-- The LEGIT SCORING deliberately still reads T.legitMode raw. The score exists
-- to measure how the shot LOOKED, and an override flight looks bad -- it should
-- score bad and say so in the log. Grading it against the relaxed rules would
-- produce a metric that cannot tell "flawless" from "cheating openly", which is
-- the same class of blind metric as the legit=100 unsteered flights.
function Core.legitNow()
    return T.legitMode and not Core.overrideActive()
end

function Core.fovScaleNow()
    local s = T.lockFovScale or 1
    if Core.overrideActive() then s = s * (T.lockFovBoostMult or 1) end
    return s
end

-- Reported both ways round: the cone asked for and the cone actually in force
-- after the clamp. A boost that is entirely eaten by the ceiling would otherwise
-- log as if it had worked -- the speed-toggle failure, where a click that landed
-- and a click that did not produced identical evidence.
local function logFovBoost(held)
    local raw = T.lockFovDeg * Core.fovScaleNow()
    local ceiling = T.legitMaxTotalDeviationDeg - LOCK_DEV_MARGIN
    -- Override lifts the ceiling in pickTarget, so report the cone that is
    -- really scanned, not the one the clamp used to impose.
    local eff = Core.overrideActive() and raw or math.min(raw, ceiling)
    Log.info(("OVERRIDE %s — fov %.1f deg%s (base %.1f) — legit gates %s")
        :format(held and "ON" or "off", eff,
            raw > ceiling + 0.05 and (" [ceiling %.0f suspended]"):format(ceiling) or "",
            T.lockFovDeg * (T.lockFovScale or 1),
            held and "SUSPENDED (no muzzle delay, no deviation budget, no "
                .. "terminal freeze, full turn rate)" or "restored"))
end

-- POLLED, not event-driven, and the first version got this wrong.
--
-- InputBegan/InputEnded with a `gameProcessedEvent` guard registered cleanly,
-- logged nothing, and did nothing when the key was pressed: LeftAlt is claimed
-- by the client before it reaches a script connection, so the handler was never
-- called and the only evidence was silence. That is the same failure as the
-- pill clicks -- a path that produces identical evidence whether it fired or
-- not.
--
-- IsKeyDown reads the state directly and cannot be swallowed by whoever
-- consumed the event, it needs no release event (so a key-up eaten by a chat
-- box cannot strand the cone wide), and it reports false on its own when the
-- window loses focus. One boolean read per frame.
--
-- The event handlers were DELETED rather than kept alongside this: two
-- mechanisms owning one flag is the fallback shape CS_CONSTRAINTS §5b forbids,
-- and it would leave the dead path looking authoritative in the source.
task.spawn(function()
    local UIS = game:GetService("UserInputService")
    local BOOST_KEY = Enum.KeyCode.LeftAlt
    -- Armed line, same reason `hot reload armed` exists: without it, "the key
    -- does nothing" and "the watcher never started" read identically in the log.
    Log.info(("cone boost armed — hold LeftAlt for %.1f deg (resting %.1f deg)")
        :format(math.min(T.lockFovDeg * (T.lockFovScale or 1) * (T.lockFovBoostMult or 1),
                    T.legitMaxTotalDeviationDeg - LOCK_DEV_MARGIN),
            T.lockFovDeg * (T.lockFovScale or 1)))
    while S.alive do
        RunService.Heartbeat:Wait()
        local held = false
        pcall(function() held = UIS:IsKeyDown(BOOST_KEY) end)
        if held ~= Core.fovBoostHeld then
            Core.fovBoostHeld = held
            logFovBoost(held)
        end
    end
end)

function Core.destroy()
    if not S.alive then return end
    S.alive = false

    -- Adornments live in CoreGui, outside our own instance tree, so nothing
    -- else would ever collect them. An unloaded engine leaving a cone drawn on
    -- screen forever is the kind of thing that gets noticed at the worst moment.
    pcall(Core.setVisualDebug, false)

    -- Cast windows are keyed by Player instances. MAINTENANCE.md §7: when adding
    -- state to the engine, ask whether Core.destroy clears it -- a second inject
    -- inheriting a stale open window would throttle rockets for no visible
    -- reason.
    table.clear(castWin.byOwner)
    table.clear(castWin.firedAt)

    -- Tear down learn mode first (finalizes active bodies)
    if learn.enabled then
        pcall(Core.learnDisable)
    end
    table.clear(learn.active)
    table.clear(learn.lastSpawn)
    if learnFolderConn then
        pcall(function() learnFolderConn:Disconnect() end)
        learnFolderConn = nil
    end
    learnWatchedFolder = nil

    -- Ally echoes are bodies WE spawned. Leaving them behind on unload leaves
    -- live projectiles in the world with no steerer and no cleanup path.
    ally.echoEnabled = false
    for echo in pairs(ally.active) do
        pcall(function() if echo.Parent then echo:Destroy() end end)
    end
    table.clear(ally.active)
    table.clear(ally.processed)
    ally.activeN = 0

    for proj in pairs(S.registry) do
        Core.unregister(proj, "unload")
    end
    for _, c in ipairs(S.conns) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(S.conns)
    table.clear(S.classes)
    table.clear(S.classOrder)
    table.clear(S.aliasMap)
    table.clear(S.ledger)
    table.clear(pendingConfirm)

    -- Drop the folder watch state too. Without this a re-inject that reuses the
    -- same ClientProjectiles folder would see `folder == watchedFolder` in
    -- attachTo and return early, leaving the new core with no watcher at all.
    watchedFolder = nil
    folderConn = nil

    S.stickyTarget = nil
    S.stickyUntil = 0

    if G[GKEY] == Core then G[GKEY] = nil end
    Log.info("core unloaded")
end

-- One Heartbeat connection for all per-frame engine work. `dt` drives the frame
-- rate estimate that picks the perf tier, so this must stay the engine's only
-- unconditional per-frame connection -- a second one would double-count frames.
conn(RunService.Heartbeat, function(dt)
    local t0 = perfBegin()
    sweepRegistry()
    learnSweepHook()
    perfEnd("sweep", t0)
    -- Last: it consumes engineMsThisFrame, which the spans above contribute to.
    perfFrame(dt)
end)

G[GKEY] = Core

-- Stamped into the payload by tools/build_admin.sh and logged on every boot.
-- Without it there is no way to tell, from inside the game or from the log,
-- whether the running copy is the one just built -- and twice now a log has
-- been analysed in detail before anyone noticed it came from a stale inject.
Core.build = G.__CS_BUILD or "UNSTAMPED — not built by tools/build_admin.sh"
Log.session("cs_core loaded — build " .. tostring(Core.build))
loadCaps()
watchDamageIndicator()
Log.info(Core.capsSummary())
watch()

return Core
]==]
ENGINE_PAYLOAD["cs_classes.lua"] = [==[
-- ==========================================================
--  CRITICAL STRIKE — cs_classes.lua
--  Per-class configuration for cs_core. Data, not code.
--
--  Adding a class means adding one table here. It does not mean copying a
--  module. If you find yourself writing logic in this file, it belongs in
--  cs_core.lua instead -- that is the whole point of the split.
--
--  Gate choice:
--    Core.gates.classProvenance  — accepts on the projectile's SourceObj
--        resolving to one of `aliases`, or on us playing the class when
--        SourceObj is unresolvable. Use this for classes that are NOT in the
--        dump. Only 13 classes are streamed (keyword_index.txt); TRICKSTER and
--        ELEMENTALIST are absent, and `fireability2` -- the working elem gate --
--        appears in 0 dump files. Absence of a template name is normal.
--
--    Core.gates.templates        — additionally requires one of `templates` to
--        appear in the part name OR the SourceObj name. Use only when the
--        template names are actually known.
--
--  ALLY SUPPORT IS AUTOMATIC. Registering a class here gives it BOTH self
--  heatseek and ally echo. There is no `allyEcho = true` to remember, and
--  `allyAllow` / `allyDeny` fall through to `allow` / `deny` -- so a class needs
--  no extra configuration at all to work for an ally.
--
--  Seven classes used to carry `allyEcho = true` and nine did not, which read as
--  "these seven support allies". They did not mean that: the engine only checks
--  `allyEcho == false`, so nil passed and all sixteen were already ally-capable.
--  The markers were decorative and actively misleading -- exactly the "the UI
--  says this class has heatseek" mismatch. They are gone.
--
--  `allyEcho = false` is now the only meaningful value: an explicit opt-out for
--  a class whose bodies must never be echoed. Nothing sets it today.
--
--  Loaded by cs_admin.lua after cs_core.lua.
-- ==========================================================

local Core = getgenv().__CS_CORE
if not Core then
    warn("[Classes] cs_core not loaded — cannot register classes")
    return
end

--------------------------------------------------------------------------
-- SNIPER and MUSKETEER — two classes, not one.
--
-- They were merged here under one entry with aliases { SNIPER, MUSKETEER } on
-- the claim that CurrentClass reads SNIPER while the folder reads MUSKETEER.
-- That was never verified and is wrong: they are separate kits. SNIPER is
-- Sniper Shot / Spring Pad / Cripple Bomb / Headhunter (0566.lua:2191);
-- MUSKETEER is Flintlock Shot / Weapon Arsenal / Bayonet Charge / Firing Squad
-- (0566.lua:1529). MUSKETEER has an RS.Classes folder (rs_combat_tree.txt:326);
-- SNIPER has none anywhere in the dump.
--
-- The merged entry also had NO `allow` list, which is why cs_core.log shows it
-- claiming `musketeerrifleremove` (speed=300 range=500). That body is a
-- discarded-rifle prop: its handler reads Speed/Origin, calls
-- DebrisGobbler:AddItem(Value, 1) and destroys itself -- no Touched, no damage,
-- no BodyVelocity (0478.lua). The Speed/Range children are template defaults
-- the handler never uses.
--------------------------------------------------------------------------
Core.registerClass("SNIPER", {
    aliases = { "SNIPER" },     -- 0566.lua:2191
    accept  = Core.gates.classProvenance,
    -- Unstreamed, so no body names are confirmed. `attack` is the LMB name in
    -- every streamed class checked (MUSKETEER 0463, RECON 0560, GAMBLER 0416,
    -- FROST, CHRONO), so it is the safe provisional allow: if it is wrong the
    -- class simply does nothing and the reject histogram says so, whereas an
    -- empty allow steers every sub-body of the cast at once.
    allow   = {
        "attack",    -- ATK Sniper Shot (0566.lua:2196) — CONFIRMED live 16:52:18
        -- The airborne Sniper Shot. Spring Pad "enables your next Sniper Shot to
        -- be aimed at your cursor while airborne" (0566.lua:2201), and that shot
        -- is a SEPARATE body: the arm-time audit listed `attackair` as a full
        -- BOLT (Speed+Range+Damage) in the live folder at 16:52:18. Without it,
        -- heatseek silently switched off for every post-Spring-Pad shot -- which
        -- is a real share of SNIPER's shots and reads as "inconsistent".
        "attackair",
        -- F Headhunter (0566.lua:2211). Critical maps to "f" (0003.lua:38), and
        -- `critical` is the CRT body name in every streamed class checked
        -- (MUSKETEER 0473.lua:24, FIGHTER 0387.lua, GAMBLER 0417.lua). UNVERIFIED
        -- for SNIPER because the class is unstreamed -- if the name is wrong the
        -- reject histogram says `not SNIPER bolt (X)` and X is the real name.
        --
        -- Headhunter is described as TERRAIN-PIERCING. The engine still enforces
        -- mid-flight LOS (T.requireLos), so a Headhunter steered at a target
        -- behind cover will end `lost LOS` and fly on unguided. Lock-time already
        -- falls back to a no-LOS candidate (scanCone bestNoLos), so it will still
        -- pick the target; it just stops correcting when the wall intervenes.
        -- Not "fixed" with a per-class ignoreLos flag on purpose: that flag would
        -- apply to `attack` as well, which is NOT terrain-piercing, and a bolt
        -- curving toward someone through a wall is the most visible tell there is.
        --
        -- MEASURED, not guessed. The first build shipped `critical` on the naming
        -- convention and cs_core.log said, on one F cast at 16:38:01:
        --     reject: not SNIPER bolt (criticalgrounded)
        --     reject: not SNIPER bolt (criticaleff1)
        -- Both cleared baseShotReject, so both carry Speed + Range + Damage.
        -- `criticaleff1` is the VFX -- `eff<n>` is the suffix every streamed class
        -- uses for one (attackeff1, ability2eff0). `criticalgrounded` is the shot:
        -- Headhunter is the stand-still ability, so "grounded" is the stance it
        -- fires from. Plain `critical` has never appeared for SNIPER; it is kept
        -- in case a second cast variant emits it, and costs nothing if it does not.
        "critical",
        "criticalgrounded",
    },
    deny    = { "visual", "sheathe", "eff", "bomb", "pad",  -- "eff" covers criticaleff1
                "ability1",  -- Q Spring Pad — a placed pad, not a bolt (0566.lua:2201)
                "ability2",  -- E Cripple Bomb — deployed then recast (0566.lua:2206)
                "ability3",  -- R slot — kit has no AB3; belt-and-braces
                "spring", "cripple" },
})

--------------------------------------------------------------------------
-- MUSKETEER
--
-- `critical` pierces until HitCap is exhausted (0473.lua:89), so bodies we
-- spawn force HitCap = 1 rather than letting one bolt chain through a crowd.
-- `musketeerability1` (the placed rifle from Weapon Arsenal) is a real body but
-- is also an interactive pickup -- left out of allow until steering one is
-- shown to be harmless.
--------------------------------------------------------------------------
Core.registerClass("MUSKETEER", {
    aliases = { "MUSKETEER" },  -- rs_combat_tree.txt:326, 0566.lua:1529
    accept  = Core.gates.classProvenance,
    allow   = { "attack", "critical", "ability2" },  -- 0463.lua:24, 0473.lua:24

    -- NO blanket HitCap here any more.
    --
    -- It used to be `options = { HitCap = 1 }`, applied to every body we spawn
    -- for this class. That was right for an ordinary bolt and wrong for the one
    -- ability it matters most on: Firing Squad (F / the Critical slot) is
    -- DESIGNED to pierce until HitCap is spent (0473.lua:89). Forcing 1 turned a
    -- multi-hit ultimate into a single hit -- reported live as "musket's F is
    -- not doing enough damage or not hitting enough".
    --
    -- The ally echo forge now inherits the source bolt's own HitCap when it has
    -- one and falls back to 1 only when it does not, so a pierce stays a pierce
    -- and a single-target bolt still cannot chain through a crowd.
    deny    = { "musketeerrifleremove", "musketeerrifleremove2", "musketeercritical",
                "musketrefresh", "attacktoss", "attacksword", "attackvisual",
                "altab", "rifleget", "visual", "sheathe", "eff" },
})

--------------------------------------------------------------------------
-- SWORDMANCER
--
-- Unstreamed (not in rs_combat_tree.txt or keyword_index.txt).
-- Kit (0566.lua:2348): ATK=Steel Notes (thrown swords that RETURN after 3-7s),
-- AB1=Swords Dance (dash-melee), AB2=Blade Waltz (TELEPORT to planted blades),
-- CRT=Steel Crescendo (AoE that spawns auto-targeting swords).
--
-- ATK body returns to owner every cast -- boomerang guard must be on.
-- AB2 body is a teleport anchor: steering it would move where the player blinks,
-- the Magic Baton problem in a different costume. Denied by substring.
-- CRT spawns self-targeting swords (auto-aim already built-in); steering them is
-- redundant and potentially dangerous if they are AoE-spawned in bulk. Denied.
-- `allow = { "attack" }` is UNVERIFIED -- class is unstreamed. Slot: ATK.
--------------------------------------------------------------------------
Core.registerClass("SWORDMANCER", {
    aliases = { "SWORDMANCER" },                    -- 0566.lua:2349
    accept  = Core.gates.classProvenance,
    -- UNVERIFIED: `attack` follows the convention of every streamed class.
    -- Steel Notes is the only bolt worth steering; AB1/CRT are melee or auto-aim.
    allow   = { "attack" },                         -- UNVERIFIED (class unstreamed)
    flight  = { stopWhenReturningToOwner = true },  -- 0566.lua:2354 -- swords return
    deny    = { "waltz", "teleport", "crescendo", "aoe",
                "slash", "sheathe", "visual", "eff" },
})

--------------------------------------------------------------------------
-- CHRONO
--------------------------------------------------------------------------
-- The RS.Classes folder is named CHRONO, not CHRONOS -- confirmed live, 294
-- occurrences of `srcClass=CHRONO` in cs_chronos_hs.log. Registering only
-- "CHRONOS" meant every chrono shot was rejected as `class CHRONO` and the
-- class could never heatseek at all. Both spellings are aliased now.
-- `allow` is the LMB bolt, and only that. One chrono cast emits attack,
-- AttackSpirit, critical, CritLmb1/2, CritShatter, TrailStart/Stop and more --
-- several of which carry Speed + Range + Damage and so pass the generic gate.
-- Steering all of them at once is what produced "duplicate projectiles doing
-- really weird stuff". The retired module allowed exactly {attack}; this
-- restores that.
-- The known dangerous sub-bodies are explicitly denied as belt-and-braces.
Core.registerClass("CHRONO", {
    aliases = { "CHRONO", "CHRONOS" },
    accept  = Core.gates.classProvenance,
    allow   = { "attack" },                         -- ATK only; CRT/AB bolts not confirmed safe
    deny    = { "spirit", "critical", "CritLmb", "CritShatter",
                "TrailStart", "TrailStop", "visual", "sheathe" },
})

--------------------------------------------------------------------------
-- ELEMENTALIST
--
-- Not streamed in the dump. Smolder fires five bolts per cast, which is what
-- the core's sticky lock exists for: without it the volley scattered across
-- five different targets. The template gate matches the part name OR the
-- SourceObj name -- checking SourceObj alone rejected every shot.
--------------------------------------------------------------------------
-- ELEMENTALIST was the LAST class with no `allow` list, and it was the worst
-- possible one to leave open: the kit has four elemental stances (fire / water
-- / wind / default), so one cast emits a whole family of bodies that all share
-- a SourceObj. The `templates` gate matches the part name OR the SourceObj
-- name, and since every sibling body resolves to the same SourceObj, matching
-- "fireability2" there let EVERY sibling through. `deny` was only
-- { visual, sheathe }, which catches none of them.
--
-- Measured in cs_core.log: 492 claims across TWENTY distinct body names,
-- including 126 x `fireswordeff`, 71 x `fireattackeff2`, 37 x `fireattackeff1`
-- and 21 x `fireability1eff` -- pure VFX, steered as if they were bolts, 14 of
-- them inside a single second. 84 flights ended "welded", meaning we claimed
-- bodies attached to a character and only the flight-time weld guard stopped
-- them. That is the duplicate-projectile report, exactly.
--
-- The allowlist below is MEASURED, not guessed: every name is one this engine
-- actually observed claiming, minus the `eff` VFX family. The `templates` gate
-- is kept -- it is what makes the class resolve at all when SourceObj is
-- unstreamed -- but `allow` is now the real filter, as it is for every other
-- class.
--
-- Smolder still fires five bolts per cast; that is what the sticky lock is for.
-- Five bolts from one cast is not a duplicate. Twenty body types is.
Core.registerClass("ELEMENTALIST", {
    aliases   = { "ELEMENTALIST" },
    accept    = Core.gates.templates,
    templates = { "fireability2", "smolder" },

    -- Real travelling bodies, per stance. MEASURED -- and as of 2026-07-31 the
    -- source is the arm-time folder audit, not inference from claim lines:
    --
    --   ELEMENTALIST bodies: 37 bolt(s) [attack, defaultability1cancel,
    --   defaultability2*, defaultcritical, defaulteff, earthability1,
    --   earthability1-2, earthability2, earthattack, earthcritical, eartheff,
    --   fireability1eff, fireability2*, fireattack1*, fireattack2*,
    --   firecritical*, fireeff, fireswordeff, head, holoremove, limb,
    --   thunderability2, thunderattack, thundercritical, thundereff, torso,
    --   waterability1*, waterability1deconate, waterability2*, waterattack*,
    --   watercritical, watereff, windability1, windability2*, windattack*,
    --   windcritical, windeff] — 10 in allow (* = allowed)
    --
    -- ==================================================================
    -- SLOT EXCLUSIONS -- USER INSTRUCTION 2026-07-31. Do not "restore" these.
    --
    -- Removed on explicit request, each for a different reason:
    --   fireattack1 / fireattack2  -- FIRE M1 must not heatseek.
    --   waterability1              -- WATER Q, the double puddle.
    --   windattack                 -- WIND M1 must not heatseek.
    -- Kept on explicit request:
    --   waterattack                -- WATER M1 stays.
    --
    -- These were the class's three most active bodies in the log (fireattack1
    -- x6, fireattack2 x3 were the top claims), so the class will get visibly
    -- quieter. That is the intended result, not a regression.
    --
    -- Each is ALSO added to `deny` below. Removing from allow alone is enough
    -- today, but deny is the belt-and-braces that survives someone re-adding a
    -- name from a stale note -- and the boot audit reports allow/deny
    -- contradictions, so a future re-add fails loudly instead of silently.
    -- ==================================================================
    --
    -- `defaultability1` was DELETED as dead, not as policy: the folder holds
    -- `defaultability1cancel` and no plain `defaultability1`, which is exactly
    -- why 11 allow entries only ever produced "10 in allow". CS_CONSTRAINTS 5b.
    --
    -- NOT COVERED, and deliberately left that way: the EARTH and THUNDER stances
    -- are real -- earthattack, earthability1, earthability1-2, earthability2,
    -- earthcritical, thunderattack, thunderability2, thundercritical -- and no
    -- allow entry touches any of them, so those two stances do not heatseek at
    -- all. That is not an oversight to fix in passing; adding eight bodies to a
    -- class this volatile is its own change with its own instruction.
    allow     = {
        -- FIRE: E and F only. M1 removed on instruction.
        "fireability2", "firecritical",
        -- WATER: M1 kept on instruction, E kept. Q removed on instruction.
        "waterattack", "waterability2",
        -- WIND: E only. M1 removed on instruction.
        "windability2",
        -- DEFAULT (no stance): E only.
        "defaultability2",
    },

    -- `eff` is the VFX suffix across every stance (fireswordeff, fireattackeff1,
    -- fireattackeff2, fireability1eff, fireeff, watereff, windeff, defaulteff,
    -- defaultability1eff2). Belt-and-braces behind the allowlist.
    deny      = {
        "eff", "sword", "visual", "sheathe",

        -- USER-INSTRUCTED EXCLUSIONS 2026-07-31. Substring matches, chosen so
        -- that each one kills exactly its own bodies and nothing that is still
        -- allowed. Verified against the folder audit above:
        --
        --   "fireattack"    -> fireattack1, fireattack2.
        --                      Does NOT touch fireability2 or firecritical.
        --   "windattack"    -> windattack.
        --                      Does NOT touch windability2.
        --   "waterability1" -> waterability1 AND waterability1deconate, the
        --                      puddle's detonation body, which is the same Q and
        --                      would otherwise be a live candidate the moment
        --                      anyone widened the allow list.
        --                      Does NOT touch waterability2 (ends in 2).
        --
        -- CRITICALLY: none of these may be shortened to "attack" or "ability1".
        -- deny is substring-matched and runs alongside allow, so a bare "attack"
        -- would silently kill `waterattack` -- the M1 explicitly kept. That is
        -- the trap "bomb" set for GHOST's `ability2bomb`, and the boot audit
        -- warns about it precisely because it fails with no log line.
        "fireattack",
        "windattack",
        "waterability1",
    },
})

--------------------------------------------------------------------------
-- TRICKSTER
--
-- Not streamed in the dump, so this gates on class provenance only.
-- Kit (0566.lua:2476): Card Trick (7 dmg, boomerangs back), Knives Out (10,
-- doubled vs bleeding), Bloodlash (melee spin), Vanishing Act (dash+stealth),
-- Magic Baton (SWAPS YOUR POSITION with the victim), Sleight Of Hand.
--
-- Magic Baton is denied outright: steering it would teleport the player into
-- whoever the lock picked, which is never what was intended.
--------------------------------------------------------------------------
Core.registerClass("TRICKSTER", {
    aliases = { "TRICKSTER" },
    accept  = Core.gates.classProvenance,
    -- UNVERIFIED: body names follow convention; class is unstreamed.
    --
    -- The ATK slot holds THREE moves -- Card Trick, Knives Out, Bloodlash --
    -- so `attack` covers the straight bolts. AB1 is Vanishing Act (dash +
    -- stealth, no bolt). CRT is Sleight Of Hand, body name unknown.
    --
    -- `ability2` is deliberately NOT allowed, and this is the whole point:
    -- AB2 is MAGIC BATON, which SWAPS YOUR POSITION with whoever it hits
    -- (0566.lua, TRICKSTER.AB2). E maps to Ability2 (0003.lua:37), so "make
    -- trickster's E track" means "teleport me into whichever target the lock
    -- picks". It is denied on purpose, not by omission.
    --
    -- It WAS briefly in `allow`, added on the naming convention with a comment
    -- claiming AB2 was Knives Out. It is not -- Knives Out is one of the three
    -- ATK variants. cs_core.log caught it: 16 `claim ability2 [TRICKSTER]`
    -- lines. Those flights only failed to teleport anyone because a separate
    -- bug was killing ally echoes at frame 0.
    --
    -- `deny` is substring-matched and "baton" does NOT match a body named
    -- `ability2`, so the exact name has to be listed too.
    -- `attack1` is KNIVES OUT and was MISSING, which is the "trickster knife
    -- doesn't heatseek" report. Read from class_census_master.txt (TRICKSTER
    -- captured v5.15.0 2026-07-31 14:44), not guessed:
    --
    --   attack   Damage=7  Range=60  Speed=200                        <- Card Trick
    --   attack1  Damage=10 Range=999 Speed=250 HitLimit=5 CanBleed=false  <- Knives Out
    --
    -- HitLimit=5 is the multi-hit knife fan. It was live-confirmed refused in
    -- cs_core.log: `ALLY BODIES [TRICKSTER] echoed={attack x3}
    -- refused={... attack1 x5 ...}` -- the engine saw the knives every cast and
    -- turned them down, silently, because exact-match allow had only `attack`.
    --
    -- Everything else in that folder stays out on purpose: ability2 /
    -- ability2ended / ability2endedtwo are the Magic Baton (position swap, see
    -- below), ability1d / ability1catch / ability1spin are Vanishing Act, and
    -- madDash / midnight / stealth / unstealth / catchscan / bounceeff are all
    -- ANCHORED or CanTouch=false and cannot be steered anyway.
    allow   = { "attack", "attack1" },  -- ATK: Card Trick + Knives Out
    flight  = { stopWhenReturningToOwner = true },  -- 0566.lua:2476 -- Card Trick returns
    deny    = { "baton",        -- Magic Baton SWAPS position with victim (0566.lua:2476)
                "ability2",     -- the Magic Baton body itself — see above
                "cosmetic", "visual", "vanish", "sheathe", "eff" },
})

--------------------------------------------------------------------------
-- GAMBLER
--
-- Streamed (rs_combat_tree.txt:1407). `attack` is the Poker Chips bolt
-- (0416.lua:19, ATK slot), `ability2` the Weighted Dice throw (0415.lua:16,
-- AB2 slot). AB1 (Risky Bet) is self-damage only, no bolt.
-- CRT (All In): `critical` body is RenderStepped-pinned to the caster's HRP
-- every frame (0417.lua:19) -- it is an orbiting VFX, not a bolt. No Damage
-- child in the tree (rs_combat_tree.txt:1540). Must be DENIED, not just absent
-- from allow, because it carries Speed+Range children and would pass classProvenance.
-- `particleon`/`particleoff` carry Speed+Range+Damage but are particle-enable
-- signals (0421.lua: walks character descendants, Emit(10), no Touched).
-- `jackpot` is a floating billboard indicator (0419.lua: no Touched, no damage).
--------------------------------------------------------------------------
Core.registerClass("GAMBLER", {
    aliases = { "GAMBLER" },    -- 0566.lua:1028, rs_combat_tree.txt:1407
    accept  = Core.gates.classProvenance,
    allow   = { "attack", "ability2" },     -- ATK: 0416.lua:19, AB2: 0415.lua:16
    deny    = { "critical",                 -- HRP-pinned VFX (0417.lua:19); no Damage child
                "particleon", "particleoff", -- particle toggle signals (0421.lua)
                "criticalcancel", "jackpot", -- signal body; floating indicator (0419.lua)
                "criticaleff",              -- scattered shards spawned by critical VFX
                "eff", "indicator", "visual", "sheathe" },
})

--------------------------------------------------------------------------
-- RECON
--
-- Streamed (rs_combat_tree.txt:2851). Three real bolts: `attack` (0560.lua),
-- `scatter` (0565.lua), `ability1` (0555.lua).
--
-- `reconability2` is the Remote Control C4 and is denied unconditionally: on
-- impact it calls weldToPart, creating a WeldConstraint between itself and the
-- part it hit (0564.lua:79-97). If that part is a character, a mover left on
-- the C4 drives that character's whole assembly -- the same failure mode that
-- crashed the game on CHRONO. releaseMover now unwinds our mover, but the weld
-- can land mid-flight while we are still steering, so the allowlist is the real
-- guard and the mover restore is the backstop.
--------------------------------------------------------------------------
Core.registerClass("RECON", {
    aliases = { "RECON" },      -- rs_combat_tree.txt:2851
    accept  = Core.gates.classProvenance,
    allow   = { "attack", "scatter", "ability1" },  -- 0560, 0565, 0555
    deny    = { "reconability2", "ability2deconate", "ability2follow",
                "ability2phone", "eff", "visual", "sheathe",
                "limb", "head", "torso" },
})

--------------------------------------------------------------------------
-- WINDDANCER
--
-- Unstreamed. The kit table spells it with a space -- CLASS = "WIND DANCER"
-- (0566.lua:2847) -- so both spellings are aliased rather than betting on which
-- one CurrentClass writes. This is the CHRONO/CHRONOS trap again.
--
-- Kit (0566.lua:2847):
--   ATK = Wind Fan (melee 8 dmg + outgoing projectile 4 dmg) → UNVERIFIED
--   AB1 = Cyclone Dance (dash + AoE, no outgoing bolt)        → no bolt
--   AB2 = Wailing Winds (tornado returns to thrower, 4 dmg)   → UNVERIFIED; BOOMERANG
--   CRT = Hurricane Dance (slow-moving AoE tornado, multi-hit) → UNVERIFIED; AoE not bolt
--
-- ATK sends a travelling projectile that does NOT return -- boomerang guard must
-- NOT apply to it or it will stop mid-flight. AB2 is the boomerang.
-- Since both are unverified and share the same `flight` flag, the safest split
-- is: allow both under the same config; stopWhenReturningToOwner is belt-and-
-- braces for AB2 and harmless if ATK never actually returns.
-- CRT is a persistent AoE tornado -- excluding from allow until confirmed safe.
--------------------------------------------------------------------------
Core.registerClass("WINDDANCER", {
    aliases = { "WINDDANCER", "WIND DANCER" },  -- 0566.lua:2847
    accept  = Core.gates.classProvenance,
    allow   = { "attack",       -- ATK: Wind Fan projectile — UNVERIFIED
                "ability2" },   -- AB2: Wailing Winds       — UNVERIFIED; returns to owner
    deny    = { "visual", "sheathe", "trail", "eff" },
    flight  = { stopWhenReturningToOwner = true },  -- 0566.lua:2877 -- Wailing Winds returns
})

--------------------------------------------------------------------------
-- PROGRAMMER
--
-- Unstreamed. One body IS visible: `programmerteleport` (0129.lua), the
-- Return Zero marker. It is Anchored = true with no BodyVelocity (0129.lua:57)
-- and the caster blinks TO it. Steering it would move where the player
-- teleports -- the Magic Baton problem in a different costume. Denied.
--
-- Pull Request (AB2) swaps locations with the enemy hit (0566.lua), so anything
-- named for it is denied too.
-- `allow` is provisional -- see the SNIPER note.
--------------------------------------------------------------------------
Core.registerClass("PROGRAMMER", {
    aliases = { "PROGRAMMER" },     -- 0566.lua:1765
    accept  = Core.gates.classProvenance,
    allow   = { "attack" },
    deny    = { "programmerteleport", "teleport", "pullrequest", "swap",
                "visual", "sheathe", "eff" },
})

--------------------------------------------------------------------------
-- MEDIC
--
-- Unstreamed (not in rs_combat_tree.txt or keyword_index.txt).
-- Kit (0566.lua:1438):
--   ATK = Syringe Gun (10 dmg dart)                    → body name: UNVERIFIED
--   AB1 = Medical Bomb (15 dmg direct, 10 AoE splash)  → body name: UNVERIFIED
--   AB2 = Disarming Vial (15 dmg direct, 10 AoE)       → body name: UNVERIFIED
--   CRT = Sleep Dart (10 dmg + Sleep 3s) (0566.lua:1459) → body name: UNVERIFIED
--
-- F-key maps to the Critical slot (0003.lua:37 binds Critical = "f").
-- The original bug: `allow = { "attack" }` alone cannot heatseek Sleep Dart
-- because "attack" is the ATK slot (Syringe Gun), not the CRT slot.
--
-- Class is unstreamed, so body names cannot be verified from the dump.
-- Convention from every streamed class: ATK → "attack", CRT → "critical".
-- Added here following that convention, marked UNVERIFIED. If these body names
-- are wrong the class will simply do nothing for those slots and the reject
-- histogram will say `not MEDIC bolt (X)` -- safe failure, not a crash.
-- AB1/AB2 body names are unknown; "ability1"/"ability2" are the conventional
-- names but are equally UNVERIFIED for this class.
--
-- To close these gaps: play MEDIC, run `eng` to enable, fire each ability,
-- then check cs_core.log for `claim X [MEDIC]` lines to confirm body names.
--------------------------------------------------------------------------
Core.registerClass("MEDIC", {
    aliases = { "MEDIC" },          -- 0566.lua:1439
    accept  = Core.gates.classProvenance,
    allow   = { "attack",           -- ATK: Syringe Gun   — UNVERIFIED (class unstreamed)
                "ability1",         -- AB1: Medical Bomb  — UNVERIFIED (class unstreamed)
                "ability2",         -- AB2: Disarming Vial — UNVERIFIED (class unstreamed)
                "critical" },       -- CRT: Sleep Dart (0566.lua:1459) — UNVERIFIED (class unstreamed)
    deny    = { "visual", "sheathe", "eff", "heal", "bomb", "vial" },
})

--------------------------------------------------------------------------
-- GHOST
--
-- Unstreamed (not in rs_combat_tree.txt). Kit (0566.lua:1062):
--   ATK = Pulse Rifle (5 bullets × 3 dmg each)         → body name: UNVERIFIED
--   AB1 = Cybernetic Stealth (gain Stealth + speed)     → no bolt, pure self-effect
--   AB2 = Pulsar Discharge (grenade, 6/12 dmg + Marked) → body name: UNVERIFIED
--   CRT = Recon Shot (15 dmg high-speed bolt, 2× on Marked) → body name: UNVERIFIED
--
-- ATK fires FIVE bullets per cast (0566.lua:1067) -- sticky lock matters here
-- the way it does for elementalist Smolder; without it the volley scatters.
-- AB1 is a self-buff with no outgoing bolt; excluded from allow.
-- AB2 (grenade) body name is UNVERIFIED. AB2/CRT added following convention.
-- CRT "Recon Shot" is a real fast projectile -- worth steering (0566.lua:1087).
--
-- To close UNVERIFIED gaps: play GHOST, fire each ability, check cs_core.log
-- for `claim X [GHOST]` lines to confirm body names.
--------------------------------------------------------------------------
Core.registerClass("GHOST", {
    aliases = { "GHOST" },          -- 0566.lua:1063
    accept  = Core.gates.classProvenance,
    -- MEASURED 2026-07-31 from the ally body census, not convention. The census
    -- line read: echoed={attack x309} refused={ability1a, ability2bomb,
    -- criticalbullet}. The old guesses `ability2` and `critical` matched nothing,
    -- so Pulsar Discharge and Recon Shot never heatseeked at all -- silently,
    -- for months, because a wrong allow entry fails without a single log line.
    allow   = { "attack",           -- ATK: Pulse Rifle (×5) — CONFIRMED live
                "ability2bomb",     -- AB2: Pulsar Discharge — CONFIRMED live
                "criticalbullet" }, -- CRT: Recon Shot — CONFIRMED live
    -- "bomb" is NOT denied: it is a substring of `ability2bomb`, which is now an
    -- allow entry, and deny runs alongside allow -- it would make the body
    -- permanently unclaimable. Same trap the boot audit warns about.
    deny    = { "ability1a",        -- Cybernetic Stealth self-buff (census)
                "stealth", "mark",
                "visual", "sheathe", "eff" },
})

--------------------------------------------------------------------------
-- FIGHTER
--
-- Streamed (rs_combat_tree.txt:612). Kit table + RS folder both spell FIGHTER
-- (0566.lua:908). Slot map (0003.lua:37): E = Ability2.
--
-- AB2 = Aura Sphere (0566.lua:934-937): travelling energy ball, 8 dmg (+10
-- with Rage). Handlers 0381.lua (ability2) and 0390.lua (eability2) use
-- CreateBodyVelocity + CreateLimitRange and ClassModule:Damage on Touched
-- (0381.lua:20-21, 84-88; 0390.lua:20-21, 71-75) — genuinely heatseekable.
--
-- ATK Close Combat welds slash VFX to caster HRP (0383.lua:21-25) — same
-- crash vector as FROST attack; denied. Q ability1/eability1 are expanding
-- fade AoE markers with no damage call (0380.lua, 0389.lua). F critical is
-- Dragon Rage buff VFX only (0387.lua). slam is Grand Slam combo tween
-- (0391.lua). User asked E-only: LMB/Q/R/F absent from allow.
--------------------------------------------------------------------------
Core.registerClass("FIGHTER", {
    aliases = { "FIGHTER" },      -- 0566.lua:908, rs_combat_tree.txt:612
    accept  = Core.gates.classProvenance,
    allow   = {
        "ability2",   -- E Aura Sphere (0381.lua)
        "eability2",  -- E enhanced during Rage (0390.lua)
    },
    deny    = {
        "attack",       -- ATK melee weld to HRP (0383.lua:21-25)
        "ability1",     -- Q Tatsumaki AoE marker (0380.lua)
        "eability1",    -- Q enhanced marker (0389.lua)
        "critical",     -- F Dragon Rage buff body (0387.lua)
        "criticaleff",
        "attackeff", "attackeff1", "attackeff2",  -- ATK VFX (0384.lua+)
        "ability2eff0", -- AB2 spawn VFX ring (0382.lua)
        "slam",         -- AB1 combo Grand Slam (0391.lua)
        "ability3",     -- no AB3 in kit (0566.lua) — belt-and-braces
        "eff", "visual", "sheathe",
    },
})

--------------------------------------------------------------------------
-- FROST
--
-- E is Ability2 (0003.lua:37 binds Ability2 = "e"), which for FROST is
-- "Frostbite Cleave" (0566.lua:1018) -- a real travelling bolt: the `ability2`
-- body carries Speed + Range + Damage and its handler only ever gives it a
-- BodyVelocity and a range limit (0407.lua), so there is nothing to fight.
--
-- The LMB `attack` is deliberately NOT allowed: it is welded to the caster's
-- HumanoidRootPart (0409.lua:23), a melee slash that never travels. Steering a
-- body welded to your own character is what crashed the game on CHRONO.
-- `criticaleff` (0413.lua:31) and `ability1spineff*` (0405.lua:22) are pinned
-- to the HRP every RenderStepped for the same reason, and `critical` is a ring
-- of stationary sub-bodies, not a bolt.
--------------------------------------------------------------------------
Core.registerClass("FROST", {
    aliases = { "FROST" },      -- RS folder confirmed rs_combat_tree.txt:1843
    accept  = Core.gates.classProvenance,
    allow   = { "ability2" },   -- E-key Frostbite Cleave, the only confirmed bolt
    deny    = {
        "eff",      -- attackeff / ability2eff / ability1eff* / criticaleff*
        "spineff",  -- HRP-pinned expanding ring (0405.lua:22)
        "cancel",   -- criticalcancel — signal body, no damage
        "remove",   -- ability1remove — VFX teardown body
        "model",    -- ability2model1/2 — cosmetic parts welded inside the bolt
        "attack",   -- melee slash welded to caster HRP (0409.lua:23)
        "critical", -- ring AoE; criticaleff welds to HRP (0413.lua:31)
    },
})

--------------------------------------------------------------------------
-- BLASTER
--
-- Unstreamed in this dump (no ReplicatedStorage.Classes.BLASTER in
-- rs_combat_tree.txt; folder appears at runtime via WaitForChild — 0003.lua:259).
-- Kit (0566.lua:210): ATK Arm Cannon, Q Assisting Drones, E Lock-On Gear,
-- F Overloaded (hover + cursor laser ticks). User restriction: ONLY ATK/Q/E —
-- R and F must not heatseek.
--
-- Slot map (0003.lua:36-39): Attack=LMB, Ability1=Q, Ability2=E, Ability3=R,
-- Critical=F.
--------------------------------------------------------------------------
Core.registerClass("BLASTER", {
    aliases = { "BLASTER" },  -- 0566.lua:211; Players stats folder BLASTER (trees/Players.txt)
    accept  = Core.gates.classProvenance,
    allow   = {
        "attack",    -- ATK Arm Cannon orbs (0566.lua:215-218) — UNVERIFIED body name
        "ability1",  -- Q Assisting Drones barrage (0566.lua:220-223) — UNVERIFIED
        "ability2",  -- E Lock-On Gear (0566.lua:225-228) — UNVERIFIED
    },
    -- R (Ability3) and F (Critical) deliberately absent from allow.
    deny    = {
        "ability3",  -- R slot — not in user allowlist; BLASTER kit has no AB3 (0566.lua)
        "critical",  -- F Overloaded laser (0566.lua:230-233) — hover beam, not steer bolt
        "overloaded", "laser", "hover", "beam",
        "eff", "visual", "sheathe", "mark",
    },
})

--------------------------------------------------------------------------
-- COWBOY
--
-- Unstreamed in this dump (rs_combat_tree.txt lists 13 streamed classes;
-- COWBOY is LoadClass-streamed at runtime like BLASTER).
-- Kit (0566.lua:396): PSV Six-Shooter/Ammo; ATK Model-27 fan-fire + Sharpshooter;
-- Q Reloading Roll (mobility/reload); E Lasso (thrown bind); F High Noon (stance).
-- Only travelling damage bolts: ATK bullets + AB2 lasso. Roll and High Noon denied.
--------------------------------------------------------------------------
-- HIGH NOON (F) — forged aimed shot, self AND ally. See Core.fireHighNoon.
--
-- The F cast is detected by a MARKER BODY, not a keypress. MEASURED live from
-- the arm-time audit plus the reject stream, which caught the whole sequence in
-- order: `criticalshow` at the moment the stance starts, then `criticalimpact`,
-- then `criticalhide`. `criticalshow` is therefore the cast itself.
--
-- That is what makes ALLY support work at all. The first version triggered on
-- our own F keypress, which could never fire for an ally -- we cannot see their
-- keyboard -- and was wrong for us too, since a press on cooldown or while
-- stunned still spawned bullets. Every player's bodies flow through the same
-- watcher and carry an Owner, so a marker gives self and ally on one code path.
--
-- The markers stay DENIED for steering (the `critical` deny below covers all of
-- them); this only watches for them.
Core.registerClass("COWBOY", {
    aliases = { "COWBOY" },     -- 0566.lua:397 matches RS folder name (0003.lua:259)
    accept  = Core.gates.classProvenance,
    -- MEASURED 2026-07-31 from the arm-time audit:
    --   COWBOY bodies: 25 bolt(s) [ability2*, ability2a, ability2eff1,
    --   ability2eff2, attack*, attackeff, criticaleff1, criticaleff2,
    --   criticalhide, criticalimpact, criticalshow, miksorghostooo]
    -- `attack` and `ability2` were both right; keeping them as-is.
    allow   = {
        "attack",    -- ATK Model-27 + Sharpshooter (0566.lua:407-414) — CONFIRMED
        "ability2",  -- E Lasso throw (0566.lua:422-425) — CONFIRMED
    },
    castTrigger = {
        -- PER SHARPSHOOTER SHOT, not per stance entry.
        --
        -- High Noon is not a shot at all -- it is a STANCE. 0566.lua: "wind-up
        -- and gain Heavy for 1.5s, then enter a stance for 8s", cd 4-10s. The
        -- thing that actually fires during it is Sharpshooter: "Fire a shot at
        -- your cursor, consuming 1 Ammo", cd 0.3s, which natively applies
        -- Stun + Burn x6 to a focused target.
        --
        -- So the first version was hooked to the wrong event. `criticalshow`
        -- fires ONCE when the stance opens, which gave one bullet per F rather
        -- than one per shot.
        --
        -- The stance sequence, read straight out of the live reject stream:
        --     criticalshow    stance opens      (once)
        --     criticalimpact  a shot lands      (per shot)   <-- this one
        --     criticalhide    stance closes     (once)
        --
        -- INFERRED, not proven: `criticalimpact` is read as the Sharpshooter
        -- shot because it sits between show and hide and is the only body in
        -- the critical family that is neither. Sharpshooter reads as hitscan
        -- ("fire a shot at your cursor"), so an impact body with no travelling
        -- round is exactly the shape expected. If it turns out to spawn only on
        -- a HIT, we fire only on their hits -- acceptable, and arguably better.
        markers  = { "criticalimpact" },
        -- Sharpshooter's own cooldown is 0.3s, so the dedupe has to sit under
        -- it or every second shot is swallowed. 0.2 still collapses the
        -- duplicate bodies that skin variants emit within a frame of each other.
        cooldown = 0.2,
        -- The forged round itself. It lives HERE, in the class, because it is
        -- part of what COWBOY does -- not a feature with a switch of its own.
        --
        -- It used to have one: `highnoon on|off`, persisted to the config file
        -- and restored at boot, plus its own panel row. Two arming surfaces for
        -- one behaviour, and the second one defaulted OFF on any machine whose
        -- config file had never seen it -- which is every copy of
        -- dist/cs_portable.lua we hand out. Pressing F did nothing and said
        -- nothing. Now `hs COWBOY` arms the class and the round together, the
        -- same single act that arms steering for every other class, and
        -- registerClass's `cfg.enabled = false` keeps it cold on inject.
        --
        -- Anything omitted falls back to the HIGH_NOON defaults in cs_core.
        highNoon = {
            template = "attack",  -- CONFIRMED in the 2026-07-31 body census
            speed    = 1200,      -- hitscan-looking; past any steerable range
            shots    = 1,         -- one round per Sharpshooter shot
            gapSec   = 0.06,
        },
    },
    deny    = {
        "ability1",  -- Q Reloading Roll — reload/dash, no damage bolt (0566.lua:417-420)
        "ability3",  -- R slot — kit has no AB3; belt-and-braces
        "critical",  -- F High Noon stance/reticle (0566.lua:427-430)
        "highnoon", "reticle", "reload", "roll", "ammo",
        "eff", "visual", "sheathe",
    },
})

--------------------------------------------------------------------------
-- JAVELIN
--
-- Unstreamed: no RS.Classes.JAVELIN folder anywhere in the dump. The only
-- JAVELIN entry in ReplicatedStorage.txt:393 is `JAVELINFrostborn`, a skin
-- cost folder (Credit/Currency/Cost), not a projectile folder. So
-- classProvenance, and the body name follows convention -- UNVERIFIED.
--
-- Kit (0566.lua:1294):
--   ATK Jagged Edge      -- a JAB. Melee, no travelling body.          DENIED
--   AB1 Piercing Punish  -- counter stance / dash. No bolt.            DENIED
--   AB2 Javelin Throw    -- E. The thrown javelin. THE ONLY BOLT.      ALLOWED
--   CRT Spiked Corridor  -- a summoned LINE of javelins in front of you,
--        / Mighty Slam      or a ground slam. Both are placed AoE anchored to
--                           the ground, not a bolt that flies at anyone.  DENIED
--
-- ===================================================================
-- THIS CLASS CANNOT HEATSEEK. MEASURED 2026-07-31. DO NOT RE-DERIVE.
--
-- JAVELIN does not emit a steerable projectile. Every body it produces was
-- named by the self-body audit during live play (cs_core.log 04:48-04:49):
--
--   self body 'Ability2Land'    no speed  (Speed=false Range=false Damage=true)
--   self body 'Ability2Retract' no speed  (Speed=false Range=false Damage=true)
--   self body 'AttackStab'      slash vfx (Speed=false Range=false Damage=true)
--   self body 'AttackSlash'     slash vfx (Speed=false Range=false Damage=true)
--   self body 'Ability1Dash'    no speed  (Speed=false Range=false Damage=true)
--   self body 'CharacterFlash'  no speed  (Speed=false Range=false Damage=true)
--
-- Damage but no Speed and no Range. These are damage HITBOXES, not projectiles.
-- baseShotReject drops them before class matching runs, so the allow list below
-- can never be reached no matter what is written in it -- which is exactly why
-- it produced not one log line naming JAVELIN.
--
-- The E throw specifically: there is NO outbound body. `Ability2Land` is the
-- impact and `Ability2Retract` is the recall; the javelin that visibly flies
-- between them never enters ClientProjectiles. It is not a CreateProjectile
-- body. The CamelCase naming across the whole kit -- against every other
-- class's lowercase `attack` / `ability2` -- says this is a newer, different
-- implementation, and `Ability2Land`/`Ability2Retract`/`AttackStab` appear in
-- ZERO of the 1113 dump scripts.
--
-- Steering it would need a subsystem that drives a Model's CFrame rather than a
-- mover on a part. That is not a config gap and adding names here will not
-- close it. Damage would still resolve off the server's own hitbox regardless.
--
-- The registration is KEPT so the class still has a panel row and so a future
-- game patch that adds a real bolt is picked up rather than silently ignored.
-- `allow` stays `ability2` for that reason, not because it matches today.
-- ===================================================================
--
-- E only, as asked. `ability2` because Ability2 is bound to "e" (0003.lua:37),
-- the same mapping that FIGHTER, FROST, GAMBLER and COWBOY are keyed on.
--
-- BOOMERANG. "Recast to recall it... When your javelin returns, launch
-- yourself in your movement direction" (0566.lua:1315). The recalled javelin
-- flies home to the thrower, so `stopWhenReturningToOwner` is mandatory here
-- for the same reason it is on TRICKSTER's Card Trick: steering a body that is
-- deliberately coming back is pointless and visibly wrong. The guard arms on
-- distance travelled, so the outbound throw is unaffected.
--
-- Nothing extra is needed for allies -- registering the class gives both self
-- heatseek and the ally echo, and allyAllow/allyDeny fall through to these.
--------------------------------------------------------------------------
Core.registerClass("JAVELIN", {
    aliases = { "JAVELIN" },    -- 0566.lua:1294-1295 (CLASS field)
    accept  = Core.gates.classProvenance,
    allow   = { "ability2" },   -- E Javelin Throw (0566.lua:1313) — UNVERIFIED
    flight  = { stopWhenReturningToOwner = true },  -- recall (0566.lua:1315)
    deny    = {
        "attack",    -- ATK Jagged Edge — a jab, melee (0566.lua:1303)
        "ability1",  -- Q Piercing Punish — counter/dash (0566.lua:1308)
        "ability3",  -- R slot — kit has no AB3; belt-and-braces
        "critical",  -- F Spiked Corridor / Mighty Slam — placed AoE (0566.lua:1318)
        "corridor", "slam", "spike",
        "eff", "visual", "sheathe",
    },
})

--------------------------------------------------------------------------
-- SCOUT — Q and F ONLY, as instructed. Nothing else.
--
-- Kit (0566.lua:2078):
--   ATK Sprayer Shot   -- 2 needles.                          NOT ALLOWED (asked)
--   AB1 Needle Blitz   -- Q. Leap + 6 needles fired downward. ALLOWED
--   AB2 Blister Bolt   -- E. Single delayed bolt.             NOT ALLOWED (asked)
--   CRT Thorn Barrage  -- F. 2 blasts x 7 needles.            ALLOWED
--
-- Slot map (0003.lua:36-39): Ability1 = Q, Critical = F. Same mapping FIGHTER,
-- FROST, GAMBLER, COWBOY and JAVELIN are keyed on.
--
-- Body names follow convention and are UNVERIFIED -- SCOUT is not streamed in
-- the dump. This is the exact way GHOST stayed half-broken for months, so do
-- NOT treat these as settled: play one round with SCOUT armed, or have an ally
-- play it, then read the `ALLY BODIES [SCOUT]` census line or the arm-time body
-- audit. Both print the real names, and GHOST's turned out to be
-- `ability2bomb` and `criticalbullet` rather than the conventional guesses.
--
-- Needle Blitz PLANTS needles that become traps (0566.lua). Those are stationary
-- and must never be steered -- `trap`, `needleplant` and `planted` are denied by
-- substring in case they are named for it.
--
-- Thorn Barrage is 2 blasts of 7 needles = up to 14 bodies per cast. That is a
-- volley, not a duplicate, and the cast-id logging will report it as such. For
-- allies the per-cast echo budget (2) caps how many we mirror, which is
-- deliberate -- 14 echoed bodies per F would be absurd on screen.
--
-- Ally support needs nothing extra: registering the class gives both self
-- heatseek and the ally echo, and allyAllow/allyDeny fall through to these.
--------------------------------------------------------------------------
Core.registerClass("SCOUT", {
    aliases = { "SCOUT" },      -- 0566.lua:2078-2079 (CLASS field)
    accept  = Core.gates.classProvenance,
    -- MEASURED 2026-07-31, not convention. The census read:
    --   ALLY BODIES [SCOUT] echoed={ability1 x26}
    --                       refused={ability2eff1 x4, attack x16, critical1 x28}
    -- F is `critical1`, NOT `critical` -- so the conventional guess matched
    -- nothing and Thorn Barrage never heatseeked, exactly as GHOST's `critical`
    -- vs the real `criticalbullet`. Third time this convention has been wrong.
    allow   = { "ability1",     -- Q Needle Blitz  (0566.lua:2088) — CONFIRMED live
                "critical1",    -- F Thorn Barrage blast 1 — CONFIRMED live
                -- Thorn Barrage is TWO blasts (0566.lua:2098). Only `critical1`
                -- has been observed; `critical2` is the obvious name for the
                -- second and costs nothing if it does not exist -- a body that
                -- never spawns simply never matches. Confirm from the next
                -- census before treating it as real.
                "critical2" },  -- F blast 2 — UNVERIFIED
    deny    = {
        "attack",       -- ATK Sprayer Shot — excluded on instruction
        "ability2",     -- E Blister Bolt   — excluded on instruction
        "ability3",     -- R slot — kit has no AB3; belt-and-braces
        "trap", "planted", "needleplant",  -- Needle Blitz ground traps
        "eff", "visual", "sheathe",
    },
})

--------------------------------------------------------------------------
-- PHANTOM — E ONLY.
--
-- Kit (0566.lua:1704). Unstreamed: ReplicatedStorage.Classes holds 14 folders
-- (rs_combat_tree.txt:325) and PHANTOM is not one, so classProvenance.
--
--   ATK Shadow Carve / Dark Mist -- melee swing; mist spread is a Blind
--       applicator, not a damage bolt.                          DENIED
--   AB1 Shrouded Mist -- Q. Self transform, no outgoing body.   DENIED
--   AB2 E. TWO FORMS, both allowed:
--       Lethal Sawblade   -- one sawblade, 14 dmg + Bleeding.
--       Sawblade Shotgun  -- 3 sawblades x 2 throws = SIX bodies, the form
--                            you get during Shrouded Mist.
--   CRT Sinister Mirage -- F. Launches a shadow copy and RECASTING TELEPORTS
--       YOU TO IT. Same hazard as TRICKSTER Magic Baton and PROGRAMMER Return
--       Zero: steering it moves the player, not a bolt.         DENIED HARD
--
-- The AB2 body names are MEASURED from the arm-time audit, not guessed -- see
-- the allow list. The earlier version bet the shotgun form on eight candidate
-- spellings derived from FIGHTER's `eability2` / GHOST's `ability2bomb` /
-- SCOUT's `critical1`, and ALL EIGHT missed: the real names are `ability2alt`,
-- `ability2alt2` and `ability2large`. Fifth time the convention has been wrong.
--
-- The lesson is the audit, not the names. PHANTOM is absent from the dump but
-- its folder streams in at runtime, so `PHANTOM bodies:` in cs_core.log lists
-- the truth the moment the class arms -- and it says how many of them the allow
-- list actually takes. Read that line before theorising about any class.
--
-- Sawblade Shotgun's six bodies are a VOLLEY, not a duplicate; the cast-id
-- logging reports them as such. For allies the per-cast echo budget caps mirrors
-- at 2, which is deliberate.
--------------------------------------------------------------------------
Core.registerClass("PHANTOM", {
    aliases = { "PHANTOM" },    -- 0566.lua:1704-1705 (CLASS field)
    accept  = Core.gates.classProvenance,
    -- BOTH E FORMS, MEASURED 2026-07-31. PHANTOM's folder IS streamed at runtime
    -- even though it is absent from the dump, so the arm-time body audit printed
    -- the real contents (cs_core.log:50):
    --
    --   PHANTOM bodies: 15 bolt(s) [ability1eff1, ability1eff1, ability1eff2,
    --   ability1eff2, ability2*, ability2alt, ability2alt2, ability2large,
    --   attack, attack, gasattack, phantomcritical1, phantomcritical1,
    --   phantomcritical2, phantomcritical2] — 1 in allow (* = allowed)
    --
    -- ONE in allow. Every one of the eight guessed shotgun spellings
    -- (`eability2`, `ability2a/b`, `ability21/22`, `ability2shotgun`,
    -- `ability2saw`, `sawblade`, `sawbladeshotgun`) matched nothing, so the only
    -- E form that ever heatseeked was Lethal Sawblade. They are deleted rather
    -- than kept as spares -- CS_CONSTRAINTS.md §5b.
    --
    -- Which body is which form is now RESOLVED, from the claim counts per cast
    -- (cs_core.log 04:39): `ability2large` arrives one per cast, while
    -- `ability2alt` and `ability2alt2` arrive three each in one burst -- 3 + 3 =
    -- the Sawblade Shotgun's "3 sawblades x 2 throws" exactly.
    --
    -- THE TWO FORMS HAVE DIFFERENT REACH, and that is what "the normal E is not
    -- heatseeking" actually was:
    --   ability2large   speed=70  range=40   -> lock cap 44 studs
    --   ability2alt/2   speed=100 range=50   -> lock cap 55 studs
    -- lockCap is Range * 1.1 (cs_core.lua:1079), so from the same spot with the
    -- same aim the shotgun locks targets the single sawblade cannot physically
    -- reach. Live: one clean normal-E lock (ang=47.1 dist=15.2, froze=terminal,
    -- legit=100) and four casts logging `no lock — cap=44 fov=49 valid=15
    -- cone=0` -- fifteen valid candidates, none inside 44 studs.
    --
    -- Do NOT "fix" this by raising the cap past the bolt's own Range. That locks
    -- a target the sawblade dies before reaching, spends the deviation budget on
    -- a flight that cannot connect, and manufactures the miss -- the failure
    -- pickTarget documents at cs_core.lua:1194.
    allow   = {
        -- E Lethal Sawblade — CONFIRMED live, one body per cast. Short: 40 studs.
        "ability2large",
        -- E Sawblade Shotgun (Shrouded Mist form) — CONFIRMED live, 3 + 3 bodies
        -- per cast, logged as a volley rather than a duplicate.
        "ability2alt", "ability2alt2",
        -- In the class folder and marked allowed by the arm-time audit, but never
        -- yet observed as a self body in play. Kept because it is a real member
        -- of the folder, not a guessed spelling; exact-match, so it costs nothing
        -- if the game never spawns it for us.
        "ability2",
    },
    deny    = {
        "attack",       -- ATK Shadow Carve melee / Dark Mist blind spread
        "ability1",     -- Q Shrouded Mist — self transform, no bolt
        "ability3",     -- R slot — kit has no AB3; belt-and-braces
        "critical",     -- F Sinister Mirage — TELEPORTS YOU. Never steer.
        "mirage", "clone", "shadowcopy", "teleport",
        "mist", "blind",
        "eff", "visual", "sheathe",
    },
})

--------------------------------------------------------------------------
-- NINJA — LMB and F ONLY, as instructed.
--
-- Kit (0566.lua:1614). Unstreamed: ReplicatedStorage.Classes holds 14 folders
-- (rs_combat_tree.txt:325) and NINJA is not one. The only NINJA entry in
-- trees/ReplicatedStorage.txt:373 is `NINJAHyperdrive`, a skin cost folder
-- (Credit/Currency/Cost), not a projectile folder. So classProvenance.
--
--   ATK Shuriken Throw  -- LMB. THREE shurikens in a spread, 5 dmg each
--                          (0566.lua:1620). Real travelling bolts.   ALLOWED
--   AB1 Smokescreen     -- Q. Smoke bomb dropped at your OWN feet; applies
--                          Stealth to you and Blind to enemies (0566.lua:1624).
--                          Nothing travels at anyone.                DENIED
--   AB2 Night Dash      -- E. You dash forwards with the kunai; the damage is
--                          the dash, not a thrown body (0566.lua:1629). Steering
--                          a body that carries the player is the Magic Baton /
--                          Return Zero hazard.                       DENIED
--   CRT Shadow Shuriken -- F. See below.                             ALLOWED
--
-- Slot map (0003.lua:36-39): Attack = LMB, Ability1 = Q, Ability2 = E,
-- Critical = F. Same mapping FIGHTER, FROST, SCOUT and JAVELIN are keyed on.
--
-- WHAT F ACTUALLY DOES -- read this before "fixing" the allow list.
--
-- Shadow Shuriken spawns NO body of its own on the keypress. Verbatim
-- (0566.lua:1636): "Your next Shuriken Throw will throw a boomeranging shuriken
-- instead, dealing 10 damage traveling forward and backwards, cooldown starts
-- when the shuriken is thrown."
--
-- So F is a BUFF on the ATK slot: the empowered shuriken is thrown as part of a
-- Shuriken Throw, not spawned by the keypress. It is still a body of its OWN
-- rather than a renamed `attack` -- live play produced `critical1` with a
-- `criticaleff1` VFX beside it, so the CRT slot does emit its own part. That is
-- why the FIGHTER-style `eattack` guess was wrong and is not in the list.
--
-- NINJA is unstreamed, so unlike PHANTOM there is no arm-time enumeration to
-- check against (`NINJA bodies: class folder not streamed`). Both names below
-- come from claim and reject lines in live play instead.
--
-- BOOMERANG. The F shuriken travels forward and back to the thrower, so
-- `stopWhenReturningToOwner` is mandatory -- same reason as TRICKSTER's Card
-- Trick and JAVELIN's recall. The guard arms on distance TRAVELLED
-- (RETURN_ARM_DIST) before it will call anything a return, so it cannot fire on
-- frame one and the three plain ATK shurikens, which never come back, are
-- unaffected. Applying it class-wide is the same call WINDDANCER makes.
--
-- Three shurikens per cast is a VOLLEY, not a duplicate -- the cast-id logging
-- reports it as such, and the sticky lock is what keeps the spread on one
-- target. For allies the per-cast echo budget caps mirrors at 2, deliberately.
--
-- Ally support needs nothing extra: registering the class gives both self
-- heatseek and the ally echo, and allyAllow/allyDeny fall through to these.
--------------------------------------------------------------------------
Core.registerClass("NINJA", {
    aliases = { "NINJA" },      -- 0566.lua:1614-1615 (CLASS field)
    accept  = Core.gates.classProvenance,
    -- MEASURED 2026-07-31, not convention. Both names came out of live play and
    -- the guessed spellings are deleted rather than left in "just in case" --
    -- CS_CONSTRAINTS.md §5b: pick the version that is right and delete the old.
    allow   = {
        -- LMB Shuriken Throw (0566.lua:1620) — CONFIRMED live: three
        -- `claim attack [NINJA] speed=80 range=30` per cast, logged as one
        -- volley (`#10 volley — attack x3 in one burst (self)`), not a
        -- duplicate. Plain `attack`; the spread is NOT numbered, so the
        -- attack1/2/3 and shuriken candidates were wrong and are gone.
        "attack",

        -- F Shadow Shuriken (0566.lua:1636) — CONFIRMED live. `critical1`,
        -- SCOUT-style numbered, NOT `critical`. Fifth time the bare convention
        -- has been wrong (GHOST, SCOUT, JAVELIN, PHANTOM, now NINJA).
        --
        -- It did not show up as a NINJA line: with armAll every class is
        -- enabled, and classify() reported the refusal of whichever class sorted
        -- LAST, so the log read `reject: not WINDDANCER bolt (critical1)` at
        -- 04:34:13 — WINDDANCER, mid-NINJA-session, for a body it has no opinion
        -- about. The companion `criticaleff1` VFX two seconds earlier is what
        -- confirms the pair. classify() now attributes to the class being
        -- played, so the next one of these names itself.
        "critical1",
    },
    -- The boomerang guard covers the F shuriken's return leg. Harmless for the
    -- plain ATK shurikens, which never return — it arms on travel first.
    flight  = { stopWhenReturningToOwner = true },  -- 0566.lua:1636 — travels back
    deny    = {
        "ability1",     -- Q Smokescreen — self-centred smoke bomb (0566.lua:1624)
        "ability2",     -- E Night Dash — the dash carries YOU (0566.lua:1629)
        "ability3",     -- R slot — kit has no AB3; belt-and-braces
        "smoke", "smokescreen", "blind", "stealth",
        "dash", "kunai",
        "eff", "visual", "sheathe",
        -- NOTE: "shuriken" must NOT be denied — it is a substring of four allow
        -- entries, and deny runs alongside allow, so it would make them
        -- permanently unclaimable. Same trap that "bomb" set for GHOST.
    },
})

--------------------------------------------------------------------------
-- WIZARD — F ONLY, as instructed. Nothing else.
--
-- Kit (0566.lua:2880). Unstreamed in the dump: ReplicatedStorage.Classes holds
-- 14 folders (rs_combat_tree.txt:325) and WIZARD is not one. The only WIZARD
-- entry anywhere is `WIZARDFrostborn` (trees/ReplicatedStorage.txt:397), a skin
-- cost folder (Credit/Currency/Cost), not a projectile folder. So
-- classProvenance. PHANTOM was absent from the dump too and still streamed its
-- folder in at runtime, so the arm-time `WIZARD bodies:` audit may well print
-- the real names on the first arm -- read it before trusting anything here.
--
--   ATK Star Staff        -- LMB. Magic star, 8 dmg; every 3rd is a stronger
--                            star at 12 (0566.lua:2886). A real bolt, and
--                            deliberately NOT allowed.              DENIED
--   AB1 Dazzling Stars    -- Q. A LINE of solar energy conjured a set distance
--                            in front of you (0566.lua:2891). Placed AoE, not a
--                            travelling body.                       DENIED
--   AB2 Meteor Strike     -- E. Meteor called down from above into the ground
--                            (0566.lua:2896). Its path is sky-to-ground, not
--                            muzzle-to-target; steering it is meaningless.
--                                                                   DENIED
--   CRT Conjure Constellation -- F. THE ONLY ALLOWED MOVE.          ALLOWED
--
-- Slot map (0003.lua:36-39): Critical = F. Same mapping SCOUT, NINJA, FIGHTER
-- and JAVELIN are keyed on.
--
-- TEN BODIES PER CAST. "Cast out a barrage of 10 stars" (0566.lua:2902). That
-- is a VOLLEY, not a duplicate -- the cast-id logging reports it as such, and
-- the sticky lock is what keeps the barrage on one target instead of scattering
-- it across ten. GHOST's 5-bullet Pulse Rifle and SCOUT's 14-needle Thorn
-- Barrage are the same shape and are handled by the same mechanism.
--
-- For an ALLY the per-cast echo budget (Core.setMaxEchoesPerCast, default 2)
-- caps how many of the ten we mirror. That is deliberate and should NOT be
-- raised for this class: ten forged bodies per ally F would be absurd on screen
-- and is exactly the "duplicate projectiles" report in a new costume.
--
-- THE STARS ACCELERATE: "10 stars that SPEED UP as they travel"
-- (0566.lua:2902). This is the one thing to watch on the first cast.
--   * steer() re-reads projSpeed(proj) EVERY steered frame (cs_core.lua:3541)
--     and writes the mover with it (cs_core.lua:3747), so if the game
--     accelerates a star by updating its `Speed` child, we track the ramp and
--     the turn clamp -- which scales as 1/Speed -- tightens correctly with it.
--   * If instead the game ramps the BodyVelocity magnitude directly and leaves
--     `Speed` static, our mover write pins the star at its LAUNCH speed and the
--     speed-up visibly disappears. That would be a real regression and it is
--     observable: the `claim critical* [WIZARD] speed=N` line gives the launch
--     value, and the stars simply would not accelerate on screen.
--   * Which one it is cannot be determined from the dump -- WIZARD is unstreamed
--     and no handler for it exists in any of the 1113 scripts. UNVERIFIED. If
--     the acceleration does die, the fix is a flight flag that leaves the
--     mover's magnitude alone, NOT a change to this allow list. Not built
--     speculatively.
--
-- BODY NAMES ARE UNVERIFIED. The bare `critical` convention has now been wrong
-- five times running: GHOST `criticalbullet`, SCOUT `critical1`, JAVELIN
-- `Ability2Land` (and not steerable at all), PHANTOM `ability2alt` /
-- `ability2large`, NINJA `critical1`. A wrong entry fails SILENTLY. `allow` is exact
-- match, so a name the game never spawns simply never matches and costs
-- nothing, which is why the numbered spellings are all listed: a ten-star
-- barrage is the single most likely thing in this kit to be numbered per body,
-- and SCOUT already numbers its per-blast bodies exactly that way.
--
-- Bare "star" is deliberately NOT in allow. ATK is Star Staff, so a body simply
-- named `star` is at least as likely to be the LMB as the F -- and allowing it
-- would break the F-only instruction silently. `criticalstar` is unambiguous.
--
-- Ally support needs nothing extra: registering the class gives both self
-- heatseek and the ally echo, and allyAllow/allyDeny fall through to these.
--------------------------------------------------------------------------
Core.registerClass("WIZARD", {
    aliases = { "WIZARD" },     -- 0566.lua:2880-2881 (CLASS field)
    accept  = Core.gates.classProvenance,
    allow   = {
        -- F Conjure Constellation (0566.lua:2900-2903) — ALL UNVERIFIED.
        "critical",             -- bare convention
        "criticalstar",         -- GHOST-style, named for the thing thrown
        -- Numbered per star, SCOUT-style. Ten stars, so ten candidates.
        "critical1", "critical2", "critical3", "critical4", "critical5",
        "critical6", "critical7", "critical8", "critical9", "critical10",
    },
    deny    = {
        "attack",     -- ATK Star Staff — excluded on instruction (0566.lua:2886)
        "ability1",   -- Q Dazzling Stars — conjured line, placed AoE (0566.lua:2891)
        "ability2",   -- E Meteor Strike — falls from the sky (0566.lua:2896)
        "ability3",   -- R slot — kit has no AB3; belt-and-braces
        "meteor", "dazzling", "solar", "conjure",
        -- NOT denied: "star". It is a substring of `criticalstar`, and deny runs
        -- alongside allow, so denying it would make that body permanently
        -- unclaimable — the trap "bomb" set for GHOST's `ability2bomb`.
        "eff", "visual", "sheathe",
    },
})

--------------------------------------------------------------------------
-- ARCHER — LMB and Q ONLY, as instructed. Different cones for each.
--
-- Kit (0566.lua:64). Unstreamed: ReplicatedStorage.Classes holds 14 folders
-- (rs_combat_tree.txt:325) and ARCHER is not one, so classProvenance. The
-- arm-time `ARCHER bodies:` audit may still enumerate it at runtime the way
-- PHANTOM's did -- read that line before trusting any name here.
--
--   ATK -- LMB, and it is THREE moves, not one (0566.lua:69-80). F cycles the
--          mode (CRT "Special Arrows"), so the same click fires:
--            Power Arrow     charged, 8/12/16/24 + knockback at max
--            Piercing Arrow  fast, true damage, TRAVELS THROUGH enemies
--            Explosive Arrow slow, AoE
--          All three are travelling bolts.                        ALLOWED
--   AB1 -- Q Sky Assault. Leap backwards and fire ALL stored arrows at the
--          cursor, 8 each (0566.lua:82-85). A fan of up to 4.      ALLOWED
--   AB2 -- E Fleetfoot. A leap that generates an arrow charge; the movement is
--          the ability and nothing is thrown (0566.lua:87-90).     DENIED
--   CRT -- F Special Arrows. Swaps arrow MODE. No body at all; it changes what
--          the next LMB spawns (0566.lua:92-95).                   DENIED
--
-- Slot map (0003.lua:36-39): Attack = LMB, Ability1 = Q.
--
-- TWO DIFFERENT CONES, which is why `lockFov` exists.
--
-- The class flavour text is "I, never miss." and it is a MARKSMAN kit: a single
-- deliberate arrow is the most scrutinised shot in the game, and any visible
-- curve on it is the clearest tell there is. A wide cone on the click would
-- acquire targets well off the crosshair and then have to bend the arrow a long
-- way to reach them -- precisely the flailing that the FOV/budget invariant was
-- written to stop.
--
--   attack*   22 deg  -- deliberately far tighter than the global 49. Locks
--                        essentially what the player already aimed at, so the
--                        correction is small enough to read as good aim.
--   ability1* 49 deg  -- Sky Assault throws a fan of arrows at once while the
--                        player is leaping backwards. Spread is expected there,
--                        the arrows are cheap (8 damage each), and a wide cone
--                        reads as ordinary scatter rather than assistance.
--
-- 49 is the CEILING, not a taste call: legitMaxTotalDeviationDeg (55) minus
-- LOCK_DEV_MARGIN (6). pickTarget clamps every override to it, so Q is already
-- at the widest cone the deviation budget can actually steer to and asking for
-- more here would do nothing at all.
--
-- Piercing Arrow pierces by design. No HitCap is forced: MUSKETEER's Firing
-- Squad taught that lesson -- forcing HitCap = 1 turned a pierce into a single
-- hit and was reported as the ability doing too little damage.
--
-- Q is a multi-arrow volley, so several claims per cast are expected and the
-- sticky lock is what holds the fan on one target. For an ALLY the per-cast
-- echo budget caps mirrors at 2, deliberately.
--
-- BODY NAMES ARE MEASURED -- see the allow list. The thing to carry forward:
-- BOTH slots carry the arrow mode in the name, so there are six bodies, not
-- two, and every LMB mode has a matching Q mode. If a future patch adds a
-- fourth arrow type it will need FOUR new entries (attack<mode>, ability1<mode>)
-- plus its two lockFov keys, or that mode will silently stop heatseeking.
--------------------------------------------------------------------------
Core.registerClass("ARCHER", {
    aliases = { "ARCHER" },     -- 0566.lua:64-65 (CLASS field)
    accept  = Core.gates.classProvenance,
    -- MEASURED 2026-07-31 from the arm-time audit, which enumerated the folder:
    --
    --   ARCHER bodies: 10 bolt(s) [ability1explosive, ability1piercing,
    --   ability1power, ability2, ability2, attackexplosive*, attackpiercing*,
    --   attackpower*, particleoff, particleon] — 3 in allow (* = allowed)
    --
    -- BOTH slots carry the arrow MODE in the body name. The click guesses were
    -- right, but Q was registered as bare `ability1`, which does not exist -- so
    -- Sky Assault matched nothing and never heatseeked once. It surfaced as
    -- `reject: not ARCHER bolt (ability1power)` and read as "Q is inconsistent"
    -- rather than "Q is off", because a wrong allow entry fails silently.
    --
    -- Sixth time a convention guess has been wrong. The dead spellings
    -- (`attack`, `attack1/2/3`, `ability1`) are deleted, not kept as spares.
    allow   = {
        -- LMB Power Arrow / Piercing Arrow / Explosive Arrow — CONFIRMED live.
        "attackpower", "attackpiercing", "attackexplosive",
        -- Q Sky Assault, one per arrow mode — CONFIRMED from the folder audit.
        "ability1power", "ability1piercing", "ability1explosive",
    },
    -- Per-body cones. Keys are body names, lowercase; see lockFovFor().
    --
    -- Q is set to 49, which is the CEILING, not a preference:
    -- legitMaxTotalDeviationDeg (55) - LOCK_DEV_MARGIN (6). pickTarget clamps
    -- every override to it, so 49 is the widest cone any body can be given while
    -- the deviation budget can still actually steer to what it locks. Asking for
    -- more here would silently do nothing.
    --
    -- Going wider than 49 would mean raising legitMaxTotalDeviationDeg, and that
    -- is GLOBAL -- it would loosen the click and every other class along with it,
    -- which is the opposite of what this class was configured for. If Q needs
    -- more than this, the next lever is the guidance (PN_GAIN) or the turn
    -- clamp, chosen from what the FLIGHT lines say is binding -- not the cone.
    lockFov = {
        default            = 22,   -- anything unlisted gets the strict cone
        attackpower        = 22,
        attackpiercing     = 22,
        attackexplosive    = 22,
        ability1power      = 49,   -- Q Sky Assault: a fan, widest legal cone
        ability1piercing   = 49,
        ability1explosive  = 49,
    },
    deny    = {
        "ability2",     -- E Fleetfoot — a leap, nothing thrown (0566.lua:87).
                        -- CONFIRMED present in the folder audit, twice.
        "ability3",     -- R slot — kit has no AB3; belt-and-braces
        "critical",     -- F Special Arrows — mode swap only (0566.lua:92)
        -- Particle enable/disable signals, CONFIRMED in the folder audit. They
        -- carry Speed + Range + Damage and so pass the generic gate, exactly as
        -- GAMBLER's do (0421.lua: walks character descendants, Emit(10), no
        -- Touched). Denied rather than merely left out of allow.
        "particleon", "particleoff",
        "fleetfoot", "swap", "mode",
        "eff", "visual", "sheathe",
    },
})

--------------------------------------------------------------------------
-- ROCKETEER — LMB and F ONLY, as instructed. Self and ally.
--
-- Kit (0566.lua:1922). Unstreamed: ReplicatedStorage.Classes holds 14 folders
-- (rs_combat_tree.txt:325) and ROCKETEER is not one. The only ROCKETEER entries
-- anywhere are `RocketeerBurn` and `RocketeerOil` (rs_combat_tree.txt:3483,
-- 3492), status-effect billboards in the shared Effects folder, not a
-- projectile folder. So classProvenance -- but PHANTOM and ARCHER were both
-- absent from the dump too and still enumerated at runtime, so the arm-time
-- `ROCKETEER bodies:` line is what settles the names. Read it first.
--
--   ATK Rocket Launcher -- LMB. One rocket, 12 direct / 5 AoE. Explodes on
--                          terrain OR player contact (0566.lua:1928). ALLOWED
--   AB1 Jet Headbutt    -- Q. Charge, then dash forwards headfirst releasing
--                          explosions as you travel (0566.lua:1933). The dash
--                          CARRIES THE PLAYER -- same hazard as TRICKSTER's
--                          Magic Baton and PROGRAMMER's Return Zero.   DENIED
--   AB2 Oil Slick       -- E. Launches 5 puddles that STAY IN PLACE for 7s
--                          (0566.lua:1938). Stationary ground hazards, the same
--                          shape as SCOUT's planted needle traps.      DENIED
--   CRT Blast Off       -- F. Launch into the air and hover while firing EIGHT
--                          rockets at the cursor, 10 direct / 5 AoE
--                          (0566.lua:1943).                            ALLOWED
--
-- Slot map (0003.lua:36-39): Attack = LMB, Critical = F.
--
-- EIGHT ROCKETS PER F CAST. That is a volley, not a duplicate -- the cast-id
-- logging reports it as such and the sticky lock is what keeps the barrage on
-- one target instead of spreading it over eight. For an ALLY the per-cast echo
-- budget caps mirrors at 2, which is deliberate and should not be raised: eight
-- forged rockets per ally F is the duplicate-projectile report in a new costume.
--
-- THE ONE THING TO WATCH: this rocket detonates on TERRAIN, not just on players
-- (0566.lua:1928). Every other class in this file throws something that either
-- passes through the world or simply expires, so a steering correction has
-- never been able to destroy the shot before. Here an aggressive curve toward a
-- target that dips into the floor or clips a wall ends the flight early, and
-- the failure looks like "the rocket randomly explodes on nothing".
--
-- Not pre-emptively worked around, on purpose. The engine already drops a lock
-- when mid-flight LOS breaks, which covers the common case of a target moving
-- behind cover, and inventing a terrain-avoidance path for a hazard that may
-- never show up is exactly the speculative machinery CS_CONSTRAINTS.md 5b
-- forbids. If it does show up it will be visible as flights ending early with
-- low `dev` and low `clamp`, and the correct lever is a TIGHTER cone for
-- `attack` via the per-body `lockFov` (see ARCHER), not new code.
--
-- BODY NAMES ARE MEASURED -- see the allow list, and read the note there about
-- F having no body of its own. The lesson to carry forward is procedural, not
-- factual: the `ROCKETEER bodies:` audit line and its "matches NONE" warning
-- were both printed at arm time and both said the class was dead. Guessing
-- first and reading second cost a round trip that the tooling already prevents.
--
-- Ally support needs nothing extra: registering the class gives both self
-- heatseek and the ally echo, and allyAllow/allyDeny fall through to these.
--------------------------------------------------------------------------
Core.registerClass("ROCKETEER", {
    aliases = { "ROCKETEER" },      -- 0566.lua:1922-1923 (CLASS field)
    accept  = Core.gates.classProvenance,
    -- MEASURED 2026-07-31 from the arm-time audit, which enumerated the folder:
    --
    --   ROCKETEER bodies: 12 bolt(s) [ability1, ability1a, ability1eff1,
    --   ability1eff1cancel, ability1eff2, ability2, ability2eff,
    --   ability2effburn, attack1, attack2, criticaleff1, criticaleff2]
    --   — 0 in allow
    --   WARN ROCKETEER: allow list matches NONE of the live bolt bodies
    --
    -- ZERO in allow. The first version guessed `attack` / `critical` /
    -- `criticalrocket` / `blastoff` and every single one missed. Seventh time a
    -- convention guess has been wrong, and it shipped despite the audit line
    -- existing precisely to prevent it. Arm the class and read that line BEFORE
    -- writing names, not after.
    --
    -- THE ROCKET IS `attack1` / `attack2`, numbered, with no bare `attack`.
    --
    -- F BLAST OFF HAS NO BODY OF ITS OWN. The folder holds `criticaleff1` and
    -- `criticaleff2` and nothing else in the CRT slot -- both carry the `eff`
    -- VFX suffix every class uses, and there is no `critical` template at all.
    -- So the eight rockets of Blast Off are the LAUNCHER's rockets: they reuse
    -- `attack1`/`attack2`. Allowing those two covers BOTH requested slots, and Q
    -- and E stay excluded because their bodies are `ability1*` / `ability2*`.
    --
    -- That inference is the one thing here still worth confirming: if F casts
    -- produce `claim attack1 [ROCKETEER]` lines eight at a time under one cast
    -- id, it is settled. If F instead produces nothing, its rocket is spawned by
    -- some path the folder audit does not cover and the reject histogram will
    -- name it.
    allow   = {
        "attack1",  -- Rocket Launcher rocket — CONFIRMED in folder
        "attack2",  -- second rocket body — CONFIRMED in folder
    },

    -- BLAST OFF ACQUISITION WIDENING. See the cast-window section in cs_core.lua.
    --
    -- The problem this solves is the one created by F having no body of its own:
    -- Blast Off's eight rockets and the ordinary LMB rocket are the same
    -- `attack1`/`attack2`, so they cannot be told apart by name and cannot be
    -- configured separately.
    --
    -- Blast Off fires from a HOVER: the player is launched into the air, so the
    -- targets worth hitting sit well BELOW the aim line rather than in front of
    -- it, and the ordinary 16-stud close-lock cylinder is far too narrow to
    -- reach them. They were not being acquired at all.
    --
    -- So: while the window is open the close-lock cylinder widens to 48 studs.
    -- Anything within 48 studs of the aim line is lockable no matter how extreme
    -- the ANGLE to it becomes, which is exactly the vertical tolerance a hover
    -- needs.
    --
    -- This REPLACED a 25% steer dice, on instruction 2026-07-31. The dice made
    -- the bad-looking case rarer without changing it; widening acquisition
    -- addresses the actual complaint.
    --
    -- 48 and not more: the cylinder is bounded in STUDS, so unlike a raised fov
    -- it cannot open into a wide-angle lock at distance -- at 200 studs, 48
    -- studs of lateral offset is still only 13.8 degrees.
    --
    -- The window is opened by the CRT VFX bodies, which are the only things in
    -- this kit unique to Blast Off -- `criticaleff1` and `criticaleff2` were
    -- both CONFIRMED present in the arm-time folder audit. They stay denied for
    -- steering by the `eff` rule; this only watches for them.
    --
    -- 6 seconds because the ability is "launch into the air and hover, while
    -- firing 8 rockets" (0566.lua:1943) -- the rockets come out over the hover,
    -- not instantly, so the window has to outlast the barrage. It is keyed per
    -- owner and expires on its own, so an over-long window costs only that the
    -- first LMB rocket after landing also gets the wider acquisition.
    castWindow = {
        markers        = { "criticaleff1", "criticaleff2" },
        seconds        = 6,
        closeLockStuds = 48,
    },
    deny    = {
        "ability1",   -- Q Jet Headbutt — the dash carries YOU (0566.lua:1933)
        "ability2",   -- E Oil Slick — 5 stationary puddles (0566.lua:1938)
        "ability3",   -- R slot — kit has no AB3; belt-and-braces
        "oil", "puddle", "slick",       -- Oil Slick bodies, by any name
        "headbutt", "jet", "dash", "charge",
        -- Post-impact and dash explosion bodies. They carry damage and would
        -- otherwise pass the generic gate, but they are the BLAST, not the
        -- rocket -- steering one is steering something that has already landed.
        "explosion", "explode", "aoe", "burn",
        -- `eff` covers ability1eff1, ability1eff2, ability1eff1cancel,
        -- ability2eff, ability2effburn, criticaleff1 and criticaleff2 — seven of
        -- the twelve bodies in the folder, all VFX, all CONFIRMED present.
        "eff", "visual", "sheathe",
        -- Safe because no allow entry contains any of these as a substring:
        -- allow is exactly { attack1, attack2 }. Nothing here can eat them.
    },
})

--------------------------------------------------------------------------
-- SHROOM — M1 ONLY, as instructed.
--
-- Kit (0566.lua:2138). Unstreamed in the dump, so classProvenance -- but the
-- arm-time `SHROOM bodies:` audit will enumerate the folder at runtime the way
-- PHANTOM, ARCHER, ROCKETEER and ELEMENTALIST all did. READ THAT LINE and trim
-- these names to it. Guessing first has now been wrong seven times, ROCKETEER
-- most recently and most completely (0 of 7 guessed names existed).
--
--   ATK Gaseous Breath -- LMB. "Launch a spore forwards", 5 damage + Toxic
--                         (0566.lua:2143). A real travelling bolt.  ALLOWED
--   AB1 Infectious     -- Q. Absorbs the spores around YOURSELF for Haste and
--                         healing (0566.lua:2148). Pure self-effect. DENIED
--   AB2 Toxic Spores   -- E. Tosses a seed that spawns a mushroom which then
--                         STAYS on the ground 8s emitting waves (0566.lua:2153).
--                         A placed hazard, same shape as SCOUT's planted needle
--                         traps and ROCKETEER's oil puddles.        DENIED
--   CRT Slumber Powder -- F. A burst released AROUND YOURSELF (0566.lua:2158).
--                         No outgoing body.                         DENIED
--
-- Worth noting: M1-only is not just the instruction here, it is also the only
-- coherent option. Nothing else in this kit throws anything at anyone -- Q and F
-- are both self-centred and E's damage comes from a stationary mushroom, not
-- from the seed. There is no second slot to argue about later.
--
-- The seed of Toxic Spores IS a thrown body and would be steerable, which is
-- exactly why `ability2` is denied explicitly rather than merely left out of
-- allow: steering it would move where the mushroom PLANTS, silently relocating
-- an 8-second area denial to wherever the lock happened to point. Same class of
-- hazard as TRICKSTER's Magic Baton and PROGRAMMER's Return Zero, and it would
-- not look like heatseek going wrong -- it would look like the player misplaying.
--
-- Ally support needs nothing extra: registering the class gives both self
-- heatseek and the ally echo, and allyAllow/allyDeny fall through to these.
--------------------------------------------------------------------------
Core.registerClass("SHROOM", {
    aliases = { "SHROOM" },     -- 0566.lua:2138-2139 (CLASS field)
    accept  = Core.gates.classProvenance,
    allow   = {
        -- LMB Gaseous Breath (0566.lua:2143) — ALL UNVERIFIED.
        --
        -- Candidates follow the two shapes the roster actually uses: a plain
        -- slot name, or the slot numbered. ROCKETEER turned out to be
        -- `attack1`/`attack2` with NO bare `attack`, so the numbered spellings
        -- are not optional padding here -- they are as likely as the plain one.
        -- Exact match, so dead candidates cost nothing.
        "attack",
        "attack1", "attack2",
        "attackspore", "spore",
    },
    deny    = {
        "ability1",   -- Q Infectious — self absorb/heal (0566.lua:2148)
        "ability2",   -- E Toxic Spores — steering the seed MOVES the mushroom
        "ability3",   -- R slot — kit has no AB3; belt-and-braces
        "critical",   -- F Slumber Powder — burst around self (0566.lua:2158)
        "seed", "mushroom", "shroom", "toxic", "sleep", "powder",
        "eff", "visual", "sheathe",
        -- NOT denied: "spore". It is a substring of the `attackspore` and
        -- `spore` allow entries, and deny runs alongside allow, so denying it
        -- would make both permanently unclaimable — the trap "bomb" set for
        -- GHOST's `ability2bomb`.
    },
})

--------------------------------------------------------------------------
-- NECROMANCER — LMB and Q, including the summoned spirits' versions of both.
--
-- Kit (0566.lua:1595). STREAMED: ReplicatedStorage.Classes.NECROMANCER exists
-- in the dump with its full Projectile folder, so unlike almost every other
-- class in this file NOTHING here is a convention guess. Every name below was
-- read out of the folder tree and every behavioural claim comes from that
-- body's own ProjectileHandler script, cited per line.
--
--   ATK Dark Bolt      -- LMB. 10 direct + 5 splash (0566.lua:1601). ALLOWED
--   ATK Spirit Strike  -- while a Summon is active it performs ITS attack
--                         alongside yours (0566.lua:1605).          ALLOWED
--   AB1 Ghastly Grasp  -- Q. Spectral hands, 10 + Slow 2s (0566.lua:1611).
--                         Spirits have their own version.           ALLOWED
--   AB2 Necronomicon   -- E. Opens a book UI and summons a spirit.  DENIED
--   CRT                -- F. Chain/grab, see below.                 DENIED
--
-- WHY THESE SEVEN. Each one creates its own mover and calls Damage:
--   attack          0506.lua:24  Instance.new("BodyVelocity"), :Damage x2
--   Ability1        0491.lua     CreateBodyVelocity, :Damage
--   attackThief     0509.lua:24  BodyVelocity, :Damage x2
--   attackGunner    0508.lua:24  BodyVelocity, :Damage x2
--   attackBullet    0507.lua:22  BodyVelocity, :Damage
--   Ability1Thief   0493.lua     CreateBodyVelocity, :Damage
--   Ability1Gunner  0492.lua     CreateBodyVelocity, :Damage
-- All use the same shape -- Velocity = CFrame.lookVector * Speed with infinite
-- MaxForce -- which is the cleanest steering target in the game. The
-- `Anchored = true` in the attack family appears only inside Explode(), the
-- impact handler, so it does not touch the flight.
--
-- ==================================================================
-- Ability2Setup IS A TRAP. Do not add it, ever.
--
-- 0494.lua contains EIGHT WeldConstraints and THREE `Anchored = true`: it is
-- the summon rig, and it welds itself to a character. A mover left on a body
-- welded to a character drives that character's whole assembly -- the RECON C4
-- vector (0564.lua:79-97) and the thing that crashed the game on CHRONO.
--
-- It carries Speed + Range + Damage, so it PASSES the generic gate and an empty
-- or loose allow list claims it. `ability2` denies it by substring.
-- ==================================================================
--
-- CRT is not a projectile in any useful sense. `critical1` (0511.lua) drives a
-- Model with SetPrimaryPartCFrame every frame, rotating chain parts by fixed
-- angles -- there is no mover to steer and a BodyVelocity would fight the CFrame
-- writes. Same shape as JAVELIN. `critical2`, `criticalKnife`, `criticalWarrior`
-- and `criticalGunner` are denied with it; none was shown to be a steerable
-- bolt and F is out of scope regardless.
--
-- THE REAL HAZARD HERE IS THE BODY COUNT. The folder holds 28 bodies and
-- TWENTY-ONE of them carry Speed + Range + Damage -- a worse ratio than
-- ELEMENTALIST, which produced 492 claims across 20 names and was the original
-- duplicate-projectile disaster. Books, trails and cancel-VFX all pass the
-- generic gate: `AttackEffCancel` and `Ab1EffCancel` are pure VFX and still
-- carry all three children. The allow list below is the only thing standing
-- between this class and that failure, so keep it exact and keep it short.
--
-- SPIRIT STRIKE IS A REAL 2-BODY VOLLEY. With a summon active, ONE click emits
-- your `attack` AND the spirit's `attackThief`/`attackGunner`. That is a volley,
-- not a duplicate, and the cast-id logging reports it as such. Note for allies:
-- it exactly saturates the per-cast echo budget of 2, which is fine and is the
-- budget doing its job.
--
-- Ally support needs nothing extra: registering the class gives both self
-- heatseek and the ally echo, and allyAllow/allyDeny fall through to these.
--------------------------------------------------------------------------
Core.registerClass("NECROMANCER", {
    aliases = { "NECROMANCER" },    -- 0566.lua:1595, rs_combat_tree.txt (streamed)
    accept  = Core.gates.classProvenance,
    allow   = {
        -- LMB Dark Bolt (0506.lua) — CONFIRMED from the folder + handler.
        "attack",
        -- Q Ghastly Grasp (0491.lua) — CONFIRMED.
        "Ability1",
        -- Spirit Strike: the summon's ATK, fired alongside yours (0566.lua:1605).
        "attackThief",      -- 0509.lua
        "attackGunner",     -- 0508.lua
        "attackBullet",     -- 0507.lua — the Gunner spirit's bullet
        -- Spirit Ability: the summon's own ability, commanded from the AB2/E
        -- slot while a summon is active (0566.lua, "Spirit Ability").
        "Ability1Thief",    -- 0493.lua
        "Ability1Gunner",   -- 0492.lua
        -- The spirit ABILITY projectiles, added 2026-07-31 after E was reported
        -- dead for the Gunner. Both are ordinary BodyVelocity bolts built
        -- exactly like `attack`, and both were being eaten by this class's own
        -- `critical` deny -- see the deny block.
        --   criticalGunner  0513.lua:22  BodyVelocity; Damage(v7, 3, "AP")
        --                   = "shoots out 4 bullets rapidly that each deal
        --                     3 neutral damage" (0566.lua, Gunner's Spirit)
        --   criticalKnife   0514.lua:22  BodyVelocity; Damage(v7, Damage.Value)
        --                   = "throws out 3 knifes" (0566.lua, Thief's Spirit)
        "criticalGunner",
        "criticalKnife",
    },
    deny    = {
        -- E Necronomicon and the summon rig. `ability2` also covers
        -- Ability2Setup, which is the welding body described above.
        "ability2",
        "ability3",     -- R slot — kit has no AB3; belt-and-braces
        -- F. CFrame-driven chain models, not steerable bolts.
        --
        -- NOT a blanket "critical". That is what this entry shipped with, and it
        -- silently killed BOTH spirit abilities: `criticalGunner` and
        -- `criticalKnife` are the Gunner's 4 bullets and the Thief's 3 knives,
        -- real BodyVelocity bolts, and a deny substring runs alongside allow --
        -- so they were unclaimable no matter what the allow list said. Reported
        -- as "the E on the spirit ability for gunner is not working".
        --
        -- This is the GHOST `ability2bomb` trap, in the one entry whose own
        -- comment warns about the GHOST `ability2bomb` trap. Deny by the exact
        -- names instead; the list is short and closed.
        "critical1",    -- 0511.lua — SetPrimaryPartCFrame chain model, no mover
        "critical2",    -- 0512.lua — same family
        "criticalWarrior",  -- no Damage child (folder tree): not a bolt
        "warriorcritical1", -- no Damage child: VFX
        -- "critical1" also covers warriorcritical1 by substring; both are listed
        -- because relying on that overlap is how this bug happened.
        "warrior",      -- attackWarriorVFX and the Warrior melee spin VFX
        -- Necronomicon props: no mover and no damage call in any handler.
        "book",         -- OpenBook, CloseBook, VaporiseBook, *BookModel
        "ab2",          -- Ab2Use (0490), Ab2Eff (0489)
        "ab1",          -- Ab1Eff (0487), Ab1EffCancel (0488)
        "spirit",       -- AttackSpirit (0497): no mover, no damage — a marker
        "model",        -- CriticalModel1/2, WraithModel, HandsModel, *BookModel
        "trail",        -- TrailStart (0502), TrailStop (0503)
        "setup", "vaporise", "wing",
        -- `eff` catches attackeff, AttackEff1, AttackEffCancel, Ab1Eff,
        -- Ab1EffCancel and Ab2Eff. `cancel` is belt-and-braces on top, because
        -- the Cancel bodies carry Speed+Range+Damage despite being VFX.
        "eff", "cancel",
        "visual", "sheathe",
        -- Substring safety, verified against the seven allow entries: none of
        -- them contains any deny string. In particular "ab1"/"ab2" are NOT
        -- substrings of "ability1" (a-b-1 is not consecutive in a-b-i-l-i-t-y-1),
        -- and no allow entry contains "spirit", "critical" or "eff". Getting
        -- this wrong is the GHOST `ability2bomb` trap and it fails silently.
    },
})

-- JESTER — ASSASSIN. Kit read from 0567.lua (the class description table).
--
-- NOTE ON CITATIONS: script ids SHIFTED in the v5.15.0 dump. The description
-- table that every other config in this file cites as `0566.lua` is now
-- `0567.lua`; id 0566 is a VALKYRIE projectile handler. Ids are dump-relative
-- by nature -- re-resolve before trusting any pre-v5.15.0 line number here.
--
-- One of four moves is a heatseek candidate, and that is not pessimism -- three
-- of them move the CASTER or place a ground object, which is the category this
-- engine denies on purpose (TRICKSTER Magic Baton, CHRONO Temporal Gateway).
--
--   ATK Juggling Trick   toss a ball forward that RETURNS to you, 7 dmg each
--                        way. A travelling damage bolt and a boomerang -> the
--                        one move worth steering.
--   AB1 Bouncy Ball      summon a giant ball and BOUNCE ON IT 3 times, then
--                        recast to kick it. The kicked ball is steerable; the
--                        ridden ball is standing under the player. Same body
--                        name in both phases for all we know, and steering the
--                        phase you are standing on moves YOU. Denied until the
--                        census separates them.
--   AB2 Comedic Banana   tosses a peel (3.5s ground trap) or a banana (heals
--                        whoever touches it). Steering a trap only changes
--                        where it lands, and steering the heal aims it at the
--                        enemy. No value either way.
--   CRT Prankster's      throw a box; RECASTING TELEPORTS YOU TO THE BOX.
--       Surprise         Steering the box picks where the player is teleported.
--                        This is exactly the Magic Baton shape and it is denied
--                        for exactly that reason -- not because it cannot be
--                        steered, but because it must not be.
--
-- Worth revisiting once bodies are known: the CRT recast also emits FOUR
-- explosive balls (7 dmg each) at the explosion. Those are ordinary travelling
-- projectiles and steering them moves nobody -- but they are almost certainly
-- named in the `critical` family, which is denied here to stop the box. Do not
-- guess which; read the census first.
Core.registerClass("JESTER", {
    aliases = { "JESTER" },     -- 0567.lua (CLASS field)
    accept  = Core.gates.classProvenance,
    -- MEASURED 2026-07-31 from the arm-time audit, not convention:
    --   JESTER bodies: 10 bolt(s) [ability1, ability1impact, ability1new,
    --   ability1pop, attack, attackeff, criticaldeconate, criticaldeconate1,
    --   jestercritical, unstealth]
    allow   = {
        -- ATK Juggling Trick — CONFIRMED live, 9 `claim attack [JESTER]`.
        -- Plain `attack`; the guessed `attack1/2/3` and `attackball` spellings
        -- did not exist and are deleted rather than kept "just in case"
        -- (CS_CONSTRAINTS §5b).
        "attack",

        -- Q Bouncy Ball. The ball the player rides IS the ball they kick --
        -- one body across both phases, which is why this was denied on the
        -- first pass. `steerAfterOwnerStuds` below is what makes allowing it
        -- safe: the body is not steered at all until it has left the player.
        "ability1",
        -- Seen in the folder listing but it did not spawn during the Q test, so
        -- which of the two is the kicked ball is not yet settled. Exact match,
        -- so if it is never the bolt this entry costs nothing -- and if it IS,
        -- the log names it on the first cast instead of the class looking dead.
        "ability1new",
    },
    -- The ball returns to the thrower and damages on the way back. The guard
    -- stops steering once it turns for home, so the return leg is the game's,
    -- not ours -- steering a body back toward the player is how you shove it
    -- through them. Arms on distance travelled first, so it cannot fire on
    -- frame one when the ball is still at the muzzle.
    flight  = {
        stopWhenReturningToOwner = true,
        -- The Q ball is summoned UNDER the player and bounced on three times
        -- before it is kicked. Same body, both phases -- so steering is held off
        -- until the body is this far from its owner, and the flight baselines
        -- (muzzle delay, LOS arm, deviation budget, boomerang arm) all start
        -- from there. 12 studs clears a giant ball with somebody standing on it
        -- without waiting so long that the kicked shot loses its guided window.
        --
        -- PER BODY, and that is the fix for HANDOFF_2026-08-01 open item 7.
        -- This was a bare number, which cs_core read as class-wide, so the m1
        -- was ALSO held unsteered for its first 12 studs -- and because the
        -- ridden branch resets the flight baselines every frame, its guided
        -- window kept restarting. JESTER first-steered at 172ms (n=11) and
        -- 173ms (n=205 the session before) against 26-36ms for every other
        -- class, and it was the only class carrying this flag. `ability1new`
        -- is listed too: if it turns out to be the kicked ball, it is ridden
        -- for exactly the same reason.
        steerAfterOwnerStuds = { ability1 = 12, ability1new = 12 },
    },

    -- LOCK REACH, per body. Shortens what the lock will REACH FOR; the bolt
    -- itself is untouched and flies exactly as far as it always did.
    --
    -- Measured this session, and it is the whole "sketchy at range" report:
    -- five `attack` flights, every one `froze=dev` at 56-66 against a 55
    -- budget, all graded legit=75(B) -- while the two Q balls that stayed
    -- inside their budget graded 90(A) and 100(A). The bolt was locking
    -- targets it could only reach by spending the entire deviation budget,
    -- which is a miss manufactured at lock time (see pickTarget's own note on
    -- exactly this failure).
    --
    --   attack   0.85  -- m1, the 15% cut asked for. JESTER only.
    --   ability1 0.55  -- Q ball. The ask was "short cone but CLOSE": the ball
    --                     rides you into the air and is enormous, so a lock at
    --                     the far end of a learned reach of 177 studs is the
    --                     one that looks worst. Cutting reach rather than
    --                     widening the cone keeps it honest up close, where it
    --                     already grades A, and simply refuses the far shots.
    lockReachScale = { attack = 0.85, ability1 = 0.55, ability1new = 0.55 },

    -- Cone, per body. Tighter than the global 49 for both, because JESTER is
    -- the class pickTarget's lock-margin note is written about: it locks at
    -- 41-48 degrees and SPENDS 55-62, the widest lock-to-spend gap in the
    -- roster, because the gap scales as atan(drift / boltSpeed) and JESTER is
    -- the slowest bolt (speed 70). A cone it can actually steer to is worth
    -- more than a wide one it abandons mid-flight.
    lockFov = { attack = 30, ability1 = 52, ability1new = 52 },

    -- DEVIATION BUDGET, per body. This is the knob that makes the Q track
    -- someone BELOW and in front of you, and the cone above is useless without
    -- it -- pickTarget clamps every cone to `budget - margin`, so at the global
    -- 55 budget this body's ceiling is 55 - (6 + atan(16/70)) = 36 degrees and a
    -- lockFov of 52 would simply be clamped back to 36, exactly as the previous
    -- 38 was. Nothing about the cone alone can move it.
    --
    -- 78 puts the ceiling at 59 degrees, which covers the shape actually being
    -- missed: the ball carries you into the air, so targets sit 40-55 degrees
    -- below the aim axis at 10-20 studs. The cone is then set just under that
    -- ceiling so the number in the config is the number in force.
    --
    -- THE TRADE, stated plainly: this body may now hook up to 78 degrees, and
    -- that is a lot of curvature. It is confined to `ability1` -- the m1 stays
    -- at the global 55 with a 30 degree cone, tighter than before -- and it is
    -- deliberately spent on the case where it reads best. Per the user, close
    -- range is where the Q already looks legit; the far shots were the sketchy
    -- ones, and lockReachScale 0.55 above is what refuses those.
    --
    -- If it starts looking wrong, `hstune` cannot reach a per-body value -- edit
    -- this number and rebuild, or drop the entry to fall back to the global.
    lockDev = { ability1 = 78, ability1new = 78 },
    deny    = {
        "ability2",   -- E Comedic Banana — ground trap / heal pickup
        "ability3",   -- R slot — kit has no AB3; belt-and-braces
        "critical",   -- F Prankster's Surprise — the box is a TELEPORT anchor
        -- MEASURED: these three spawn alongside the ball on a Q and all pass the
        -- generic gate. `impact` is the per-bounce AoE, `pop` the detonation.
        "impact", "pop",
        "banana", "peel", "box", "bounce", "kick", "juggle",
        "eff", "visual", "sheathe",
        -- Substring safety, checked mechanically against every allow entry.
        -- "ability1" is NOT denied any more: it is a substring of both ability1
        -- allow entries, and deny runs alongside allow, so it would make the Q
        -- ball permanently unclaimable while looking correct. That is the trap
        -- "bomb" set for GHOST's `ability2bomb` and "critical" for
        -- NECROMANCER's `criticalGunner`. `impact`/`pop` are denied by their
        -- own names instead, which is the deny-exact-names rule from §1.
    },
})

-- RANGER — body names READ FROM THE DUMP, not guessed.
--
-- Source: class_census_master.txt, block "=== RANGER ===", captured from
-- CRITICAL STRIKE v5.15.0 on 2026-07-31 14:41 (also in
-- archives/..._144117/classes_projectiles.txt). RANGER is ABSENT from the
-- current dump -- only classes somebody in that round had equipped are
-- streamed -- which is exactly why the master census exists: it unions every
-- run so a class captured once stays captured.
--
-- Full folder, 14 bodies. The five carrying Speed+Range+Damage and NOT
-- anchored / CanTouch=false:
--
--   attack1     Range=70  Speed=100 Damage=8
--   attack2     Range=70  Speed=100 Damage=8
--   ability2    Range=100 Speed=100 Damage=8
--   critical1   Range=100 Speed=100 Damage=8  TurnDistance=7 TurnLimit=5 TurnAngle=-22 HitCap=2
--   critical2   Range=100 Speed=100 Damage=8  TurnDistance=7 TurnLimit=5 TurnAngle=+22 HitCap=2
--
-- Everything else is anchored VFX (ability1a/b, ability2eff, ability2cancel,
-- ability2off), a CanTouch=false cosmetic (attackskin), or a Model
-- (Ability2Model, AttackModel, CriticalModel). None of them can be steered and
-- none are allowed.
--
-- THE CRITICALS ARE DELIBERATELY NOT ALLOWED, and this is the whole point of
-- this entry. critical1/critical2 are the game's own NATIVE TURNING
-- projectiles: TurnDistance / TurnLimit / TurnAngle are real value children
-- driven by CFrame * CFrame.new(0,0,-TurnDistance) * CFrame.Angles(0,
-- rad(TurnAngle), 0), repeated up to TurnLimit times (HANDOFF section 8b, read
-- from 0114.lua:105 in the v4.3 dump run -- that file's index has since shifted,
-- so do not expect to re-find it at the same path).
--
-- That is a per-segment CFrame write, not a BodyVelocity. Our steer() only
-- writes BodyVelocity / LinearVelocity, so there is no mover to take over --
-- the same shape as JAVELIN and NECROMANCER's critical1, both of which are
-- registered-but-unsteerable for exactly this reason. Allowing them would put
-- our mover in a fight with the game's own CFrame driver over one body, which
-- is the two-steerers-one-bolt failure the CORE_TAG rule exists to prevent.
--
-- They are ALSO the game's own statement of how far a bolt may visibly bend and
-- still read as native: +/-22 degrees, 5 segments, 7 studs apart. That is a
-- reference point for the legitness model, not something to steer.
--
-- ability2 IS allowed but is the least certain entry here: it is a genuine
-- damaging bolt (Speed+Range+Damage, unanchored), but its siblings
-- `ability2cancel` and `ability2off` suggest a held or toggled ability, and the
-- kit is not otherwise documented. If steering it turns out to move where
-- something PLACES rather than where it flies -- the SHROOM seed / CHRONO
-- gateway / TRICKSTER baton failure -- remove it from allow. Confirm with one
-- cast and a look at the FLIGHT line before trusting it.
--
-- Skins need nothing: the folder is ProjectileValentine for a skinned player and
-- the engine prefix-matches "Projectile" (OverrideProjectile 0704.lua:284).
Core.registerClass("RANGER", {
    aliases = { "RANGER" },
    accept  = Core.gates.classProvenance,
    allow   = { "attack1", "attack2", "ability2" },
    deny    = {
        -- Exact names, not families (§1: NECROMANCER's deny={"critical"} ate
        -- criticalGunner and criticalKnife). "critical" as a bare family string
        -- would be correct here by luck, but the exact names say WHY.
        "critical1", "critical2",   -- native TurnAngle zig-zag, no mover to steer
        "attackskin",               -- CanTouch=false cosmetic
        "ability2cancel", "ability2off", "ability2eff",
        "ability1a", "ability1b",
        "eff", "model",
    },
})

-- HUNTER — allow list CAPTURED 2026-07-31 19:45. Was deliberately empty before
-- that; the names below were read from the live reject stream, not guessed.
--
-- HUNTER is still absent from class_census_master.txt ("STILL MISSING (63)")
-- and from every dump run, so the log is the ONLY source for these names. The
-- class was played at 19:45:34-37 with an empty allow list, and each refused
-- body printed its real name as `reject: not HUNTER bolt (<name>)`. That is the
-- capture path when a class never streams -- an empty allow list is a body-name
-- probe, which is the second reason to register a class before you can name it.
--
-- Convention guesses have been wrong SEVEN times (GHOST, SCOUT, JAVELIN,
-- PHANTOM, NINJA, ARCHER, ROCKETEER), so nothing here is guessed: `attack` and
-- `ability1` both appeared verbatim in that capture.
--
-- STILL UNCAPTURED: AB2 Bear Trap. It was not cast in that window, so its real
-- name is unknown and the "trap"/"bear" deny substrings remain the only guard.
-- If a `not HUNTER bolt (...)` line ever shows an AB2 body under some other
-- spelling, add it to `deny` -- do NOT let it fall through to allow.
--
-- WHAT THE KIT SAYS, from ClassInfo (0567.lua:1238) -- this part IS verified,
-- and it is why the deny list can be written before the names are known:
--
--   ATK "Crossbow Bolt"  fire an arrow, 10 dmg.            -> STEERABLE
--   AB1 "Pursuit"        dash, then fire a powerful arrow,
--                        15 dmg + knockback.               -> the ARROW is
--                        steerable; the dash is not a projectile.
--   AB2 "Bear Trap"      toss a trap that CAMOUFLAGES ON
--                        LANDING and damages enemies who
--                        WALK OVER IT. Max 3 at once.      -> NEVER STEER
--   CRT "Hawkeye"        launch a hawk that MARKS enemies
--                        as it travels.                     -> NEVER STEER
--       "Hawk Rider"     activated airborne: YOU RIDE THE
--                        HAWK for up to 1.2s.               -> NEVER STEER
--
-- The two CRT/AB2 denials are the whole reason this entry is worth writing
-- early, because both are failures the engine has already paid for once:
--
--  * Bear Trap is the SHROOM seed shape. Flight-correcting a projectile whose
--    job is to LAND somewhere moves where it lands, not what it hits -- the
--    trap ends up under the target instead of where you aimed it, and a
--    camouflaged trap in the wrong place is worse than no trap.
--
--  * Hawk Rider is the TRICKSTER Magic Baton / CHRONO Temporal Gateway shape,
--    and it is the dangerous one: the player is ATTACHED TO the hawk. Steering
--    that body steers the person riding it, which yanks you across the map into
--    whichever target the lock picked. Hawkeye and Hawk Rider are the same CRT
--    slot, so the body is denied outright rather than conditionally.
--
-- Names below are DENY SUBSTRINGS covering the likely spellings for those two
-- slots. Substring denial is safe for a class with no allow list yet, but once
-- you fill `allow` in, re-check it against these: deny runs ALONGSIDE allow and
-- is substring-matched, so a deny string contained in an allow entry makes that
-- body permanently unclaimable and silent (the NECROMANCER deny={"critical"}
-- trap that ate criticalGunner and criticalKnife).
Core.registerClass("HUNTER", {
    aliases = { "HUNTER" },
    accept  = Core.gates.classProvenance,
    -- FILLED 2026-07-31 from LIVE reject lines, not guessed. One HUNTER cast at
    -- 19:45:34-37 produced exactly five bodies in cs_core.log:
    --   attack          -> ATK Crossbow Bolt        ALLOWED
    --   ability1        -> AB1 Pursuit arrow        ALLOWED
    --   ability1eff     -> AB1 dash/trail effect    denied by "eff"
    --   criticalalt     -> CRT hawk                 denied by "critical"
    --   criticalaltend  -> CRT hawk                 denied by "critical"
    -- AB2 Bear Trap was not cast, so its real name is still unknown; the "trap"
    -- and "bear" substrings stay as the guard until it appears in a log.
    allow   = { "attack", "ability1" },
    deny    = {
        "trap",     -- AB2 Bear Trap: steering moves where it LANDS
        "bear",
        "hawk",     -- CRT Hawkeye / Hawk Rider: the player RIDES this body
        "critical", -- CRT slot generally, until the real name is known
        "eff", "cosmetic", "visual", "model",
    },
})

-- HITMAN — allow list CAPTURED 2026-07-31 20:02, same path as HUNTER.
--
-- HITMAN is still absent from class_census_master.txt ("STILL MISSING (63)") and
-- never streams its class folder, so `bodies HITMAN` cannot verify anything --
-- the reject stream is the ONLY source. The class was played with an empty allow
-- list and each refused body printed its own name.
--
-- STILL UNSETTLED: AB2 and `imagebody`, both held in `deny` with the reasoning
-- at the entries themselves. Resolve those before widening this list.
--
-- WHAT THE KIT SAYS, from ClassInfo (0567.lua:1208) -- verified, and the reason
-- the deny list can be written before the names are:
--
--   PSV "Target Acquired"    a RANDOM enemy is your target; 50% of damage dealt
--                            to them is stored. Not a projectile.
--   ATK "Combat Expertise"   PROXIMITY-SWITCHED: slash if near (12 dmg),
--                            else fire a bullet (8 dmg).   -> the BULLET is steerable
--   AB1 "Shaded Strike"      stealth, then a melee strike.  -> not a projectile
--   AB2 "Guillotine Drop"    leap; on landing, spin slash if near, ELSE fire
--                            3 bullets (4 dmg each).        -> those 3 ARE steerable
--   CRT "Finish the Job"     after a long delay, one powerful bullet, 5-30 TRUE
--                            damage scaled by stored damage. -> steerable
--
-- Two things here that are specific to this class and worth knowing before
-- writing the allow list:
--
--  * ATK and AB2 are PROXIMITY-SWITCHED, so each emits either a melee body or a
--    bullet body depending on range. Expect at least two body names per slot and
--    do NOT assume the one you saw first is the only one -- arm it and take a
--    cast at range AND in someone's face before trusting the audit line. This is
--    the same shape as ARCHER, where both slots carried the arrow MODE and it
--    turned out to be six bodies rather than two.
--
--  * AB2's ranged branch is a THREE-bullet volley, so it needs the sticky lock
--    to stay coherent (the ELEMENTALIST Smolder problem) and it will hit the
--    per-cast echo budget for allies (Core.setMaxEchoesPerCast, default 2).
--    Raise that budget if the ally echo only ever forges two of the three --
--    do NOT loosen `allow` to work around it.
--
-- The melee bodies are denied by name below. They are welded slash hitboxes,
-- not projectiles; steering one drives the caster's own assembly, which is the
-- NECROMANCER Ability2Setup / RECON C4 failure.
Core.registerClass("HITMAN", {
    aliases = { "HITMAN" },
    accept  = Core.gates.classProvenance,
    -- FILLED 2026-07-31 from LIVE reject lines, not guessed. HITMAN casts at
    -- 19:45 and 20:02 printed these bodies as `not HITMAN bolt (<name>)`:
    --   attack       -> ATK Combat Expertise, BULLET branch    ALLOWED
    --   execute      -> CRT Finish the Job, the delayed bullet ALLOWED
    --   ability2     -> AB2 Guillotine Drop, BULLET branch     ALLOWED (below)
    --   imagebody    -> anchored decoy, denied by name (below)
    --   ability2eff2 -> AB2 effect, denied by "eff"
    --
    -- Reaching that reject line is real evidence, not just a name sighting:
    -- baseShotReject runs FIRST and requires Speed + Range + Damage children and
    -- rejects slash vfx/welds outright, so every name above is a genuine
    -- damaging projectile. That is also why `attack` is safe to allow despite
    -- the proximity switch -- the melee branch is a welded slash hitbox and
    -- never survives baseShotReject to be named here.
    -- `ability2` is E, and it IS the 3-bullet volley, not the leap. Settled
    -- 2026-07-31 by the SELF BODY census rather than by reasoning about the
    -- name: `Speed=150 Range=50 Damage=4`. ClassInfo gives Guillotine Drop's
    -- ranged branch as three bullets at FOUR damage each, so the value matches
    -- the volley exactly. A leap or landing body reads Speed=0 or Range=0 --
    -- compare `imagebody` in the same census, Speed=0 Range=20 Damage=0
    -- ANCHORED, which is why it stays denied.
    allow   = { "attack", "execute", "ability2" },
    deny    = {
        "slash",    -- ATK / AB2 melee branch: welded hitbox, not a bolt
        "spin",     -- AB2 near-branch spin slash
        "stealth",  -- AB1 Shaded Strike is melee out of stealth
        "tether",   -- PSV draws a tether to the current target
        -- Anchored decoy: Speed=0 Range=20 Damage=0 in the SELF BODY census.
        -- It does no damage and does not travel, so there is nothing to steer;
        -- writing a mover to it would just drag a prop around.
        "imagebody",
        "eff", "cosmetic", "visual", "model",
    },
})

-- MERCENARY — registered with an EMPTY allow list on purpose. It claims nothing
-- until one cast names its bodies. Read this before filling it in.
--
-- MERCENARY is in the dump's "ABSENT (69)" list, has no retired module in
-- scripts/_archive/, and has never appeared in any cs_*.log, so there is no
-- source for its body names anywhere and nothing here is guessed. Convention
-- guesses have been wrong seven times.
--
-- CAPTURED 2026-07-31 20:24 by the SELF BODY census, one cast per slot. Values
-- verbatim from cs_core.log, and they settle every slot on their own:
--
--   attack          Speed=150 Range=50  Damage=10            -> ATK Trigger
--                                                               Finger, ALLOWED
--   GrenadeToss     Speed=60  Range=100 Damage=15            -> AB2 thrown
--                                                               grenade, ALLOWED
--                                                               (see the reversal)
--   GrenadeTicking  Speed=0   Range=0   Damage=10 ANCHORED   -> cooking in hand
--   CritReady       Speed=0   Range=20  Damage=14 ANCHORED   -> CRT windup
--   critical        Speed=0   Range=0   Damage=15 ANCHORED   -> CRT morale shot
--   ability2eff     Speed=0   Range=0   Damage=5  ANCHORED   -> AB2 blast vfx
--
-- `attack` matches ATK's stated 10 damage exactly, and it is the ONLY body here
-- that both moves and is not a landing body. Everything else reads Speed=0 and
-- ANCHORED — nothing to steer even if it were allowed.
--
-- GRENADETOSS WAS DENIED FIRST, THEN ALLOWED. Both halves are worth keeping,
-- because the reasoning that denied it was wrong in a specific, repeatable way.
--
-- It was denied on the assumption that Frag Pitch is the SHROOM seed / HUNTER
-- Bear Trap shape: a body whose damage comes from where it comes to REST, so
-- steering moves the landing spot instead of aiming the throw. That inference
-- came from the word "grenade", not from the kit text. Re-reading ClassInfo side
-- by side is what settled it -- the two real placement moves SAY SO explicitly:
--
--   HUNTER  Bear Trap        "camouflages ON LANDING and damages enemies who
--                             WALK OVER IT"
--   SANTA   Christmas Gift   "upon landing IT STAYS THERE for a while. Anyone
--                             TOUCHING the present causes it to explode"
--   MERC    Frag Pitch       "Cook a grenade for up to 2s. Recast to THROW it,
--                             dealing 10 damage and applying Cripple (2s)"
--
-- Frag Pitch has no landing clause and no persistence clause. It is a thrown
-- explosive that detonates on its own fuse, not a trap that waits to be walked
-- over, so guiding it puts the blast on the target exactly as guiding a bolt
-- does. The live census agrees: Speed=60 Range=100 Damage=15 is a real
-- travelling damaging body.
--
-- THE RULE THIS LEAVES BEHIND: "does the body come to rest and stay dangerous?"
-- is the question, and the kit text answers it in words. A body being thrown,
-- arcing, or named after an explosive does NOT make it a placement body.
--
-- `GrenadeTicking` (Speed=0, ANCHORED) is the grenade cooking in hand and stays
-- denied by name -- it is held, not thrown, and writing a mover to a body the
-- caster is holding is the failure the weld guard exists for.
--
-- WATCH ONCE, then decide whether to keep it: a thrown grenade is likely to
-- ARC under the game's own gravity, and our mover writes BodyVelocity, which
-- can flatten that arc into a flat glide. If cs_core.log shows these flights
-- ending `froze=reversed`, or the throw stops looking like a throw, that is the
-- JESTER shape -- a body the game is also moving -- and it should come back out.
--
-- WHAT THE KIT SAYS, from ClassInfo (0567.lua:1468) — verified, and why the deny
-- list can be written before the names are:
--
--   ATK "Trigger Finger"     fire a bullet, 10 dmg.        -> STEERABLE, the
--                                                             only allowed slot
--   AB1 "Evasive Maneuver"   leap, recast to DIVE, AoE
--                            slash on landing.             -> NEVER STEER
--   AB2 "Frag Pitch"         cook a grenade up to 2s,
--                            recast to THROW it, 10 dmg
--                            + Cripple.                    -> NEVER STEER
--   CRT "Dauntless Spirit"   immobilize, fire a morale shot
--                            INTO THE AIR, buffs you and
--                            nearby allies.                -> NEVER STEER
--
-- The user described this class as "click and bomb". The click is Trigger
-- Finger and it is exactly what heatseek is for. **The bomb is the one body on
-- this class that must never be steered**, and the distinction is the whole
-- reason this entry is written out rather than pattern-matched:
--
--  * Frag Pitch is a THROWN, COOKED grenade — the SHROOM seed / HUNTER Bear
--    Trap shape. Its damage comes from where it LANDS and detonates, not from
--    what it touches in flight. Flight-correcting it moves the landing point to
--    whatever the lock picked instead of where it was pitched, which is both
--    useless (the arc is the aiming skill) and unmistakable to watch.
--  * Evasive Maneuver leaps and dives the CASTER. If a body of it is ever
--    steerable, steering it flies the player — the Hawk Rider / Magic Baton
--    failure.
--  * Dauntless Spirit is fired deliberately INTO THE AIR and damages nobody. A
--    morale shot that curves onto an enemy is a pure tell for zero gain.
Core.registerClass("MERCENARY", {
    aliases = { "MERCENARY" },
    accept  = Core.gates.classProvenance,
    -- ATK Trigger Finger + the thrown AB2 grenade. `grenade` is NOT a deny
    -- substring any more -- it would have made GrenadeToss permanently
    -- unclaimable while the allow entry sat there looking correct, which is the
    -- NECROMANCER deny={"critical"} trap.
    allow   = { "attack", "GrenadeToss" },
    deny    = {
        "grenadeticking",                    -- cooking in hand: anchored, held,
                                             -- never thrown
        "frag", "pitch", "cook",             -- any other cook/pitch stage
        "ability2",                          -- AB2 slot, until the thrown body
                                             -- is named and proven
        "dive", "leap", "evasive",           -- AB1 leaps/dives the CASTER
        "slash", "spin",                     -- AB1 landing AoE is a welded
                                             -- hitbox, not a bolt
        "critical",                          -- CRT is fired into the air
        "eff", "cosmetic", "visual", "model",
    },
})

-- SANTA — `allow` filled from LIVE CAPTURE (cs_core.log, 02:38). Before this it
-- was empty, which fails closed, so the class claimed nothing and silently did
-- nothing in play. This class has MODES: read the mode section before adding.
--
-- SANTA is in the dump's "ABSENT (69)" list with no module, so every name below
-- comes from a `SELF BODY` line, not from convention. What one Rapidfire-mode
-- session printed:
--
--   attack1          Speed=110 Range=50  Damage=5   -> ATK Rapidfire snowball.
--                                                      Travels, damages, matches
--                                                      the kit's 5 dmg. ALLOWED.
--   SantaPresent     Speed=50  Range=30  Damage=8   -> AB2 Christmas Gift. Lands
--                                                      and waits. DENIED (by the
--                                                      `present` substring).
--   bigsnowball      Speed=50  Range=100 Damage=15  -> AB1 Rapidfire drag ball.
--                                                      HELD BACK on legitness,
--                                                      denied by name below.
--   criticaleffoff   Speed=0 ANCHORED               -> CRT mode-switch vfx.
--   criticaleff1     (same shape)                      Both denied by `critical`.
--
-- STILL UNCAPTURED: the Spray and Longshot bodies of ATK, and the AB1 Spray
-- gusts. `allow` is exact-match, so those stay unclaimed until someone fires
-- them and reads the log — that is the intended failure mode, not a bug. Do NOT
-- guess `attack2` / `attack3`: `attack` / `critical` / `ability2` have been
-- wrong seven times in this file.
--
-- THE MODES ARE THE WHOLE PROBLEM. CRT "Setting Switch" (0.1s cooldown) cycles
-- the Chimney Launcher between Rapidfire / Spray / Longshot, and BOTH ATK and
-- AB1 change move entirely with the mode:
--
--   ATK Rapidfire   3 snowballs, 5 dmg each        -> STEERABLE
--   ATK Spray       4 blasts of frigid wind, 3 dmg -> STEERABLE
--   ATK Longshot    1 long-range icicle, 10-30 dmg -> STEERABLE, see the
--                   BY RANGE TRAVELLED                caveat below
--   AB1 Rapidfire   giant snowball that DRAGS
--                   enemies inside it until it
--                   explodes                       -> HELD BACK, see below
--   AB1 Spray       3 long-ranged gusts of wind    -> STEERABLE
--   AB1 Longshot    icicle launched AT YOUR CURSOR -> NEVER STEER
--   AB2 "Christmas Gift"  present that LANDS, sits
--                   there, and explodes on touch   -> NEVER STEER
--   CRT "Setting Switch"  mode swap, no projectile -> nothing to claim
--
-- So ONE slot emits at least three different body names depending on a mode the
-- log never states. This is the ARCHER trap that cost six bodies instead of two:
-- do NOT fill `allow` from a single cast and assume the slot is done. Capture
-- each mode separately — fire ATK, press CRT, fire ATK again, three times round
-- — and read every distinct `SELF BODY` line before writing the list.
--
-- TO FINISH IT (Rapidfire ATK is done; the other two modes are not):
--   1. Play SANTA. Fire ATK in Spray and in Longshot, cycling with CRT.
--   2. Fire AB1 in Spray mode as well.
--   3. grep "SELF BODY" cs_core.log — each prints name + Speed/Range/Damage.
--   4. Add the ATK bodies (the 3 dmg wind and the 10-30 icicle) and the AB1
--      Spray gusts to `allow`. Leave everything else out.
--
-- WHAT MUST NEVER BE STEERED, and why each one is a shape already paid for:
--
--  * AB2 Christmas Gift is a PLACED body: it is launched, it LANDS, and it sits
--    waiting to be touched. Damage comes from where it settles, so steering it
--    moves the trap rather than aiming it — the SHROOM seed / HUNTER Bear Trap
--    failure exactly.
--  * AB1 Longshot lands an icicle AT THE CURSOR. The cursor IS the aim; there is
--    nothing for a lock to improve, and steering it desyncs the strike from the
--    place the player pointed at.
--  * AB1 Rapidfire's giant snowball DRAGS PLAYERS INSIDE IT until it detonates.
--    It is held back on legitness grounds rather than mechanics: steering a body
--    that is carrying a real person means remote-controlling where that player
--    is dragged to, which is the same loud surface as `stun` and the kind of
--    thing a victim reports. If you want it, it is the user's call, not a
--    default -- see the ban note in HANDOFF_2026-07-31_EVENING.md §1.
--
-- TWO THINGS TO EXPECT NOW THAT IT CLAIMS:
--  * Rapidfire is 3 bolts and Spray is 4, both above the default per-cast echo
--    budget of 2 (Core.setMaxEchoesPerCast). An ally's SANTA will forge only two
--    of them until that is raised. Raise the budget -- do NOT loosen `allow`.
--  * Longshot's damage scales 10-30 WITH DISTANCE TRAVELLED. Curving it onto a
--    closer target shortens its flight and can lower the damage, so it is the
--    one body here where heatseek and damage actively trade against each other.
Core.registerClass("SANTA", {
    aliases = { "SANTA" },
    accept  = Core.gates.classProvenance,
    -- Live-captured ATK Rapidfire snowball. Spray/Longshot bodies are still
    -- unnamed and stay unclaimed until the census prints them.
    allow   = { "attack1" },
    deny    = {
        "gift", "present",      -- AB2: lands and waits to be touched (SantaPresent)
        "ability2",             -- AB2 slot, until the present body is named
        "cursor",               -- AB1 Longshot strikes the cursor position
        "bigsnowball",          -- AB1 Rapidfire drag ball, named from the census
        "drag", "grab",         -- AB1 Rapidfire snowball carries a real player
        "critical",             -- CRT is a mode switch, emits no bolt
        "eff", "cosmetic", "visual", "model",
    },
})

--------------------------------------------------------------------------
-- CONTROLLER — the drone class. ONE steerable body out of fourteen, and the
-- reason it is worth this much text is that NONE of the usual assumptions hold:
-- the thing that shoots is not the player, and the thing that flies is not
-- always a bolt.
--
-- Kit (0567.lua:348). CAT=SUPPORT. Passive "Drone Control": a drone follows a
-- MARKER you place in front of yourself, and every slot is a COMMAND to it.
-- CRT "Change Mode" swaps Combat/Movement, so like SANTA each slot has two
-- meanings — but unlike SANTA the Movement half emits no damaging body at all,
-- which is what makes the split tractable here:
--
--   ATK Combat  "Shoot"        stop the drone, fire 4 bullets, 5 dmg each
--   ATK Move    "Hover"        move/teleport the drone to the marker
--   AB1 Combat  "Supply Pulse" pulse AROUND THE DRONE, knockback + heal
--   AB1 Move    "Closer"       move the marker in
--   AB2 Combat  "EMP"          shockwave toward the MARKER, PIERCES TERRAIN,
--                              applies Disable (1.5s)
--   AB2 Move    "Further"      move the marker out
--   CRT         "Change Mode"  mode swap, no projectile
--
-- MEASURED, from the archive folder listing (archives/…_2026-07-31_144117/
-- classes_projectiles.txt:55) — 14 bodies, so nothing below is a convention
-- guess:
--
--   attack           Speed=125 Range=50  Damage=5   -> ALLOWED, the only one
--   ability2         Speed=150 Range=100 Damage=5   -> DENIED, see below
--   ability1         Speed=0 ANCHORED   Damage=8    -> Supply Pulse aura
--   ability2eff/effbig  ANCHORED CanTouch=false     -> vfx
--   hovereff         ANCHORED CanTouch=false        -> vfx
--   drone            Speed=100 Range=0  no Damage   -> THE DRONE ITSELF
--   droneremove      Speed=70  Range=0  no Damage   -> despawn body
--   commandemp / commandhover / commandshoot / commandsupply / commandteleport
--                    Speed=0 ANCHORED, ReplicateCFrame -> command signals
--   DroneModel [Model]                              -> not a part at all
--
-- `attack` matches the kit's 4x5 exactly and is the ONLY body here that both
-- travels and damages on contact.
--
-- WHY `drone` IS THE HARDEST DENY ON THE ROSTER. It carries Speed=100 and so
-- passes the generic "is it a bolt" shape the way GAMBLER's particle signals
-- do, and it is a body of ours that genuinely moves — but it is the class's
-- PET, not a shot. Writing a mover to it steers the player's own drone into
-- whatever the lock picked: the TRICKSTER Magic Baton / PHANTOM Sinister Mirage
-- failure, one step removed. It also has Range=0, so reachFor would give it the
-- fallback lock range and it would chase across the map. Denied by name, and
-- `droneremove` with it. CanTouch=false on both is the tell: a body that cannot
-- touch anything cannot be a damage bolt.
--
-- WHY AB2 EMP IS DENIED even though it looks like the best body on the class
-- (Speed=150, Range=100, travels, damages). Two independent reasons, either one
-- sufficient:
--   1. It is launched TOWARD YOUR MARKER, a position the player placed. The
--      marker IS the aim, exactly as SANTA's AB1 Longshot cursor and PROGRAMMER's
--      Return Zero. Steering it moves the shockwave off the spot the player
--      pointed at, so the assist actively fights the player's own placement.
--   2. It applies Disable (1.5s). A curving projectile that removes someone's
--      abilities is the `stun` surface CS_CONSTRAINTS holds back on legitness
--      grounds — the loudest possible thing to be seen bending.
-- It PIERCES TERRAIN, which also means the line-of-sight gate is meaningless
-- for it: our targeting would happily lock through a wall it can legitimately
-- cross, so its rejects would read nothing like every other body's.
--
-- THE ORIGIN PROBLEM — this is the real work, and it is engine-side.
-- `attack` spawns AT THE DRONE, which hovers at the marker: routinely 30-60
-- studs from the player and facing wherever the drone was told to face. The
-- self targeting path anchors its cone at the PLAYER's root and camera look, so
-- for this class alone the search was being run from a point the bullets do not
-- come out of. That is the third-person-camera-offset bug in a worse form: not
-- a 12-stud error but an arbitrary one, in position AND direction.
-- `lockFromBody = { "attack" }` switches this body to the origin the ally-echo
-- path and the mid-flight relock already use — the body's own position and
-- heading. Without it the class is not "slightly off", it locks nothing.
--
-- The cone stays at whatever the global is: the drone's own facing is a real
-- aim, so a strict cone measured from IT is meaningful. Widening the cone was
-- the wrong fix for the same reason it was wrong for MEDIC — the origin was
-- broken, not the aperture.
--
-- EXPECT: 4 bullets per cast on a 0.6s cooldown. That is a VOLLEY, not the
-- duplicate-projectile bug, and it is above the per-cast ally echo budget of 2
-- (Core.setMaxEchoesPerCast), so an ally CONTROLLER mirrors two of four until
-- that is raised. Raise the budget — do not loosen `allow`.
--
-- UNVERIFIED: every value above is from the ARCHIVE folder, not from a live
-- `SELF BODY` census — CONTROLLER is in the "STILL MISSING" list. Skins are the
-- known risk: the same listing shows a `ProjectileValentine` variant folder, so
-- if a cosmetic swaps the functional body names, `attack` stops matching and the
-- class silently does nothing. Play it once, read `CONTROLLER bodies:` at arm
-- time, and confirm.
--------------------------------------------------------------------------
Core.registerClass("CONTROLLER", {
    aliases = { "CONTROLLER" },     -- 0567.lua:348-349 (CLASS field)
    accept  = Core.gates.classProvenance,
    allow   = { "attack" },         -- ATK Combat-Shoot barrage, 4 x 5 dmg
    -- The barrage leaves the DRONE, not me. See the origin section above.
    lockFromBody = { "attack" },
    deny    = {
        "drone", "droneremove",     -- the pet itself: steering it flies the drone
        "dronemodel",               -- the model container
        "command",                  -- command*: anchored marker signals
        "ability1",                 -- AB1 Supply Pulse: anchored aura on the drone
        "ability2",                 -- AB2 EMP: marker-aimed + Disable + pierces
        "emp", "pulse", "supply",   -- same moves under any other spelling
        "hover", "teleport",        -- Movement-mode commands, nothing to steer
        "marker",                   -- the placement reticle
        "eff", "cosmetic", "visual", "model",
    },
})

-- Audits and logs the registration. Replaces a bare count, which could not tell
-- you that a class had no allow list or that a deny string was eating one of its
-- own allow entries -- both of which fail silently in play.
Core.auditClasses()

return true
]==]
ENGINE_PAYLOAD["cs_projectile_forge.lua"] = [==[
-- CRITICAL STRIKE — projectile forge v2
-- Re-inject safe: self-teardown on load; K = unload
-- J = fire | K = unload | __CS_PFORGE.exec('help')
-- Visible-speed pin (Heartbeat on ALL active). Docs: CS_PROJECTILE_FORGE.md
-- TARGETS: lobby PlaceId 8246089782 players OR AI/NPC; LOS + team/faint filters.
-- Examples: exec('preset musketeer') | exec('quality medium') | exec('list'|'scan')

local S = {
    alive = true, conns = {}, cm = nil,
    templatePath = "Classes.MUSKETEER.Projectile.attack",
    dmg = 50,
    speed = 100,
    range = 500,
    size = 8,
    track = true,
    vis = true,
    aim = "nearest",
    lifetime = 4,
    lastFire = 0,
    fireCooldown = 0.6,
    sprayCount = 1,
    sprayDegrees = 20,
    sprayMode = "fan",
    active = {},
    pending = {},
    hits = 0, misses = 0,
    fired = 0,
    preset = "musketeer",
}

local LOS_RECHECK_SEC = 0.1
local MOVER_MAX_FORCE = Vector3.new(1e7, 1e7, 1e7)
local LOCK_RANGE = 90
local LOCK_FOV_DEG = 35
local SPRAY_MAX_COUNT = 8
local SPRAY_STAGGER_SEC = 0.06
local CATALOG_REFRESH_DEBOUNCE = 0.5
local SCAN_LOG_CAP = 80

local PRESETS = {
    { key = "musketeer", path = "Classes.MUSKETEER.Projectile.attack",
      dmg = 50, speed = 110, range = 500, size = 6, track = true,
      note = "DEFAULT sniper bullet (Damage)." },
    { key = "gunner_crit", path = "Classes.GUNNER.Projectile.critical",
      dmg = 50, speed = 130, range = 500, size = 6, track = true,
      note = "TrueDamage, no rig dep." },
    { key = "gunner_attack", path = "Classes.GUNNER.Projectile.attack",
      dmg = 40, speed = 120, range = 400, size = 6, track = true,
      note = "needs GUNNER GunEmit off-class may inert." },
    { key = "fighter", path = "Classes.FIGHTER.Projectile.attack",
      dmg = 40, speed = 110, range = 400, size = 6, track = true,
      note = "fighter M1." },
    { key = "knight", path = "Classes.KNIGHT.Projectile.critical",
      dmg = 40, speed = 110, range = 400, size = 6, track = true,
      note = "critical bullet NOT attack (HRP weld slash)." },
    { key = "gambler", path = "Classes.GAMBLER.Projectile.attack",
      dmg = 40, speed = 120, range = 450, size = 6, track = true,
      note = "gambler card attack." },
    { key = "recon", path = "Classes.RECON.Projectile.attack",
      dmg = 40, speed = 120, range = 500, size = 5, track = true,
      note = "recon shot." },
    { key = "necro", path = "Classes.NECROMANCER.Projectile.attackBullet",
      dmg = 40, speed = 110, range = 450, size = 5, track = true,
      note = "necromancer bullet." },
    { key = "pumpkin", path = "SubClasses.PUMPKIN.Projectile.ability3",
      dmg = 30, speed = 90, range = 300, size = 6, track = true,
      risk = true,
      note = "RISK: handler TurkeyBurn rider — dmg-only intent, not recommended." },
    { key = "banana", path = "SubClasses.BANANDIUM.Projectile.testerbanana",
      dmg = 40, speed = 90, range = 400, size = 6, track = true,
      note = "StunLong in handler (class behavior)." },
    { key = "swordmancer", path = "Classes.SWORDMANCER.Projectile.attack",
      dmg = 40, speed = 110, range = 400, size = 6, track = true,
      note = "streams on LoadClass — exec('swordmancer') to bind." },
    { key = "swordmancer_c", path = "Classes.SWORDMANCER.Projectile.critical",
      dmg = 40, speed = 110, range = 400, size = 6, track = true,
      note = "critical path — exec('swordmancer') lists children." },
    { key = "infernus_bouncer", path = "ChristmasProjectiles.AIsAttack.Infernus.Bouncer",
      dmg = 35, speed = 100, range = 400, size = 6, track = false,
      sprayCount = 5, sprayDegrees = 28,
      note = "Infernus bolt — no client burn riders." },
}

local FIRE_KEY, KILL_KEY = Enum.KeyCode.J, Enum.KeyCode.K
local CATALOG = {}
local catalogRefreshScheduled = false

local Log = (function()
    local ok, L = pcall(function() return loadfile("log.lua")()("cs_pforge") end)
    if ok and L then return L end
    return {
        info = function(m) print("[PForge] " .. tostring(m)) end,
        warn = function(m) warn("[PForge] " .. tostring(m)) end,
        err  = function(m) warn("[PForge] " .. tostring(m)) end,
    }
end)()

local t0 = os.clock()
local function stamp() return string.format("%7.3f", os.clock() - t0) end
local function LOG(tag, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    Log.info(("[%s][%s] %s"):format(stamp(), tag, msg))
end
local function WARN(tag, fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    Log.warn(("[%s][%s] %s"):format(stamp(), tag, msg))
end

local G = getgenv()
local GKEY = "__CS_PFORGE"
if G[GKEY] and type(G[GKEY].destroy) == "function" then
    pcall(G[GKEY].destroy)
end

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local RS         = game:GetService("ReplicatedStorage")
local Debris     = game:GetService("Debris")
local lp         = Players.LocalPlayer

local function conn(sig, fn)
    local c = sig:Connect(fn)
    table.insert(S.conns, c)
    return c
end

local function canApplyProjectileSize(part)
    if not part or not part:IsA("BasePart") then return false end
    if part:IsA("MeshPart") or part:IsA("UnionOperation") then return false end
    if part:FindFirstChildOfClass("SpecialMesh") then return false end
    return part:IsA("Part") or part:IsA("WedgePart") or part:IsA("CornerWedgePart")
        or part:IsA("TrussPart") or part:IsA("SpawnLocation")
end

local function char()
    local c = lp.Character
    if not c or not c.Parent then return nil end
    return c
end

local function hrp()
    local c = char(); if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart")
end

local function statsHP(c)
    local st = c and c:FindFirstChild("Stats")
    local v  = st and st:FindFirstChild("CurrentHP")
    return v and v.Value or nil
end

local function myClass()
    local c = char()
    local cc = c and c:FindFirstChild("CurrentClass")
    return cc and cc.Value or "none"
end

local function isFainted(c)
    if not c then return true end
    if c:GetAttribute("Fainted") == true then return true end
    local fv = c:FindFirstChild("Fainted")
    if fv and fv:IsA("BoolValue") and fv.Value then return true end
    local st = c:FindFirstChild("Stats")
    local sf = st and st:FindFirstChild("Fainted")
    if sf and sf:IsA("BoolValue") and sf.Value then return true end
    return false
end

local function sameTeam(aChar, bChar)
    if not aChar or not bChar then return false end
    local at = aChar:FindFirstChild("Team")
    local bt = bChar:FindFirstChild("Team")
    if at and bt and at:IsA("StringValue") and bt:IsA("StringValue") then
        return at.Value == bt.Value
    end
    local ap = Players:GetPlayerFromCharacter(aChar)
    local bp = Players:GetPlayerFromCharacter(bChar)
    if ap and bp and ap.Team == bp.Team and ap.Team ~= nil and ap.Neutral ~= true then
        return true
    end
    return false
end

local function isFriendlyDummy(c)
    local fd = c and c:FindFirstChild("FriendlyDummy")
    return fd ~= nil and fd:IsA("BoolValue")
end

local function isAIOrNpc(c)
    if not c or isFriendlyDummy(c) then return false end
    if c:FindFirstChild("AI") or c:FindFirstChild("Dummy") then return true end
    local n = c
    while n and n ~= game do
        local name = n.Name
        if name == "NPC's" or name == "NPCs" or name == "AIs"
            or name == "Dummys" or name == "Dummies" then
            return true
        end
        n = n.Parent
    end
    if Players:GetPlayerFromCharacter(c) == nil
        and c:FindFirstChildOfClass("Humanoid")
        and c:FindFirstChild("HumanoidRootPart") then
        return true
    end
    return false
end

local CS_LOBBY_PLACE_ID = 8246089782

local function inLobbyPlace()
    return game.PlaceId == CS_LOBBY_PLACE_ID
end

local function isAllowedTarget(c)
    if isAIOrNpc(c) then return true end
    local plr = Players:GetPlayerFromCharacter(c)
    if not plr then return false end
    return inLobbyPlace()
end

local function isValidOpponent(c)
    if not c or not c.Parent then return false end
    if c == char() then return false end
    if not isAllowedTarget(c) then return false end
    if isFriendlyDummy(c) then return false end
    local mc = char()
    if mc and sameTeam(mc, c) then return false end
    if isFainted(c) then return false end
    local hp = statsHP(c)
    if hp ~= nil and hp <= 0 then return false end
    local hum = c:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health <= 0 then return false end
    return c:FindFirstChild("HumanoidRootPart") ~= nil
end

local function losExcludeInstances(myChar, tgtChar)
    local list = {}
    if myChar then list[#list + 1] = myChar end
    if tgtChar then list[#list + 1] = tgtChar end
    local cp = workspace:FindFirstChild("ClientProjectiles")
    if cp then list[#list + 1] = cp end
    local ce = workspace:FindFirstChild("ClientEffects")
    if ce then list[#list + 1] = ce end
    local cg = workspace:FindFirstChild("ClientProjectileGhost")
    if cg then list[#list + 1] = cg end
    return list
end

local function targetAimPart(c)
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart")
        or c:FindFirstChild("UpperTorso")
        or c:FindFirstChild("Torso")
end

local function hasClearLos(fromPos, tgtChar, myChar)
    if not fromPos or not tgtChar or not tgtChar.Parent then return false end
    local aim = targetAimPart(tgtChar)
    if not aim then return false end
    local delta = aim.Position - fromPos
    local dist = delta.Magnitude
    if dist < 0.5 then return true end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = losExcludeInstances(myChar, tgtChar)
    params.IgnoreWater = true
    params.RespectCanCollide = true
    local hit = workspace:Raycast(fromPos, delta.Unit * dist, params)
    return hit == nil
end

local function resolvePath(path)
    local node = RS
    for seg in tostring(path):gmatch("[^%.]+") do
        node = node and node:FindFirstChild(seg)
        if not node then return nil, seg end
    end
    return node
end

local function isForgeable(inst)
    return typeof(inst) == "Instance"
        and inst:IsA("BasePart")
        and inst:FindFirstChild("ProjectileHandler") ~= nil
end

local function isFreeBullet(inst)
    if not isForgeable(inst) then return false end
    if inst:FindFirstChild("CFrameOffset") then return false end
    local spd = inst:FindFirstChild("Speed")
    local rng = inst:FindFirstChild("Range")
    if not (spd and rng) then return false end
    return true
end

local function catalogTags(path, name)
    local tags = { free = true }
    local blob = (path .. "." .. name):lower()
    if blob:find("testerbanana", 1, true) or blob:find("ability3", 1, true)
        or blob:find("pumpkin", 1, true) or blob:find("burninfernus", 1, true) then
        tags.effect_risk = true
    end
    if path:find("^Classes%.", 1) then
        tags.stream = true
    end
    return tags
end

local function scanAvailable()
    local out = {}
    local function walkRoot(rootName)
        local root = RS:FindFirstChild(rootName)
        if not root then return end
        for _, classFolder in ipairs(root:GetChildren()) do
            local proj = classFolder:FindFirstChild("Projectile")
            if proj then
                for _, child in ipairs(proj:GetChildren()) do
                    if isFreeBullet(child) then
                        local path = rootName .. "." .. classFolder.Name .. ".Projectile." .. child.Name
                        out[#out + 1] = {
                            path = path,
                            class = classFolder.Name,
                            name = child.Name,
                            inst = child,
                            tags = catalogTags(path, child.Name),
                        }
                    end
                end
            end
        end
    end
    walkRoot("Classes")
    walkRoot("SubClasses")
    local xmas = RS:FindFirstChild("ChristmasProjectiles")
    local aiAtk = xmas and xmas:FindFirstChild("AIsAttack")
    if aiAtk then
        for _, bossFolder in ipairs(aiAtk:GetChildren()) do
            for _, child in ipairs(bossFolder:GetChildren()) do
                if isFreeBullet(child) then
                    local path = "ChristmasProjectiles.AIsAttack." .. bossFolder.Name .. "." .. child.Name
                    out[#out + 1] = {
                        path = path,
                        class = bossFolder.Name,
                        name = child.Name,
                        inst = child,
                        tags = catalogTags(path, child.Name),
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.class == b.class then return a.name < b.name end
        return a.class < b.class
    end)
    return out
end

local function refreshCatalog(forceLog)
    CATALOG = scanAvailable()
    if forceLog then
        LOG("CATALOG", "refreshed %d free-bullet paths", #CATALOG)
    end
    return CATALOG
end

local function scheduleCatalogRefresh()
    if catalogRefreshScheduled or not S.alive then return end
    catalogRefreshScheduled = true
    task.delay(CATALOG_REFRESH_DEBOUNCE, function()
        catalogRefreshScheduled = false
        if S.alive then refreshCatalog(true) end
    end)
end

local function weldedToMyCharacter(proj)
    local mc = char()
    if not mc or not proj then return false end
    local function touchesChar(part)
        return part and typeof(part) == "Instance" and part:IsDescendantOf(mc)
    end
    for _, w in ipairs(proj:GetChildren()) do
        if w:IsA("Weld") or w:IsA("Motor6D") then
            if touchesChar(w.Part0) or touchesChar(w.Part1) then return true end
        elseif w:IsA("WeldConstraint") then
            if touchesChar(w.Part0) or touchesChar(w.Part1) then return true end
        end
    end
    local ok, joints = pcall(function() return proj:GetJoints() end)
    if ok and joints then
        for _, w in ipairs(joints) do
            if w:IsA("Weld") or w:IsA("Motor6D") or w:IsA("WeldConstraint") then
                if touchesChar(w.Part0) or touchesChar(w.Part1) then return true end
            end
        end
    end
    return false
end

local function bindTemplate(path, presetKey, requireFree)
    local node, miss = resolvePath(path)
    if not node then return false, miss or "missing" end
    if requireFree ~= false then
        if not isFreeBullet(node) then
            return false, "not free bullet (slash/weld VFX?)"
        end
    elseif not isForgeable(node) then
        return false, "no ProjectileHandler"
    end
    S.templatePath = path
    if presetKey then S.preset = presetKey end
    return true
end

local function waitClassProjectileFolder(className, timeout)
    local classes = RS:FindFirstChild("Classes")
    if not classes then return nil end
    local folder = classes:FindFirstChild(className)
    if not folder then
        local ok, got = pcall(function()
            return classes:WaitForChild(className, timeout or 15)
        end)
        if not (ok and got) then return nil end
        folder = got
    end
    local proj = folder:FindFirstChild("Projectile")
    if proj then return proj end
    local ok2, got2 = pcall(function()
        return folder:WaitForChild("Projectile", 5)
    end)
    return (ok2 and got2) or nil
end

local function bindStreamedClass(className, presetKey, defaults, preferName)
    defaults = defaults or {}
    LOG("STREAM", "waiting for RS.Classes.%s (LoadClass stream, up to 15s)...", className)
    local projFolder = waitClassProjectileFolder(className, 15)
    if not projFolder then
        WARN("STREAM", "%s not replicated — pick that class so LoadClass fires", className)
        return false
    end
    LOG("STREAM", "%s.Projectile children:", className)
    local freeHit, preferHit = nil, nil
    if preferName and preferName ~= "" then
        for _, child in ipairs(projFolder:GetChildren()) do
            if child.Name == preferName and isFreeBullet(child) then
                preferHit = {
                    path = "Classes." .. className .. ".Projectile." .. child.Name,
                    name = child.Name, rank = 0,
                }
                break
            end
        end
    end
    local prefer = { attack = 1, critical = 2, ability1 = 3, ability2 = 4, attack1 = 5, attackBullet = 6 }
    for _, child in ipairs(projFolder:GetChildren()) do
        local free = isFreeBullet(child)
        local forge = isForgeable(child)
        LOG("STREAM", "  %-24s forgeable=%s free=%s offset=%s",
            child.Name, tostring(forge), tostring(free),
            tostring(child:FindFirstChild("CFrameOffset") ~= nil))
        if free then
            local path = "Classes." .. className .. ".Projectile." .. child.Name
            freeHit = freeHit or { path = path, name = child.Name }
            local rank = prefer[child.Name]
            if rank and (not preferHit or rank < preferHit.rank) then
                preferHit = { path = path, name = child.Name, rank = rank }
            end
        end
    end
    local hit = preferHit or freeHit
    if not hit then
        WARN("STREAM", "%s has Projectile folder but no FREE bullet", className)
        return false
    end
    S.preset = presetKey or ("auto_" .. className:lower())
    S.templatePath = hit.path
    if defaults.dmg ~= nil then S.dmg = defaults.dmg end
    if defaults.speed ~= nil then S.speed = defaults.speed end
    if defaults.range ~= nil then S.range = defaults.range end
    if defaults.size ~= nil then S.size = defaults.size end
    if defaults.track ~= nil then S.track = defaults.track end
    LOG("STREAM", "bound %s -> %s", S.preset, hit.path)
    return true
end

local function findPreset(key)
    key = tostring(key):lower()
    if key == "pumpkin_burn" then key = "pumpkin" end
    for _, p in ipairs(PRESETS) do
        if p.key == key then return p end
    end
    return nil
end

local function pathAvailability(path)
    path = tostring(path or "")
    if path == "" then return "MISS", "empty path" end
    local node, miss = resolvePath(path)
    if not node then
        if path:find("SWORDMANCER", 1, true) then
            return "STREAM", "SWORDMANCER not in RS — pick class (LoadClass)"
        end
        if path:find("^ChristmasProjectiles", 1) then
            return "MISS", "ChristmasProjectiles not in RS"
        end
        if path:find("^Classes%.", 1) or path:find("^SubClasses%.", 1) then
            return "MISS", "RS missing " .. tostring(miss) .. " (match / LoadClass)"
        end
        return "MISS", "missing segment " .. tostring(miss)
    end
    if isFreeBullet(node) then return "LIVE", nil end
    if isForgeable(node) then
        return "SLASH", "weld/CFrameOffset — not free bullet"
    end
    return "MISS", "no ProjectileHandler on instance"
end

local function applyQuality(tier)
    tier = tostring(tier or ""):lower()
    if tier == "slow" then
        S.speed, S.size, S.track = 90, 6, false
    elseif tier == "medium" then
        S.speed, S.size, S.track = 120, 6, true
    elseif tier == "fast" then
        S.speed, S.size, S.track = 220, 8, true
    else
        WARN("QUALITY", "use slow | medium | fast")
        return false
    end
    LOG("QUALITY", "%s -> spd=%s size=%s track=%s", tier, tostring(S.speed), tostring(S.size), tostring(S.track))
    return true
end

local function applyPreset(key)
    local p = findPreset(key)
    if not p then
        WARN("PRESET", "unknown '%s' — run 'list'", tostring(key))
        return false, "unknown preset '" .. tostring(key) .. "'"
    end
    if p.risk then
        WARN("PRESET", "RISK preset '%s' — handler may apply effects; forge does not add riders", p.key)
    end
    local node = resolvePath(p.path)
    if node and isFreeBullet(node) then
        S.preset = p.key
        S.templatePath = p.path
        S.dmg, S.speed, S.range, S.size, S.track = p.dmg, p.speed, p.range, p.size, p.track
        S.sprayCount = p.sprayCount ~= nil and p.sprayCount or 1
        S.sprayDegrees = p.sprayDegrees ~= nil and p.sprayDegrees or 20
        LOG("PRESET", "%s -> %s  dmg=%s spd=%s rng=%s size=%s  (%s)",
            p.key, p.path, tostring(p.dmg), tostring(p.speed), tostring(p.range),
            tostring(p.size), p.note)
        return true
    end
    if p.path:find("SWORDMANCER", 1, true) then
        local preferName = p.path:match("%.Projectile%.([^%.]+)$")
        if bindStreamedClass("SWORDMANCER", p.key, {
            dmg = p.dmg, speed = p.speed, range = p.range, size = p.size, track = p.track,
        }, preferName) then
            return true
        end
        return false, "[STREAM] SWORDMANCER not loaded — pick class in match"
    end
    local stat, detail = pathAvailability(p.path)
    local msg = string.format("[%s] %s", stat, detail or p.path)
    WARN("PRESET", "%s %s — %s", p.key, stat, detail or p.path)
    return false, msg
end

local function ensureTemplate()
    if S.templatePath and S.templatePath ~= "" then
        if bindTemplate(S.templatePath, S.preset ~= "custom" and S.preset or nil, true) then
            return true
        end
        if S.preset == "swordmancer" or S.preset == "swordmancer_c"
            or (S.templatePath:find("SWORDMANCER", 1, true)) then
            if bindStreamedClass("SWORDMANCER", "swordmancer", {
                dmg = 40, speed = 110, range = 400, size = 6, track = true,
            }) then
                return true
            end
        end
    end

    for _, p in ipairs(PRESETS) do
        if not p.risk and bindTemplate(p.path, p.key, true) then
            S.dmg, S.speed, S.range, S.size, S.track =
                p.dmg, p.speed, p.range, p.size, p.track
            LOG("AUTO", "bound live preset %s -> %s", p.key, p.path)
            return true
        end
    end

    local cls = myClass()
    if cls and cls ~= "none" then
        if tostring(cls):upper() == "SWORDMANCER" then
            if bindStreamedClass("SWORDMANCER", "swordmancer", {
                dmg = 40, speed = 110, range = 400, size = 6, track = true,
            }) then
                return true
            end
        end
        for _, name in ipairs({ "critical", "attackBullet", "attacka", "attackb", "attack" }) do
            local path = "Classes." .. cls .. ".Projectile." .. name
            if bindTemplate(path, "auto_" .. cls:lower(), true) then
                LOG("AUTO", "bound current-class %s", path)
                return true
            end
        end
    end

    refreshCatalog(false)
    if #CATALOG > 0 then
        local hit = CATALOG[1]
        S.templatePath = hit.path
        S.preset = "auto_scan"
        LOG("AUTO", "bound first catalog entry %s", hit.path)
        return true
    end

    WARN("AUTO", "NO free-bullet template — try exec('scan') after LoadClass")
    return false
end

local function requireCM()
    if S.cm then return S.cm end
    local ok, m = pcall(function()
        return require(RS:WaitForChild("Modules", 5):WaitForChild("ClassModule", 5))
    end)
    if ok and m then S.cm = m; return m end
    WARN("INIT", "ClassModule require FAILED: %s", tostring(m))
    return nil
end

local function forEachCandidate(fn)
    local seen = {}
    local function consider(model)
        if not model or seen[model] then return end
        if not model:IsA("Model") then return end
        seen[model] = true
        fn(model)
    end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then consider(p.Character) end
    end
    for _, folderName in ipairs({ "NPC's", "NPCs", "AIs", "Dummys", "Dummies" }) do
        local folder = workspace:FindFirstChild(folderName)
        if folder then
            for _, ch in ipairs(folder:GetChildren()) do consider(ch) end
        end
    end
    for _, ch in ipairs(workspace:GetChildren()) do
        if ch:IsA("Model") and (ch:FindFirstChild("AI") or ch:FindFirstChild("Dummy")) then
            consider(ch)
        end
    end
end

local function getLockAimOrigin()
    local cam = workspace.CurrentCamera
    if cam then
        return cam.CFrame.Position, cam.CFrame.LookVector
    end
    local h = hrp()
    if h then
        return h.Position, h.CFrame.LookVector
    end
    return nil, nil
end

local function lockRangeCap(maxDist)
    local cap = LOCK_RANGE
    if maxDist and maxDist > 0 then
        cap = math.min(maxDist, LOCK_RANGE)
    end
    return cap
end

local function pickLookLockTarget(maxDist)
    local fromPos, look = getLockAimOrigin()
    if not fromPos or not look or look.Magnitude < 1e-6 then return nil, nil end
    look = look.Unit
    local cap = lockRangeCap(maxDist or tonumber(S.range))
    local mc = char()

    local bestLosAng, bestLosDist, bestLos = math.huge, math.huge, nil
    local bestConeAng, bestConeDist, bestCone = math.huge, math.huge, nil
    local bestNearDist, bestNear = cap * 0.5, nil

    forEachCandidate(function(c)
        if not isValidOpponent(c) then return end
        local ph = c:FindFirstChild("HumanoidRootPart")
        if not ph then return end
        local dir = ph.Position - fromPos
        local dist = dir.Magnitude
        if dist <= 0.5 or dist > cap then return end
        local ang = math.deg(math.acos(math.clamp(look:Dot(dir.Unit), -1, 1)))
        if ang > LOCK_FOV_DEG then
            return
        end
        if ang < bestConeAng or (math.abs(ang - bestConeAng) < 1e-4 and dist < bestConeDist) then
            bestConeAng, bestConeDist, bestCone = ang, dist, c
        end
        if hasClearLos(fromPos, c, mc) then
            if ang < bestLosAng or (math.abs(ang - bestLosAng) < 1e-4 and dist < bestLosDist) then
                bestLosAng, bestLosDist, bestLos = ang, dist, c
            end
        end
    end)

    if bestLos then
        LOG("AIM", "track lock %s ang=%.1f dist=%.1f", bestLos.Name, bestLosAng, bestLosDist)
        return bestLos, bestLosDist
    end
    if bestCone then
        LOG("AIM", "track lock %s ang=%.1f dist=%.1f (no-LOS)", bestCone.Name, bestConeAng, bestConeDist)
        return bestCone, bestConeDist
    end
    return nil, nil
end

local function nearestEnemy(maxDist)
    return pickLookLockTarget(maxDist)
end

local function characterFromRayHit(inst)
    if not inst then return nil end
    local model = inst:FindFirstAncestorOfClass("Model")
    if model and isValidOpponent(model) then return model end
    return nil
end

local function aimTargetFromCursor()
    local cam = workspace.CurrentCamera
    local h = hrp()
    if not cam or not h then return nil, nil end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = losExcludeInstances(char(), nil)
    params.IgnoreWater = true
    params.RespectCanCollide = true
    local ray = cam:ScreenPointToRay(cam.ViewportSize.X * 0.5, cam.ViewportSize.Y * 0.5)
    local hit = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
    if hit then
        local tgt = characterFromRayHit(hit.Instance)
        if tgt then return tgt, (tgt:FindFirstChild("HumanoidRootPart").Position - h.Position).Magnitude end
    end
    return nil, nil
end

local function resolveFireTarget()
    local mode = tostring(S.aim or "nearest"):lower()
    if mode == "forward" then return nil, nil end
    if mode == "cursor" then return aimTargetFromCursor() end
    return nearestEnemy()
end

local function armIndicator()
    local ind = RS:FindFirstChild("Remotes") and RS.Remotes:FindFirstChild("DamageIndicator")
    if not ind then
        WARN("INIT", "DamageIndicator NOT FOUND")
        return
    end
    conn(ind.OnClientEvent, function(payload)
        if type(payload) ~= "table" then return end
        local dealer, victim, amount, kind = payload[1], payload[2], payload[3], payload[4]
        local mine = (dealer == lp) or (dealer == char())
        if not mine then return end
        local vname = typeof(victim) == "Instance" and victim.Name or tostring(victim)
        LOG("SERVER-OK", "dealer=SELF victim=%s amount=%s kind=%s", vname, tostring(amount), tostring(kind))
        S.hits = S.hits + 1
        for amt, rec in pairs(S.pending) do
            if math.abs((tonumber(amount) or -1) - amt) < 0.001 then
                LOG("CONFIRM", "matched pending %.3f after %.3fs", amt, os.clock() - rec.t)
                S.pending[amt] = nil
            end
        end
    end)
    LOG("INIT", "DamageIndicator armed")
end

local function projSpeed(proj)
    local s = tonumber(S.speed)
    if not s or s ~= s or s <= 0 then
        local v = proj and proj:FindFirstChild("Speed")
        s = v and tonumber(v.Value) or nil
    end
    if not s or s ~= s or s <= 0 then s = 100 end
    return math.clamp(s, 40, 500)
end

local MUZZLE_Z = -3

local function aimOrigin(targetChar)
    local h = hrp()
    if not h then return nil end

    local cm = requireCM()
    local base
    if cm and type(cm.CharCF) == "function" then
        local ok, cf = pcall(function() return cm:CharCF() end)
        if ok and typeof(cf) == "CFrame" then base = cf end
    end
    if not base then
        local cam = workspace.CurrentCamera
        if cam then
            local flat = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
            if flat.Magnitude > 1e-3 then
                base = CFrame.new(h.Position, h.Position + flat.Unit)
            end
        end
    end
    if not base then base = h.CFrame end

    local origin = base * CFrame.new(0, 0, MUZZLE_Z)
    if targetChar then
        local th = targetChar:FindFirstChild("HumanoidRootPart")
        if th and th.Parent then
            local muzzle = origin.Position
            local goal = th.Position
            if (goal - muzzle).Magnitude > 1e-3 then
                origin = CFrame.lookAt(muzzle, goal)
            end
        end
    end
    return origin
end

local function ensureMover(proj, speed, look)
    if not proj or not proj.Parent then return nil end
    pcall(function()
        proj.Anchored = false
        proj.CanCollide = false
    end)
    local bv = proj:FindFirstChildOfClass("BodyVelocity")
    local lv = proj:FindFirstChildWhichIsA("LinearVelocity", true)
    look = look or proj.CFrame.LookVector
    speed = speed or projSpeed(proj)
    local vel = look * speed

    local function silenceBodyVelocity()
        if not bv then return end
        if bv.Name == "PForgeBV" then
            pcall(function() bv:Destroy() end)
            bv = nil
        else
            pcall(function()
                bv.Velocity = Vector3.zero
                bv.MaxForce = Vector3.zero
            end)
        end
    end

    local function silenceLinearVelocity()
        if not lv then return end
        pcall(function()
            lv.VectorVelocity = Vector3.zero
            lv.MaxAxesForce = Vector3.zero
        end)
    end

    if lv then
        silenceBodyVelocity()
        pcall(function()
            lv.VectorVelocity = vel
            lv.MaxAxesForce = MOVER_MAX_FORCE
        end)
        return lv
    end
    if bv then
        silenceLinearVelocity()
        bv.Velocity = vel
        bv.MaxForce = MOVER_MAX_FORCE
        return bv
    end
    local ok, created = pcall(function()
        local n = Instance.new("BodyVelocity")
        n.Name = "PForgeBV"
        n.Velocity = vel
        n.MaxForce = MOVER_MAX_FORCE
        n.Parent = proj
        return n
    end)
    return ok and created or nil
end

local function pinSpeedValue(proj)
    pcall(function()
        local sv = proj:FindFirstChild("Speed")
        if sv then sv.Value = projSpeed(proj) end
    end)
end

local function applyForgeVis(proj)
    if S.vis == false or not proj then return end
    pcall(function()
        if proj.Transparency > 0.15 then proj.Transparency = 0.15 end
        proj.Material = Enum.Material.Neon
    end)
    if not proj:FindFirstChild("PForgeLight") then
        pcall(function()
            local pl = Instance.new("PointLight")
            pl.Name = "PForgeLight"
            pl.Brightness = 0.6
            pl.Range = 8
            pl.Parent = proj
        end)
    end
end

local function registerActive(proj, rec)
    S.active[proj] = rec
end

local function updateActiveProjectiles()
    if not S.alive then return end
    local now = os.clock()
    local mc = char()
    for proj, rec in pairs(S.active) do
        if not proj or not proj.Parent then
            S.active[proj] = nil
        elseif weldedToMyCharacter(proj) then
            WARN("ACTIVE", "drop welded-to-self projectile")
            S.active[proj] = nil
        elseif now - rec.spawnT >= S.lifetime then
            pcall(function() proj:Destroy() end)
            S.active[proj] = nil
        else
            pcall(function()
                proj.CanCollide = false
                proj.Anchored = false
            end)
            pinSpeedValue(proj)
            local look = rec.originLook
            if rec.track and rec.target and isValidOpponent(rec.target) then
                if now - rec.lastLos >= LOS_RECHECK_SEC then
                    rec.lastLos = now
                    if not hasClearLos(proj.Position, rec.target, mc) then
                        LOG("ACTIVE", "drop lock — LOS blocked")
                        rec.target = nil
                    end
                end
                if rec.target then
                    local th = rec.target:FindFirstChild("HumanoidRootPart")
                    if th and th.Parent then
                        local delta = th.Position - proj.Position
                        if delta.Magnitude > 1e-3 then look = delta.Unit end
                    else
                        rec.target = nil
                    end
                end
            end
            ensureMover(proj, projSpeed(proj), look)
        end
    end
end

local function logShotVerify(proj)
    local sv = proj and proj:FindFirstChild("Speed")
    local svNum = sv and tonumber(sv.Value) or -1
    local mag = -1
    local bv = proj and proj:FindFirstChildOfClass("BodyVelocity")
    if bv then mag = bv.Velocity.Magnitude end
    if mag < 0 then
        local lv = proj and proj:FindFirstChildWhichIsA("LinearVelocity", true)
        if lv then mag = lv.VectorVelocity.Magnitude end
    end
    LOG("VERIFY", "Speed.Value=%s BVmag=%.1f S.speed=%s", tostring(svNum), mag, tostring(S.speed))
end

local function applyPartSize(proj, sz, quiet)
    if not sz or sz <= 0 then return end
    if canApplyProjectileSize(proj) then
        local oks = pcall(function()
            proj.Size = Vector3.new(math.min(sz, 8), math.min(sz, 8), math.max(sz * 1.5, 8))
        end)
        if not quiet then LOG("SIZE", "set=%s ok=%s", tostring(sz), tostring(oks)) end
    elseif not quiet then
        LOG("SIZE", "skip resize class=%s", proj.ClassName)
    end
end

local function forgeProjectile(targetChar, origin, fireOpts)
    fireOpts = fireOpts or {}
    local h = hrp()
    if not h then WARN("FIRE", "no HumanoidRootPart"); return false end

    if not ensureTemplate() then
        WARN("FIRE", "no live template")
        return false
    end

    local tpl, missing = resolvePath(S.templatePath)
    if not tpl then
        WARN("FIRE", "template NOT FOUND: %s seg=%s", S.templatePath, tostring(missing))
        return false
    end
    if not isFreeBullet(tpl) then
        WARN("FIRE", "refusing non-free bullet %s", S.templatePath)
        return false
    end

    local cm = requireCM()
    if not cm or not cm.CreateProjectile then
        WARN("FIRE", "no CreateProjectile")
        return false
    end

    origin = origin or aimOrigin(targetChar)
    if not origin then WARN("FIRE", "no aim origin"); return false end

    local col
    pcall(function()
        local wc = lp:FindFirstChild("CharacterColors")
        col = wc and wc:FindFirstChild("WeaponColor") and wc.WeaponColor.Value
    end)

    local options
    if S.dmg ~= nil or S.speed ~= nil or S.range ~= nil then
        options = {}
        if S.dmg ~= nil then options.Damage = S.dmg end
        if S.speed ~= nil then options.Speed = S.speed end
        if S.range ~= nil then options.Range = S.range end
    end

    local okc, projOrErr = pcall(function()
        return cm:CreateProjectile(tpl, origin, col, nil, nil, nil, options)
    end)
    if not okc then
        WARN("FIRE", "CreateProjectile THREW: %s", tostring(projOrErr))
        return false
    end

    local proj = projOrErr
    if typeof(proj) ~= "Instance" or not proj:IsA("BasePart") then
        WARN("FIRE", "bad return: %s", tostring(proj))
        if typeof(proj) == "Instance" then pcall(function() proj:Destroy() end) end
        return false
    end

    pcall(function()
        proj.Anchored = false
        proj.CFrame = origin
    end)

    pinSpeedValue(proj)
    applyPartSize(proj, tonumber(S.size), fireOpts.quiet)
    applyForgeVis(proj)

    local speed = projSpeed(proj)
    local look = origin.LookVector
    ensureMover(proj, speed, look)
    logShotVerify(proj)

    local doTrack = fireOpts.track
    if doTrack == nil then doTrack = S.track end
    if doTrack and targetChar and isValidOpponent(targetChar)
        and hasClearLos(h.Position, targetChar, char()) then
        -- tracked via shared Heartbeat
    elseif doTrack and targetChar and not fireOpts.quiet then
        LOG("TRACK", "no steer — target lost LOS at fire")
        targetChar = nil
        doTrack = false
    end

    registerActive(proj, {
        target = (doTrack and targetChar) or nil,
        originLook = look,
        spawnT = os.clock(),
        lastLos = 0,
        track = doTrack and targetChar ~= nil,
    })

    S.fired = S.fired + 1
    if S.dmg then S.pending[S.dmg] = { t = os.clock(), victim = targetChar } end

    if not fireOpts.quiet then
        LOG("FIRE", "proj=%s tpl=%s spd=%s look=%s track=%s",
            proj.Name, S.templatePath, tostring(speed), tostring(look), tostring(doTrack))
    end

    task.delay(S.lifetime + 1, function()
        S.active[proj] = nil
        pcall(function() if proj and proj.Parent then proj:Destroy() end end)
    end)

    return true
end

local function forge(targetChar)
    local now = os.clock()
    if now - S.lastFire < S.fireCooldown then
        WARN("FIRE", "cooldown %.2fs left", S.fireCooldown - (now - S.lastFire))
        return false
    end

    local count = math.clamp(math.floor(tonumber(S.sprayCount) or 1), 1, SPRAY_MAX_COUNT)
    local baseOrigin = aimOrigin(targetChar)
    if not baseOrigin then WARN("FIRE", "no aim origin"); return false end

    S.lastFire = now

    if count <= 1 then
        return forgeProjectile(targetChar, baseOrigin)
    end

    local spreadDeg = math.abs(tonumber(S.sprayDegrees) or 20)
    local halfSpread = math.rad(spreadDeg * 0.5)
    local mode = tostring(S.sprayMode or "fan"):lower()
    local okAny = false
    LOG("SPRAY", "n=%d spread=%.1fdeg mode=%s", count, spreadDeg, mode)
    for i = 1, count do
        if not S.alive then break end
        local origin = baseOrigin
        if mode == "parallel" then
            local jx = (math.random() - 0.5) * 0.35
            local jy = (math.random() - 0.5) * 0.25
            origin = baseOrigin * CFrame.new(jx, jy, 0)
        else
            local yaw = -halfSpread + (halfSpread * 2) * ((i - 1) / (count - 1))
            local pitch = (math.random() - 0.5) * math.rad(4)
            origin = baseOrigin * CFrame.Angles(pitch, yaw, 0)
        end
        if forgeProjectile(targetChar, origin, { quiet = true, track = false }) then
            okAny = true
        end
        if i < count then task.wait(SPRAY_STAGGER_SEC) end
    end
    return okAny
end

local function fireAtNearest()
    local tgt, dist = resolveFireTarget()
    local hpBefore = tgt and statsHP(tgt) or nil

    LOG("SHOT", "#%d class=%s preset=%s aim=%s tpl=%s target=%s dist=%s hp=%s dmg=%s spd=%s track=%s",
        S.fired + 1, myClass(), S.preset, tostring(S.aim), S.templatePath,
        tgt and tgt.Name or "NONE",
        dist and string.format("%.1f", dist) or "-",
        tostring(hpBefore), tostring(S.dmg), tostring(S.speed), tostring(S.track))

    if not tgt and S.aim ~= "forward" then
        WARN("SHOT", "no target — firing forward")
    end

    local ok = forge(tgt)
    if not ok then S.misses = S.misses + 1; return end

    if tgt and hpBefore then
        task.delay(1.0, function()
            if not S.alive then return end
            local after = statsHP(tgt)
            if after and after ~= hpBefore then
                LOG("HP-DELTA", "%s %s -> %s (delta %s)",
                    tgt.Name, tostring(hpBefore), tostring(after), tostring(hpBefore - after))
            else
                LOG("HP-DELTA", "%s no change (%s)", tgt.Name, tostring(after))
            end
        end)
    end
end

local function previewTemplate()
    if not ensureTemplate() then return false end
    local tpl = resolvePath(S.templatePath)
    if not tpl or not isFreeBullet(tpl) then
        WARN("PREVIEW", "no free bullet at %s", tostring(S.templatePath))
        return false
    end
    local origin = aimOrigin(nil)
    if not origin then return false end
    local folder = workspace:FindFirstChild("ClientProjectiles") or workspace
    local clone = tpl:Clone()
    for _, d in ipairs(clone:GetDescendants()) do
        if d.Name == "ProjectileHandler" and (d:IsA("Script") or d:IsA("LocalScript")) then
            pcall(function() d:Destroy() end)
        end
    end
    local ph = clone:FindFirstChild("ProjectileHandler")
    if ph and (ph:IsA("Script") or ph:IsA("LocalScript")) then
        pcall(function() ph:Destroy() end)
    end
    clone.Anchored = true
    clone.CanCollide = false
    clone.CFrame = origin
    applyPartSize(clone, tonumber(S.size), true)
    applyForgeVis(clone)
    clone.Parent = folder
    Debris:AddItem(clone, 2)
    LOG("PREVIEW", "2s visual at muzzle — no damage")
    return true
end

local function report()
    local nActive = 0
    for _ in pairs(S.active) do nActive = nActive + 1 end
    LOG("REPORT", "fired=%d serverOK=%d forgeFail=%d class=%s active=%d catalog=%d",
        S.fired, S.hits, S.misses, myClass(), nActive, #CATALOG)
    local n = 0
    for amt, rec in pairs(S.pending) do
        n = n + 1
        LOG("REPORT", "  UNCONFIRMED dmg=%.3f age=%.1fs", amt, os.clock() - rec.t)
    end
    if n == 0 then LOG("REPORT", "  no unconfirmed shots") end
end

local function listPresets()
    LOG("LIST", "%d curated presets (exec preset <key>):", #PRESETS)
    for _, p in ipairs(PRESETS) do
        local mark = (p.key == S.preset) and "*" or " "
        local live = (function()
            local n = resolvePath(p.path)
            if not n then return "MISS" end
            if isFreeBullet(n) then return "LIVE" end
            return "SLASH"
        end)()
        local risk = p.risk and " RISK" or ""
        LOG("LIST", " %s %-16s [%s]%s spd=%-4s %s", mark, p.key, live, risk, tostring(p.speed), p.note)
    end
end

local function listScan(cap)
    cap = cap or SCAN_LOG_CAP
    if #CATALOG == 0 then refreshCatalog(false) end
    LOG("SCAN", "%d forgeable paths (runtime catalog):", #CATALOG)
    for i, row in ipairs(CATALOG) do
        if i > cap then
            LOG("SCAN", "  ... +%d more (exec scan refresh)", #CATALOG - cap)
            break
        end
        local mark = (row.path == S.templatePath) and "*" or " "
        local tag = row.tags and row.tags.effect_risk and " risk" or ""
        LOG("SCAN", " %s %s%s", mark, row.path, tag)
    end
end

local function printHelp()
    LOG("HELP", "fire | preset <key>|auto | list | scan | scan refresh | quality slow|medium|fast")
    LOG("HELP", "aim nearest|cursor|forward | vis on|off | spray <n> <deg> | spraymode fan|parallel")
    LOG("HELP", "dmg|speed|range|size|track|life|cd | tpl <path> | auto | swordmancer | preview | debug | report | unload")
end

local PRESET_EXPORT_KEYS = {
    "key", "path", "dmg", "speed", "range", "note", "risk", "sprayCount", "sprayDegrees",
}

local function exportPresets()
    local out = {}
    for _, p in ipairs(PRESETS) do
        local row = {}
        for _, k in ipairs(PRESET_EXPORT_KEYS) do
            if p[k] ~= nil then row[k] = p[k] end
        end
        out[#out + 1] = row
    end
    return out
end

-- api.select only: admin caps dmg at 10 after bind. exec('preset …') keeps preset table dmg.
-- Returns ok, err? — err is short UX string for admin status line.
local function selectSpec(spec)
    spec = tostring(spec or "")
    if spec == "" then return false, "empty selection" end

    if findPreset(spec) then
        local ok, err = applyPreset(spec)
        if not ok then return false, err end
        S.dmg = 10
        LOG("SELECT", "preset %s -> %s dmg=10", spec, S.templatePath)
        return true
    end

    local path = spec
    local node, miss = resolvePath(path)
    if node and isFreeBullet(node) then
        S.templatePath = path
        S.preset = "custom"
        LOG("SELECT", "tpl %s dmg=10", path)
        S.dmg = 10
        return true
    end
    local stat, detail = pathAvailability(path)
    if node and isForgeable(node) then
        WARN("TPL", "refused slash/weld %s", path)
        return false, detail or "[SLASH] not free bullet"
    end
    WARN("TPL", "not forgeable %s (%s)", path, tostring(miss))
    return false, detail or ("[MISS] " .. tostring(miss))
end

local api

local function exec(line)
    local a = {}
    for w in tostring(line):gmatch("%S+") do a[#a + 1] = w end
    local c = (a[1] or ""):lower()

    if c == "help" or c == "?" then printHelp()
    elseif c == "fire" then fireAtNearest()
    elseif c == "preset" then
        if a[2] == "auto" then
            S.templatePath = ""
            if ensureTemplate() then LOG("AUTO", "preset=%s tpl=%s", S.preset, S.templatePath) end
        elseif a[2] then applyPreset(a[2])
        else LOG("PRESET", "current=%s", S.preset); listPresets() end
    elseif c == "list" then listPresets()
    elseif c == "scan" then
        if a[2] == "refresh" then refreshCatalog(true); listScan() else listScan() end
    elseif c == "quality" then applyQuality(a[2])
    elseif c == "aim" then
        if a[2] then
            local m = a[2]:lower()
            if m == "nearest" or m == "cursor" or m == "forward" then
                S.aim = m
                LOG("SET", "aim=%s", m)
            else WARN("AIM", "nearest | cursor | forward") end
        else LOG("SET", "aim=%s", tostring(S.aim)) end
    elseif c == "vis" then
        if a[2] then S.vis = (a[2]:lower() ~= "off"); LOG("SET", "vis=%s", tostring(S.vis)) end
    elseif c == "spraymode" then
        if a[2] then
            local m = a[2]:lower()
            if m == "fan" or m == "parallel" then S.sprayMode = m; LOG("SET", "sprayMode=%s", m)
            else WARN("SPRAY", "fan | parallel") end
        else LOG("SET", "sprayMode=%s", tostring(S.sprayMode)) end
    elseif c == "swordmancer" or c == "sm" then
        task.spawn(function()
            local ok = bindStreamedClass("SWORDMANCER", "swordmancer", {
                dmg = 40, speed = 110, range = 400, size = 6, track = true,
            })
            if ok then LOG("SM", "ready tpl=%s", S.templatePath)
            else WARN("SM", "pick SWORDMANCER for LoadClass stream") end
        end)
    elseif c == "auto" then
        S.templatePath = ""
        if ensureTemplate() then LOG("AUTO", "preset=%s tpl=%s", S.preset, S.templatePath) end
    elseif c == "preview" then previewTemplate()
    elseif c == "tpl" then
        if a[2] then
            local path = table.concat(a, ".", 2)
            if #a == 2 then path = a[2] end
            local node, miss = resolvePath(path)
            if node and isFreeBullet(node) then
                S.templatePath = path; S.preset = "custom"; LOG("TPL", "%s", path)
            elseif node and isForgeable(node) then
                WARN("TPL", "refused slash/weld %s", path)
            else
                WARN("TPL", "not forgeable %s (%s)", path, tostring(miss))
            end
        else LOG("TPL", "current=%s", S.templatePath) end
    elseif c == "dmg" then
        local v = tonumber(a[2])
        if v == nil then WARN("SET", "dmg needs number — kept %s", tostring(S.dmg))
        else S.dmg = v; LOG("SET", "dmg=%s", tostring(S.dmg)) end
    elseif c == "speed" then
        local v = tonumber(a[2])
        if v == nil then WARN("SET", "speed needs number — kept %s", tostring(S.speed))
        else S.speed = v; LOG("SET", "speed=%s", tostring(S.speed)) end
    elseif c == "range" then S.range = tonumber(a[2]); LOG("SET", "range=%s", tostring(S.range))
    elseif c == "size"  then S.size  = tonumber(a[2]); LOG("SET", "size=%s", tostring(S.size))
    elseif c == "track" then S.track = (a[2] ~= "off"); LOG("SET", "track=%s", tostring(S.track))
    elseif c == "life"  then S.lifetime = math.max(tonumber(a[2]) or S.lifetime, 0.5); LOG("SET", "life=%s", tostring(S.lifetime))
    elseif c == "cd"    then S.fireCooldown = math.max(tonumber(a[2]) or S.fireCooldown, 0.15); LOG("SET", "cd=%s", tostring(S.fireCooldown))
    elseif c == "spray" then
        if a[2] then
            S.sprayCount = math.clamp(math.floor(tonumber(a[2]) or 1), 1, SPRAY_MAX_COUNT)
            if a[3] then S.sprayDegrees = math.abs(tonumber(a[3]) or S.sprayDegrees) end
        end
        LOG("SET", "spray count=%s deg=%s mode=%s", tostring(S.sprayCount), tostring(S.sprayDegrees), tostring(S.sprayMode))
    elseif c == "debug" then
        local okc = pcall(function() requireCM().HitboxDebugMode = true end)
        local okp = pcall(function() workspace.GameSetting.ProjectileDebug.Value = true end)
        LOG("DEBUG", "hitbox=%s projectile=%s", tostring(okc), tostring(okp))
    elseif c == "report" then report()
    elseif c == "unload" or c == "kill" then
        if api and api.destroy then api.destroy() end
    else printHelp()
    end
end

conn(RunService.Heartbeat, updateActiveProjectiles)

conn(UIS.InputBegan, function(input, gpe)
    if gpe or not S.alive then return end
    if UIS:GetFocusedTextBox() then return end
    if input.KeyCode == FIRE_KEY then fireAtNearest()
    elseif input.KeyCode == KILL_KEY then
        if api and api.destroy then api.destroy() end
    end
end)

local function wireCatalogRefresh()
    local function onChild() scheduleCatalogRefresh() end
    local classes = RS:FindFirstChild("Classes")
    local subs = RS:FindFirstChild("SubClasses")
    local xmas = RS:FindFirstChild("ChristmasProjectiles")
    if classes then conn(classes.ChildAdded, onChild) end
    if subs then conn(subs.ChildAdded, onChild) end
    if xmas then conn(xmas.ChildAdded, onChild) end
end

api = {
    S = S,
    exec = exec,
    fire = fireAtNearest,
    presets = exportPresets,
    select = selectSpec,
    pathStatus = pathAvailability,
    catalog = function() return CATALOG end,
    destroy = function()
        if not S.alive then return end
        S.alive = false
        for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
        for proj in pairs(S.active) do
            pcall(function() if proj and proj.Parent then proj:Destroy() end end)
        end
        table.clear(S.active)
        report()
        LOG("EXIT", "unloaded v2")
        if G[GKEY] == api then G[GKEY] = nil end
    end,
}
G[GKEY] = api

armIndicator()
requireCM()
refreshCatalog(false)
wireCatalogRefresh()

if not applyPreset("musketeer") then
    if ensureTemplate() then applyQuality("medium") end
end

LOG("INIT", "v2 ready preset=%s tpl=%s spd=%s track=%s vis=%s aim=%s catalog=%d  J=fire K=unload",
    S.preset, S.templatePath, tostring(S.speed), tostring(S.track), tostring(S.vis), tostring(S.aim), #CATALOG)
]==]
ENGINE_PAYLOAD["cs_esp.lua"] = [==[
--------------------------------------------------------------------------
-- cs_esp.lua — player overlay: name, health, shield, skeleton, through walls
--
-- Separate module, not part of cs_core, for one hard reason: cs_core.lua sits
-- at Luau's 200-top-level-local ceiling (HANDOFF_2026-08-01.md §2) and the next
-- chunk-level `local` added there makes Potassium refuse the whole engine while
-- luau-compile still reports it clean. This file has its own chunk and its own
-- budget. It also has no dependency on Core at all, so a core failure does not
-- take the overlay with it and vice versa.
--
-- Loaded lazily from ENGINE_PAYLOAD by cs_admin the first time `esp` is turned
-- on, the same mechanism as cs_projectile_forge (CS_CONSTRAINTS.md §1: one
-- injected file, nothing for the user to load by hand).
--
-- WHAT IT SHOWS, and why those numbers specifically
--
-- The values are the ones the game itself reads, mirrored rather than
-- re-derived:
--
--   health  Stats.CurrentHP / (Stats.MaxHP * Stats.MaxHPMult)   (0005.lua:468-469)
--           colour green  Color3.fromRGB(35,255,35), grey at <= 0 (0603.lua:240)
--   shield  Stats.CurrentShield / Stats.Shield      (0603.lua:180-186)
--           HUD colour gold   Color3.fromRGB(255,200,35), grey at <= 0
--           and the HUD HIDES the shield readout entirely when Stats.Shield
--           is 0 (0603.lua:164-175) — so do we. A permanent empty gold bar on
--           every player is noise, and it is not what the game shows.
--
-- DO NOT READ THE HUMANOID. This version did, and every player in the lobby
-- and in a round read 1000/1000. `characters.txt` states the schema in its own
-- header — "ESP / aim targeting schema (read for HP source + rig)" — and every
-- row is `hp=<n> (Stats.CurrentHP)  HumHP=1000/1000`. The Humanoid is a fixed
-- 1000 for every player in this game and carries no combat meaning: one row
-- reads `HumHP=0/1000  alive=true`, so gating on Humanoid.Health also hides
-- living players. The local HUD's `Humanoid.Health` readout (0603.lua:243) is
-- the misleading part — it only ever renders YOUR character, where the numbers
-- happen to be maintained. The Humanoid is kept here strictly as a fallback for
-- non-player entities (0003.lua:5830 gives spawned entities a real one).
--
-- MaxHPMult is why the max is a product and not just MaxHP: upgrades scale the
-- ceiling, so MaxHP alone reads a full bar as partial on any built character.
--
-- THROUGH WALLS is not an extra feature here, it is the default of both
-- primitives used: BillboardGui.AlwaysOnTop and LineHandleAdornment.AlwaysOnTop.
-- Note this is the OPPOSITE choice from the cone overlay, which deliberately
-- draws its cone surface occluded so it reads as geometry in the world. There
-- the shape is the information; here the person is, and a skeleton you lose
-- behind a crate is worth nothing.
--
-- COST. This is a per-frame overlay over every player, so it is built as a
-- pool: instances are created once, reused, and hidden rather than destroyed.
-- Nothing allocates in the update loop except the bone position lookups.
--------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LP = Players.LocalPlayer

local COL_HP      = Color3.fromRGB(35, 255, 35)    -- 0603.lua:240
local COL_SHIELD  = Color3.fromRGB(255, 200, 35)   -- 0603.lua:184
local COL_DEAD    = Color3.fromRGB(91, 93, 105)    -- 0603.lua:238 / :182
local COL_TEXT    = Color3.fromRGB(255, 255, 255)
local COL_DIM     = Color3.fromRGB(170, 172, 180)  -- secondary text: distance
local COL_BONE    = Color3.fromRGB(255, 255, 255)
local COL_TRACK   = Color3.fromRGB(12, 12, 14)     -- bar background
local COL_EDGE    = Color3.fromRGB(0, 0, 0)        -- outline

-- SAFE was drawn in blue. It read as "decorative" against a bright game and was
-- the first thing called out, so the whole overlay is monochrome white now with
-- the two HUD-mirrored bar colours as the only hue — the same rule the panel
-- follows (CS_CONSTRAINTS.md §4: black surfaces, white contrast, colour reserved
-- for meaning). SAFE is a white pill instead, which is louder than any tint.

local FOLDER_NAME = "CsEsp"

-- R15 first, R6 second. Both lists are tried against every character: the game
-- ships both rigs (dummies in the lobby are R6, players are R15) and a rig test
-- by name is one more thing to get wrong. A bone whose parts are missing is
-- simply skipped.
local BONES_R15 = {
    { "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
    { "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
    { "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
    { "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
    { "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}
local BONES_R6 = {
    { "Head", "Torso" },
    { "Torso", "Left Arm" }, { "Torso", "Right Arm" },
    { "Torso", "Left Leg" }, { "Torso", "Right Leg" },
}

local ESP = {}
local S = {
    on = false,
    alive = true,
    folder = nil,
    conn = nil,
    tags = {},          -- [Player] = { gui, name, hpFill, hpText, shRow, shFill, shText }
    lines = {},         -- flat pool of LineHandleAdornment
    used = 0,
    maxDist = 500,      -- studs; beyond this a tag is unreadable anyway
    ticks = 0,          -- frames update() has actually run. Zero is the ONLY
                        -- honest answer to "is it drawing" before frame one.
    scanned = 0,
    drawn = 0,
    diag = {},          -- per-player skip reasons, refreshed every frame
    skeleton = true,
    teamCheck = false,  -- hide allies. Off by default: teams.txt is empty and
                        -- FFA characters carry no Team child at all, so a team
                        -- filter hides nobody in the mode that is actually
                        -- played (critical-strike skill, "Team logic").
}

local function hostUi()
    return (gethui and gethui()) or game:GetService("CoreGui")
end

-- Swept by NAME, not by our handle. Same lesson as the cone overlay: an orphan
-- folder belongs by definition to a module instance that is already gone, and a
-- handle only knows about folders THIS load created. A hot reload that missed
-- its teardown otherwise leaves a full second overlay frozen on screen.
local function sweepOrphans()
    local parent = hostUi()
    for _, ch in ipairs(parent:GetChildren()) do
        if ch.Name == FOLDER_NAME then pcall(function() ch:Destroy() end) end
    end
end

local function ensureFolder()
    if S.folder and S.folder.Parent then return S.folder end
    sweepOrphans()
    local f = Instance.new("Folder")
    f.Name = FOLDER_NAME
    f.Parent = hostUi()
    S.folder = f
    return f
end

---------------------------------------------------------------------- bones --

local function line(from, to, color, thickness)
    local n = S.used + 1
    S.used = n
    local a = S.lines[n]
    if not a then
        a = Instance.new("LineHandleAdornment")
        a.Adornee = workspace.Terrain
        a.AlwaysOnTop = true
        a.ZIndex = 6
        a.Parent = S.folder
        S.lines[n] = a
    end
    local d = to - from
    local len = d.Magnitude
    if len < 1e-3 then a.Visible = false ; return end
    a.Length = len
    a.Thickness = thickness or 2
    a.Color3 = color
    a.CFrame = CFrame.lookAt(from, to)
    a.Visible = true
end

local function drawSkeleton(char, color)
    for _, set in ipairs({ BONES_R15, BONES_R6 }) do
        for _, bone in ipairs(set) do
            local a = char:FindFirstChild(bone[1])
            local b = char:FindFirstChild(bone[2])
            if a and b and a:IsA("BasePart") and b:IsA("BasePart") then
                line(a.Position, b.Position, color, 2)
            end
        end
    end
end

----------------------------------------------------------------------- tags --

-- Rounded, outlined, and the fill INSET inside its track by a pixel. The flat
-- square frames the first version drew read as debug output: against a bright,
-- saturated game a hard 1px colour edge with no outline vibrates and the text
-- on top of it is unreadable at range. An outline plus a corner radius is what
-- separates "a UI" from "two rectangles".
local function corner(inst, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 3)
    c.Parent = inst
    return c
end

local function stroke(inst, thickness, transparency)
    local s = Instance.new("UIStroke")
    s.Color = COL_EDGE
    s.Thickness = thickness or 1
    s.Transparency = transparency or 0.25
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = inst
    return s
end

local function bar(parent, y, height, fillColor)
    local track = Instance.new("Frame")
    track.BackgroundColor3 = COL_TRACK
    track.BackgroundTransparency = 0.25
    track.BorderSizePixel = 0
    track.Position = UDim2.new(0, 0, 0, y)
    track.Size = UDim2.new(1, 0, 0, height)
    track.Parent = parent
    corner(track, 3)
    stroke(track, 1, 0.15)

    -- Inset by 1px on every side so the fill never touches the outline. This is
    -- the difference between a bar that looks drawn and one that looks printed.
    local fill = Instance.new("Frame")
    fill.BackgroundColor3 = fillColor
    fill.BorderSizePixel = 0
    fill.Position = UDim2.new(0, 1, 0, 1)
    fill.Size = UDim2.new(1, -2, 1, -2)
    fill.Parent = track
    corner(fill, 2)

    local txt = Instance.new("TextLabel")
    txt.BackgroundTransparency = 1
    txt.Size = UDim2.new(1, 0, 1, 0)
    txt.Font = Enum.Font.GothamBold
    txt.TextSize = height - 2
    txt.TextColor3 = COL_TEXT
    txt.TextStrokeTransparency = 1
    txt.ZIndex = 3
    txt.Text = ""
    txt.Parent = track
    stroke(txt, 1.4, 0.1)   -- outline the glyphs, not a blurry TextStroke

    return track, fill, txt
end

local function makeTag(plr)
    local gui = Instance.new("BillboardGui")
    gui.Name = "tag_" .. plr.Name
    gui.AlwaysOnTop = true            -- through walls
    gui.LightInfluence = 0
    gui.Size = UDim2.new(0, 150, 0, 42)
    gui.StudsOffset = Vector3.new(0, 3.0, 0)
    gui.Parent = S.folder

    -- Name row: name left, distance right, in one row rather than stacked. The
    -- distance is the thing that decides whether a target is worth turning for,
    -- and it costs no vertical space here.
    local row = Instance.new("Frame")
    row.BackgroundTransparency = 1
    row.Size = UDim2.new(1, 0, 0, 15)
    row.Parent = gui

    local nameLbl = Instance.new("TextLabel")
    nameLbl.BackgroundTransparency = 1
    nameLbl.Size = UDim2.new(1, -34, 1, 0)
    nameLbl.Font = Enum.Font.GothamBold
    nameLbl.TextSize = 13
    nameLbl.TextColor3 = COL_TEXT
    nameLbl.TextStrokeTransparency = 1
    nameLbl.TextXAlignment = Enum.TextXAlignment.Center
    nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
    nameLbl.Position = UDim2.new(0, 17, 0, 0)
    nameLbl.Text = plr.Name
    nameLbl.Parent = row
    stroke(nameLbl, 1.6, 0.05)

    local distLbl = Instance.new("TextLabel")
    distLbl.BackgroundTransparency = 1
    distLbl.Size = UDim2.new(0, 34, 1, 0)
    distLbl.Position = UDim2.new(1, -34, 0, 0)
    distLbl.Font = Enum.Font.Gotham
    distLbl.TextSize = 11
    distLbl.TextColor3 = COL_DIM
    distLbl.TextStrokeTransparency = 1
    distLbl.TextXAlignment = Enum.TextXAlignment.Right
    distLbl.Text = ""
    distLbl.Parent = row
    stroke(distLbl, 1.4, 0.15)

    -- SAFE pill. Hidden by default, white on black, sat under the name row so
    -- it cannot push anything around when it appears.
    local safe = Instance.new("TextLabel")
    safe.BackgroundColor3 = COL_TEXT
    safe.Size = UDim2.new(0, 40, 0, 11)
    -- Sits ABOVE the name row, outside the gui's own bounds (nothing clips —
    -- ClipsDescendants is false), so showing it never reflows the rows below.
    safe.Position = UDim2.new(0.5, -20, 0, -13)
    safe.Font = Enum.Font.GothamBold
    safe.TextSize = 9
    safe.TextColor3 = COL_TRACK
    safe.Text = "SAFE"
    safe.Visible = false
    safe.ZIndex = 4
    safe.Parent = gui
    corner(safe, 3)
    stroke(safe, 1, 0.2)

    local _, hpFill, hpText = bar(gui, 17, 12, COL_HP)
    local shRow, shFill, shText = bar(gui, 30, 12, COL_SHIELD)

    local t = { gui = gui, name = nameLbl, dist = distLbl, safe = safe,
                hpFill = hpFill, hpText = hpText,
                shRow = shRow, shFill = shFill, shText = shText }
    S.tags[plr] = t
    return t
end

local function dropTag(plr)
    local t = S.tags[plr]
    if not t then return end
    pcall(function() t.gui:Destroy() end)
    S.tags[plr] = nil
end

-- One decimal on current HP, integer max — exactly the HUD's own formatting
-- (0603.lua:243), so a number read off the overlay matches the number the
-- player themselves is looking at.
local function fmtHp(cur, max)
    return ("%s/%s"):format(math.floor(cur * 10 + 0.5) / 10, math.floor(max + 0.5))
end

local function statValue(char, name)
    local stats = char:FindFirstChild("Stats")
    local v = stats and stats:FindFirstChild(name)
    return v and v.Value or nil
end

---------------------------------------------------------------------- update --

local function update()
    if not S.on or not S.alive then return end
    local folder = S.folder
    if not folder or not folder.Parent then return end

    local cam = workspace.CurrentCamera
    local myChar = LP.Character
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    local origin = (myRoot and myRoot.Position) or (cam and cam.CFrame.Position)
    if not origin then return end

    S.used = 0
    S.scanned, S.drawn = 0, 0
    S.diag = {}
    S.ticks = S.ticks + 1

    for _, plr in ipairs(Players:GetPlayers()) do
        local t = S.tags[plr]
        local char = plr.Character
        local head = char and char:FindFirstChild("Head")
        local hum = char and char:FindFirstChildOfClass("Humanoid")

        -- Every reason to skip lands here, and the tag is hidden rather than
        -- destroyed: a character that is streaming in, respawning or briefly
        -- out of range must not cost a full rebuild of its instances.
        -- Every skip is NAMED, not counted. An anonymous histogram cannot
        -- answer "why is this player not on my screen" — four wrong diagnoses
        -- came out of exactly that (HANDOFF_2026-08-01.md §4), and this overlay
        -- reproduced it immediately: `0 tagged` was reported while the real
        -- answer was that nothing had been measured yet.
        local show, why = true, nil
        if plr == LP then show, why = false, "self"
        elseif not char then show, why = false, "no character"
        elseif not head then show, why = false, "no head (streaming?)"
        elseif S.teamCheck and plr.Team and LP.Team and plr.Team == LP.Team then
            show, why = false, "teammate"
        elseif (head.Position - origin).Magnitude > S.maxDist then
            show, why = false, ("%d studs > dist %d"):format(
                (head.Position - origin).Magnitude, S.maxDist)
        end

        -- NO ALIVENESS GATE. The previous version hid anyone whose CurrentHP
        -- was <= 0, which is a filter that can silently empty the whole
        -- overlay and looks identical to the feature being broken. A dead
        -- player draws with a grey bar instead — the HUD's own behaviour
        -- (0603.lua:238) — because "drawn and obviously dead" is diagnosable
        -- and "absent" is not.
        if why then S.diag[#S.diag + 1] = plr.Name .. ": " .. why end
        S.scanned = S.scanned + 1

        if not show then
            if t then t.gui.Enabled = false end
        else
            if not t then t = makeTag(plr) end
            t.gui.Adornee = head
            t.gui.Enabled = true
            S.drawn = S.drawn + 1

            local cur = statValue(char, "CurrentHP")
            local max = statValue(char, "MaxHP")
            if cur and max then
                max = max * (statValue(char, "MaxHPMult") or 1)
            else
                -- No Stats folder: a spawned entity rather than a player, and
                -- those DO carry a real Humanoid (0003.lua:5830-5831).
                cur = cur or (hum and hum.Health) or 0
                max = max or (hum and hum.MaxHealth) or 0
            end
            if max <= 0 then max = 1 end
            local frac = math.clamp(cur / max, 0, 1)
            t.hpFill.Size = UDim2.new(frac, 0, 1, 0)
            t.hpFill.BackgroundColor3 = cur > 0 and COL_HP or COL_DEAD
            t.hpText.Text = fmtHp(cur, max)

            -- The HUD hides the shield readout when the player has no shield
            -- stat at all (0603.lua:164-175); mirror that instead of drawing a
            -- dead bar on everyone.
            -- Two different shield schemas exist and both are live. The HUD
            -- reads CurrentShield/Shield (0603.lua:180-186), but a freshly
            -- spawned character in spawn_state.txt carries `Stats.ShieldHP`
            -- (also read directly at 0393.lua:17) with no CurrentShield at all.
            -- Reading only the HUD pair means the shield row never appears for
            -- anyone on the ShieldHP path.
            local shMax = statValue(char, "Shield") or 0
            local shieldHp = statValue(char, "ShieldHP")
            if shMax <= 0 and shieldHp and shieldHp > 0 then shMax = shieldHp end
            if shMax > 0 then
                local shCur = statValue(char, "CurrentShield") or shieldHp or 0
                t.shRow.Visible = true
                t.shFill.Size = UDim2.new(math.clamp(shCur / shMax, 0, 1), 0, 1, 0)
                t.shFill.BackgroundColor3 = shCur > 0 and COL_SHIELD or COL_DEAD
                t.shText.Text = ("%d/%d"):format(shCur, shMax)
                t.gui.Size = UDim2.new(0, 150, 0, 42)
            else
                t.shRow.Visible = false
                t.gui.Size = UDim2.new(0, 150, 0, 29)
            end

            -- Spawn protection is the single most useful thing to see at a
            -- glance: a Safe player cannot be damaged at all (CheckSafe,
            -- 0003.lua:4715) and is also the top reject reason in the engine's
            -- own histogram. Colouring the name is cheaper to read than a
            -- fourth row of text.
            local safe = (statValue(char, "Safe") or 0) > 0
            t.safe.Visible = safe
            t.name.Text = plr.Name
            t.dist.Text = ("%dm"):format((head.Position - origin).Magnitude)

            if S.skeleton then
                drawSkeleton(char, COL_BONE)
            end
        end
    end

    -- Hide the tail of the line pool that this frame did not use. Lines are
    -- kept, not destroyed: player count swings every round and rebuilding
    -- fourteen adornments per character per frame is the whole cost of this
    -- feature if you get it wrong.
    for i = S.used + 1, #S.lines do
        S.lines[i].Visible = false
    end
end

----------------------------------------------------------------------- api --

function ESP.setOn(on)
    on = on and true or false
    if on == S.on then return S.on end
    S.on = on

    if not on then
        if S.conn then pcall(function() S.conn:Disconnect() end) ; S.conn = nil end
        for plr in pairs(S.tags) do dropTag(plr) end
        S.tags = {}
        if S.folder then pcall(function() S.folder:Destroy() end) ; S.folder = nil end
        -- The pool indexes the destroyed folder's adornments; keeping it would
        -- hand out dead instances whose .Visible writes go nowhere and the
        -- skeleton would silently draw fewer lines every toggle.
        S.lines, S.used = {}, 0
        return false
    end

    ensureFolder()
    S.lines, S.used = {}, 0
    S.ticks, S.scanned, S.drawn, S.diag = 0, 0, 0, {}
    S.conn = RunService.RenderStepped:Connect(function()
        local ok, err = pcall(update)
        if not ok then
            -- One throw must not leave a dead connection spamming every frame.
            warn("[CsEsp] update error, disabling — " .. tostring(err))
            ESP.setOn(false)
        end
    end)
    return true
end

function ESP.isOn() return S.on end

function ESP.setSkeleton(on)
    S.skeleton = on and true or false
    if not S.skeleton then
        for i = 1, #S.lines do S.lines[i].Visible = false end
    end
    return S.skeleton
end
function ESP.skeletonOn() return S.skeleton end

function ESP.setMaxDist(n)
    n = tonumber(n)
    if n and n > 0 then S.maxDist = n end
    return S.maxDist
end
function ESP.maxDist() return S.maxDist end

function ESP.setTeamCheck(on)
    S.teamCheck = on and true or false
    return S.teamCheck
end
function ESP.teamCheck() return S.teamCheck end

-- Reports what the LAST FRAME actually did, and says so when there has not
-- been one yet. The first version counted S.tags immediately after setOn(true)
-- — before update had ever run — so it printed "0 tagged" every single time and
-- was read as "the overlay is finding nobody". A diagnostic that cannot
-- distinguish "measured zero" from "not measured" is worse than none.
function ESP.status()
    if not S.on then
        return ("esp off · skeleton %s · dist %d · teamcheck %s"):format(
            S.skeleton and "on" or "off", S.maxDist, S.teamCheck and "on" or "off")
    end
    if S.ticks == 0 then
        return "esp ON · no frame rendered yet — run `esp status` again in a second"
    end
    return ("esp ON · skeleton %s · dist %d · teamcheck %s · %d/%d drawn · %d bones · %d frames"):format(
        S.skeleton and "on" or "off", S.maxDist, S.teamCheck and "on" or "off",
        S.drawn, S.scanned, S.used, S.ticks)
end

-- Names every player the overlay skipped and why, in the same order and with
-- the same predicates update() uses. This is the `why <player>` of the ESP.
function ESP.why()
    if not S.on then return { "esp is off" } end
    if S.ticks == 0 then return { "no frame rendered yet" } end
    local out = { ("scanned %d, drawn %d, bones %d, folder %s"):format(
        S.scanned, S.drawn, S.used,
        (S.folder and S.folder.Parent) and "live" or "MISSING") }
    if #S.diag == 0 then
        out[#out + 1] = "nobody skipped"
    else
        for _, line in ipairs(S.diag) do out[#out + 1] = line end
    end
    return out
end

function ESP.destroy()
    S.alive = false
    pcall(ESP.setOn, false)
    sweepOrphans()
    if getgenv().__CS_ESP == ESP then getgenv().__CS_ESP = nil end
end

Players.PlayerRemoving:Connect(function(plr) dropTag(plr) end)

-- A respawn replaces the Character, so the Adornee a tag holds is a destroyed
-- Head. update() re-points it every frame from the live Character, so nothing
-- is needed here beyond not caching the character itself — noted because the
-- obvious "cache char per player" optimisation breaks exactly this.

getgenv().__CS_ESP = ESP
return ESP
]==]
local ENGINE_ORDER = { "cs_core.lua", "cs_classes.lua", "cs_projectile_forge.lua", "cs_esp.lua", }
local ENGINE_BUILD = "2026-08-01 20:57:36"
getgenv().__CS_BUILD = ENGINE_BUILD
-- <<< ENGINE PAYLOAD END

-- Drops a readable copy of each payload into the workspace. Purely for
-- inspection: nothing ever loads from these files, so failure here is not fatal
-- and is not allowed to stop the engine.
local function mirrorEngineToDisk()
    if not (writefile and readfile and isfile) then return nil end
    local wrote = 0
    for _, name in ipairs(ENGINE_ORDER) do
        local body = ENGINE_PAYLOAD[name]
        if body and #body > 0 then
            local stale = true
            if isfile(name) then
                local ok, cur = pcall(readfile, name)
                if ok and cur == body then stale = false end
            end
            -- Content-compare rather than blind overwrite, so a session that
            -- did not change the engine does not churn the disk.
            if stale and pcall(writefile, name, body) then wrote = wrote + 1 end
        end
    end
    return wrote
end

-- Loads the engine from the EMBEDDED payload, always. The disk mirror is a
-- side effect, never a dependency: an executor with no file API can still run
-- the engine perfectly well, and gating on writefile would disable heatseek
-- for no reason.
-- ENGINE_CORE_FILES: files that must be present and are loaded eagerly by
-- bootEngine. The forge (cs_projectile_forge.lua) is in ENGINE_PAYLOAD but
-- loaded lazily by ensureForge() when the PROJ tab is first opened.
local ENGINE_CORE_FILES = { "cs_core.lua", "cs_classes.lua" }

local function bootEngine()
    for _, name in ipairs(ENGINE_CORE_FILES) do
        local body = ENGINE_PAYLOAD[name]
        if not body or #body == 0 then
            Log.warn("engine: payload missing " .. name .. " — run tools/build_admin.sh")
            return false
        end
    end

    -- cs_core must load. cs_classes failing is degraded-but-usable: the engine
    -- runs with no classes registered, which the panel shows as empty rather
    -- than pretending the whole engine is dead.
    local ok, err = pcall(function() loadstring(ENGINE_PAYLOAD["cs_core.lua"])() end)
    if not ok then
        Log.warn("engine: cs_core failed to load — " .. tostring(err))
        return false
    end

    local core = getgenv().__CS_CORE
    if not core then
        Log.warn("engine: core did not register")
        return false
    end

    local okC, errC = pcall(function() loadstring(ENGINE_PAYLOAD["cs_classes.lua"])() end)
    if not okC then
        Log.warn("engine: cs_classes failed — no classes registered — " .. tostring(errC))
    end

    local wrote = mirrorEngineToDisk()
    Log.info(("engine ready%s"):format(
        wrote and (" (%d file%s mirrored)"):format(wrote, wrote == 1 and "" or "s") or ""))
    return true
end

local ENGINE_OK = bootEngine()
local function engine() return ENGINE_OK and getgenv().__CS_CORE or nil end

-- Restore the saved ally names into the engine.
--
-- loadConfig() runs long before the engine exists -- it is near the top of the
-- file and the engine is self-extracted below it -- so it can only put the string
-- into S. This is the point where it can actually be applied. Without it the
-- names persisted in the file, showed up in the panel textbox, and meant nothing
-- to the engine, which is a worse failure than not saving them at all.
--
-- Deferred because pushAllyNameAllModules and findPlayer are declared later in
-- the file, and a name typed before the player has joined should still resolve
-- once they do.
--
-- Note this restores WHO the allies are, not whether ally assist is on. Every
-- toggle still boots OFF (CS_CONSTRAINTS.md).
-- Arm every registered class on load when armAll is set.
--
-- Its own defer block, NOT folded into the ally restore below: that one returns
-- early when no ally names are saved, and class arming must not be conditional
-- on having an ally.
--
-- Retries briefly because the engine self-extracts from the payload and may not
-- have finished registering classes at this point -- arming zero classes and
-- reporting success is exactly the kind of silent no-op this codebase keeps
-- getting bitten by.
task.defer(function()
    if not S.armAll then return end
    for _ = 1, 20 do
        local core = engine()
        if core and core.classes then
            local n, spawners = 0, {}
            for name, cfg in pairs(core.classes()) do
                core.setEnabled(name, true)
                n = n + 1
                -- A class with a castTrigger does more than steer: it SPAWNS a
                -- body on cast (COWBOY High Noon on F). armAll used to skip
                -- these so injecting could never put projectiles in the world by
                -- itself -- but armAll is where classes are armed, and singling
                -- one out made COWBOY the only class that did not come up with
                -- the rest. It is armed like everything else now.
                --
                -- Still NAMED at boot, because the difference is real and worth
                -- knowing you have live: `hs off` disarms everything and
                -- persists, `hs COWBOY off` disarms just this one.
                if cfg and cfg.castTrigger then
                    spawners[#spawners + 1] = name
                end
            end
            if n > 0 then
                Log.info(("armAll: %d classes armed on load"):format(n))
                if #spawners > 0 then
                    table.sort(spawners)
                    Log.warn(("armAll: %s armed and SPAWNS bodies on cast — live "
                        .. "from this moment, lobby included. `hs %s off` to stop it")
                        :format(table.concat(spawners, ", "), spawners[1]))
                end
                return
            end
        end
        task.wait(0.25)
    end
    Log.warn("armAll: engine never reported any classes — nothing armed")
end)

-- Restore the visual debug cone when it was left on.
--
-- Same retry shape and the same reason as armAll above: the engine self-extracts
-- from the payload, so setVisualDebug may not exist yet at this point in the
-- boot. Its own defer block rather than folded into armAll's, because the cone
-- must come back even when armAll is off -- the two are unrelated switches and
-- sharing a block would make one silently depend on the other.
task.defer(function()
    if not S.coneVis then return end
    for _ = 1, 20 do
        local core = engine()
        if core and core.setVisualDebug then
            core.setVisualDebug(true)
            Log.info("cone: visual debug restored")
            return
        end
        task.wait(0.25)
    end
    Log.warn("cone: engine never loaded — visual debug not restored")
end)

-- There is no High Noon restore block. Arming is `hs COWBOY`, and class arming
-- is deliberately never restored from disk (registerClass forces
-- cfg.enabled = false), so a restore here would reintroduce exactly the
-- comes-up-hot-on-inject behaviour that rule exists to prevent.

task.defer(function()
    local raw = S.allyNames
    if not raw or raw == "" then return end
    local core = engine()
    if not core then
        Log.warn("ally names restored to the panel but the engine is not loaded: " .. raw)
        return
    end
    core.setAllyNames(raw)
    local st = core.allyStatus()
    if #st.resolved > 0 then
        Log.info(("ally names restored: %s"):format(table.concat(st.resolved, ", ")))
    end

    -- Re-arm ally assist if it was on when the config was last written. Restoring
    -- the names without the switch is what made every reload look like ally
    -- heatseek had broken: the panel listed the allies, and nothing echoed.
    --
    -- Requires at least one name to actually RESOLVE to a player in the server.
    -- Arming against zero resolved allies is the silent-failure case the toggle
    -- path already refuses, and a restore must not be able to do what a manual
    -- toggle would not.
    if S.allyAssist then
        local function armIfResolved()
            local s = core.allyStatus()
            if #s.resolved == 0 then return false end
            core.setAllyEchoEnabled(true)
            core.setAllyHeatseekEnabled(true)
            Log.info(("ally assist restored ON from config (echo + heatseek) — %s")
                :format(table.concat(s.resolved, ", ")))
            return true
        end
        if not armIfResolved() then
            -- They have not loaded in yet. On a fresh join our client is usually
            -- ready before the rest of the lobby, so "no ally in the server" at
            -- inject is the NORMAL case, not the exception -- failing here is
            -- what would make the restore feel unreliable. Retry on join, with a
            -- ceiling so this cannot poll forever in a server they never enter.
            Log.info("ally assist saved ON — waiting for an ally to join")
            task.spawn(function()
                local deadline = os.clock() + 180
                local conn
                conn = Players.PlayerAdded:Connect(function()
                    task.wait(1)   -- let the character and stats replicate
                    core.setAllyNames(S.allyNames)
                    if armIfResolved() and conn then conn:Disconnect() end
                end)
                while os.clock() < deadline do
                    task.wait(5)
                    core.setAllyNames(S.allyNames)
                    if armIfResolved() then break end
                end
                if conn then conn:Disconnect() end
            end)
        end
    end
    if #st.unresolved > 0 then
        -- Not an error: allies are commonly saved from a previous server. Said
        -- out loud anyway, because a silently unresolved name is exactly the
        -- failure this persistence is meant to stop repeating.
        Log.info(("ally names restored but not in this server yet: %s")
            :format(table.concat(st.unresolved, ", ")))
    end
end)

local setFeedback  -- forward decl, defined with the UI

-- console + file only; used for multi-line dumps that would thrash the
-- one-line feedback label
local function logLine(msg)
    print("[CSAdmin] " .. tostring(msg))
    Log.info(msg)
end

local function log(msg)
    logLine(msg)
    if setFeedback then setFeedback(tostring(msg)) end
end

local function logChunks(indent, items, per)
    per = per or 10
    for i = 1, #items, per do
        logLine(indent .. table.concat(items, "  ", i, math.min(i + per - 1, #items)))
    end
end

-- ============ core ============

local CD_FUNCS = { "Cooldown", "NonAbilityCooldown",
    "StackAbilityCooldown", "SubStackAbilityCooldown" }
local MOVE_GATES = { "MoveAvailable", "MoveVailable", "SubMoveAvailable",
    "SubMoveVailable", "NonAbilityAvailable", "AvailableStacks",
    "SubAvailableStacks" }
local SUB_GATES = { SubMoveAvailable = true, SubMoveVailable = true,
    SubAvailableStacks = true }

local function currentClassName()
    local ch = lp.Character
    local cc = ch and ch:FindFirstChild("CurrentClass")
    if not cc then return nil end
    local v = tostring(cc.Value)
    if v == "" or v == "none" or v == "None" then return nil end
    return string.lower(v)
end

local function inMatch() return currentClassName() ~= nil end

local function findCM()
    if filtergc then
        local ok, t = pcall(function()
            return filtergc("table", {
                Keys = { "Cooldown", "NonAbilityAvailable", "LoadedClasses" },
            }, true)
        end)
        if ok and type(t) == "table" then return t end
    end
    if getgc then
        for _, obj in ipairs(getgc(true)) do
            if type(obj) == "table"
                and type(rawget(obj, "Cooldown")) == "function"
                and type(rawget(obj, "NonAbilityAvailable")) == "function"
                and type(rawget(obj, "LoadedClasses")) == "table" then
                return obj
            end
        end
    end
end

-- ClassModule.Essentials is live: 0003.lua:1413 rewrites Essentials.P from
-- ChangeEssentials.OnClientEvent, and every legit send re-reads it through
-- GetUtility:GetPassword (0003.lua:1441). Only the two handles are cached
-- here — the password itself is derived fresh per send, same as the game.
local lastEnsure = 0
local function ensureCM()
    if S.cm and S.getUtil then return end
    local now = os.clock()
    if now - lastEnsure < 0.5 then return end
    lastEnsure = now
    if not S.cm then S.cm = findCM() end
    if not S.getUtil then
        local ok, mod = pcall(function()
            return require(RS.ClientModules.GetUtility)
        end)
        S.getUtil = ok and mod or nil
    end
end

local function password()
    ensureCM()
    if not S.getUtil or not S.cm then return nil end
    local ok, pw = pcall(function()
        return S.getUtil:GetPassword(S.cm.Essentials)
    end)
    return ok and pw or nil
end

-- every forged remote carries the password, so a bare "no password" was the
-- one message four different failures collapsed into. Name the missing link.
local function pwError()
    if not inMatch() then
        return "no password — not in a match yet, wait for 'armed <class>'"
    end
    if not S.cm then return "no password — ClassModule not found yet" end
    if not S.getUtil then return "no password — GetUtility not loaded yet" end
    return "no password — Essentials empty, respawn or wait for ChangeEssentials"
end

-- exact -> prefix -> substring on Name AND DisplayName, same as admin_core
-- findPlayer. Ambiguity fails soft: an exact hit always wins, otherwise 2+
-- equal-quality matches return nil + the candidate list so a forged remote
-- never lands on the wrong person.
local function matchPlayers(query, tier)
    local out = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp then
            local n, d = p.Name:lower(), p.DisplayName:lower()
            local hit
            if tier == 1 then
                hit = (n == query or d == query)
            elseif tier == 2 then
                hit = (n:sub(1, #query) == query or d:sub(1, #query) == query)
            else
                hit = (n:find(query, 1, true) ~= nil or d:find(query, 1, true) ~= nil)
            end
            if hit then out[#out + 1] = p end
        end
    end
    return out
end

local function describePlayers(list)
    local names = {}
    for i, p in ipairs(list) do
        names[i] = (p.DisplayName ~= p.Name)
            and (p.Name .. "(" .. p.DisplayName .. ")") or p.Name
    end
    return table.concat(names, ", ")
end

-- returns player, err
local function findPlayer(query)
    if not query or query == "" then return nil, "no player given" end
    query = query:lower()
    for tier = 1, 3 do
        local hits = matchPlayers(query, tier)
        if #hits == 1 then return hits[1] end
        if #hits > 1 then
            return nil, "ambiguous '" .. query .. "': " .. describePlayers(hits)
        end
    end
    return nil, "no player matching '" .. query .. "'"
end

-- ghost suggestion only: best prefix match on Name then DisplayName, shortest
-- Name wins a tie. Ambiguity is fine here because Tab is an explicit accept.
local function bestPlayerName(frag)
    if frag == "" then return nil end
    local best
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp and (p.Name:lower():sub(1, #frag) == frag
            or p.DisplayName:lower():sub(1, #frag) == frag) then
            if not best or #p.Name < #best.Name then best = p end
        end
    end
    return best and best.Name or nil
end

-- target of a player-arg command; keeps the "why" out of every call site
local function targetChar(query)
    local p, err = findPlayer(query)
    if not p then return nil, nil, err end
    if not p.Character then return nil, nil, "no character for " .. p.Name end
    return p, p.Character
end

local function mainValues(char)
    local stats = char and char:FindFirstChild("Stats")
    return stats and stats:FindFirstChild("MainValues")
end

local function hpOf(char)
    local mv = mainValues(char)
    local h = mv and mv:FindFirstChild("Health")
    if h then return h.Value end
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    return hum and hum.Health or nil
end

local function myHrp()
    local ch = lp.Character
    return ch and ch:FindFirstChild("HumanoidRootPart")
end

local function isValidTarget(char)
    if not char or not char:FindFirstChild("HumanoidRootPart") then return false end
    local hp = hpOf(char)
    if not hp or hp <= 0 then return false end
    local me = lp.Character
    if me and me:FindFirstChild("Playing")
        and not char:FindFirstChild("Playing") then return false end
    return true
end

-- Spawn protection. The game refuses the hit outright (CheckSafe,
-- 0003.lua:4715; spawn_state.txt shows Safe = 1 on respawn), so a reach or
-- ladder pulse at a Safe target is a guaranteed-wasted send. Heal is exempt:
-- Safe does not gate healing.
local function isSafeProtected(char)
    local stats = char and char:FindFirstChild("Stats")
    local safe = stats and stats:FindFirstChild("Safe")
    return safe ~= nil and tonumber(safe.Value) ~= nil and safe.Value > 0
end

local function nearest(range)
    local hrp = myHrp()
    if not hrp then return nil end
    local best, bestD = nil, math.huge
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= lp and pl.Character and isValidTarget(pl.Character) then
            local e = pl.Character:FindFirstChild("HumanoidRootPart")
            local d = (hrp.Position - e.Position).Magnitude
            if d <= range and d < bestD then
                best, bestD = { player = pl, char = pl.Character, dist = d }, d
            end
        end
    end
    return best
end

-- ============ confirmation feed ============

local function isLocalDealer(d)
    if typeof(d) ~= "Instance" then return false end
    if d:IsA("Player") then return d == lp end
    return d == lp.Character
end

local refreshRows  -- fwd

local function onIndicator(p)
    if not S.alive or type(p) ~= "table" then return end
    local dealer, victim, amount, kind = p[1], p[2], p[3], p[4]
    if not isLocalDealer(dealer) then return end
    local amt = tonumber(amount)
    if not amt then return end
    local k = tostring(kind)
    for i = 1, #S.pending do
        local pd = S.pending[i]
        if pd.victim == victim and pd.kind == k
            and math.abs(amt - pd.amount) < 0.01 then
            if pd.tag and not S.confirmed[pd.tag] then
                S.confirmed[pd.tag] = true
                log(pd.tag .. " CONFIRMED by server (" .. tostring(amt) .. ")")
                if refreshRows then refreshRows() end
            end
            if pd.tag == "ladder" then
                S.ladderMax = math.max(S.ladderMax, amt)
            end
            table.remove(S.pending, i)
            return
        end
    end
end

local function track(victim, amount, kind, tag)
    S.pending[#S.pending + 1] =
        { t = os.clock(), victim = victim, amount = amount, kind = kind, tag = tag }
end

local function reap()
    local now = os.clock()
    local i = 1
    while i <= #S.pending do
        if now - S.pending[i].t > 0.8 then
            table.remove(S.pending, i)
        else
            i = i + 1
        end
    end
end

-- ============ actions ============

-- Damage/Heal are RemoteFunctions — InvokeServer YIELDS. The game never
-- calls them inline: 0003.lua:2386 wraps Damage in task.spawn, :2489 wraps
-- Heal in coroutine.create. Calling them straight from a Heartbeat handler
-- hangs that thread whenever the server declines to reply, and Heartbeat
-- keeps spawning more every frame until the client dies. Always detach.
local function async(fn)
    task.spawn(function() pcall(fn) end)
end

local function sendDamage(victimChar, amount, tag)
    local pw = password()
    if not pw then return false, pwError() end
    track(victimChar, amount, "Damage", tag)
    -- 7 fields WITH serverTime (0003.lua:2372)
    async(function()
        S.damageRemote:InvokeServer({
            pw, workspace:GetServerTimeNow(), victimChar, amount, nil, nil, nil,
        })
    end)
    return true
end

local function sendDamageTyped(victimChar, amount, dtype, tag)
    local pw = password()
    if not pw then return false, pwError() end
    local remote = S.damageRemote or RS.Remotes:FindFirstChild("Damage")
    if not remote then return false, "no Damage" end
    track(victimChar, amount, "Damage", tag)
    async(function()
        remote:InvokeServer({
            pw, workspace:GetServerTimeNow(), victimChar, amount, dtype, nil, nil,
        })
    end)
    return true
end

local function sendTrueDamage(victimChar, amount, tag)
    return sendDamageTyped(victimChar, amount, "TrueDamage", tag)
end

local STRING_EFFECTS = {
    knockback = "Knockback", knockup = "Knockup",
    release = "Release", knockbackaoe = "KnockbackAOE",
}

local function findEffectInFolder(folder, name)
    if not folder then return nil end
    local direct = folder:FindFirstChild(name)
    if direct then return direct end
    local low = name:lower()
    for _, ch in ipairs(folder:GetChildren()) do
        if ch.Name:lower() == low then return ch end
    end
    return nil
end

-- ---- canonical effect paths ----
-- The kick is Instance identity, not the remote. Two names can read the same
-- and be different Instances: RS.Effects.Stun is an orphan no client emits
-- (kicked 2026-07-25) while RS.SubClasses.GOLEM.Effects.Stun is the one class
-- code actually sends at an enemy. A folder walk that starts at RS.Effects
-- therefore picks the kicking Instance for half the useful names. Names are
-- resolved through this table FIRST; the walk is only the fallback.
--   safe    dump-verified enemy call site, owner-gated
--   medium  genuine enemy sites but event-gated (TurkeyBurn / PUMPKIN)
local CANON_PATH = {
    stun                    = { path = "SubClasses/GOLEM/Stun", risk = "safe" },
    stunlong                = { path = "SubClasses/BANANDIUM/StunLong", risk = "safe" },
    slow                    = { path = "Classes/NECROMANCER/Slow", risk = "safe" },
    cripple                 = { path = "Classes/RAVAGER/Cripple", risk = "safe" },
    frostbite               = { path = "Classes/FROST/Frostbite", risk = "safe" },
    frostbiteextend2        = { path = "Classes/FROST/FrostbiteExtend2", risk = "safe" },
    staggerlong             = { path = "Classes/ADMIRAL/StaggerLong", risk = "safe" },
    charmed                 = { path = "SubClasses/CHARMER/Charmed", risk = "safe" },
    damagedebuffthief       = { path = "Classes/NECROMANCER/DamageDebuffThief", risk = "safe" },
    defensedebuffgunnercrit = { path = "Classes/NECROMANCER/DefenseDebuffGunnerCrit", risk = "safe" },
    gamblerrandom           = { path = "Classes/GAMBLER/GamblerRandom", risk = "safe" },
    pull                    = { path = "SubClasses/MUMMY/Pull", risk = "safe" },
    turkeyburn              = { path = "Effects/TurkeyBurn", risk = "medium" },
}

-- 'SubClasses/GOLEM/Effects/Stun' and 'SubClasses/GOLEM/Stun' name the same
-- Instance, so the class-scoped 'Effects' hop is dropped before comparing.
local function normPath(p)
    local segs = {}
    for seg in tostring(p):lower():gmatch("[^/]+") do
        if not (seg == "effects" and #segs > 0) then segs[#segs + 1] = seg end
    end
    return table.concat(segs, "/")
end

local CANON_BY_PATH = {}
for name, e in pairs(CANON_PATH) do
    CANON_BY_PATH[normPath(e.path)] = { risk = e.risk, name = name }
end

local function childOf(node, seg)
    if not node then return nil end
    local direct = node:FindFirstChild(seg)
    if direct then return direct end
    local low = tostring(seg):lower()
    for _, ch in ipairs(node:GetChildren()) do
        if ch.Name:lower() == low then return ch end
    end
    return nil
end

-- 'SubClasses/GOLEM/Stun' -> RS.SubClasses.GOLEM.Effects.Stun. Each hop tries
-- the direct child first, then that node's Effects folder, so the 'Effects'
-- segment is optional and a fully written path still resolves. Case is
-- ignored because exec() lowercases every argument.
local function walkPath(path)
    local node = RS
    for seg in tostring(path):gmatch("[^/]+") do
        if typeof(node) ~= "Instance" then return nil end
        local nxt = childOf(node, seg) or childOf(childOf(node, "Effects"), seg)
        if not nxt then return nil end
        node = nxt
    end
    return (node ~= RS) and node or nil
end

local function effectPath(effect)
    if typeof(effect) ~= "Instance" then return tostring(effect) .. " (string)" end
    local ok, full = pcall(function() return effect:GetFullName() end)
    return ok and full or effect.Name
end

-- returns instance|string, exact
-- 'exact' means it came from the path the caller named (canon table or an
-- explicit '/' path) rather than from the loose name walk. The risk guard
-- needs that distinction: a canon name that fell through to the walk is a
-- different Instance than the one that was classified SAFE.
local function resolveEffect(effectInstOrString)
    if typeof(effectInstOrString) ~= "string" then
        return effectInstOrString, false
    end
    local name = effectInstOrString
    if name:find("/", 1, true) then
        return walkPath(name), true    -- explicit path: literal walk, no name resolution
    end
    local canon = CANON_PATH[name:lower()]
    if canon then
        local hit = walkPath(canon.path)
        if hit then return hit, true end
    end
    local rootFx = RS:FindFirstChild("Effects")
    local inst = findEffectInFolder(rootFx, name)
    if inst then return inst, false end
    local classes = RS:FindFirstChild("Classes")
    if classes then
        for _, cls in ipairs(classes:GetChildren()) do
            inst = findEffectInFolder(cls:FindFirstChild("Effects"), name)
            if inst then return inst, false end
        end
    end
    local subs = RS:FindFirstChild("SubClasses")
    if subs then
        for _, sub in ipairs(subs:GetChildren()) do
            inst = findEffectInFolder(sub:FindFirstChild("Effects"), name)
            if inst then return inst, false end
        end
    end
    local str = STRING_EFFECTS[name:lower()]
    if str then return str, false end
    return nil, false
end

-- ---- effect catalog ----
-- Runtime scan is the source of truth (always current). This seed is only used
-- when the scan comes back empty — names lifted from the CS v5.14.2 dump,
-- full_dump/rs_combat_tree.txt, BillboardGui children under RS.Effects.
local EFFECT_FALLBACK = {
    "AssaultLand", "AttackWarning", "Bind", "Bleeding", "BossStun", "Burn",
    "BurnInfernus", "BurnMap", "Capture", "Charmed", "Cripple",
    "DamageDebuffThief", "DefenseBuff",
    "DefenseDebuff", "DefenseDebuffGunnerCrit", "DefUpWarrior", "Disable",
    "DoubleUp", "ForceField", "ForceFieldExtend", "ForceFieldInfernus",
    "ForceFieldShort", "ForceFieldShortish", "Freeze", "Frostbite",
    "FrostbiteExtend2", "GamblerRandom",
    "GlitchEffect", "GunnerEmpower", "Haste", "HasteThief", "Heavy",
    "HungerBuildup", "HunterTrap", "Infernal", "Injured", "MummyCapture",
    "MummySpinAnim", "MummySpinCancel", "MummyThrow", "Overdrive",
    "Overheat", "Pull", "Purify", "Reboot", "RocketeerBurn", "RocketeerOil",
    "Shock", "Slow", "Stagger", "StaggerLong", "StealthWarning", "Stun",
    "StunLong", "SubClassTag",
    "TargetMark", "TurkeyBurn", "UndeadSave", "Unstoppable", "VampireBite",
    "WerewolfAttack",
}

local function scanEffectFolder(folder, set)
    if not folder then return end
    for _, ch in ipairs(folder:GetChildren()) do
        if ch:IsA("BillboardGui") then set[ch.Name] = true end
    end
end

local function effectCatalog(force)
    if S.effects and not force then return S.effects end
    local set = {}
    scanEffectFolder(RS:FindFirstChild("Effects"), set)
    for _, rootName in ipairs({ "Classes", "SubClasses" }) do
        local root = RS:FindFirstChild(rootName)
        if root then
            for _, cls in ipairs(root:GetChildren()) do
                scanEffectFolder(cls:FindFirstChild("Effects"), set)
            end
        end
    end
    if not next(set) then
        for _, n in ipairs(EFFECT_FALLBACK) do set[n] = true end
    end
    for _, n in pairs(STRING_EFFECTS) do set[n] = true end
    local list = {}
    for n in pairs(set) do list[#list + 1] = n end
    table.sort(list, function(a, b) return a:lower() < b:lower() end)
    S.effects = list
    return list
end

-- ---- effect safety ----
-- Read off the v5.14.2 EffectApply call sites, one entry per victim argument.
--   SAFE    a dumped site applies this exact Instance to a hit enemy, so the
--           payload is a shape the server already sees from real clients
--   MEDIUM  genuine enemy sites, but event-gated (TurkeyBurn is PUMPKIN-only)
--   RISK    self-only Instance, or a proven kick. 0247.lua:82 gates even the
--           hitbox result on 'v == LocalPlayer.Character'
--   ?       no known enemy site — DEFAULT-DENY, treated like RISK at another
--           player, because 61 of 71 RS.Effects children are orphans that no
--           client ever emits and sending one is exactly what earns the kick
local EFFECT_SAFE_ENEMY = {
    "Capture", "Charmed", "Cripple", "DamageDebuffThief",
    "DefenseDebuffGunnerCrit", "Frostbite", "FrostbiteExtend2", "GamblerRandom",
    "Knockback", "Knockup", "MummyCapture", "MummySpinAnim", "MummySpinCancel",
    "MummyThrow", "Pull", "Release", "Slow", "StaggerLong",
    "StunLong", "VampireBite", "WerewolfAttack",
}
local EFFECT_MEDIUM_ENEMY = { "TurkeyBurn" }
local EFFECT_SELF_ONLY = {
    "Bind", "BossStun", "BurnInfernus", "BurnMap", "DefenseDebuff",
    "ForceFieldInfernus", "Freeze", "GhostUntargetable", "Haste",
    "Hunger", "KnockbackAOE", "Shock", "Stagger",
}
-- Proven Agency kicks (2026-07-25 log). Bare "Stun" only reaches this list if
-- the canon GOLEM path is missing from the build — CANON_PATH.stun otherwise
-- resolves the name to the class-scoped Instance and classifies it SAFE.
local EFFECT_KICK_PROVEN = {
    "Stun", "Freeze", "UndeadSave",
}

local function lowerSet(list)
    local set = {}
    for _, n in ipairs(list) do set[n:lower()] = true end
    return set
end

local SAFE_SET = lowerSet(EFFECT_SAFE_ENEMY)
local MEDIUM_SET = lowerSet(EFFECT_MEDIUM_ENEMY)
local SELF_SET = lowerSet(EFFECT_SELF_ONLY)
local KICK_SET = lowerSet(EFFECT_KICK_PROVEN)
local EFFECT_TAG =
    { safe = "SAFE", medium = "MEDIUM", risk = "RISK", unknown = "?" }
local RISK_NOTE = {
    stun = "RS.Effects.Stun is an orphan with zero emit sites — kicked 2026-07-25",
    freeze = "RS.Effects.Freeze is self-only — enemy Freeze kicked 2026-07-25",
    undeadsave = "orphan asset, zero call sites — kicked 2026-07-25",
}

-- "safe" | "medium" | "risk" | "unknown"
local function effectClass(name)
    local k = tostring(name):lower()
    if k:find("/", 1, true) then
        local e = CANON_BY_PATH[normPath(k)]
        return e and e.risk or "unknown"
    end
    local c = CANON_PATH[k]
    if c then return c.risk end
    if SAFE_SET[k] then return "safe" end
    if MEDIUM_SET[k] then return "medium" end
    if KICK_SET[k] or SELF_SET[k] then return "risk" end
    return "unknown"
end

local function riskReason(name, cls)
    local k = tostring(name):lower()
    if RISK_NOTE[k] then return RISK_NOTE[k] end
    if cls == "unknown" then
        return "no dumped enemy call site — most RS.Effects children are "
            .. "orphans no client emits, and that Instance is what gets kicked"
    end
    return "every dumped call site targets your own character"
end

-- exact -> prefix -> substring, same fail-soft policy as findPlayer
local function resolveEffectName(query)
    if not query or query == "" then return nil, "no effect given" end
    -- explicit path: literal, never name-resolved, so 'SubClasses/GOLEM/Stun'
    -- can never slide onto RS.Effects.Stun
    if query:find("/", 1, true) then
        if walkPath(query) then return query end
        return nil, "no Instance at RS." .. query:gsub("/", ".")
    end
    local q = query:lower()
    local tiers = { {}, {}, {} }
    for _, n in ipairs(effectCatalog(false)) do
        local ln = n:lower()
        if ln == q then
            tiers[1][#tiers[1] + 1] = n
        elseif ln:sub(1, #q) == q then
            tiers[2][#tiers[2] + 1] = n
        elseif ln:find(q, 1, true) then
            tiers[3][#tiers[3] + 1] = n
        end
    end
    for _, hits in ipairs(tiers) do
        if #hits == 1 then return hits[1] end
        if #hits > 1 then
            return nil, "ambiguous effect '" .. query .. "': "
                .. table.concat(hits, ", ")
        end
    end
    -- not in the catalog but the live tree may still hold it
    if resolveEffect(query) then return query end
    return nil, "unknown effect '" .. query .. "' — run 'effects'"
end

local function bestEffectName(frag)
    if frag == "" then return nil end
    local best
    for _, n in ipairs(effectCatalog(false)) do
        if n:lower():sub(1, #frag) == frag and (not best or #n < #best) then
            best = n
        end
    end
    return best
end

-- quiet: skip the per-invoke return line. Only loopeffect passes it — at
-- 3 fires a second the log would be nothing but 'effect return:'.
local function sendEffect(victimChar, effectInstOrString, tag, quiet)
    local pw = password()
    if not pw then return false, pwError() end
    local effect = resolveEffect(effectInstOrString)
    if not effect then return false, "no effect" end
    local head = victimChar and victimChar:FindFirstChild("Head")
    if not head then return false, "no head" end
    local effectName = typeof(effect) == "Instance" and effect.Name or tostring(effect)
    local remote = S.effectRemote or RS.Remotes:FindFirstChild("EffectApply")
    if not remote then return false, "no EffectApply" end
    task.spawn(function()
        local conn
        if tag then
            -- gate the line on effect+victim, not on the command tag: one
            -- shared 'confirmed.effect' latch meant the first effect that
            -- landed silenced every probe after it. The command tag still
            -- flips for the UI mark.
            conn = head.ChildAdded:Connect(function(child)
                if not S.alive then return end
                local cn = child.Name
                if cn == effectName or cn:find(effectName, 1, true) then
                    local pl = Players:GetPlayerFromCharacter(victimChar)
                    local key = effectName .. "|" .. tostring(pl and pl.UserId or "?")
                    if not S.fxConfirmed[key] then
                        S.fxConfirmed[key] = true
                        S.fxSeen[effectName] = true
                        S.confirmed[tag] = true
                        log("effect CONFIRMED on "
                            .. (pl and pl.Name or "?") .. " (" .. cn .. ")")
                        if refreshRows then refreshRows() end
                    end
                end
            end)
        end
        local ok, result = pcall(function()
            return remote:InvokeServer({
                pw, victimChar, effect, head, nil, nil, nil,
            })
        end)
        if not quiet then
            -- the path is the whole story on a kick post-mortem: two Instances
            -- can share a Name and only one of them is legal
            log("effect " .. effectPath(effect) .. " return: "
                .. tostring(ok and result or result))
        end
        task.wait(1.2)
        if conn then conn:Disconnect() end
    end)
    return true
end

-- ---- loopeffect ----

local function stopLoops(player)
    local n = 0
    for key, L in pairs(S.loops) do
        if not player or L.player == player then
            S.loops[key] = nil
            n = n + 1
        end
    end
    return n
end

local function countLoops()
    local n = 0
    for _ in pairs(S.loops) do n = n + 1 end
    return n
end

-- A loop dies on its own when the target leaves or loses its character, so a
-- forgotten 'loopeffect' never keeps firing at a stale Instance.
local function tickLoops()
    if not S.alive then return end
    ensureCM()
    local now = os.clock()
    for key, L in pairs(S.loops) do
        local p = L.player
        local char = p and p.Character
        if not p or p.Parent ~= Players or not char then
            S.loops[key] = nil
        elseif now - L.last >= L.interval then
            L.last = now
            sendEffect(char, L.name, nil, true)
        end
    end
end

local function sendHeal(targetChar, amount, tag)
    local pw = password()
    if not pw then return false, pwError() end
    track(targetChar, amount, "Heal", tag)
    -- 4 fields, NO serverTime (0003.lua:2487)
    async(function()
        S.healRemote:InvokeServer({ pw, targetChar, amount, nil })
    end)
    return true
end

local function selfHeal(amount)
    local char = lp.Character
    if not S.cm or not char then return false end
    async(function() S.cm:Heal(char, amount, nil) end)
    return true
end

-- ---- loopheal ----
-- Same two heal paths as the one-shots: ClassModule:Heal for yourself,
-- forged Heal:InvokeServer for anyone else. Only the cadence is new.

local function stopHealLoops(player)
    local n = 0
    for key, L in pairs(S.healLoops) do
        if not player or L.player == player then
            S.healLoops[key] = nil
            n = n + 1
        end
    end
    return n
end

local function countHealLoops()
    local n = 0
    for _ in pairs(S.healLoops) do n = n + 1 end
    return n
end

-- A loop on someone else dies when they leave. The self loop survives death
-- and respawn — it simply has nothing to heal until the character is back.
local function tickHealLoops()
    if not S.alive then return end
    local now = os.clock()
    for key, L in pairs(S.healLoops) do
        local char
        if L.selfTarget then
            char = lp.Character
        elseif not L.player or L.player.Parent ~= Players then
            S.healLoops[key] = nil
        else
            char = L.player.Character
        end
        if char and now - L.last >= L.interval then
            L.last = now
            if L.selfTarget then
                selfHeal(L.amount)
            else
                sendHeal(char, L.amount, "loopheal")
            end
        end
    end
end

-- ============ cooldowns / speed ============

local function rememberFull(key, full)
    if type(full) ~= "number" or full <= 0 then return end
    local k = tostring(key)
    if not S.fullCd[k] or full > S.fullCd[k] then S.fullCd[k] = full end
end

local function processTable(tbl, zero)
    if not tbl then return end
    for k, v in pairs(tbl) do
        if v ~= "Perm" and type(v) == "number" then
            if zero then
                if v > 0 then tbl[k] = 0 end
            else
                local key = tostring(k)
                if v <= 0.001 then
                    S.fullCd[key] = nil
                else
                    if not S.fullCd[key] or v > (S.fullCd[key] + 0.05) then
                        rememberFull(key, v)
                    end
                    local full = S.fullCd[key]
                    if full then
                        local fl = full * S.cdMult
                        if fl < S.minCd and full >= S.minCd then fl = S.minCd end
                        if v > fl + 0.01 then tbl[k] = fl end
                    end
                end
            end
        end
    end
end

local function processFlags(tbl)
    if not tbl then return end
    for k in pairs(tbl) do tbl[k] = false end
end

local function dataOf(cm, sub)
    local fn = sub and cm.GetCurrentSubClassData or cm.GetCurrentClassData
    if not fn then return nil end
    local ok, d = pcall(function() return fn(cm) end)
    return ok and d or nil
end

local function processData(d, zero)
    if not d then return end
    processTable(d.CooldownNumber, zero)
    processTable(d.StackCooldownNumber, zero)
    if zero then
        processFlags(d.OnCooldown)
        processFlags(d.StackOnCooldown)
    end
end

local function anyRecastHold(cm)
    local function scan(d)
        if not d or not d.OnRecast then return false end
        for _, v in pairs(d.OnRecast) do if v == true then return true end end
        return false
    end
    return scan(dataOf(cm, false)) or scan(dataOf(cm, true))
end

local function sweepCd()
    local cm = S.cm
    if not cm or S.cdMode == "off" then return end
    local zero = S.cdMode == "zero"
    processData(dataOf(cm, false), zero)
    processData(dataOf(cm, true), zero)
    if zero then
        if cm.LoadedClasses then
            for _, d in pairs(cm.LoadedClasses) do processData(d, true) end
        end
        if cm.LoadedSubClasses then
            for _, d in pairs(cm.LoadedSubClasses) do processData(d, true) end
        end
    end
    local nac = cm.NonAbilityCooldowns
    if nac then
        processTable(nac.CooldownNumber, zero)
        if zero then processFlags(nac.OnCooldown) end
    end
    if zero and not anyRecastHold(cm) then
        cm.ToolDisable = false
        cm.NonAbilityTD = false
    end
end

local function canAct(self)
    local ch = self.Character
    if not ch or self:CheckAlive(ch) == false then return false end
    local st = ch:FindFirstChild("Stats")
    if st and st:FindFirstChild("Disable") and st.Disable.Value > 0 then return false end
    if self.HasEffect and self:HasEffect("Stop") then return false end
    return true
end

local function canBypass(self, moveName, isSub)
    if S.cdMode ~= "zero" then return false end
    if not canAct(self) then return false end
    if self.ToolDisable == true then return false end
    local d = isSub and dataOf(self, true) or dataOf(self, false)
    if moveName and d and d.OnRecast and d.OnRecast[moveName] == true then
        return false
    end
    return true
end

local function baseSpeedValue()
    local ch = lp.Character
    local st = ch and ch:FindFirstChild("Stats")
    local bs = st and st:FindFirstChild("BaseSpeed")
    if bs and (bs:IsA("NumberValue") or bs:IsA("IntValue")) then return bs end
    return nil
end

-- Force the game to recompute Humanoid.WalkSpeed from Stats.
--
-- Writing Stats.BaseSpeed does NOT move you. The actual assignment lives in
-- UpdateWalkSpeed (0003.lua:2530):
--
--   Humanoid.WalkSpeed = (NoWalk or NoSubWalk) and 0
--       or Stats.BaseSpeed.Value + Stats.ChangedSpeed.Value + LocalSpeed
--
-- and until something calls it, our write just sits in the value.
--
-- The two names tried below DO NOT EXIST. UpdateWalkSpeed is a file-scope
-- function in 0003.lua, not a member of the ClassModule -- there is no
-- `cm.UpdateWalkSpeed` and no `cm.UpdateSpeed` -- so both type() checks failed
-- and this whole function was a silent no-op. The speed buff worked only when
-- the game happened to recompute for its own reasons (an effect landing, an
-- ability, a class change), which is why it could feel inconsistent between
-- classes: ARCHER recomputes constantly because charging calls
-- DecreaseWalkSpeed, while a class that never touches its speed might not
-- recompute for a long time.
--
-- IncreaseWalkSpeed IS a real method (0003.lua:2533) and ends in
-- UpdateWalkSpeed(classData). Called with a delta of ZERO it changes nothing
-- and forces the recompute -- the game's own oracle, so NoWalk, ChangedSpeed
-- and per-class LocalSpeed all keep their exact meaning.
--
-- Deliberately NOT writing Humanoid.WalkSpeed directly: that would duplicate
-- the formula, and it would override the `NoWalk -> 0` branch, letting us move
-- during stuns. That is a behaviour change nobody asked for and a visible tell.
local function updateWalkSpeed()
    local cm = S.cm
    if not cm then return end
    -- Real, and the one that works. Zero delta: recompute without changing.
    -- The old UpdateWalkSpeed/UpdateSpeed probes are deleted (5b): neither
    -- method exists on the ClassModule (UpdateWalkSpeed is file-scope in
    -- 0003.lua), so both type() checks failed on every call for the life of
    -- the script -- a method-existence probe guarding a state that cannot occur.
    if type(cm.IncreaseWalkSpeed) == "function" then
        pcall(function() cm:IncreaseWalkSpeed(0) end)
    end
end

local function restoreSpeed()
    local bs = baseSpeedValue()
    if bs and S.origBaseSpeed ~= nil and S.lastWritten ~= nil
        and math.abs(bs.Value - S.lastWritten) <= 0.01 then
        pcall(function() bs.Value = S.origBaseSpeed end)
        updateWalkSpeed()
    end
    S.origBaseSpeed = nil
    S.lastWritten = nil
end

local function applySpeed()
    if not S.speedOn or not inMatch() then
        if S.origBaseSpeed ~= nil then restoreSpeed() end
        return
    end
    local bs = baseSpeedValue()
    if not bs then return end
    local cur = bs.Value
    if type(cur) ~= "number" then return end
    -- re-derive native each frame so the bonus cannot ratchet
    if S.lastWritten == nil or math.abs(cur - S.lastWritten) > 0.01 then
        S.origBaseSpeed = cur
    end
    if S.origBaseSpeed == nil then return end
    local target = S.origBaseSpeed + S.speedBonus
    if math.abs(cur - target) > 0.01 then
        pcall(function() bs.Value = target end)
        updateWalkSpeed()
    end
    S.lastWritten = target
end

-- ============ hooks ============

local function hookCd(name, fn)
    if type(fn) ~= "function" or S.orig[name] then return end
    S.orig[name] = fn
    local function wrapped(self, moveName, duration, ...)
        local ret = S.orig[name](self, moveName, duration, ...)
        if S.cdMode ~= "off" then
            if type(duration) == "number" then rememberFull(moveName, duration) end
            sweepCd()
        end
        return ret
    end
    if hookfunction then
        S.orig[name] = hookfunction(fn, wrapped)
    else
        S.cm[name] = wrapped
    end
end

local function hookGate(name, fn)
    if type(fn) ~= "function" or S.orig[name] then return end
    S.orig[name] = fn
    local isSub = SUB_GATES[name] == true
    local function wrapped(self, moveName, ...)
        if S.orig[name](self, moveName, ...) then return true end
        if canBypass(self, moveName, isSub) then return true end
        return false
    end
    if hookfunction then
        S.orig[name] = hookfunction(fn, wrapped)
    else
        S.cm[name] = wrapped
    end
end

-- amp: scale the client-supplied dmg on genuine swings. Rides real swing
-- context, so it is not subject to the ~45 stud cap that raw fire hits.

-- RETIRED PER-CLASS MODULES
--
-- cs_admin used to be able to load eight standalone heatseek modules
-- (cs_sniper_heatseek, cs_chronos_heatseek, cs_swordmancer_heatseek,
-- cs_elementalist_heatseek, cs_trickster_heatseek and three ally echo variants)
-- through an ensureModule() loader, as a "fallback" alongside the engine.
--
-- That loader WAS the duplicate-projectile bug. Each module installs its own
-- ClientProjectiles watcher, and the three ally variants each forge their own
-- echo for the same source bolt. With the engine also running, one ally cast
-- produced up to four bodies: the ally's bolt, the engine's echo, and one echo
-- per legacy ally module. The self modules fail differently but just as badly --
-- they steer the game's own body without knowing about CORE_TAG, so two
-- steerers fight over one mover, which reads as "heatseek just doesn't work".
--
-- Evidence it was live, not theoretical: cs_ally_echo_hs.log,
-- cs_ally_elem_echo_hs.log and cs_ally_trick_echo_hs.log were all being written
-- at 2026-07-30 04:34, in the same session as a current-stamp cs_core.log, each
-- logging ProjectileAdded for the same bodies. Nothing in the UI asked for
-- them: pushAllyNameAllModules called ensureAllyEcho/Elem/Trick "to keep the
-- legacy hs ally* commands in sync", so naming a single ally loaded all three.
--
-- The loader, the eight globals, the per-class `hs` subcommands and the
-- musketeer-echo tuning rows are all gone. What remains is the purge below,
-- because deleting the loader does not stop a module that an EARLIER inject in
-- this same session already started -- that instance lives in getgenv with its
-- connections attached and needs destroying.
--
-- Sources kept for reference in scripts/_archive/. Nothing loads them.
local RETIRED_GLOBALS = {
    "__CS_ALLY_ECHO_HS", "__CS_ALLY_ELEM_ECHO_HS", "__CS_ALLY_TRICK_ECHO_HS",
    "__CS_SNIPER_HEATSEEK", "__CS_CHRONO_HEATSEEK", "__CS_SWORDMANCER_HEATSEEK",
    "__CS_ELEMENTALIST_HEATSEEK", "__CS_TRICKSTER_HEATSEEK",
}

local function purgeRetiredModules()
    local killed = {}
    for _, gkey in ipairs(RETIRED_GLOBALS) do
        local api = G[gkey]
        if api then
            if type(api.destroy) == "function" then pcall(api.destroy) end
            G[gkey] = nil
            killed[#killed + 1] = gkey
        end
    end
    if #killed > 0 then
        Log.warn(("purged %d retired heatseek module(s) left running by an earlier inject: %s")
            :format(#killed, table.concat(killed, ", ")))
    end
    return #killed
end

purgeRetiredModules()

-- Streamed class folder may appear only after LoadClass in-match.
--
-- Skins rename the folder to "Projectile"..Skin (OverrideProjectile 0704:284),
-- e.g. ProjectileWoodland, so this prefix-matches the class folder's children
-- instead of asking for an exact "Projectile" child. Asking exactly is what
-- made the elementalist probe report "not streamed" for every skinned user.
local function classProjectileStreamProbe(className)
    local cf = walkPath("Classes/" .. className)
    if not cf then return false end
    for _, ch in ipairs(cf:GetChildren()) do
        if ch.Name:sub(1, 10) == "Projectile" then return true end
    end
    return false
end

local function elemProjectileStreamProbe()
    return classProjectileStreamProbe("ELEMENTALIST")
end

local function trickProjectileStreamProbe()
    return classProjectileStreamProbe("TRICKSTER")
end

-- These two must stay above resolveAllyRawCanonical: Lua resolves an unseen
-- local as a global, so declaring them later made every APPLY / 'ally' call
-- error with "attempt to call a nil value (global 'trimAllyRaw')".
local function trimAllyRaw(s)
    return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function allyRawHasMulti(raw)
    return string.find(raw, "[,;]") ~= nil
end

local function resolveAllyRawCanonical(raw)
    raw = trimAllyRaw(raw)
    if raw == "" then return "" end
    if not allyRawHasMulti(raw) then
        local p = findPlayer(raw)
        return p and p.Name or raw
    end
    local parts = {}
    for token in string.gmatch(raw, "[^,;]+") do
        local t = token:match("^%s*(.-)%s*$")
        if t ~= "" then
            local p = findPlayer(t)
            parts[#parts + 1] = p and p.Name or t
        end
    end
    return table.concat(parts, ",")
end

local function countAllyTokensInServer(raw)
    local n = 0
    for token in string.gmatch(raw, "[^,;]+") do
        local t = token:match("^%s*(.-)%s*$")
        if t ~= "" then
            local p = findPlayer(t)
            if p then n = n + 1 end
        end
    end
    return n
end

local function pushAllyNameAllModules(name)
    local n = resolveAllyRawCanonical(tostring(name or ""))
    -- Engine only. This used to also call ensureAllyEcho / ensureAllyElemEcho /
    -- ensureAllyTrickEcho "to keep the legacy modules in sync", which meant
    -- naming a single ally silently LOADED all three retired ally modules --
    -- each with its own watcher and its own echo forge. See LEGACY_RETIRED.
    local core = engine()
    if core then core.setAllyNames(n) end

    -- Mirror into S so the config layer persists it. The autosave is diff-based
    -- on a 5s tick, so assigning here is the whole of "saving" -- there is no
    -- save() call to forget at this or any other mutation site.
    S.allyNames = n

    if n ~= "" then
        Log.info("ally push modules: " .. n)
        local onServer = countAllyTokensInServer(n)
        local tokens = 0
        for _ in string.gmatch(n, "[^,;]+") do tokens = tokens + 1 end
        if onServer < tokens then
            Log.warn(("ally: %d/%d name(s) not in server — typo or not joined yet"):format(
                onServer, tokens))
        end
    end
end

local function appendAllyBoxName(cur, pName)
    cur = trimAllyRaw(cur)
    if cur == "" then return pName end
    local pl = string.lower(pName)
    for token in string.gmatch(cur, "[^,;]+") do
        if string.lower(token:match("^%s*(.-)%s*$") or "") == pl then return cur end
    end
    return cur .. ", " .. pName
end

local ALLY_REQUIRED_MSG = "set ally first: ally <name>"


local function hookDamage(fn)
    if type(fn) ~= "function" or S.orig.Damage then return end
    S.orig.Damage = fn
    local function wrapped(self, victim, dmg, dtype, sound, sync, extra)
        local out = dmg
        if S.ampOn and type(dmg) == "number" and dmg > 0 then
            -- The retired-module echo-skip that used to live here is gone
            -- (CS_CONSTRAINTS.md 5b). It walked three __CS_ALLY_*_HS globals
            -- that can never exist since the loader was deleted, so the scan
            -- allocated a table per damage call and always fell through. The
            -- engine's shared damage ledger (Core.canDamage) is what actually
            -- coordinates echo vs amp double-hits now.
            out = dmg * S.ampMult
            if victim then track(victim, out, "Damage", "amp") end
        end
        return S.orig.Damage(self, victim, out, dtype, sound, sync, extra)
    end
    if hookfunction then
        S.orig.Damage = hookfunction(fn, wrapped)
    else
        S.cm.Damage = wrapped
    end
end

local function restoreHooks()
    if not S.cm then return end
    for name, fn in pairs(S.orig) do
        pcall(function() S.cm[name] = fn end)
    end
    S.orig = {}
end

-- ============ loop ============

local function tickAuras()
    local now = os.clock()
    if S.reachOn and now - S.lastReach >= S.fireInterval then
        local t = nearest(S.reachRange)
        if t and not isSafeProtected(t.char) then
            S.lastReach = now
            sendDamage(t.char, S.reachDmg, nil)
        end
    end
    if S.healAuraOn and now - S.lastHeal >= S.fireInterval then
        local t = nearest(S.healRange)
        if t then
            S.lastHeal = now
            sendHeal(t.char, S.healAmount, "healaura")
        end
    end
    if S.ladder and now - S.lastLadder >= 0.8 then
        S.ladderIdx = S.ladderIdx + 1
        local v = S.ladder[S.ladderIdx]
        if not v then
            log(string.format("ladder done — highest confirmed: %s",
                S.ladderMax > 0 and tostring(S.ladderMax) or "none"))
            S.ladder = nil
        else
            local t = nearest(S.reachRange)
            if t and not isSafeProtected(t.char) then
                S.lastLadder = now
                sendDamage(t.char, v, "ladder")
                log("ladder " .. tostring(v))
            else
                S.ladderIdx = S.ladderIdx - 1
            end
        end
    end
end

local function tick()
    if not S.alive then return end
    -- Loops must run before arm() — ensureCM()+password work pre-hook, and
    -- 'stun' / 'loopeffect' registered while waiting for ClassModule still
    -- need refires once you are in-match (see logs: lock message before armed).
    tickLoops()
    tickHealLoops()
    -- Reap BEFORE the armed gate. loopheal/stun registered pre-match still
    -- track() pending confirmations, and with reap() below the gate the
    -- pending list grew unbounded until the first arm.
    reap()
    if not S.armed then return end
    local c = currentClassName()
    if c ~= S.lastClass then
        S.lastClass = c
        S.fullCd = {}
        -- Re-derive the speed baseline whenever the class changes, INCLUDING
        -- the change to nil at the end of a round.
        --
        -- applySpeed only notices that the game moved BaseSpeed when the new
        -- value differs from what we last wrote. Every class has its own native
        -- BaseSpeed, so sooner or later the game sets it to a number that
        -- happens to equal our inflated one -- and at that moment the guard goes
        -- quiet, origBaseSpeed stays pinned to the PREVIOUS class's native, and
        -- the bonus is silently absorbed: target == native, nothing is written,
        -- and the buff is gone with no way to notice from inside applySpeed.
        --
        -- Toggling does not recover it either. `speed off` restores the stale
        -- origBaseSpeed, which now sits BELOW the real native, so off is slower
        -- than everyone else and on is merely normal. That is the whole of
        -- "speed stopped working and toggling it does nothing" -- the bind was
        -- dispatching correctly the entire time (six flips logged in one second
        -- at 18:33:53, four more at 18:46:44).
        --
        -- CharacterAdded already clears these, but it is not enough on its own:
        -- a class swap inside one life never fires it, and on respawn it clears
        -- them and then the very next Heartbeat latches whatever BaseSpeed the
        -- game has set SO FAR for the new class. Keying on CurrentClass instead
        -- means the baseline is taken after the class is actually the new one.
        --
        -- restoreSpeed(), NOT a bare nil of the two fields: if the game has not
        -- yet written the new class's BaseSpeed, ours is still sitting in it,
        -- and re-deriving from that would take our own inflated number as the
        -- native and add the bonus a second time. restoreSpeed puts the old
        -- native back first -- and only when our write is still intact -- then
        -- clears both fields, which is exactly the ordering needed here.
        restoreSpeed()
    end
    if not inMatch() then return end
    sweepCd()
    applySpeed()
    tickAuras()
end

-- ============ commands ============

local CMDS = {}
local ORDER = {}

local function cmd(name, risk, help, fn)
    CMDS[name] = { risk = risk, help = help, fn = fn }
    ORDER[#ORDER + 1] = name
end

-- ---- native debug visuals ----
--
-- Both of these are flags the client reads locally (ClassModule.HitboxDebugMode
-- 0003.lua:3926, workspace.GameSetting.ProjectileDebug 0704.lua:215). They send
-- nothing and need no rank -- the game draws every hitbox as a red ForceField
-- part and tints projectiles pink. Free ground truth for tuning the engine.

local function setHitboxDebug(on)
    local cm = S.cm
    if not cm then
        local core = engine()
        cm = core and core.requireCM()
    end
    if not cm then return false, "ClassModule unavailable — wait for a match" end
    local ok = pcall(function() cm.HitboxDebugMode = on and true or false end)
    if not ok then return false, "could not set HitboxDebugMode" end
    S.hitboxDebug = on and true or false
    return true, "hitbox debug " .. (S.hitboxDebug and "ON" or "OFF")
end

local function setProjectileDebug(on)
    local gs = workspace:FindFirstChild("GameSetting")
    local flag = gs and gs:FindFirstChild("ProjectileDebug")
    if not flag then return false, "GameSetting.ProjectileDebug not present" end
    local ok = pcall(function() flag.Value = on and true or false end)
    if not ok then return false, "could not set ProjectileDebug" end
    S.projDebug = on and true or false
    return true, "projectile debug " .. (S.projDebug and "ON" or "OFF")
end

S.setHitboxDebug = setHitboxDebug
S.setProjectileDebug = setProjectileDebug

cmd("hitboxdebug", "proven", "hitboxdebug [on|off] — draw every hitbox (local only)", function(a)
    local want = a[1]
    if want == nil then want = not S.hitboxDebug else want = (want == "on" or want == "1" or want == "true") end
    return setHitboxDebug(want)
end)

cmd("projdebug", "proven", "projdebug [on|off] — tint projectiles (local only)", function(a)
    local want = a[1]
    if want == nil then want = not S.projDebug else want = (want == "on" or want == "1" or want == "true") end
    return setProjectileDebug(want)
end)

-- Draws the lock geometry the engine is actually using: aim ray, the angular
-- cone AFTER the deviation-budget clamp, the close-lock cylinder, every
-- candidate coloured by whether it would be taken, and each live bolt joined to
-- its locked target.
--
-- Added because the close-range blind spot could not be seen in the log -- a
-- target refused for being 31 deg off at 5 studs logs the same `out of cone`
-- line as one genuinely behind you. Some geometry faults are only visible.
-- Escape hatch for a panel you cannot reach.
--
-- Positions persist now, and a saved position can put rows past the bottom of
-- the screen -- which is unrecoverable through the UI, because the thing you
-- would use to drag it back is the part that is off-screen. That failure cost a
-- real session: the speed toggle read as "frozen" when it was simply below the
-- edge. The clamp should prevent it; this is what you type when it does not.
-- COWBOY High Noon — fire ONE forged round by hand, for testing.
--
-- No on|off any more. The behaviour is armed with its class (`hs COWBOY`) and
-- fires off the `criticalimpact` marker, which is owner-stamped and therefore
-- works for an assisted ally as well as for us -- neither of which a keypress
-- or a global switch could do. This command exists only so the shot can be
-- triggered without waiting for a cast.
--
-- It refuses when COWBOY is not armed, deliberately: a manual fire that bypassed
-- arming would be a second way to put bodies in the world, which is the thing
-- being removed.
cmd("highnoon", "unproven", "highnoon — fire one COWBOY High Noon round now (needs `hs COWBOY`)", function()
    local core = engine()
    if not core then return false, "engine not loaded" end
    if type(core.fireHighNoon) ~= "function" then
        return false, "engine build has no fireHighNoon — rebuild"
    end
    local ok, msg = core.fireHighNoon()
    return ok, msg or (ok and "high noon" or "high noon failed")
end)

cmd("panel", "proven", "panel [reset] — move the HUD back to the default corner", function()
    S.panelX, S.panelY = 24, 120
    if S.resetPanel then pcall(S.resetPanel) end
    return true, "panel reset to 24,120"
end)

cmd("cone", "proven", "cone [on|off] — draw lock cone / candidates / bolt locks", function(a)
    local core = engine()
    if not core then return false, "engine not loaded" end
    local want = a[1]
    if want == nil then want = not core.visualDebugOn()
    else want = (want == "on" or want == "1" or want == "true") end
    local now = core.setVisualDebug(want)
    -- Remembered across reloads and hot reloads. Written to S rather than saved
    -- here directly: persistence is a 5s diff tick, and both teardown paths
    -- (unload, and hot reload) flush before they go, so a toggle made seconds
    -- before a rebuild is not lost.
    S.coneVis = now
    return true, ("cone debug %s%s"):format(now and "ON" or "off",
        now and " — RED=tracking (bolt→its target) · white=aim blue=cone edge green=close-lock yellow=lockable grey=refused" or "")
end)

-- ---- player overlay (ESP) ----
--
-- Reads only. Nothing here fires a remote, touches a character or changes a
-- value: it draws Humanoid.Health/MaxHealth and Stats.CurrentShield/Stats.Shield
-- with the game's own HUD colours (0603.lua:235-243, :180-186) plus a skeleton,
-- all AlwaysOnTop so it renders through geometry.
--
-- Boots OFF and is not persisted. Unlike the combat toggles (CS_CONSTRAINTS.md
-- §3) there is no reason to carry it across an inject, and a lobby full of
-- name tags is exactly the kind of surface a person watching a stream notices.
cmd("esp", "proven", "esp [on|off|skel|dist N|team|status|why] — names, health, shield, skeleton through walls", function(a)
    -- Lazy-loaded from the embedded payload, same mechanism as the forge: the
    -- overlay is dead weight in a session that never turns it on.
    local function espApi()
        if getgenv().__CS_ESP then return getgenv().__CS_ESP end
        local body = ENGINE_PAYLOAD["cs_esp.lua"]
        if not body or #body == 0 then
            Log.warn("esp: payload missing cs_esp.lua — run tools/build_admin.sh")
            return nil
        end
        local ok, err = pcall(function() loadstring(body)() end)
        if not ok then Log.warn("esp: failed to load — " .. tostring(err)) end
        return getgenv().__CS_ESP
    end

    local api = espApi()
    if not api then return false, "esp module not loaded — rebuild with tools/build_admin.sh" end

    local sub = a[1]
    if sub == "status" then return true, api.status() end
    if sub == "why" then
        for _, line in ipairs(api.why()) do Log.info("  " .. line) end
        return true, api.status()
    end
    if sub == "skel" or sub == "skeleton" then
        return true, "skeleton " .. (api.setSkeleton(not api.skeletonOn()) and "on" or "off")
    end
    if sub == "dist" then
        if not tonumber(a[2]) then return false, "esp dist <studs>" end
        return true, ("esp range %d studs"):format(api.setMaxDist(a[2]))
    end
    if sub == "team" or sub == "teamcheck" then
        return true, "teamcheck " .. (api.setTeamCheck(not api.teamCheck()) and "on — allies hidden" or "off")
    end

    local want
    if sub == nil then want = not api.isOn()
    else want = (sub == "on" or sub == "1" or sub == "true") end
    api.setOn(want)
    -- Wait a frame before reporting. status() counts what the last UPDATE did,
    -- and enabling does not run one, so reporting immediately always printed
    -- "0 tagged" no matter what the overlay was doing.
    if want then task.wait() end
    return true, api.status()
end)

-- ---- engine ----

-- "eng" predates the engine-backed `hs` and is kept as an alias surface; both
-- drive the same class registry now. (The old comment about `hs` driving the
-- archived modules was stale — those modules are retired and nothing loads them.)
cmd("eng", "proven", "eng <CLASS|list|off> — toggle engine heatseek per class", function(a)
    local core = engine()
    if not core then return false, "engine not loaded" end
    local sub = string.upper(tostring(a[1] or ""))

    if sub == "" or sub == "LIST" then
        local names = {}
        for name, cfg in pairs(core.classes()) do
            names[#names + 1] = name .. (cfg.enabled and "=on" or "=off")
        end
        table.sort(names)
        return true, "classes: " .. table.concat(names, "  ")
    end

    if sub == "OFF" then
        for name in pairs(core.classes()) do core.setEnabled(name, false) end
        return true, "all heatseek off"
    end

    local cfg = core.getClass(sub)
    if not cfg then return false, "unknown class " .. sub end
    -- Compute the new state explicitly instead of re-reading cfg.enabled after
    -- setEnabled: the message must not depend on whether getClass returned the
    -- live table or a copy.
    local newState = not cfg.enabled
    core.setEnabled(sub, newState)
    return true, ("hs %s %s"):format(sub, newState and "on" or "off")
end)

cmd("hstune", "proven", "hstune [key] [value] — engine tunables", function(a)
    local core = engine()
    if not core then return false, "engine not loaded" end
    local key = a[1]
    if not key then
        local keys = {}
        for k in pairs(core.T) do keys[#keys + 1] = k end
        table.sort(keys)
        return true, "tunables: " .. table.concat(keys, " ")
    end
    if a[2] == nil then
        return true, ("%s = %s"):format(key, tostring(core.T[key]))
    end
    local num = tonumber(a[2])
    local val = num
    if val == nil then
        if a[2] == "true" then val = true elseif a[2] == "false" then val = false end
    end
    if val == nil then return false, "value must be a number or true/false" end
    local ok, err = core.tune(key, val)
    if not ok then return false, err end
    return true, ("%s = %s"):format(key, tostring(val))
end)

-- `legit` answers the only question that matters about heatseek appearance:
-- would somebody watching call this out? It aggregates the per-flight FLIGHT
-- telemetry, names which tell is costing the score, and prints the settings that
-- produced it so a tuning change can be compared to the run before it.
--
-- Detection in this game is a moderator typing aimbotcheck (0691.lua) -- a
-- person, not a heuristic -- so the metric is deliberately "how visible is this",
-- not "would an anticheat flag it".
cmd("legit", "proven", "legit [reset] — how legit does the heatseek look", function(a)
    local core = engine()
    if not core then return false, "engine not loaded" end
    if (a[1] or "") == "reset" then
        core.resetLegitStats()
        return true, "legit stats cleared"
    end
    local L = core.legitReport()
    if L.flights == 0 then
        return true, "legit: no flights yet — arm a class and fire"
    end
    return true, ("legit avg=%.1f over %d flights -> logs/cs_core.log")
        :format(L.scoreSum / L.flights, L.flights)
end)

-- `bench` is the counterpart for frame cost. "The script crashes our game" had
-- no numbers behind it and no way to tell which part was spending the frame.
cmd("bench", "proven", "bench [reset] — engine frame cost and FPS tier", function(a)
    local core = engine()
    if not core then return false, "engine not loaded" end
    if (a[1] or "") == "reset" then
        core.resetBench()
        return true, "bench counters cleared"
    end
    local b = core.benchReport()
    return true, ("bench fps=%.0f engine=%.2fms/frame tier=%s -> logs/cs_core.log")
        :format(b.fps, b.engineMsEma, b.tier)
end)

-- Log categories are switchable at runtime because the useful setting depends on
-- what you are chasing. `mover` and `target` are per-frame firehoses and stay off
-- until something needs them; everything else is on, because a diagnostic behind
-- a debug flag is a diagnostic nobody has when they need it.
cmd("hslog", "proven", "hslog [cat] [on|off] — engine log categories", function(a)
    local core = engine()
    if not core then return false, "engine not loaded" end
    if not a[1] then
        logLine("log categories:")
        logChunks("  ", core.logCats(), 4)
        logLine("  cast ids group one keypress: '#7 claim attack' twice = duplicate")
        return true, "hslog"
    end
    local cat = a[1]:lower()
    if a[2] == nil then
        return true, ("%s = %s"):format(cat, tostring(core.LOGCAT[cat]))
    end
    local ok, err = core.setLogCat(cat, a[2]:lower() ~= "off")
    if not ok then
        return false, (err or "bad category") .. " — try `hslog` for the list"
    end
    return true, ("%s = %s"):format(cat, tostring(core.LOGCAT[cat]))
end)

cmd("hsstats", "proven", "hsstats — locks, hits and top reject reasons", function()
    local core = engine()
    if not core then return false, "engine not loaded" end
    local st = core.getStatus()
    local parts = {
        ("locks=%d hits=%d active=%d"):format(st.locks, st.hits, st.active),
    }
    for _, r in ipairs(core.topRejects(5)) do
        parts[#parts + 1] = ("%s=%d"):format(r.why, r.count)
    end
    return true, table.concat(parts, "  ")
end)

-- Probe 2: does a replicate=false projectile's damage land with no
-- Projectile:FireServer of its own? Marked unproven because it fires a real
-- projectile at a real player -- run it deliberately, not in bulk.
--
-- Until it confirms, the engine stays on the replicating path, which is the
-- one we already know works. A wrong guess here costs a duplicate bolt on
-- other screens; guessing the other way would cost every shot.
cmd("why", "proven", "why <player> — why that person is or is not lockable, right now", function(a)
    local core = engine()
    if not core then return false, "engine not loaded" end
    if not a[1] then return false, "why <player>" end
    local p, err = findPlayer(a[1])
    if not p then return false, err end
    return true, core.explainTarget(p)
end)

cmd("probe2", "unproven", "probe2 [player] — test replicate=false damage", function(a)
    local core = engine()
    if not core then return false, "engine not loaded" end

    local target
    if a[1] then
        local p, ch, err = targetChar(a[1])
        if not p then return false, err end
        target = ch
    end

    local ok, detail = core.runProbe2({ target = target })
    return true, (ok and "PROBE2 " or "PROBE2 ") .. detail
end)

cmd("bodies", "proven", "bodies [CLASS] — real projectile names from the live class folder", function(a)
    local core = engine()
    if not core then return false, "engine not loaded" end
    local want = a[1] and a[1]:upper() or nil
    local list, err = core.listClassBodies(want)
    if not list then return false, err or "not streamed" end
    if #list == 0 then return false, "no projectile bodies found" end

    -- This is the answer to "why does class X do nothing": compare these names
    -- against the class's allow list. Half the roster ships convention-guessed
    -- names marked UNVERIFIED, and a wrong guess fails silently.
    local cfg = core.getClass(want or "")
    local allowed = {}
    if cfg and cfg.allow then
        for _, n in ipairs(cfg.allow) do allowed[n] = true end
    end

    local out = { ("bodies for %s:"):format(want or "current class") }
    for _, b in ipairs(list) do
        local tags = b.bolt and "BOLT" or ""
        if not b.speed then tags = tags .. " no-Speed" end
        if not b.range then tags = tags .. " no-Range" end
        if not b.damage then tags = tags .. " no-Damage" end
        local mark = allowed[b.name] and " <- in allow" or ""
        out[#out + 1] = ("  %-28s %s%s"):format(b.name, tags, mark)
    end
    out[#out + 1] = "BOLT = has Speed+Range+Damage. Compare against the allow list."
    return true, table.concat(out, "\n")
end)

cmd("caps", "proven", "caps — what the engine has proven it can do", function()
    local core = engine()
    if not core then return false, "engine not loaded" end
    return true, core.capsSummary()
end)

cmd("allystatus", "proven", "allystatus — who ally echo actually resolves to", function()
    local core = engine()
    if not core then return false, "engine not loaded" end
    local st = core.allyStatus()
    local out = {
        ("ally raw: %s"):format(st.raw ~= "" and st.raw or "(none set)"),
        ("echo %s · heatseek %s · hide bolt %s"):format(
            st.echo and "ON" or "OFF",
            st.heatseek and "ON" or "OFF",
            st.hideBolt and "ON" or "OFF"),
        ("echoes in flight: %d / %d"):format(st.active, st.maxActive),
    }
    if #st.resolved > 0 then
        out[#out + 1] = "resolves to: " .. table.concat(st.resolved, ", ")
    else
        out[#out + 1] = "resolves to: NOBODY — ally echo cannot fire"
    end
    if #st.unresolved > 0 then
        out[#out + 1] = "NO MATCH in server: " .. table.concat(st.unresolved, ", ")
    end
    out[#out + 1] = "class is auto-detected per bolt; any registered class works"
    return true, table.concat(out, "\n")
end)

cmd("config", "proven", "config [save|reset] — show, force-save, or reset persisted settings", function(a)
    local sub = (a[1] or ""):lower()

    if sub == "save" then
        if not saveConfig() then return false, "writefile unavailable" end
        return true, "config saved to " .. CFG_FILE
    end

    if sub == "reset" then
        -- Restores the shipped defaults for persisted settings only. Toggles are
        -- not in the spec, so nothing that is currently ON gets turned off here.
        for key, def in pairs(CFG_DEFAULTS) do S[key] = def end
        for name, kc in pairs(BIND_DEFAULTS) do BINDS[name] = kc end
        saveConfig()
        return true, "config reset to defaults"
    end

    local core = engine()
    local out = {
        "engine build: " .. tostring(core and core.build or "engine not loaded"),
        "classes registered: " .. tostring(core and core.classCount() or "?"),
        "config file: " .. CFG_FILE,
        "toggles always boot OFF and are not saved",
    }
    local keys = {}
    for key in pairs(CFG_SPEC) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local mark = (S[key] ~= CFG_DEFAULTS[key]) and " *" or ""
        out[#out + 1] = ("  %s = %s%s"):format(key, tostring(S[key]), mark)
    end
    local bindNames = {}
    for name in pairs(BINDS) do bindNames[#bindNames + 1] = name end
    table.sort(bindNames)
    for _, name in ipairs(bindNames) do
        local kc = BINDS[name]
        local mark = (kc ~= BIND_DEFAULTS[name]) and " *" or ""
        out[#out + 1] = ("  bind.%s = %s%s"):format(name, typeof(kc) == "EnumItem" and kc.Name or "?", mark)
    end
    out[#out + 1] = "* = changed from default"
    return true, table.concat(out, "\n")
end)

cmd("hsreset", "proven", "hsreset — clear engine telemetry", function()
    local core = engine()
    if not core then return false, "engine not loaded" end
    core.resetStats()
    return true, "engine stats cleared"
end)

cmd("hslearn", "proven", "hslearn <on|off|status|dump|reset> — passive projectile learn mode", function(a)
    local core = engine()
    if not core then return false, "engine not loaded" end
    local sub = (a[1] or "status"):lower()

    if sub == "on" then
        return core.learnEnable()
    end
    if sub == "off" then
        return core.learnDisable()
    end
    if sub == "status" then
        return true, core.learnStatus()
    end
    if sub == "dump" then
        return core.learnDump()
    end
    if sub == "reset" then
        return core.learnReset()
    end
    return false, "usage: hslearn on|off|status|dump|reset"
end)

cmd("dmg", "proven", "dmg <player> <amount>", function(a)
    local p, char, err = targetChar(a[1])
    if not p then return false, err end
    local n = tonumber(a[2]) or S.reachDmg
    sendDamage(char, n, nil)
    return true, string.format("dmg %s -> %s", tostring(n), p.Name)
end)

cmd("kill", "unproven", "kill <player>", function(a)
    local p, char, err = targetChar(a[1])
    if not p then return false, err end
    local hp = hpOf(char) or 1000
    sendDamage(char, hp + 500, "kill")
    return true, string.format("kill attempt on %s (%s dmg)", p.Name, tostring(hp + 500))
end)

cmd("heal", "proven", "heal [amount]", function(a)
    local n = tonumber(a[1]) or S.selfHealAmount
    S.selfHealAmount = n
    selfHeal(n)
    return true, "self heal " .. tostring(n)
end)

cmd("healother", "unproven", "healother <player> [amount]", function(a)
    local p, char, err = targetChar(a[1])
    if not p then return false, err end
    local n = tonumber(a[2]) or S.healAmount
    sendHeal(char, n, "healother")
    return true, string.format("heal %s -> %s", tostring(n), p.Name)
end)

cmd("healaura", "unproven", "healaura <on|off>", function(a)
    S.healAuraOn = (a[1] ~= "off")
    return true, "healaura " .. (S.healAuraOn and "on" or "off")
end)

cmd("reach", "proven", "reach <on|off|dmg N|range N>", function(a)
    local k = a[1]
    if k == "dmg" then
        S.reachDmg = tonumber(a[2]) or S.reachDmg
        return true, "reach dmg " .. tostring(S.reachDmg)
    elseif k == "range" then
        S.reachRange = tonumber(a[2]) or S.reachRange
        return true, "reach range " .. tostring(S.reachRange)
    end
    S.reachOn = (k ~= "off")
    return true, "reach " .. (S.reachOn and "on" or "off")
end)

cmd("amp", "unproven", "amp <mult|off>", function(a)
    if a[1] == "off" then
        S.ampOn = false
        return true, "amp off"
    end
    S.ampMult = tonumber(a[1]) or S.ampMult
    S.ampOn = true
    return true, "amp x" .. tostring(S.ampMult)
end)

cmd("cd", "proven", "cd <off|half|zero>", function(a)
    local m = a[1]
    if m ~= "off" and m ~= "half" and m ~= "zero" then
        return false, "cd <off|half|zero>"
    end
    S.cdMode = m
    S.fullCd = {}
    return true, "cd " .. m
end)

cmd("speed", "proven", "speed <n|off>", function(a)
    if a[1] == "off" then
        S.speedOn = false
        restoreSpeed()
        return true, "speed off"
    end
    S.speedBonus = tonumber(a[1]) or S.speedBonus
    S.speedOn = true
    return true, "speed +" .. tostring(S.speedBonus)
end)

cmd("ladder", "unproven", "ladder (damage ceiling probe)", function()
    S.ladder = { 10, 25, 50, 100, 250, 500, 1000, 2500 }
    S.ladderIdx = 0
    S.ladderMax = 0
    return true, "ladder started — stay near a target"
end)

-- The grammar is '<player> <name>', but the EFFECTS tab seeds the name first
-- and a hand-typed 'effect Freeze res' reads just as naturally. Accept both
-- orders — only when slot 1 is unambiguously an effect and slot 2 is a real
-- player, so a player whose name looks like an effect is never mis-targeted.
local function isSelfQuery(q) return q == "me" or q == "self" end

-- 'me' / 'self' target your own character. SELF_ONLY effects are exactly the
-- ones the game only ever applies to you, so that is the one shape of them
-- the server already expects — no reason to make them unreachable.
local function targetCharOrSelf(query)
    if isSelfQuery(query) then
        local ch = lp.Character
        if not ch then return nil, nil, "no character" end
        return lp, ch, nil
    end
    return targetChar(query)
end

local function playerEffectArgs(a)
    local pq, eq = a[1], a[2]
    if pq and eq and not findPlayer(pq) and not isSelfQuery(pq)
        and resolveEffectName(pq) and (findPlayer(eq) or isSelfQuery(eq)) then
        return eq, pq
    end
    return pq, eq
end

-- 'effect force <player> <name>' overrides the RISK refusal. Only slot 1 is
-- read as the override, so 'effects force' still filters and an effect whose
-- name starts with Force is never eaten.
local function takeForce(a)
    if a[1] ~= "force" then return a, false end
    local out = {}
    for i = 2, #a do out[#out + 1] = a[i] end
    return out, true
end

-- Default-deny at another player: only SAFE and MEDIUM go out. Your own
-- character is always allowed, since that is the call the dump shows the game
-- making. A canon name whose canon path is missing from this build is
-- downgraded to RISK — the fallback walk would hand back a DIFFERENT Instance
-- than the one that was classified, and that swap is the whole kick vector.
local function riskGuard(verb, name, player, char, forced)
    if char == lp.Character then return true end
    local cls, reason = effectClass(name), nil
    local canon = CANON_PATH[tostring(name):lower()]
    if canon then
        local _, exact = resolveEffect(name)
        if not exact then
            cls = "risk"
            reason = "canonical RS." .. canon.path:gsub("/", ".")
                .. " is missing here, so the bare name resolves to an orphan"
        end
    end
    if cls == "safe" or cls == "medium" then return true end
    reason = reason or riskReason(name, cls)
    if forced then
        log(string.format("force: %s is %s — %s", name, EFFECT_TAG[cls], reason))
        return true
    end
    return false, string.format("%s refused: %s (%s) — '%s force %s %s' to send anyway",
        name, EFFECT_TAG[cls], reason, verb, player.Name, name)
end

cmd("effect", "unproven", "effect [force] <player|me> <name|path>", function(a)
    local args, forced = takeForce(a)
    local pq, eq = playerEffectArgs(args)
    local p, char, err = targetCharOrSelf(pq)
    if not p then return false, err end
    if not eq or eq == "" then
        return false, "effect <player> <name> — run 'effects' for the list"
    end
    local name, nerr = resolveEffectName(eq)
    if not name then return false, nerr end
    local okRisk, rerr = riskGuard("effect", name, p, char, forced)
    if not okRisk then return false, rerr end
    local ok, serr = sendEffect(char, name, "effect")
    if not ok then return false, serr end
    return true, string.format("effect %s [%s] -> %s",
        name, EFFECT_TAG[effectClass(name)], p.Name)
end)

-- Effects expire on a server timer; re-sending the SAME EffectApply payload on
-- an interval is what keeps one pinned. No new remote shape, just cadence.
cmd("loopeffect", "unproven",
    "loopeffect [force] <player|me> <name|path> [interval] | loopeffect off [player]",
    function(a)
    local args, forced = takeForce(a)
    local first = args[1]
    if first == "off" or first == "stop" then
        if args[2] and args[2] ~= "" then
            local p, err = findPlayer(args[2])
            if not p then return false, err end
            return true, string.format("loopeffect off %s — %d stopped",
                p.Name, stopLoops(p))
        end
        return true, string.format("loopeffect off — %d stopped", stopLoops(nil))
    end
    local pq, eq = playerEffectArgs(args)
    local p, char, err = targetCharOrSelf(pq)
    if not p then return false, err end
    if not eq or eq == "" then
        return false, "loopeffect <player> <name> [interval] — 'effects' lists names"
    end
    local name, nerr = resolveEffectName(eq)
    if not name then return false, nerr end
    local okRisk, rerr = riskGuard("loopeffect", name, p, char, forced)
    if not okRisk then return false, rerr end
    local iv = math.max(tonumber(args[3]) or LOOP_INTERVAL, LOOP_MIN_INTERVAL)
    local ok, serr = sendEffect(char, name, "loopeffect")
    if not ok then return false, serr end
    S.loops[tostring(p.UserId) .. "|" .. name] =
        { player = p, name = name, interval = iv, last = os.clock() }
    return true, string.format("loopeffect %s [%s] -> %s every %.2fs (%d active)",
        name, EFFECT_TAG[effectClass(name)], p.Name, iv, countLoops())
end)

cmd("loopheal", "unproven",
    "loopheal [player|me] [amount] [interval] | loopheal off [player|me]",
    function(a)
    local first = a[1]
    if first == "off" or first == "stop" then
        local who = a[2]
        if who == "me" or who == "self" then
            local had = S.healLoops.self ~= nil
            S.healLoops.self = nil
            return true, had and "loopheal off (self)" or "no self heal loop"
        elseif who and who ~= "" then
            local p, err = findPlayer(who)
            if not p then return false, err end
            return true, string.format("loopheal off %s — %d stopped",
                p.Name, stopHealLoops(p))
        end
        return true, string.format("loopheal off — %d stopped", stopHealLoops(nil))
    end
    -- no target, 'me' or 'self' -> the proven ClassModule:Heal path
    if not first or first == "" or first == "me" or first == "self" then
        local amt = tonumber(a[2]) or S.selfHealAmount
        local iv = math.max(tonumber(a[3]) or HEAL_LOOP_INTERVAL,
            HEAL_LOOP_MIN_INTERVAL)
        S.selfHealAmount = amt
        S.healLoops.self =
            { selfTarget = true, amount = amt, interval = iv, last = 0 }
        return true, string.format("loopheal self %s every %.2fs (%d active)",
            tostring(amt), iv, countHealLoops())
    end
    local p, char, err = targetChar(first)
    if not p then return false, err end
    local amt = tonumber(a[2]) or S.healAmount
    local iv = math.max(tonumber(a[3]) or HEAL_LOOP_INTERVAL, HEAL_LOOP_MIN_INTERVAL)
    local ok, serr = sendHeal(char, amt, "loopheal")
    if not ok then return false, serr end
    S.healLoops[tostring(p.UserId)] =
        { player = p, amount = amt, interval = iv, last = os.clock() }
    return true, string.format("loopheal %s %s every %.2fs (%d active)",
        p.Name, tostring(amt), iv, countHealLoops())
end)

-- ---- sustained CC (stun / freeze) ----
-- One EffectApply is a blink: StunLong expires on a server timer and the
-- target walks away. The lock is the cadence — re-fire the SAME legal Instance
-- before it lapses. That is exactly what loopeffect already does, so this
-- rides the same S.loops engine and tickLoops; 'cc = true' is only a marker so
-- 'stun off' stops locks without killing a hand-started loopeffect.
-- Same cadence as loopeffect — StunLong expires on a server timer; 0.5s
-- left gaps where the target walked between refires.
local CC_INTERVAL = LOOP_INTERVAL
local CC_MIN_INTERVAL = LOOP_MIN_INTERVAL

-- Path-first and SAFE-only. Stagger and BossStun are deliberately absent:
-- both are self-only Instances, and a self-only Instance at another player is
-- the shape that gets kicked. GOLEM Stun is referenced BY PATH, never by the
-- bare name, so it can never fall through to the orphan RS.Effects.Stun.
local CC_CHAIN = { "StunLong", "SubClasses/GOLEM/Stun", "StaggerLong" }

local function ccFireRef(ref)
    if ref:find("/", 1, true) then return ref end
    local canon = CANON_PATH[ref:lower()]
    return (canon and canon.path) or ref
end

local function pickCC()
    for _, ref in ipairs(CC_CHAIN) do
        local inst, exact = resolveEffect(ref)
        if exact and typeof(inst) == "Instance" then
            return ccFireRef(ref), inst
        end
    end
    return nil, nil
end

local function stopCC(player)
    local n = 0
    for key, L in pairs(S.loops) do
        if L.cc and (not player or L.player == player) then
            S.loops[key] = nil
            n = n + 1
        end
    end
    return n
end

local function ccCommand(verb, a)
    local first = a[1]
    if first == "off" or first == "stop" then
        if a[2] and a[2] ~= "" then
            local p, err = findPlayer(a[2])
            if not p then return false, err end
            return true, string.format("%s off %s — %d stopped",
                verb, p.Name, stopCC(p))
        end
        return true, string.format("%s off — %d stopped", verb, stopCC(nil))
    end
    local p, char, err = targetChar(first)
    if not p then return false, err end
    local ref, inst = pickCC()
    if not ref then
        return false, "no SAFE stun Instance found "
            .. "(StunLong / SubClasses/GOLEM/Stun / StaggerLong)"
    end
    local iv = math.max(tonumber(a[2]) or CC_INTERVAL, CC_MIN_INTERVAL)
    local ok, serr = sendEffect(char, ref, verb)
    if not ok then return false, serr end
    S.loops[tostring(p.UserId) .. "|" .. ref] =
        { player = p, name = ref, interval = iv, last = os.clock(), cc = true }
    log(verb .. " instance: " .. effectPath(inst))
    return true, string.format("%s locking %s with %s every %.2fs — '%s off' to stop",
        verb, p.Name, inst.Name, iv, verb)
end

cmd("stun", "unproven", "stun <player> [interval] | stun off [player]", function(a)
    return ccCommand("stun", a)
end)

-- 'freeze' is an alias, not a Freeze: RS.Effects.Freeze is a self-only
-- Instance and sending it at another player was kicked on 2026-07-25.
cmd("freeze", "unproven", "freeze <player> [interval] | freeze off [player]",
    function(a)
    return ccCommand("freeze", a)
end)

-- explicit release for the sustained stun/freeze lock; same as 'stun off'
cmd("unstun", "proven", "unstun [player]", function(a)
    if a[1] and a[1] ~= "" then
        local p, err = findPlayer(a[1])
        if not p then return false, err end
        return true, string.format("unstun %s — %d stopped", p.Name, stopCC(p))
    end
    return true, string.format("unstun — %d stopped", stopCC(nil))
end)

cmd("truedmg", "unproven", "truedmg <player> <amount>", function(a)
    local p, char, err = targetChar(a[1])
    if not p then return false, err end
    local n = tonumber(a[2]) or S.reachDmg
    local ok, serr = sendTrueDamage(char, n, "truedmg")
    if not ok then return false, serr end
    return true, string.format("truedmg %s -> %s", tostring(n), p.Name)
end)

local DTYPE_MAP = {
    cross = "Cross", fixed = "Fixed", truedamage = "TrueDamage",
    neutral = "Neutral", safe = "Safe",
}

cmd("dtype", "unproven", "dtype <player> <amount> <type>", function(a)
    local p, char, err = targetChar(a[1])
    if not p then return false, err end
    local n = tonumber(a[2]) or S.reachDmg
    local dt = DTYPE_MAP[a[3] and a[3]:lower() or ""]
    if not dt then return false, "dtype Cross|Fixed|TrueDamage|Neutral|Safe" end
    local ok, serr = sendDamageTyped(char, n, dt, "dtype")
    if not ok then return false, serr end
    return true, string.format("dtype %s %s -> %s", dt, tostring(n), p.Name)
end)

-- Default-deny in the UI too: the list is what a hand reaches for, so it shows
-- only what may legally be aimed at another player. 'effects all' opens the
-- full catalog with every tag, for reading rather than for firing.
cmd("effects", "proven", "effects [all] [filter]", function(a)
    local showAll = (a[1] == "all")
    -- 'all' is consumed, so a bare 'effects all' filters on nothing rather
    -- than on the word "all"
    local filter = showAll and (a[2] or "") or (a[1] or "")
    local rows, hidden = {}, 0
    local n = { safe = 0, medium = 0, risk = 0, unknown = 0 }
    for _, name in ipairs(effectCatalog(true)) do
        local cls = effectClass(name)
        if not (showAll or cls == "safe" or cls == "medium") then
            hidden = hidden + 1
        elseif filter == "" or name:lower():find(filter, 1, true) then
            n[cls] = n[cls] + 1
            rows[#rows + 1] = name .. "[" .. EFFECT_TAG[cls]
                .. (S.fxSeen[name] and "*" or "") .. "]"
        end
    end
    if #rows == 0 then
        return false, "no effect names matched" ..
            (showAll and "" or " — 'effects all' shows the RISK / ? names too")
    end
    logLine("")
    logLine(string.format("EFFECTS (%d)%s%s — apply with: effect <player> <name>",
        #rows, showAll and " ALL" or " sendable",
        (filter ~= "") and (" matching '" .. filter .. "'") or ""))
    logLine("   SAFE = dumped enemy call site   MEDIUM = enemy sites but "
        .. "event-gated   RISK = self-only / proven kick   ? = no known site")
    logLine("   Only SAFE + MEDIUM may be aimed at another player; the rest "
        .. "need 'force'.   * = seen landing live")
    logChunks("   ", rows, 5)
    if not showAll then
        logLine(string.format("   %d RISK/? names hidden — 'effects all'", hidden))
    end
    return true, string.format(
        "%d shown (%d SAFE, %d MEDIUM, %d RISK, %d ?), %d hidden -> console + logs",
        #rows, n.safe, n.medium, n.risk, n.unknown, hidden)
end)

-- one-liners for `help`; long form in DETAIL
local PURPOSE = {
    legit = "how visible is the heatseek to somebody watching",
    bench = "engine frame cost, FPS and the adaptive perf tier",
    dmg = "forged Damage:InvokeServer at any range",
    kill = "damage = target HP + 500, ceiling unknown",
    heal = "heal yourself via ClassModule:Heal",
    healother = "forged Heal on another character",
    healaura = "auto-heal the nearest valid target",
    reach = "damage aura on the nearest target",
    amp = "multiply the dmg of your real swings",
    cd = "ability cooldown clamp (half) or wipe (zero)",
    speed = "BaseSpeed bonus, re-derived each frame",
    ladder = "step damage 10..2500 to find the cap",
    effect = "forged EffectApply — SAFE/MEDIUM only unless you force it",
    loopeffect = "keep one effect pinned by re-firing it",
    loopheal = "heal on a timer — self, or another player",
    stun = "sustained CC: loops StunLong so the target stays locked",
    freeze = "alias of stun — real Freeze is self-only and kicks",
    unstun = "release the stun/freeze lock (all, or one player)",
    truedmg = "Damage with dtype TrueDamage",
    dtype = "Damage with an explicit dtype",
    effects = "sendable effect names; 'effects all' shows RISK too",
    help = "this list, or detail for one command",
    menu = "toggle the toggle panel",
    unload = "tear down hooks, GUI, conns (or press K)",
    ally = "set/clear ally for musk + elem Smolder echo (comma-separated)",
    allyecho = "toggle musketeer ally echo forge",
    allyhs = "toggle musketeer heatseek on your echoes",
    allyelem = "toggle elem Smolder ally echo + heatseek",
    allysmolder = "alias of allyelem",
    allytrick = "toggle ally TRICKSTER card/knife echo + heatseek",
    friend = "add player to heatseek friends whitelist",
    unfriend = "remove from friends whitelist",
    friends = "toggle or list friends whitelist",
    hs = "lazy-load sniper/chrono/sword/elem/ally heatseek; hs off tears down all hub HS",
    config = "show/save/reset persisted settings (toggles always boot OFF)",
    allystatus = "who ally echo resolves to, and whether it is actually armed",
    bodies = "real projectile names for a class, straight from ReplicatedStorage",
    hslearn = "passive observer: capture every player's projectiles for class config",
}

local DETAIL = {
    dmg = { "amount falls back to the current 'reach dmg' setting",
            "PROVEN: 6/10 direct, victim-swap 2/2 at 139-153 studs" },
    kill = { "UNPROVEN — the server may clamp the amount silently" },
    heal = { "no player arg: always you. amount sticks as the new default" },
    healaura = { "heals the nearest valid target on the aura interval" },
    reach = { "reach on|off        arm / disarm the aura",
              "reach dmg N         damage per pulse",
              "reach range N       stud radius (raw fire caps near ~45)" },
    amp = { "amp 3 / amp off. Multiplies ClassModule:Damage;",
            "skips only nearby ally-echo tagged bolts (≤12 studs of victim HRP)" },
    cd = { "off   no interference",
           "half  clamp every cooldown to half its full value",
           "zero  wipe cooldowns and force the move gates open" },
    speed = { "speed 4 adds +4 to BaseSpeed; speed off restores the native value" },
    effect = { "effect <player> <name>  — name is case-insensitive and resolves",
               "through CANON_PATH first, then exact -> prefix -> substring;",
               "ambiguous names list and abort. 'effect me <name>' is always",
               "allowed. A name with a '/' is walked literally instead:",
               "effect res SubClasses/GOLEM/Stun   (the legal Stun Instance)",
               "The kick is Instance identity, not the remote — 'Stun' means",
               "the GOLEM Instance here, never the orphan RS.Effects.Stun.",
               "Only SAFE and MEDIUM go out at another player. RISK and ? are",
               "refused with the reason; 'effect force <player> <name>' sends",
               "one anyway. 'effects' lists the sendable ones, 'effects all'",
               "the whole catalog with tags." },
    loopeffect = {
        "loopeffect res Slow          re-fire Slow on 'res' every 0.35s",
        "loopeffect res Slow 1        one second between fires",
        "loopeffect force res Freeze  send a refused effect anyway (kick risk)",
        "loopeffect off               stop every loop, CC locks included",
        "loopeffect off res           stop only that player's loops",
        "Interval clamps to 0.15s. Same default-deny as 'effect'. A loop drops",
        "itself when the target leaves or respawns without a character.",
        "Unload / K stops every loop.",
    },
    loopheal = {
        "loopheal                     heal yourself every 0.5s",
        "loopheal me 80 1             80 HP a second",
        "loopheal res 40              heal 'res' every 0.5s   [?]",
        "loopheal off | off me | off res",
        "Interval clamps to 0.2s. Self uses ClassModule:Heal (PROVEN); a named",
        "player uses the same forged Heal as 'healother' (UNPROVEN).",
        "Own store — 'loopeffect off' leaves heal loops running. K stops both.",
    },
    effects = { "effects            SAFE + MEDIUM only — what you can send",
                "effects all        the whole catalog, RISK and ? included",
                "effects burn       filter the sendable list",
                "effects all burn   filter the whole catalog",
                "Scanned live from RS.Effects + Classes/SubClasses Effects;",
                "tags come from the v5.14.2 EffectApply call sites." },
    stun = { "stun res           lock 'res' — loops StunLong every 0.35s so the",
             "                   debuff never lapses and they cannot move",
             "stun res 0.35      tighter re-fire (clamps at 0.25s)",
             "stun off           stop every lock    stun off res  stop one",
             "Instance chain, SAFE only: StunLong (BANANDIUM) -> GOLEM Stun by",
             "path -> StaggerLong. Stagger and BossStun are never used: both",
             "are self-only Instances and both kick. Runs on the loopeffect",
             "engine, so 'loopeffect off' and unload / K also stop it.",
             "The exact Instance path sent is logged on every start." },
    freeze = { "freeze res / freeze res 0.35 / freeze off [player]",
               "Same sustained lock as 'stun'. RS.Effects.Freeze is a self-only",
               "Instance — sending it at another player was kicked 2026-07-25,",
               "so this deliberately does NOT send a real Freeze." },
    unstun = { "unstun            stop every stun/freeze lock",
               "unstun res        stop only that player's lock",
               "Same as 'stun off'. Leaves hand-started loopeffect running." },
    dtype = { "type is one of Cross, Fixed, TrueDamage, Neutral, Safe" },
    help = { "help          list every command",
             "help effect   detail for one command",
             "help effects  same as the 'effects' command",
             "An empty Enter in the ']' bar also prints this list." },
    menu = { "MAIN mirrors cd / speed / reach / healaura / amp + self heal",
             "EFFECTS filters the catalog; a click fills the ']' bar",
             "BINDS rebinds every key. RightShift also toggles the panel.",
             "PROJ drives cs_projectile_forge (__CS_PFORGE): list, dmg=10 on select, FIRE.",
             "AIM lazy-loads heatseek modules; toggles ON ensure, OFF destroy (shot HS)." },
    ally = { "ally <name|name1,name2|off>  set echo allies (musk + elem modules)",
             "ally off          clear ally names",
             "Comma or semicolon separates multiple friends.",
             "Loads cs_ally_echo_heatseek.lua if missing." },
    allyecho = { "allyecho on|off   toggle musketeer echo forge" },
    allyhs = { "allyhs on|off     toggle musketeer heatseek on your echoes" },
    allyelem = { "allyelem on|off   elem Smolder ally echo + heatseek (fireability2)",
                 "allysmolder on|off  same" },
    allytrick = { "allytrick on|off  ally TRICKSTER echo + heatseek",
                  "Echoes cards + knives (any non-cosmetic TRICKSTER bolt).",
                  "Magic Baton is never echoed — it swaps the THROWER position." },
    friend = { "friend res        add player to heatseek friends whitelist" },
    unfriend = { "unfriend res      remove from whitelist" },
    friends = { "friends on|off    toggle whitelist (never lock whitelisted)",
                "friends list      print whitelisted names" },
    hs = { "hs sniper|chrono|sword|elem|trick  load + enable that shot heatseek",
           "elem aliases: elementalist, smolder   trick alias: trickster",
           "hs allytrick             ally TRICKSTER echo + hs ON",
           "hs ally                  load ally echo + echo/hs ON",
           "hs off                   destroy all hub-loaded heatseek modules" },
    config = { "config            list persisted settings, * marks changed",
               "config save       force a write now (autosave is every 5s)",
               "config reset      restore shipped defaults",
               "amounts, ranges, multipliers, intervals and keybinds persist",
               "on/off state never persists — everything boots OFF by design",
               "file: cs_admin_config.txt in the Potassium workspace" },
    hslearn = {
        "hslearn on           start observing all players' projectiles",
        "hslearn off          stop observing and finalize data",
        "hslearn status       classes seen, body counts, tracking count",
        "hslearn dump         write candidate registerClass blocks to workspace",
        "hslearn reset        clear all captured data",
        "PASSIVE ONLY — never steers. Boots OFF. Does not persist across injects.",
        "Output: cs_learn_candidates.lua in the Potassium workspace root.",
    },
}

cmd("help", "proven", "help [command]", function(a)
    local q = a[1]
    if q and q ~= "" then
        if q == "effects" then return CMDS.effects.fn({}) end
        local name, c = q, CMDS[q]
        if not c then
            for _, n in ipairs(ORDER) do
                if n:sub(1, #q) == q then name, c = n, CMDS[n] break end
            end
        end
        if not c then return false, "no such command: " .. q end
        local mark = (c.risk == "unproven" and not S.confirmed[name])
            and "   [?] unproven" or ""
        logLine("")
        logLine("  " .. c.help .. mark)
        logLine("    " .. (PURPOSE[name] or ""))
        for _, line in ipairs(DETAIL[name] or {}) do logLine("      " .. line) end
        return true, "help " .. name
    end
    logLine("")
    logLine("CS ADMIN — ? = unproven until the server confirms it live")
    for _, n in ipairs(ORDER) do
        local c = CMDS[n]
        local mark = (c.risk == "unproven" and not S.confirmed[n]) and "?" or " "
        logLine(string.format(" %s %-32s %s", mark, c.help, PURPOSE[n] or ""))
    end
    logLine("   help <command> for detail   |   effects for every effect name")
    return true, "help -> console + logs/cs_admin.log"
end)

-- ALLY + HEATSEEK COMMANDS
--
-- All engine-backed. Every command in this block used to drive one of the
-- retired per-class modules through ensureAllyEcho / ensureAllyElemEcho /
-- ensureAllyTrickEcho, which is how naming an ally silently loaded three extra
-- projectile engines (see RETIRED_GLOBALS).
--
-- allyelem / allysmolder / allytrick are GONE, not ported. They existed because
-- ally support was three per-class modules; the engine detects the ally's class
-- from the bolt's own SourceObj provenance, so a per-class ally command is a
-- category error (CS_CONSTRAINTS.md §3 -- no per-class ally selection, ever).
local function coreOrErr()
    local core = engine()
    if not core then return nil, "engine not loaded" end
    return core
end

cmd("ally", "proven", "ally <player[,player]|off>", function(a)
    local core, err = coreOrErr()
    if not core then return false, err end
    if a[1] == "off" or a[1] == "" or not a[1] then
        pushAllyNameAllModules("")
        return true, "ally cleared"
    end
    local raw = trimAllyRaw(table.concat(a, " "))
    if allyRawHasMulti(raw) then
        local resolved = resolveAllyRawCanonical(raw)
        pushAllyNameAllModules(resolved)
        if countAllyTokensInServer(resolved) == 0 then
            return true, "ally set (no matches in server yet): " .. resolved
        end
        return true, "ally " .. resolved
    end
    local p, perr = findPlayer(a[1])
    if not p then return false, perr end
    pushAllyNameAllModules(p.Name)
    return true, "ally " .. p.Name
end)

cmd("allyecho", "proven", "allyecho <on|off>", function(a)
    local core, err = coreOrErr()
    if not core then return false, err end
    local on = (a[1] ~= "off")
    if on and #core.allyStatus().resolved == 0 then
        return false, ALLY_REQUIRED_MSG
    end
    core.setAllyEchoEnabled(on)
    return true, "allyecho " .. (on and "on" or "off")
end)

cmd("allyhs", "proven", "allyhs <on|off>", function(a)
    local core, err = coreOrErr()
    if not core then return false, err end
    local on = (a[1] ~= "off")
    local st = core.allyStatus()
    if on and #st.resolved == 0 then
        return false, ALLY_REQUIRED_MSG
    end
    -- Steering an echo you never forged is a no-op, so arming heatseek arms the
    -- forge with it rather than leaving the user with two switches and one
    -- visible effect.
    local autoEcho = false
    if on and not st.echo then
        core.setAllyEchoEnabled(true)
        autoEcho = true
    end
    core.setAllyHeatseekEnabled(on)
    return true, "allyhs " .. (on and "on" or "off")
        .. (autoEcho and " (echo auto-on)" or "")
end)

cmd("friend", "proven", "friend <player>", function(a)
    local core, err = coreOrErr()
    if not core then return false, err end
    local p, perr = findPlayer(a[1])
    if not p then return false, perr end
    core.addFriend(p.Name)
    return true, "friend " .. p.Name
end)

cmd("unfriend", "proven", "unfriend <player>", function(a)
    local core, err = coreOrErr()
    if not core then return false, err end
    local p, perr = findPlayer(a[1])
    if not p then return false, perr end
    core.removeFriend(p.Name)
    return true, "unfriend " .. p.Name
end)

cmd("friends", "proven", "friends <on|off|list>", function(a)
    local core, err = coreOrErr()
    if not core then return false, err end
    local sub = a[1]
    if sub == "list" then
        local names = core.friendsList()
        logLine("friends whitelist (" .. #names .. ") — "
            .. (core.friendsWhitelistOn() and "ON: never locked" or "OFF: not enforced"))
        if #names == 0 then
            logLine("  (empty)")
        else
            logChunks("  ", names, 8)
        end
        return true, "friends list"
    end
    if sub == "on" or sub == "off" then
        core.setFriendsWhitelistOn(sub == "on")
        return true, "friends " .. sub
    end
    return false, "friends <on|off|list>"
end)

-- `hs` now drives the engine class registry instead of loading modules.
--
-- The old form was `hs <sniper|chrono|sword|elem|trick|ally|allytrick|off>`:
-- five hardcoded class names, out of sixteen registered, each one loading a
-- retired module. Class names now come from the registry, so this cannot drift
-- out of sync with cs_classes.lua again.
cmd("hs", "proven", "hs <CLASS|all|off|list|ally on|ally off>", function(a)
    local core, err = coreOrErr()
    if not core then return false, err end
    local sub = (a[1] or ""):lower()

    if sub == "" or sub == "list" then
        local names = {}
        for name, cfg in pairs(core.classes()) do
            names[#names + 1] = name .. (cfg.enabled and "=ON" or "=off")
        end
        table.sort(names)
        logLine("engine classes (" .. #names .. "):")
        logChunks("  ", names, 5)
        return true, "hs list"
    end

    if sub == "ally" then
        local on = ((a[2] or "on"):lower() ~= "off")
        if on and #core.allyStatus().resolved == 0 then
            return false, ALLY_REQUIRED_MSG
        end
        core.setAllyEchoEnabled(on)
        core.setAllyHeatseekEnabled(on)
        S.allyAssist = on
        pcall(saveConfig)
        return true, "hs ally " .. (on and "on (echo + heatseek)" or "off")
    end

    if sub == "off" then
        local n = 0
        for name in pairs(core.classes()) do
            core.setEnabled(name, false)
            n = n + 1
        end
        core.setAllyEchoEnabled(false)
        -- `hs off` must SURVIVE a reload, or armAll re-arms everything three
        -- seconds later and the command looks broken. Turning it back on is
        -- `hs all`.
        S.armAll = false
        S.allyAssist = false
        pcall(saveConfig)
        return true, ("hs off — %d classes disarmed, ally echo off (armAll OFF, persists)"):format(n)
    end

    if sub == "all" then
        local n = 0
        for name in pairs(core.classes()) do
            core.setEnabled(name, true)
            n = n + 1
        end
        -- Remembered, so this is also how you turn armAll back ON after an
        -- `hs off`. Without this the two commands would fight the config every
        -- reload.
        S.armAll = true
        pcall(saveConfig)
        return true, ("hs all — %d classes armed (armAll ON, persists)"):format(n)
    end

    -- A class name. Matching is via the engine's own alias resolution so
    -- "chronos", "wind dancer" and "CHRONO" all land on the right config.
    local want = (a[1] or ""):upper()
    local on = ((a[2] or "on"):lower() ~= "off")
    for name, cfg in pairs(core.classes()) do
        if name == want or core.aliasMatches(cfg, want) then
            core.setEnabled(name, on)
            local extra = ""
            if name == "ELEMENTALIST" and not elemProjectileStreamProbe() then
                extra = " (Projectile folder not streamed yet — pick the class in a match)"
            elseif name == "TRICKSTER" and not trickProjectileStreamProbe() then
                extra = " (Projectile folder not streamed yet — pick the class in a match)"
            end
            return true, ("hs %s %s%s"):format(name, on and "on" or "off", extra)
        end
    end
    return false, "no registered class matches '" .. tostring(a[1]) .. "' — try `hs list`"
end)

local toggleMenu  -- fwd
cmd("menu", "proven", "menu", function()
    if toggleMenu then toggleMenu() end
    return true, "menu"
end)

cmd("unload", "proven", "unload", function()
    task.defer(function() S.destroy() end)
    return true, "unloading"
end)

-- which arg slots take a player / effect / command name — drives the ghost
local ARGSPEC = {
    dmg = { "player" }, kill = { "player" }, healother = { "player" },
    effect = { "player", "effect" }, loopeffect = { "player", "effect" },
    loopheal = { "player" }, stun = { "player" }, freeze = { "player" },
    unstun = { "player" },
    truedmg = { "player" }, dtype = { "player" },
    effects = { "effect" }, help = { "cmd" },
}

-- exact, then prefix, same spirit as admin_core
local function resolveCmdName(name)
    if CMDS[name] then return name end
    for _, n in ipairs(ORDER) do
        if n:sub(1, #name) == name then return n end
    end
    return nil
end

local function exec(text)
    local parts = {}
    for w in string.gmatch(text, "%S+") do parts[#parts + 1] = w end
    if #parts == 0 then return false end
    -- Every typed command goes to the log verbatim, before it runs. A session
    -- post-mortem needs "what was typed and when" next to what the engine did;
    -- only the RESULT line was being written, so a command that errored before
    -- producing one was invisible.
    Log.info("> " .. text)
    local typed = string.lower(parts[1])
    local args = {}
    for i = 2, #parts do args[#args + 1] = string.lower(parts[i]) end

    local name = resolveCmdName(typed)
    local c = name and CMDS[name]
    if not c then
        log("unknown command: " .. typed .. " — type 'help'")
        return false
    end

    local ok, msg = c.fn(args)
    local prefix = ""
    if c.risk == "unproven" and not S.confirmed[name] then prefix = "[?] " end
    log(prefix .. tostring(msg or name))
    return ok ~= false
end

-- ============ UI ============
-- Command bar is admin_core's (']' + green '>' + Code font + grey ghost).
-- Panel is cs_hub's (dark root, drag header, bind buttons, pills), grown
-- into tabs so the effect catalog has somewhere to live.

local function mk(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end

-- Monochrome. The only thing that carries hue is risk, because "this command
-- can get you noticed" is information the eye should get before the click --
-- everything else is state, and state reads better as contrast than as colour.
--
-- Rule: ON is white on black, OFF is grey on near-black. There is no third
-- "kind of on". If a control needs a third state it needs a label, not a hue.
local COL = {
    bg = Color3.fromRGB(0, 0, 0),
    panel = Color3.fromRGB(10, 10, 10),
    line = Color3.fromRGB(38, 38, 38),
    text = Color3.fromRGB(242, 242, 242),
    dim = Color3.fromRGB(122, 122, 122),
    faint = Color3.fromRGB(74, 74, 74),

    -- active control: white fill, black glyph
    on = Color3.fromRGB(255, 255, 255),
    onText = Color3.fromRGB(0, 0, 0),
    off = Color3.fromRGB(28, 28, 28),

    ok = Color3.fromRGB(235, 235, 235),
    risk = Color3.fromRGB(226, 96, 96),
    medium = Color3.fromRGB(168, 168, 168),
}

-- EFFECTS rows carry their dump classification in the colour as well as the
-- tag, so a RISK name reads as one before it is ever clicked
local FX_COL = { safe = COL.text, medium = COL.medium, risk = COL.risk,
    unknown = COL.dim }

local function corner(inst, r)
    mk("UICorner", { CornerRadius = UDim.new(0, r or 4) }, inst)
end

local BIND_ORDER = {
    { key = "cd", label = "cooldown cycle" },
    { key = "speed", label = "speed" },
    { key = "reach", label = "reach" },
    { key = "heal", label = "heal aura" },
    { key = "amp", label = "amp" },
    { key = "selfHeal", label = "self heal" },
    { key = "gui", label = "show / hide HUD" },
    { key = "unload", label = "unload" },
}

-- MAIN tab. 'nums' are the numeric boxes that belong under a row, 'tag' is the
-- confirmation key that clears the row's '?' once the server answers live.
local ROWS = {
    { key = "cdMode", kind = "cycle", label = "cooldowns", bind = "cd",
      risk = "proven", nums = { { "multiplier (half)", "cdMult", 0, 1 } } },
    { key = "speedOn", label = "speed", bind = "speed", risk = "proven",
      nums = { { "bonus studs/s", "speedBonus", 0, 60 } } },
    { key = "reachOn", label = "reach", bind = "reach", risk = "proven",
      nums = { { "damage", "reachDmg", 1, 10000 },
               { "range", "reachRange", 1, 300 } } },
    { key = "healAuraOn", label = "heal aura", bind = "heal",
      risk = "unproven", tag = "healaura",
      nums = { { "amount", "healAmount", 1, 10000 },
               { "range", "healRange", 1, 300 } } },
    { key = "ampOn", label = "amp", bind = "amp", risk = "unproven", tag = "amp",
      nums = { { "multiplier", "ampMult", 1, 100 } } },
    -- Sticky twin of the LeftAlt hold. Same state, two ways to reach it, so the
    -- pill is a readout of the engine rather than a second opinion about it.
    { key = "overrideOn", label = "override cone", bind = "override",
      risk = "unproven", tag = "override" },
    -- No High Noon row. It is not a toggle -- it is part of COWBOY, armed with
    -- the class by `hs COWBOY`. A row here would be a second arming surface for
    -- one behaviour, which is the drift bug this codebase keeps paying for.
}

local function cycleCd()
    S.cdMode = (S.cdMode == "off" and "half")
        or (S.cdMode == "half" and "zero") or "off"
    S.fullCd = {}
end

-- one entry point for a row so the pill and the keybind can never drift
local function setToggle(row)
    if row.kind == "cycle" then
        cycleCd()
        return "cd " .. S.cdMode
    end
    -- Read, flip, write, and report the value we WROTE -- not a re-read of
    -- S[row.key] afterwards. A re-read reports whatever the field holds by the
    -- time the string is built, so if anything else mutated it in between (a
    -- second resident instance, a config restore, a hot reload landing mid
    -- click) the message described someone else's state and the pill repainted
    -- from that same stale read. Same discipline as the `eng` command.
    local want = not S[row.key]
    S[row.key] = want
    if row.key == "speedOn" and not want then restoreSpeed() end
    -- Push straight into the engine. The panel field is the readout; the engine
    -- flag is the thing that acts, and a pill that reads ON while the engine
    -- disagrees is the exact bug this codebase keeps paying for.
    if row.key == "overrideOn" then
        local core = getgenv().__CS_CORE
        if core then core.fovBoostSticky = want end
    end
    return row.label .. " " .. (want and "on" or "off")
end

local screen, bar, box, ghost, barStroke
local rowRefresh = {}
local bindBtns = {}
local refreshBinds
local currentGhost = nil

local function buildUi()
    -- Last line of defence: nothing may build a second panel while one exists.
    -- Cheap, and it makes the invariant true at the only place that can break it.
    destroyPanels()

    local parentGui = (gethui and gethui()) or lp:WaitForChild("PlayerGui")

    screen = mk("ScreenGui", {
        Name = "CSAdmin", ResetOnSpawn = false, DisplayOrder = 100,
        IgnoreGuiInset = true,
    }, parentGui)

    -- ---- command bar ----
    bar = mk("Frame", {
        Size = UDim2.fromOffset(360, 34),
        Position = UDim2.new(0.5, -180, 1, -70),
        BackgroundColor3 = Color3.fromRGB(0, 0, 0),
        BackgroundTransparency = 0.1,
        BorderSizePixel = 0,
        Visible = false,
    }, screen)
    mk("UICorner", { CornerRadius = UDim.new(0, 6) }, bar)
    barStroke = mk("UIStroke", { Color = COL.line, Thickness = 1 }, bar)

    mk("TextLabel", {
        Size = UDim2.fromOffset(18, 34), Position = UDim2.fromOffset(10, 0),
        BackgroundTransparency = 1, Text = ">",
        TextColor3 = COL.text,
        Font = Enum.Font.Code, TextSize = 16,
    }, bar)

    box = mk("TextBox", {
        Size = UDim2.new(1, -40, 1, 0), Position = UDim2.fromOffset(30, 0),
        BackgroundTransparency = 1, Text = "",
        PlaceholderText = "help",
        PlaceholderColor3 = COL.faint,
        TextColor3 = COL.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = Enum.Font.Code, TextSize = 15, ClearTextOnFocus = false,
    }, bar)

    ghost = mk("TextLabel", {
        Size = UDim2.new(1, -40, 1, 0), Position = UDim2.fromOffset(30, 0),
        BackgroundTransparency = 1, Text = "",
        TextColor3 = COL.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = Enum.Font.Code, TextSize = 15, ZIndex = box.ZIndex + 1,
    }, bar)

    local feedback = mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 16), Position = UDim2.fromOffset(0, -20),
        BackgroundTransparency = 1, Text = "",
        TextColor3 = COL.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        Font = Enum.Font.Code, TextSize = 12,
    }, bar)

    setFeedback = function(t)
        feedback.Text = t
        -- pcall: the delay can outlive the panel (unload / hot reload), and a
        -- property write on a destroyed Instance throws.
        task.delay(4, function()
            pcall(function()
                if feedback and feedback.Text == t then feedback.Text = "" end
            end)
        end)
    end

    local function flash(ok)
        if not barStroke then return end
        barStroke.Color = ok and COL.ok
            or COL.risk
        task.delay(0.25, function()
            pcall(function()
                if barStroke then barStroke.Color = COL.line end
            end)
        end)
    end

    -- ---- ghost autocomplete ----
    -- currentGhost is the FULL replacement text (command + args), so Tab can
    -- accept a completion in any slot, not just the command name.
    local function bestCmdName(frag)
        for _, n in ipairs(ORDER) do
            if n:sub(1, #frag) == frag and #n > #frag then return n end
        end
        return nil
    end

    local function completionFor(t)
        if t:sub(-1):match("%s") then return nil end
        local parts = {}
        for w in t:gmatch("%S+") do parts[#parts + 1] = w end
        if #parts == 0 then return nil end
        local frag = parts[#parts]:lower()
        if #parts == 1 then return bestCmdName(frag) end
        local cname = resolveCmdName(parts[1]:lower())
        local spec = cname and ARGSPEC[cname]
        local kind = spec and spec[#parts - 1]
        local pick
        if kind == "player" then
            pick = bestPlayerName(frag)
        elseif kind == "effect" then
            pick = bestEffectName(frag)
        elseif kind == "cmd" then
            pick = bestCmdName(frag)
        end
        if not pick or pick:lower() == frag then return nil end
        return t:sub(1, #t - #parts[#parts]) .. pick
    end

    local function updateGhost()
        local t = box.Text
        currentGhost = nil
        ghost.Text = ""
        if t == "" then return end
        local full = completionFor(t)
        if not full or #full <= #t then return end
        currentGhost = full
        ghost.Text = string.rep(" ", #t) .. full:sub(#t + 1)
    end
    S.conns[#S.conns + 1] =
        box:GetPropertyChangedSignal("Text"):Connect(updateGhost)

    -- prefill/caret exist for the EFFECTS tab: it drops a half-written command
    -- in the bar and parks the caret in the slot the player still has to fill.
    local function setBar(visible, prefill, caret)
        bar.Visible = visible
        if visible then
            task.spawn(function()
                task.wait()   -- let the ']' keypress finish before focusing
                if not S.alive or not box then return end
                -- a click on the EFFECTS list drops TextBox focus first, and
                -- that FocusLost hides the bar; re-show it after the yield
                bar.Visible = true
                box.Text = ""
                ghost.Text = ""
                currentGhost = nil
                box:CaptureFocus()
                box.Text = prefill or ""
                if prefill then
                    box.CursorPosition = caret or (#prefill + 1)
                    updateGhost()
                end
            end)
        else
            box:ReleaseFocus()
            ghost.Text = ""
            currentGhost = nil
        end
    end
    S.setBar = setBar

    S.conns[#S.conns + 1] = box.FocusLost:Connect(function(enter)
        local text = box.Text
        box.Text = ""
        ghost.Text = ""
        currentGhost = nil
        if enter and text ~= "" then
            local ok = exec(text)
            flash(ok)
            if refreshRows then refreshRows() end
        elseif enter then
            exec("help")   -- empty submit from the ']' bar == typing 'help'
            flash(true)
        end
        bar.Visible = false
    end)

    S.acceptGhost = function()
        if not currentGhost then return false end
        box.Text = currentGhost
        if not box:IsFocused() then box:CaptureFocus() end
        box.CursorPosition = #currentGhost + 1
        updateGhost()
        return true
    end

    -- ---- HUD panel ----
    -- Restored position. Clamped properly AFTER build -- see clampPanel below.
    --
    -- The first version of this clamped only the top-left CORNER into the
    -- viewport, which is useless for a panel that grows downward: a saved
    -- panelY of 564 on a 1080-tall screen passed the corner check happily and
    -- still pushed the lower half of the rows off the bottom of the screen,
    -- where they cannot be clicked at all. Reported as "my speed is frozen,
    -- can't be toggled in the menu" -- the speed row was simply below the edge,
    -- and every row under it was too.
    --
    -- It only became reachable once positions persisted: before that, every
    -- reload reset to (24, 120), which always fit.
    local startX, startY = S.panelX or 24, S.panelY or 120

    local root = mk("Frame", {
        Name = "HUD",
        Size = UDim2.fromOffset(300, 0),
        Position = UDim2.new(0, startX, 0, startY),
        BackgroundColor3 = COL.bg,
        BorderSizePixel = 0,
        AutomaticSize = Enum.AutomaticSize.Y,
    }, screen)
    corner(root, 8)
    mk("UIStroke", { Color = COL.line, Thickness = 1 }, root)
    mk("UIPadding", {
        PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10),
        PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
    }, root)
    mk("UIListLayout", {
        Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
    }, root)

    -- header doubles as the drag handle
    local head = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, LayoutOrder = 1,
    }, root)
    mk("TextLabel", {
        Size = UDim2.new(1, -70, 1, 0), BackgroundTransparency = 1,
        Text = "CRITICAL STRIKE", TextColor3 = COL.text,
        Font = Enum.Font.Code, TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, head)
    local statusLbl = mk("TextLabel", {
        Size = UDim2.fromOffset(70, 20), Position = UDim2.new(1, -70, 0, 0),
        BackgroundTransparency = 1, Text = "...", TextColor3 = COL.dim,
        Font = Enum.Font.Code, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Right,
    }, head)

    -- Keep the WHOLE panel on screen, not just its corner, and record where it
    -- ended up.
    --
    -- Uses AbsoluteSize, so it must run after a layout pass -- the frame is
    -- AutomaticSize.Y and reads 0 tall until Roblox has laid the rows out. It is
    -- called on drop (size is settled by then) and once deferred after build.
    --
    -- MARGIN keeps a strip of the panel reachable rather than flush to the edge,
    -- because a row sitting exactly on the boundary is still awkward to hit.
    local PANEL_MARGIN = 8
    local function clampPanel()
        if not root then return end
        local cam = workspace.CurrentCamera
        local vp = cam and cam.ViewportSize
        local x, y = root.Position.X.Offset, root.Position.Y.Offset
        if vp and vp.X > 0 and vp.Y > 0 then
            local size = root.AbsoluteSize
            local w = (size and size.X > 0) and size.X or 300
            -- Height can legitimately exceed the screen once every row is open.
            -- Clamping to (vp.Y - h) would then force a NEGATIVE y and push the
            -- header off the top, which is worse: the header is the drag handle
            -- and the only way back. So never push the top above the margin.
            local h = (size and size.Y > 0) and size.Y or 0
            local maxX = math.max(PANEL_MARGIN, vp.X - w - PANEL_MARGIN)
            local maxY = math.max(PANEL_MARGIN, vp.Y - h - PANEL_MARGIN)
            x = math.clamp(x, PANEL_MARGIN, maxX)
            y = math.clamp(y, PANEL_MARGIN, maxY)
            root.Position = UDim2.new(0, x, 0, y)
        end
        S.panelX, S.panelY = x, y
    end

    -- Exposed so the `panel` command can recover a HUD dragged off-screen.
    S.resetPanel = function()
        if not root then return end
        root.Position = UDim2.new(0, S.panelX or 24, 0, S.panelY or 120)
        clampPanel()
    end

    local dragging, dragStart, startPos = false, nil, nil
    head.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, i.Position, root.Position
        end
    end)
    head.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
            -- Recorded on drop, not on every InputChanged: dragging fires per
            -- mouse move, and writing S on each one would make the 5s diff tick
            -- see a change every frame of a drag for no benefit.
            clampPanel()
        end
    end)
    S.conns[#S.conns + 1] = UIS.InputChanged:Connect(function(i)
        if not dragging or not S.alive then return end
        if i.UserInputType == Enum.UserInputType.MouseMovement
            or i.UserInputType == Enum.UserInputType.Touch then
            local d = i.Position - dragStart
            root.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    -- The header's own InputEnded misses a release that happens off the header
    -- (fast drag, release over another frame), leaving the panel glued to the
    -- cursor until the next click. The service-level release always fires.
    S.conns[#S.conns + 1] = UIS.InputEnded:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1
            or i.UserInputType == Enum.UserInputType.Touch) then
            dragging = false
            pcall(clampPanel)
        end
    end)

    -- Clamp once the layout has actually run.
    --
    -- ONE Heartbeat is not enough and that is why the first attempt at this fix
    -- did nothing. The frame is AutomaticSize.Y with nested UIListLayouts, so
    -- AbsoluteSize.Y can still read 0 a frame later -- and a height of 0 makes
    -- the clamp compute maxY = viewport - 0, which permits every position and
    -- leaves the panel exactly where it was. Silent no-op, same symptom.
    --
    -- So: poll until the height is real, then clamp. Bounded, because a panel
    -- that never lays out is a different bug and this must not spin forever.
    task.defer(function()
        for _ = 1, 120 do
            if not (S.alive and root) then return end
            RunService.Heartbeat:Wait()
            if root.AbsoluteSize.Y > 0 then
                pcall(clampPanel)
                return
            end
        end
    end)

    -- Re-clamp whenever the panel's height changes -- opening a page or a
    -- collapse section can make it taller than it was when restored, which puts
    -- the lower rows back off the bottom. This is the case the deferred clamp
    -- above cannot cover, because it runs once.
    S.conns[#S.conns + 1] =
        root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
            if S.alive then pcall(clampPanel) end
        end)

    -- And again if the window is resized or the display changes. A position that
    -- was legal at one resolution is not necessarily legal at the next, and the
    -- failure mode is unreachable controls rather than anything visible.
    do
        local cam = workspace.CurrentCamera
        if cam then
            S.conns[#S.conns + 1] =
                cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
                    if S.alive then pcall(clampPanel) end
                end)
        end
    end

    -- LayoutOrder counter per parent frame
    local ord = {}
    local function ordOf(parent)
        ord[parent] = (ord[parent] or 0) + 1
        return ord[parent]
    end

    local function sep(parent)
        mk("Frame", {
            Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = COL.line,
            BorderSizePixel = 0, LayoutOrder = ordOf(parent),
        }, parent)
    end

    -- click a bind button -> the next KeyCode lands in BINDS (Esc cancels)
    local function bindButton(parent, bindKey, xOffset)
        -- A row whose `bind` has no entry in BINDS used to index nil HERE, and
        -- the throw killed buildUi partway through: every row after it vanished,
        -- the bind buttons that were never created could not be rebound, and the
        -- half-built panel looked like two unrelated bugs. Cost of one missing
        -- table key, 2026-07-31 (`override`).
        --
        -- Named and survivable instead. The row still builds, the button says
        -- so, and the log names the key that is missing.
        local kc = BINDS[bindKey]
        if not kc then
            Log.warn(("bind %q has no default in BINDS — row builds without a "
                .. "keybind; add it to the BINDS table"):format(tostring(bindKey)))
        end
        local b = mk("TextButton", {
            Size = UDim2.fromOffset(54, 20), Position = UDim2.new(1, xOffset, 0, 2),
            BackgroundColor3 = COL.panel, BorderSizePixel = 0, AutoButtonColor = false,
            Text = kc and kc.Name or "—", TextColor3 = COL.dim,
            Font = Enum.Font.Code, TextSize = 10,
        }, parent)
        corner(b, 4)
        b.MouseButton1Click:Connect(function()
            S.capturing = bindKey
            if refreshBinds then refreshBinds() end
            b.Text = "..."
            b.TextColor3 = COL.on
        end)
        bindBtns[#bindBtns + 1] = { btn = b, key = bindKey }
        return b
    end

    refreshBinds = function()
        for _, e in ipairs(bindBtns) do
            if S.capturing == e.key then
                e.btn.Text = "..."
                e.btn.TextColor3 = COL.on
            else
                e.btn.Text = BINDS[e.key] and BINDS[e.key].Name or "—"
                e.btn.TextColor3 = COL.dim
            end
        end
    end

    local function numRow(parent, label, key, min, max)
        local row = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1,
            LayoutOrder = ordOf(parent),
        }, parent)
        mk("TextLabel", {
            Size = UDim2.new(1, -64, 1, 0), BackgroundTransparency = 1,
            Text = "   " .. label, TextColor3 = COL.dim, Font = Enum.Font.Code,
            TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
        }, row)
        local input = mk("TextBox", {
            Size = UDim2.fromOffset(60, 18), Position = UDim2.new(1, -60, 0, 1),
            BackgroundColor3 = COL.panel, BorderSizePixel = 0,
            Text = tostring(S[key]), TextColor3 = COL.text,
            Font = Enum.Font.Code, TextSize = 11, ClearTextOnFocus = false,
        }, row)
        corner(input, 4)
        input.FocusLost:Connect(function()
            local n = tonumber(input.Text)
            if n then S[key] = math.clamp(n, min, max) end
            input.Text = tostring(S[key])
        end)
    end

    local function toggleRowUi(parent, row)
        local frame = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1,
            LayoutOrder = ordOf(parent),
        }, parent)
        local lbl = mk("TextLabel", {
            Size = UDim2.new(1, -118, 1, 0), BackgroundTransparency = 1,
            Text = row.label, TextColor3 = COL.text, Font = Enum.Font.Code,
            TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
        }, frame)
        bindButton(frame, row.bind, -118)
        local pill = mk("TextButton", {
            Size = UDim2.fromOffset(56, 20), Position = UDim2.new(1, -56, 0, 2),
            BackgroundColor3 = COL.off, BorderSizePixel = 0, AutoButtonColor = false,
            Text = "OFF", TextColor3 = COL.text, Font = Enum.Font.Code, TextSize = 11,
        }, frame)
        corner(pill, 4)

        local function refresh()
            -- '?' marks unproven until the server confirms it live
            local mark = ""
            if row.risk == "unproven" and not (row.tag and S.confirmed[row.tag]) then
                mark = "  ?"
            end
            lbl.Text = row.label .. mark
            local v = (row.kind == "cycle") and S.cdMode or S[row.key]
            local on = (v ~= false) and (v ~= "off") and (v ~= nil)
            pill.Text = (type(v) == "string") and string.upper(v)
                or (on and "ON" or "OFF")
            pill.BackgroundColor3 = on and COL.on or COL.off
            pill.TextColor3 = on and COL.onText or COL.text
        end
        -- A pill click used to be SILENT. setToggle returns the same message the
        -- keybind path logs, and this path threw it away -- so a click that
        -- registered and a click that did not were indistinguishable from the
        -- log, which is precisely the "every action should say what it did" rule
        -- (HANDOFF section 6). It is also why the log could not tell a pill
        -- click apart from a `C` keypress while diagnosing this row.
        pill.MouseButton1Click:Connect(function()
            local msg = setToggle(row)
            refresh()
            if msg then log(msg .. "  [pill]") end
        end)
        rowRefresh[#rowRefresh + 1] = refresh
        refresh()
    end

    local function actionRow(parent, label, fn, bindKey)
        local row = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1,
            LayoutOrder = ordOf(parent),
        }, parent)
        mk("TextLabel", {
            Size = UDim2.new(1, -118, 1, 0), BackgroundTransparency = 1,
            Text = label, TextColor3 = COL.text, Font = Enum.Font.Code,
            TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
        }, row)
        bindButton(row, bindKey, -118)
        local btn = mk("TextButton", {
            Size = UDim2.fromOffset(56, 20), Position = UDim2.new(1, -56, 0, 2),
            BackgroundColor3 = COL.panel, BorderSizePixel = 0, AutoButtonColor = false,
            Text = "CAST", TextColor3 = COL.text, Font = Enum.Font.Code, TextSize = 11,
        }, row)
        corner(btn, 4)
        btn.MouseButton1Click:Connect(fn)
    end

    -- ---- tabs ----
    local tabBar = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, LayoutOrder = 2,
    }, root)
    mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, tabBar)

    local function page(order)
        local f = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 0), BackgroundTransparency = 1,
            AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order,
            Visible = false,
        }, root)
        mk("UIListLayout", {
            Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder,
        }, f)
        return f
    end

    local pageMain, pageEffects, pageBinds, pageProj, pageAim =
        page(3), page(4), page(5), page(6), page(7)
    local pages = {
        MAIN = pageMain, EFFECTS = pageEffects, BINDS = pageBinds, PROJ = pageProj,
        AIM = pageAim,
    }
    local tabBtns = {}
    local rebuildEffects   -- fwd, defined with the EFFECTS page
    local rebuildProjectiles, syncProjNums, refreshProjStatus  -- fwd, PROJ tab
    local refreshAimStatus, rebuildAllyList, syncAllyNums  -- fwd, AIM tab

    local function pfApi()
        return getgenv().__CS_PFORGE
    end

    -- The panel talks to the engine directly. There is no allyApi/allyElemApi/
    -- allyTrickApi any more: those returned the retired per-class ally modules
    -- (see RETIRED_GLOBALS) and reading them is what made the AIM status bar
    -- describe modules instead of the engine that was actually flying the bolts.
    local function coreApi()
        return getgenv().__CS_CORE
    end

    local PF_PRESETS = {
        { key = "musketeer", path = "Classes.MUSKETEER.Projectile.attack" },
        { key = "gunner_crit", path = "Classes.GUNNER.Projectile.critical" },
        { key = "gunner_attack", path = "Classes.GUNNER.Projectile.attack" },
        { key = "fighter", path = "Classes.FIGHTER.Projectile.attack" },
        { key = "knight", path = "Classes.KNIGHT.Projectile.critical" },
        { key = "gambler", path = "Classes.GAMBLER.Projectile.attack" },
        { key = "recon", path = "Classes.RECON.Projectile.attack" },
        { key = "necro", path = "Classes.NECROMANCER.Projectile.attackBullet" },
        { key = "pumpkin", path = "SubClasses.PUMPKIN.Projectile.ability3", risk = true },
        { key = "banana", path = "SubClasses.BANANDIUM.Projectile.testerbanana" },
        { key = "swordmancer", path = "Classes.SWORDMANCER.Projectile.attack" },
        { key = "swordmancer_c", path = "Classes.SWORDMANCER.Projectile.critical" },
        { key = "infernus_bouncer", path = "ChristmasProjectiles.AIsAttack.Infernus.Bouncer" },
    }

    local function ensureForge()
        if pfApi() then return true end
        -- Load from the embedded ENGINE_PAYLOAD — same mechanism as cs_core/cs_classes.
        -- No readfile dependency; the forge travels inside cs_admin.lua.
        local body = ENGINE_PAYLOAD["cs_projectile_forge.lua"]
        if body and #body > 0 then
            local ok, err = pcall(function() loadstring(body)() end)
            if not ok then
                Log.warn("forge: failed to load from payload — " .. tostring(err))
            end
        else
            Log.warn("forge: payload missing cs_projectile_forge.lua — run tools/build_admin.sh")
        end
        return pfApi() ~= nil
    end

    local function showTab(name)
        for n, pg in pairs(pages) do pg.Visible = (n == name) end
        for n, b in pairs(tabBtns) do
            b.BackgroundColor3 = (n == name) and COL.line or COL.panel
            b.TextColor3 = (n == name) and COL.text or COL.dim
        end
        -- catalog can be empty if RS was still streaming when the HUD built
        if name == "EFFECTS" and rebuildEffects then
            rebuildEffects(#effectCatalog(false) == 0)
        end
        if name == "PROJ" then
            ensureForge()
            local api = pfApi()
            if api and api.catalog and #api.catalog() == 0 then
                pcall(function() api.exec("scan refresh") end)
            end
            if refreshProjStatus then refreshProjStatus() end
            if syncProjNums then syncProjNums() end
            if rebuildProjectiles then rebuildProjectiles() end
        end
        if name == "AIM" then
            if refreshRows then refreshRows() end
            if refreshAimStatus then refreshAimStatus() end
            if syncAllyNums then syncAllyNums() end
            if rebuildAllyList then rebuildAllyList() end
        end
    end

    for i, name in ipairs({ "MAIN", "EFFECTS", "BINDS", "PROJ", "AIM" }) do
        local b = mk("TextButton", {
            Size = UDim2.fromOffset(56, 22), BackgroundColor3 = COL.panel,
            BorderSizePixel = 0, AutoButtonColor = false, LayoutOrder = i,
            Text = name, TextColor3 = COL.dim, Font = Enum.Font.Code, TextSize = 11,
        }, tabBar)
        corner(b, 4)
        tabBtns[name] = b
        b.MouseButton1Click:Connect(function() showTab(name) end)
    end

    -- ---- MAIN ----
    for i, row in ipairs(ROWS) do
        if i > 1 then sep(pageMain) end
        toggleRowUi(pageMain, row)
        for _, n in ipairs(row.nums or {}) do
            numRow(pageMain, n[1], n[2], n[3], n[4])
        end
    end
    sep(pageMain)
    actionRow(pageMain, "self heal", function() selfHeal(S.selfHealAmount) end,
        "selfHeal")
    numRow(pageMain, "amount", "selfHealAmount", 1, 10000)

    -- ---- EFFECTS ----
    local fxHead = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1,
        LayoutOrder = ordOf(pageEffects),
    }, pageEffects)
    local filterBox = mk("TextBox", {
        Size = UDim2.new(1, -200, 0, 22), BackgroundColor3 = COL.panel,
        BorderSizePixel = 0, Text = "", PlaceholderText = "filter",
        PlaceholderColor3 = COL.dim, TextColor3 = COL.text,
        Font = Enum.Font.Code, TextSize = 12, ClearTextOnFocus = false,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, fxHead)
    corner(filterBox, 4)
    mk("UIPadding", { PaddingLeft = UDim.new(0, 6) }, filterBox)

    -- default-deny mirror of the 'effects' command: the list is a thing you
    -- click and fire, so it only offers what may legally be aimed at someone
    local allPill = mk("TextButton", {
        Size = UDim2.fromOffset(60, 22), Position = UDim2.new(1, -196, 0, 0),
        BackgroundColor3 = COL.off, BorderSizePixel = 0, AutoButtonColor = false,
        Text = "SAFE", TextColor3 = COL.text, Font = Enum.Font.Code, TextSize = 11,
    }, fxHead)
    corner(allPill, 4)

    local loopPill = mk("TextButton", {
        Size = UDim2.fromOffset(64, 22), Position = UDim2.new(1, -132, 0, 0),
        BackgroundColor3 = COL.off, BorderSizePixel = 0, AutoButtonColor = false,
        Text = "ONCE", TextColor3 = COL.text, Font = Enum.Font.Code, TextSize = 11,
    }, fxHead)
    corner(loopPill, 4)
    local stopBtn = mk("TextButton", {
        Size = UDim2.fromOffset(64, 22), Position = UDim2.new(1, -64, 0, 0),
        BackgroundColor3 = COL.panel, BorderSizePixel = 0, AutoButtonColor = false,
        Text = "STOP", TextColor3 = COL.text, Font = Enum.Font.Code, TextSize = 11,
    }, fxHead)
    corner(stopBtn, 4)

    local hint = mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1,
        LayoutOrder = ordOf(pageEffects),
        Text = "click a name -> 'effect  <name>', caret in the player slot",
        TextColor3 = COL.dim, Font = Enum.Font.Code, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, pageEffects)

    mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1,
        LayoutOrder = ordOf(pageEffects),
        Text = "SAFE dumped enemy site   MEDIUM event-gated   RISK/? need 'force'",
        TextColor3 = COL.dim, Font = Enum.Font.Code, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, pageEffects)

    local function refreshLoopPill()
        loopPill.Text = S.loopFill and "LOOP" or "ONCE"
        loopPill.BackgroundColor3 = S.loopFill and COL.on or COL.off
        loopPill.TextColor3 = S.loopFill and COL.onText or COL.text
        hint.Text = S.loopFill
            and "click a name -> 'loopeffect  <name>', caret in the player slot"
            or "click a name -> 'effect  <name>', caret in the player slot"
    end

    local list = mk("ScrollingFrame", {
        Size = UDim2.new(1, 0, 0, 196), BackgroundColor3 = COL.panel,
        BorderSizePixel = 0, LayoutOrder = ordOf(pageEffects),
        CanvasSize = UDim2.new(), ScrollBarThickness = 4,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarImageColor3 = COL.line,
    }, pageEffects)
    corner(list, 4)
    mk("UIListLayout", {
        Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder,
    }, list)
    mk("UIPadding", {
        PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
        PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 8),
    }, list)

    -- The grammar is 'effect <player> <name>', so a name click cannot simply
    -- append: it writes both spaces and parks the caret in the empty player
    -- slot. One click, one word, Enter.
    local function fillBar(name)
        local verb = S.loopFill and "loopeffect" or "effect"
        if S.setBar then S.setBar(true, verb .. "  " .. name, #verb + 2) end
    end

    rebuildEffects = function(force)
        local names = effectCatalog(force)
        for _, c in ipairs(list:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
        local q = filterBox.Text:lower()
        local shown = 0
        for _, n in ipairs(names) do
            local cls = effectClass(n)
            local allowed = S.fxShowAll or cls == "safe" or cls == "medium"
            if allowed and (q == "" or n:lower():find(q, 1, true)) then
                shown = shown + 1
                local base = FX_COL[cls]
                local b = mk("TextButton", {
                    Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
                    AutoButtonColor = false, LayoutOrder = shown,
                    Text = string.format("%-28s %s%s", n, EFFECT_TAG[cls],
                        S.fxSeen[n] and "*" or ""),
                    TextColor3 = base, Font = Enum.Font.Code,
                    TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
                }, list)
                b.MouseEnter:Connect(function() b.TextColor3 = COL.on end)
                b.MouseLeave:Connect(function() b.TextColor3 = base end)
                b.MouseButton1Click:Connect(function() fillBar(n) end)
            end
        end
        if shown == 0 then
            mk("TextButton", {
                Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
                AutoButtonColor = false, TextColor3 = COL.dim,
                Text = S.fxShowAll and "(no match)" or "(no match — ALL shows RISK)",
                Font = Enum.Font.Code, TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left,
            }, list)
        end
    end

    filterBox:GetPropertyChangedSignal("Text"):Connect(function()
        rebuildEffects(false)
    end)
    loopPill.MouseButton1Click:Connect(function()
        S.loopFill = not S.loopFill
        refreshLoopPill()
    end)
    allPill.MouseButton1Click:Connect(function()
        S.fxShowAll = not S.fxShowAll
        allPill.Text = S.fxShowAll and "ALL" or "SAFE"
        allPill.BackgroundColor3 = S.fxShowAll and COL.risk or COL.off
        rebuildEffects(false)
    end)
    stopBtn.MouseButton1Click:Connect(function()
        log(string.format("all loops off - %d stopped (stun / freeze included)",
            stopLoops(nil)))
    end)
    refreshLoopPill()

    -- ---- PROJ (__CS_PFORGE) ----
    local projSelectedPath = nil

    local projStatus = mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1,
        LayoutOrder = ordOf(pageProj),
        Text = "forge offline — payload missing, rebuild cs_admin.lua",
        TextColor3 = COL.risk, Font = Enum.Font.Code, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, pageProj)

    local projHead = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1,
        LayoutOrder = ordOf(pageProj),
    }, pageProj)
    local projFilter = mk("TextBox", {
        Size = UDim2.new(1, -72, 0, 22), BackgroundColor3 = COL.panel,
        BorderSizePixel = 0, Text = "", PlaceholderText = "filter",
        PlaceholderColor3 = COL.dim, TextColor3 = COL.text,
        Font = Enum.Font.Code, TextSize = 12, ClearTextOnFocus = false,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, projHead)
    corner(projFilter, 4)
    mk("UIPadding", { PaddingLeft = UDim.new(0, 6) }, projFilter)
    local projRefreshBtn = mk("TextButton", {
        Size = UDim2.fromOffset(68, 22), Position = UDim2.new(1, -68, 0, 0),
        BackgroundColor3 = COL.panel, BorderSizePixel = 0, AutoButtonColor = false,
        Text = "REFRESH", TextColor3 = COL.text, Font = Enum.Font.Code, TextSize = 10,
    }, projHead)
    corner(projRefreshBtn, 4)

    mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1,
        LayoutOrder = ordOf(pageProj),
        Text = "click row: bind tpl · damage→10 · [LIVE]/[MISS]/[SLASH]/[STREAM] · J=fire",
        TextColor3 = COL.dim, Font = Enum.Font.Code, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, pageProj)

    local projList = mk("ScrollingFrame", {
        Size = UDim2.new(1, 0, 0, 190), BackgroundColor3 = COL.panel,
        BorderSizePixel = 0, LayoutOrder = ordOf(pageProj),
        CanvasSize = UDim2.new(), ScrollBarThickness = 4,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarImageColor3 = COL.line,
    }, pageProj)
    corner(projList, 4)
    mk("UIListLayout", {
        Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder,
    }, projList)
    mk("UIPadding", {
        PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
        PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 8),
    }, projList)

    local projSelLbl = mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1,
        LayoutOrder = ordOf(pageProj),
        Text = "selected: —", TextColor3 = COL.dim, Font = Enum.Font.Code,
        TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left,
    }, pageProj)

    local projDmgBox, projSpdBox, projRngBox

    local function projNumRow(parent, label, min, max, getField)
        local row = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1,
            LayoutOrder = ordOf(parent),
        }, parent)
        mk("TextLabel", {
            Size = UDim2.new(1, -64, 1, 0), BackgroundTransparency = 1,
            Text = "   " .. label, TextColor3 = COL.dim, Font = Enum.Font.Code,
            TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
        }, row)
        local input = mk("TextBox", {
            Size = UDim2.fromOffset(60, 18), Position = UDim2.new(1, -60, 0, 1),
            BackgroundColor3 = COL.panel, BorderSizePixel = 0,
            Text = "10", TextColor3 = COL.text,
            Font = Enum.Font.Code, TextSize = 11, ClearTextOnFocus = false,
        }, row)
        corner(input, 4)
        input.FocusLost:Connect(function()
            local api = pfApi()
            if not api then return end
            local n = tonumber(input.Text)
            if n then
                n = math.clamp(n, min, max)
                api.exec(getField .. " " .. tostring(n))
            end
            syncProjNums()
        end)
        return input
    end

    projDmgBox = projNumRow(pageProj, "damage", 1, 10000, "dmg")
    projSpdBox = projNumRow(pageProj, "speed", 1, 500, "speed")
    projRngBox = projNumRow(pageProj, "range", 1, 2000, "range")

    syncProjNums = function()
        local api = pfApi()
        if not api or not api.S then return end
        projDmgBox.Text = tostring(api.S.dmg or 10)
        projSpdBox.Text = tostring(api.S.speed or 110)
        projRngBox.Text = tostring(api.S.range or 500)
    end

    local projFireBtn, projPreviewBtn
    local function applyProjActionDim(dim)
        for _, btn in ipairs({ projFireBtn, projPreviewBtn }) do
            if btn then
                btn.Active = not dim
                btn.AutoButtonColor = not dim
                btn.TextColor3 = dim and COL.dim or COL.text
                btn.TextTransparency = dim and 0.35 or 0
                btn.BackgroundColor3 = dim and COL.off or COL.panel
            end
        end
    end

    refreshProjStatus = function()
        local api = pfApi()
        if not api then
            projStatus.Text = "forge offline — payload missing, rebuild cs_admin.lua"
            projStatus.TextColor3 = COL.risk
            projSelLbl.Text = "selected: —"
            applyProjActionDim(true)
            return
        end
        applyProjActionDim(false)
        local st = api.S or {}
        local tpl = st.templatePath or "?"
        local preset = st.preset and tostring(st.preset) or "?"
        projStatus.Text = string.format("forge online · preset=%s", preset)
        projStatus.TextColor3 = COL.on
        projSelLbl.Text = "selected: " .. tpl
        if st.templatePath then projSelectedPath = st.templatePath end
    end

    local function pfPresetRows()
        local api = pfApi()
        if api and type(api.presets) == "function" then
            return api.presets()
        end
        return PF_PRESETS
    end

    local function projRowStatus(path, kind)
        if kind == "live" then return "LIVE" end
        local api = pfApi()
        if api and type(api.pathStatus) == "function" then
            return api.pathStatus(path)
        end
        return "?", nil
    end

    local function mergeProjRows()
        local byPath = {}
        local order = {}
        for _, p in ipairs(pfPresetRows()) do
            local path = p.path
            if path and not byPath[path] then
                byPath[path] = {
                    key = p.key, path = path, kind = "preset",
                    risk = p.risk, label = p.key or path,
                }
                order[#order + 1] = path
            end
        end
        local api = pfApi()
        if api and type(api.catalog) == "function" then
            for _, row in ipairs(api.catalog()) do
                local path = row.path
                if path and not byPath[path] then
                    local lbl = row.name or path:match("[^%.]+$") or path
                    byPath[path] = {
                        path = path, kind = "live", label = lbl,
                        class = row.class, risk = row.tags and row.tags.effect_risk,
                    }
                    order[#order + 1] = path
                end
            end
        end
        table.sort(order, function(a, b)
            local ra, rb = byPath[a], byPath[b]
            if ra.kind ~= rb.kind then return ra.kind == "preset" end
            return (ra.label or a) < (rb.label or b)
        end)
        return order, byPath
    end

    local function selectProjRow(row)
        local api = pfApi()
        if not api then return end
        local intended = row.path
        local ok, err = false, nil
        local dmgAlready = false
        if type(api.select) == "function" then
            ok, err = api.select(row.key or row.path)
            ok = (ok == true)
            dmgAlready = ok
            if not ok then
                local msg = (type(err) == "string" and err ~= "") and err or "select failed"
                projStatus.Text = msg
                projStatus.TextColor3 = COL.risk
                warn("cs_admin PROJ: " .. msg)
                return
            end
        elseif row.key and row.kind == "preset" then
            api.exec("preset " .. row.key)
            ok = api.S and api.S.templatePath == intended
            if not ok then
                local stat = projRowStatus(intended, "preset")
                err = stat and ("[" .. stat .. "] cannot bind") or "select failed"
            end
        else
            api.exec("tpl " .. row.path)
            ok = api.S and api.S.templatePath == intended
        end
        if not ok then
            local msg = (type(err) == "string" and err ~= "") and err or "select failed"
            projStatus.Text = msg
            projStatus.TextColor3 = COL.risk
            warn("cs_admin PROJ: " .. msg)
            return
        end
        if not dmgAlready then
            api.exec("dmg 10")
        end
        projSelectedPath = row.path
        refreshProjStatus()
        syncProjNums()
        rebuildProjectiles()
    end

    rebuildProjectiles = function()
        for _, c in ipairs(projList:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
        local api = pfApi()
        if not api then
            mk("TextButton", {
                Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
                AutoButtonColor = false, TextColor3 = COL.dim,
                Text = "(forge payload missing — rebuild cs_admin.lua)",
                Font = Enum.Font.Code, TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left,
            }, projList)
            return
        end
        local order, byPath = mergeProjRows()
        local q = projFilter.Text:lower()
        local shown = 0
        for _, path in ipairs(order) do
            local row = byPath[path]
            local hay = (row.label .. " " .. path .. " " .. tostring(row.class or "")):lower()
            if q == "" or hay:find(q, 1, true) then
                shown = shown + 1
                local stat = projRowStatus(path, row.kind)
                local statTag = stat
                if row.risk and stat == "LIVE" then statTag = "RISK" end
                local deadPick = (stat == "MISS" or stat == "SLASH" or stat == "STREAM")
                local sel = (path == projSelectedPath) and "● " or "  "
                local base = row.risk and COL.risk or COL.text
                if deadPick then base = COL.dim end
                if path == projSelectedPath then base = COL.on end
                local shortPath = path
                if #shortPath > 22 then
                    shortPath = "…" .. shortPath:sub(-21)
                end
                local riskSuffix = (row.risk and stat == "LIVE") and " !" or ""
                local b = mk("TextButton", {
                    Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
                    AutoButtonColor = false, LayoutOrder = shown,
                    Text = string.format("%s%-14s %-7s %s%s", sel, row.label, statTag, shortPath, riskSuffix),
                    TextColor3 = base, Font = Enum.Font.Code,
                    TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
                    TextTransparency = deadPick and 0.25 or 0,
                }, projList)
                b.MouseEnter:Connect(function()
                    if path ~= projSelectedPath then b.TextColor3 = COL.on end
                end)
                b.MouseLeave:Connect(function()
                    b.TextColor3 = (path == projSelectedPath) and COL.on or base
                end)
                b.MouseButton1Click:Connect(function() selectProjRow(row) end)
            end
        end
        if shown == 0 then
            mk("TextButton", {
                Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
                AutoButtonColor = false, TextColor3 = COL.dim,
                Text = "(no match)", Font = Enum.Font.Code, TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left,
            }, projList)
        end
    end

    projFilter:GetPropertyChangedSignal("Text"):Connect(function()
        rebuildProjectiles()
    end)
    projRefreshBtn.MouseButton1Click:Connect(function()
        local api = pfApi()
        if api then
            pcall(function() api.exec("scan refresh") end)
        end
        refreshProjStatus()
        rebuildProjectiles()
    end)

    local projActRow = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1,
        LayoutOrder = ordOf(pageProj),
    }, pageProj)
    mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, projActRow)
    local function projActionBtn(text, layoutOrder, fn)
        local btn = mk("TextButton", {
            Size = UDim2.fromOffset(72, 22), BackgroundColor3 = COL.panel,
            BorderSizePixel = 0, AutoButtonColor = false, LayoutOrder = layoutOrder,
            Text = text, TextColor3 = COL.text, Font = Enum.Font.Code, TextSize = 11,
        }, projActRow)
        corner(btn, 4)
        btn.MouseButton1Click:Connect(function()
            if not pfApi() then return end
            fn()
        end)
        return btn
    end
    projFireBtn = projActionBtn("FIRE", 1, function()
        local api = pfApi()
        if api and api.fire then api.fire() end
    end)
    projPreviewBtn = projActionBtn("PREVIEW", 2, function()
        local api = pfApi()
        if api then api.exec("preview") end
    end)
    applyProjActionDim(pfApi() == nil)

    -- ---- AIM (heatseek hub — lazy load per toggle) ----
    local function aimSection(parent, title)
        mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1,
            LayoutOrder = ordOf(parent),
            Text = title, TextColor3 = COL.on, Font = Enum.Font.Code,
            TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
        }, parent)
    end

    -- Two jobs live on this page and they were interleaved, which is what made
    -- it unreadable: steering YOUR OWN shots, and assisting an ALLY. They share
    -- almost no controls, so they get their own sub-pages instead of one flat
    -- column of thirty rows.
    local aimSubBar = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1,
        LayoutOrder = ordOf(pageAim),
    }, pageAim)

    local selfPage = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 0), BackgroundTransparency = 1,
        AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = ordOf(pageAim),
    }, pageAim)
    mk("UIListLayout", {
        Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder,
    }, selfPage)

    local allyPage = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 0), BackgroundTransparency = 1,
        AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = ordOf(pageAim),
        Visible = false,
    }, pageAim)
    mk("UIListLayout", {
        Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder,
    }, allyPage)

    local aimSubBtns = {}
    local function showAimSub(which)
        selfPage.Visible = (which == "self")
        allyPage.Visible = (which == "ally")
        for name, btn in pairs(aimSubBtns) do
            local on = (name == which)
            btn.BackgroundColor3 = on and COL.on or COL.off
            btn.TextColor3 = on and COL.onText or COL.text
        end
    end

    for i, entry in ipairs({
        { key = "self", label = "MY SHOTS" },
        { key = "ally", label = "ALLIES" },
    }) do
        local btn = mk("TextButton", {
            Size = UDim2.new(0.5, -3, 1, 0),
            Position = UDim2.new(0.5 * (i - 1), (i - 1) * 6, 0, 0),
            BackgroundColor3 = COL.off, BorderSizePixel = 0, AutoButtonColor = false,
            Text = entry.label, TextColor3 = COL.text,
            Font = Enum.Font.Code, TextSize = 11,
        }, aimSubBar)
        corner(btn, 4)
        aimSubBtns[entry.key] = btn
        btn.MouseButton1Click:Connect(function() showAimSub(entry.key) end)
    end

    -- Paint the initial state, or both tabs render as inactive on load.
    showAimSub("self")

    local aimStatus = mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1,
        LayoutOrder = ordOf(pageAim),
        Text = "",
        TextColor3 = COL.dim, Font = Enum.Font.Code, TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
    }, pageAim)

    -- ---- ENGINE ----
    --
    -- Built from the class registry rather than a hardcoded row per class, so
    -- registering a class in cs_classes.lua makes its row appear here with no
    -- UI change at all. This is what replaces the six near-identical flat rows.
    --
    -- The telemetry line under it is the fix for "state-blind": the reject
    -- histogram is the single most useful diagnostic we have, and it used to be
    -- visible only by reading a log file after the fact.
    local engineRows = {}
    local engineTelemetry

    -- Forward-declared: buildEngineRow is assigned inside the panel builder,
    -- syncEngineRows is called from there AND from refreshEnginePanel.
    local buildEngineRow
    local function syncEngineRows()
        local core = engine()
        if not core or not buildEngineRow then return end
        local have = {}
        for _, r in ipairs(engineRows) do have[r.name] = true end
        local missing = {}
        for name in pairs(core.classes()) do
            if not have[name] then missing[#missing + 1] = name end
        end
        if #missing == 0 then return end
        table.sort(missing)
        for _, name in ipairs(missing) do buildEngineRow(name) end
    end

    local selfClassLabel

    do
        local core = engine()

        -- Which class you are actually playing. Without this the five rows all
        -- look equally relevant, and turning on the wrong one looks identical
        -- to the engine being broken.
        selfClassLabel = mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1,
            LayoutOrder = ordOf(selfPage),
            Text = "playing: —", TextColor3 = COL.text,
            Font = Enum.Font.Code, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, selfPage)

        if not core then
            mk("TextLabel", {
                Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1,
                LayoutOrder = ordOf(selfPage),
                Text = "engine failed to load — run tools/build_admin.sh",
                TextColor3 = COL.risk, Font = Enum.Font.Code, TextSize = 10,
                TextXAlignment = Enum.TextXAlignment.Left,
            }, selfPage)
        else
            -- Row construction lives in a named builder so it can run again
            -- later. It used to be inlined in a one-shot loop, which meant the
            -- rows were whatever the class registry happened to contain at the
            -- instant the panel was built. Register a class after that -- or
            -- build the panel before cs_classes.lua finishes -- and the toggle
            -- simply never existed, with no way to get it back short of a
            -- re-inject. buildEngineRow + syncEngineRows below make the panel
            -- follow the registry instead of snapshotting it.
            buildEngineRow = function(name)
                local row = mk("Frame", {
                    Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1,
                    LayoutOrder = ordOf(selfPage),
                }, selfPage)

                local pill = mk("TextButton", {
                    Size = UDim2.new(0, 34, 0, 16), Position = UDim2.new(0, 0, 0, 2),
                    BackgroundColor3 = COL.off, BorderSizePixel = 0,
                    Text = "off", TextColor3 = COL.text,
                    Font = Enum.Font.Code, TextSize = 10, AutoButtonColor = false,
                }, row)
                corner(pill, 3)

                local label = mk("TextLabel", {
                    Size = UDim2.new(1, -110, 0, 20), Position = UDim2.new(0, 42, 0, 0),
                    BackgroundTransparency = 1, Text = string.lower(name),
                    TextColor3 = COL.text, Font = Enum.Font.Code, TextSize = 11,
                    TextXAlignment = Enum.TextXAlignment.Left,
                }, row)

                -- Precondition, inline. A toggle that silently does nothing
                -- because the class is not streamed is the thing that generated
                -- most "it's broken" reports.
                local badge = mk("TextLabel", {
                    Size = UDim2.new(0, 64, 0, 20), Position = UDim2.new(1, -64, 0, 0),
                    BackgroundTransparency = 1, Text = "",
                    TextColor3 = COL.dim, Font = Enum.Font.Code, TextSize = 9,
                    TextXAlignment = Enum.TextXAlignment.Right,
                }, row)

                pill.MouseButton1Click:Connect(function()
                    local c = engine()
                    if not c then return end
                    local cfg = c.getClass(name)
                    if not cfg then return end
                    c.setEnabled(name, not cfg.enabled)
                    if refreshAimStatus then refreshAimStatus() end
                end)

                engineRows[#engineRows + 1] =
                    { name = name, pill = pill, label = label, badge = badge }
            end

            syncEngineRows()

            engineTelemetry = mk("TextLabel", {
                Size = UDim2.new(1, 0, 0, 38), BackgroundTransparency = 1,
                LayoutOrder = ordOf(selfPage),
                Text = "no shots yet", TextColor3 = COL.dim,
                Font = Enum.Font.Code, TextSize = 9,
                TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
            }, selfPage)
        end
    end

    -- Repaints the engine rows and telemetry. Called from refreshAimStatus.
    local function refreshEnginePanel()
        local core = engine()
        if not core then return end

        -- Pick up any class registered since the panel was built. Cheap: it is
        -- a set difference over ~16 names and exits immediately when nothing is
        -- new, which is every call after the first.
        syncEngineRows()

        for _, r in ipairs(engineRows) do
            local cfg = core.getClass(r.name)
            local on = cfg and cfg.enabled
            r.pill.Text = on and "on" or "off"
            r.pill.BackgroundColor3 = on and COL.on or COL.off
            r.pill.TextColor3 = on and COL.onText or COL.text

            -- The badge answers "why is this on and doing nothing", which was
            -- the entire confusion: five rows, no indication which one is even
            -- relevant to the class being played.
            local why = ""
            local playing = core.myClass() or "none"
            local cfgMatch = cfg and core.aliasMatches(cfg, playing)

            if r.name == "ELEMENTALIST" and not elemProjectileStreamProbe() then
                why = "not streamed"
            elseif r.name == "TRICKSTER" and not trickProjectileStreamProbe() then
                why = "not streamed"
            elseif on and cfgMatch then
                why = "ACTIVE"
            elseif on then
                why = "not your class"
            end

            r.badge.Text = why
            r.badge.TextColor3 = (why == "ACTIVE") and COL.on or COL.dim
            r.label.TextColor3 = (on and cfgMatch) and COL.text or COL.dim
        end

        if selfClassLabel then
            local playing = core.myClass() or "none"
            selfClassLabel.Text = "playing: " .. tostring(playing)
        end

        -- One unambiguous line at the top of the whole page: is heatseek
        -- actually going to do anything right now, yes or no. "I can't tell if
        -- it's on" was the single most common complaint about this panel.
        if aimStatus then
            local st = core.getStatus()
            local playing = st.myClass or "none"
            local armed = nil
            for _, name in ipairs(st.enabledClasses or {}) do
                local cfg = core.getClass(name)
                if cfg and core.aliasMatches(cfg, playing) then
                    armed = name
                    break
                end
            end

            if armed then
                aimStatus.Text = ("ARMED — %s · %d locks · %d in flight")
                    :format(armed, st.locks, st.active)
                aimStatus.TextColor3 = COL.on
            elseif #(st.enabledClasses or {}) > 0 then
                aimStatus.Text = ("IDLE — %s is on but you're playing %s")
                    :format(table.concat(st.enabledClasses, "/"), tostring(playing))
                aimStatus.TextColor3 = COL.risk
            else
                aimStatus.Text = "OFF — no class enabled"
                aimStatus.TextColor3 = COL.dim
            end
        end

        if engineTelemetry then
            local st = core.getStatus()
            local bits = { ("locks %d (%d no-los) · hits %d · %d in flight")
                :format(st.locks, st.noLosLocks or 0, st.hits, st.active) }
            local rejects = core.topRejects(3)
            if #rejects > 0 then
                local parts = {}
                for _, x in ipairs(rejects) do
                    parts[#parts + 1] = ("%s %d"):format(x.why, x.count)
                end
                bits[#bits + 1] = table.concat(parts, " · ")
            end
            -- Capability line: an UNKNOWN here is not a bug, it means Probe 2
            -- has not been run yet and the engine is on the safe path.
            bits[#bits + 1] = core.capsSummary()
            engineTelemetry.Text = table.concat(bits, "\n")
        end
    end

    local allyApplyRow = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1,
        LayoutOrder = ordOf(allyPage),
    }, allyPage)
    local allyNameBox = mk("TextBox", {
        Size = UDim2.new(1, -72, 0, 22), BackgroundColor3 = COL.panel,
        -- Seeded from the restored config so the saved allies are visible the
        -- first time the page is opened, not only after the next refresh tick.
        BorderSizePixel = 0, Text = S.allyNames or "", PlaceholderText = "Name1, Name2",
        PlaceholderColor3 = COL.dim, TextColor3 = COL.text,
        Font = Enum.Font.Code, TextSize = 12, ClearTextOnFocus = false,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, allyApplyRow)
    corner(allyNameBox, 4)
    mk("UIPadding", { PaddingLeft = UDim.new(0, 6) }, allyNameBox)
    local allyApplyBtn = mk("TextButton", {
        Size = UDim2.fromOffset(68, 22), Position = UDim2.new(1, -68, 0, 0),
        BackgroundColor3 = COL.panel, BorderSizePixel = 0, AutoButtonColor = false,
        Text = "APPLY", TextColor3 = COL.text, Font = Enum.Font.Code, TextSize = 10,
    }, allyApplyRow)
    corner(allyApplyBtn, 4)

    local function aimToggleRow(parent, label, readOn, writeOn)
        local frame = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1,
            LayoutOrder = ordOf(parent),
        }, parent)
        mk("TextLabel", {
            Size = UDim2.new(1, -64, 1, 0), BackgroundTransparency = 1,
            Text = label, TextColor3 = COL.text, Font = Enum.Font.Code,
            TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
        }, frame)
        local pill = mk("TextButton", {
            Size = UDim2.fromOffset(56, 20), Position = UDim2.new(1, -56, 0, 2),
            BackgroundColor3 = COL.off, BorderSizePixel = 0, AutoButtonColor = false,
            Text = "OFF", TextColor3 = COL.text, Font = Enum.Font.Code, TextSize = 11,
        }, frame)
        corner(pill, 4)
        local function refresh()
            local on = readOn()
            pill.Text = on and "ON" or "OFF"
            pill.BackgroundColor3 = on and COL.on or COL.off
            pill.TextColor3 = on and COL.onText or COL.text
        end
        pill.MouseButton1Click:Connect(function()
            -- Toggle from visual (not readOn): after destroy, pill can stay ON
            -- while api nil — readOn() false would wrongly request ON again.
            local want = pill.Text ~= "ON"
            local ok = writeOn(want)
            if ok == false then
                pill.Text = "OFF"
                pill.BackgroundColor3 = COL.off
                pill.TextColor3 = COL.text
            else
                refresh()
            end
            if refreshAimStatus then refreshAimStatus() end
        end)
        rowRefresh[#rowRefresh + 1] = refresh
        refresh()
    end

    local function aimNumRow(parent, label, min, max, readVal, writeVal)
        local row = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1,
            LayoutOrder = ordOf(parent),
        }, parent)
        mk("TextLabel", {
            Size = UDim2.new(1, -64, 1, 0), BackgroundTransparency = 1,
            Text = "   " .. label, TextColor3 = COL.dim, Font = Enum.Font.Code,
            TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
        }, row)
        local input = mk("TextBox", {
            Size = UDim2.fromOffset(60, 18), Position = UDim2.new(1, -60, 0, 1),
            BackgroundColor3 = COL.panel, BorderSizePixel = 0,
            Text = "0", TextColor3 = COL.text,
            Font = Enum.Font.Code, TextSize = 11, ClearTextOnFocus = false,
        }, row)
        corner(input, 4)
        input.FocusLost:Connect(function()
            local n = tonumber(input.Text)
            if n then
                writeVal(math.clamp(n, min, max))
            end
            if syncAllyNums then syncAllyNums() end
        end)
        return input
    end

    local allySpawnBox, allyMaxEchoBox

    -- ONE toggle, not six.
    --
    -- The old page had `echo forge` + `ally heatseek` per class (musketeer,
    -- elementalist, trickster) -- six near-identical rows, and picking the wrong
    -- pair for the ally's class silently did nothing. You should not have to know
    -- what class your friend is playing (CS_CONSTRAINTS.md §3).
    --
    -- Ally assist runs on the ENGINE. Those three modules covered musketeer,
    -- elementalist and trickster only, which is why ally RECON never worked --
    -- there was no module, so there was nothing to fix. Every class registered
    -- in cs_classes.lua now gets ally echo, and the echo is steered by the same
    -- steer() as our own bolts, so it inherits the weld guard, mover restore,
    -- turn clamp and FLIGHT telemetry.
    local function allyAssistIsOn()
        local core = engine()
        if not core then return false end
        local st = core.allyStatus()
        return st.echo == true
    end

    local function setAllyAssist(on)
        local core = engine()
        if not core then
            log("engine not loaded — ally assist unavailable")
            return false
        end
        core.setAllyEchoEnabled(on)
        core.setAllyHeatseekEnabled(on)
        S.allyAssist = on
        pcall(saveConfig)

        -- An ally name that resolves to nobody is the single most common reason
        -- ally assist "does nothing", and it used to fail in total silence.
        if on and core.allyStatus then
            local st = core.allyStatus()
            if #st.resolved == 0 then
                log("ally assist ON but NO ally name resolves to a player in this server")
            elseif #st.unresolved > 0 then
                log("ally: no player matches " .. table.concat(st.unresolved, ", "))
            end
        end

        if refreshRows then refreshRows() end
        if refreshAimStatus then refreshAimStatus() end
        return true
    end

    aimToggleRow(allyPage, "ally assist", allyAssistIsOn, setAllyAssist)

    aimToggleRow(allyPage, "hide ally bolt", function()
        local core = engine()
        if core then return core.allyStatus().hideBolt == true end
        return false
    end, function(on)
        local core = engine()
        if not core then
            log("engine not loaded — hide ally bolt unavailable")
            return false
        end
        core.setHideAllyBolt(on)
        return true
    end)

    -- "CRT speed mult" and "CRT speed floor" used to live here. They tuned the
    -- MUSKETEER ally module's own re-speed of the Firing Squad body, a module
    -- that no longer exists -- and the engine's forge inherits the source bolt's
    -- real Speed instead of overriding it. Two dead knobs on the page the user
    -- already called "so unclear" is worse than no knobs.
    aimSection(allyPage, "— echo tuning —")
    allySpawnBox = aimNumRow(allyPage, "spawn forward", 0, 20, function()
        local core = engine()
        return core and core.ally.spawnForward or 2
    end, function(n)
        local core = engine()
        if core then core.setAllySpawnForward(n) end
    end)
    allyMaxEchoBox = aimNumRow(allyPage, "max echoes", 1, 64, function()
        local core = engine()
        return core and core.ally.maxActive or 16
    end, function(n)
        local core = engine()
        if core then core.setMaxActiveEchoes(n) end
    end)

    aimSection(allyPage, "— Friends —")
    mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1,
        LayoutOrder = ordOf(allyPage),
        Text = "LMB player = ally · RMB = add friend · whitelist ON skips lock on friends",
        TextColor3 = COL.dim, Font = Enum.Font.Code, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
    }, allyPage)

    aimToggleRow(allyPage, "friends whitelist", function()
        local core = engine()
        return (core and core.friendsWhitelistOn()) or false
    end, function(on)
        local core = engine()
        if not core then
            log("engine not loaded — friends whitelist unavailable")
            return false
        end
        core.setFriendsWhitelistOn(on)
        return true
    end)

    local allyList = mk("ScrollingFrame", {
        Size = UDim2.new(1, 0, 0, 100), BackgroundColor3 = COL.panel,
        BorderSizePixel = 0, LayoutOrder = ordOf(allyPage),
        CanvasSize = UDim2.new(), ScrollBarThickness = 4,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarImageColor3 = COL.line,
    }, allyPage)
    corner(allyList, 4)
    mk("UIListLayout", {
        Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder,
    }, allyList)
    mk("UIPadding", {
        PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
        PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 8),
    }, allyList)

    local allyFriendBtn = mk("TextButton", {
        Size = UDim2.fromOffset(72, 22), BackgroundColor3 = COL.panel,
        BorderSizePixel = 0, AutoButtonColor = false, LayoutOrder = ordOf(allyPage),
        Text = "FRIEND", TextColor3 = COL.text, Font = Enum.Font.Code, TextSize = 11,
    }, allyPage)
    corner(allyFriendBtn, 4)

    syncAllyNums = function()
        local core = engine()
        if not core then return end
        allySpawnBox.Text = tostring(core.ally.spawnForward or 2)
        allyMaxEchoBox.Text = tostring(core.ally.maxActive or 16)
        if core.ally.raw and core.ally.raw ~= "" then
            allyNameBox.Text = core.ally.raw
        end
    end

    refreshAimStatus = function()
        refreshEnginePanel()
        -- Engine only.
        --
        -- This line used to be assembled entirely from the retired per-class
        -- modules (allyApi / allyElemApi / hsStatusTag over five __CS_*_HEATSEEK
        -- globals). Now that those never load it would have read
        -- "ally: — | sniper=— chrono=— sword=— elem=— trick=—" forever: a status
        -- bar that reports nothing about the system that is actually running.
        -- CS_CONSTRAINTS.md §4 makes legibility a hard requirement, so it reads
        -- the engine instead.
        local core = engine()
        local warnAlly = false

        if not core then
            aimStatus.Text = "engine not loaded — no heatseek available"
            aimStatus.TextColor3 = COL.risk
            return
        end

        local st = core.allyStatus()

        -- Armed self classes, named. "3 armed" without saying which is the kind
        -- of detail that forces a second click to answer "is it on".
        local armed = {}
        for name, cfg in pairs(core.classes()) do
            if cfg.enabled then armed[#armed + 1] = name end
        end
        table.sort(armed)

        -- Allies are listed as name=CLASS, not as bare names.
        --
        -- The status line used to be able to say "no class enabled", which is the
        -- SELF reject reason and tells you nothing about the allies you just
        -- armed. What you actually need to know is which class each ally is on
        -- and whether that class will be echoed -- "ally assist ON" and "ally
        -- assist ON but your friend is playing something we do not support" were
        -- indistinguishable.
        local allyBit
        if not st.echo then
            allyBit = "ALLY off"
        elseif #st.resolved == 0 then
            warnAlly = true
            allyBit = "ALLY ON · NO ally name resolves in this server"
        else
            local bits = {}
            for _, name in ipairs(st.resolved) do
                bits[#bits + 1] = name .. "=" .. tostring(st.classes[name] or "?")
            end
            allyBit = "ALLY ON · " .. table.concat(bits, " ")
            -- A "?" entry means the class is unknown, unregistered or opted out,
            -- so nothing will be echoed for that ally.
            if #st.unsupported > 0 then warnAlly = true end
            if #st.unresolved > 0 then
                warnAlly = true
                allyBit = allyBit .. (" · unmatched: %s"):format(
                    table.concat(st.unresolved, ","))
            end
        end

        aimStatus.Text = ("%s · echoes %d/%d · hide=%s | self: %s")
            :format(allyBit, st.active or 0, st.maxActive or 0,
                st.hideBolt and "ON" or "off",
                #armed > 0 and table.concat(armed, ",") or "none armed")

        if warnAlly then
            aimStatus.TextColor3 = COL.risk
        else
            aimStatus.TextColor3 = (st.echo or #armed > 0) and COL.on or COL.dim
        end
    end

    rebuildAllyList = function()
        for _, c in ipairs(allyList:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
        local order = 0
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= lp then
                order = order + 1
                local core = engine()
                local tags = {}
                if core then
                    -- Core.isAllyPlayer takes the Player, not a name, and does
                    -- the same prefix match the echo forge uses -- so what this
                    -- list marks ALLY is exactly what will actually be echoed.
                    if core.isAllyPlayer(p) then
                        -- Named with the class, and whether we support it. Which
                        -- class an ally is on decides whether ally assist does
                        -- anything at all for them, so it belongs on the row you
                        -- click, not in a separate command.
                        local ok, why = core.allyClassSupport(p)
                        tags[#tags + 1] = ok and ("ALLY " .. ok)
                            or ("ALLY ? " .. tostring(why))
                    else
                        local cls = core.playerClass(p)
                        if cls then tags[#tags + 1] = cls end
                    end
                    if core.isFriend(p.Name) then
                        tags[#tags + 1] = "FRIEND"
                    end
                end
                local suffix = (#tags > 0) and ("  [" .. table.concat(tags, ",") .. "]") or ""
                local b = mk("TextButton", {
                    Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
                    AutoButtonColor = false, LayoutOrder = order,
                    Text = p.Name .. suffix,
                    TextColor3 = COL.text, Font = Enum.Font.Code,
                    TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
                }, allyList)
                b.MouseButton1Click:Connect(function()
                    if not engine() then
                        log("engine not loaded")
                        return
                    end
                    local newRaw = appendAllyBoxName(allyNameBox.Text, p.Name)
                    pushAllyNameAllModules(newRaw)
                    Log.info("ally set to " .. newRaw)
                    allyNameBox.Text = newRaw
                    refreshAimStatus()
                    rebuildAllyList()
                end)
                b.MouseButton2Click:Connect(function()
                    local core = engine()
                    if not core then
                        log("engine not loaded")
                        return
                    end
                    core.addFriend(p.Name)
                    refreshAimStatus()
                    rebuildAllyList()
                end)
            end
        end
        if order == 0 then
            mk("TextButton", {
                Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
                AutoButtonColor = false, TextColor3 = COL.dim,
                Text = "(no other players)",
                Font = Enum.Font.Code, TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left,
            }, allyList)
        end
    end

    allyFriendBtn.MouseButton1Click:Connect(function()
        local core = engine()
        if not core then
            log("engine not loaded")
            return
        end
        local q = allyNameBox.Text
        if q == "" then return end
        local p = findPlayer(q)
        if p then
            core.addFriend(p.Name)
            refreshAimStatus()
            rebuildAllyList()
        end
    end)

    -- Autofill: expand whatever you typed to the real player names, in place,
    -- as soon as you leave the box. Typing four letters and getting the full
    -- name back is also the fastest way to SEE that a name resolves -- an ally
    -- token matching nobody is the most common reason ally assist silently does
    -- nothing, and it cost a whole test session ("zoeyzplaz10" vs the real
    -- "zoeyzplayz10").
    local function autofillAllyBox()
        local raw = trimAllyRaw(allyNameBox.Text)
        if raw == "" then return "" end
        local resolved = resolveAllyRawCanonical(raw)
        if resolved ~= "" and resolved ~= allyNameBox.Text then
            allyNameBox.Text = resolved
        end
        return resolved
    end

    allyNameBox.FocusLost:Connect(function()
        local resolved = autofillAllyBox()
        if resolved == "" then return end
        -- Report unmatched tokens immediately rather than at APPLY time.
        for token in string.gmatch(resolved, "[^,;]+") do
            local t = trimAllyRaw(token)
            if t ~= "" then
                local p, err = findPlayer(t)
                -- findPlayer's own message distinguishes "no match" from
                -- "ambiguous, here are the candidates". Reporting a fragment
                -- that matched three people as "no player matches" would send
                -- you looking for a typo that is not there -- type another
                -- letter instead.
                if not p then log(err or ("no player matching '" .. t .. "'")) end
            end
        end
    end)

    allyApplyBtn.MouseButton1Click:Connect(function()
        -- No longer gated on the archived module being present: ally echo runs
        -- on the engine now, and requiring cs_ally_echo_heatseek.lua here would
        -- refuse to set a name on a perfectly working install.
        local q = autofillAllyBox()
        if q == "" then
            pushAllyNameAllModules("")
            Log.info("ally cleared")
        elseif allyRawHasMulti(q) then
            local resolved = resolveAllyRawCanonical(q)
            pushAllyNameAllModules(resolved)
            allyNameBox.Text = resolved
            if countAllyTokensInServer(resolved) == 0 then
                log("ally set — no names in server yet (late join OK): " .. resolved)
            else
                Log.info("ally set to " .. resolved)
            end
        else
            local p, err = findPlayer(q)
            if not p then
                log(err or "player not found")
                return
            end
            pushAllyNameAllModules(p.Name)
            Log.info("ally set to " .. p.Name)
            allyNameBox.Text = p.Name
        end
        refreshAimStatus()
        rebuildAllyList()
    end)

    refreshAimStatus()
    rebuildAllyList()

    -- Live refresh while the AIM tab is open.
    --
    -- Everything else on this page repaints on click, which is fine for
    -- toggles but useless for the engine telemetry: locks, hits and the reject
    -- histogram all change while you are shooting, and shooting is precisely
    -- when you are not clicking the panel. Without this the diagnostic sits
    -- frozen on whatever it read when you last touched a control.
    --
    -- Throttled, and gated on the tab actually being visible, so it costs
    -- nothing when the panel is closed or on another page.
    task.spawn(function()
        local ENGINE_REFRESH_SEC = 0.25
        local nextAt = 0
        while S.alive do
            RunService.Heartbeat:Wait()
            local now = os.clock()
            if now >= nextAt and root and root.Visible and pageAim.Visible then
                nextAt = now + ENGINE_REFRESH_SEC
                pcall(refreshEnginePanel)
            end
        end
    end)

    -- ---- BINDS ----
    mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1,
        LayoutOrder = ordOf(pageBinds),
        Text = "click a key, press the new one (Esc cancels)",
        TextColor3 = COL.dim, Font = Enum.Font.Code, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, pageBinds)
    for _, entry in ipairs(BIND_ORDER) do
        local row = mk("Frame", {
            Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1,
            LayoutOrder = ordOf(pageBinds),
        }, pageBinds)
        mk("TextLabel", {
            Size = UDim2.new(1, -60, 1, 0), BackgroundTransparency = 1,
            Text = entry.label, TextColor3 = COL.text, Font = Enum.Font.Code,
            TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
        }, row)
        bindButton(row, entry.key, -54)
    end
    mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1,
        LayoutOrder = ordOf(pageBinds),
        Text = "']' opens the console and is not rebindable",
        TextColor3 = COL.dim, Font = Enum.Font.Code, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, pageBinds)

    -- ---- footer + status ----
    local foot = mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1, LayoutOrder = 9,
        Text = "']' console  ·  help", TextColor3 = COL.dim,
        Font = Enum.Font.Code, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, root)

    refreshRows = function()
        for _, f in ipairs(rowRefresh) do pcall(f) end
        if refreshBinds then refreshBinds() end
    end

    -- MAIN rows were STATE-BLIND between clicks.
    --
    -- rowRefresh only ran on a click or on one of the scattered refreshRows()
    -- calls, so anything that changed S underneath left the pill showing stale
    -- text indefinitely -- a config restore, a hot reload, or a second resident
    -- instance flipping the same field. The reported symptom is exactly that:
    -- "I click OFF and it stays ON".
    --
    -- The AIM page already repaints on a throttled Heartbeat for the same
    -- reason (telemetry moves while you are shooting, not while you are
    -- clicking). MAIN needs it for the same reason, so the pill is a readout of
    -- S rather than a memory of the last click.
    task.spawn(function()
        local ROW_REFRESH_SEC = 0.25
        local nextAt = 0
        while S.alive do
            RunService.Heartbeat:Wait()
            local now = os.clock()
            if now >= nextAt and root and root.Visible and pageMain.Visible then
                nextAt = now + ROW_REFRESH_SEC
                pcall(refreshRows)
            end
        end
    end)
    -- Restore the saved visibility. Done here rather than at Frame creation so
    -- the layout and the position clamp still run with the panel realised --
    -- AbsoluteSize reads 0 on an invisible frame, which would defeat the clamp
    -- and put the rows off-screen again the moment it was shown.
    root.Visible = true
    screen.Enabled = (S.hudVisible ~= false)

    toggleMenu = function()
        -- Hide the WHOLE ScreenGui, not just the HUD frame.
        --
        -- This used to flip root.Visible, which leaves the command bar and the
        -- ']' console still on screen -- so RightShift looked like it "wasn't
        -- hiding the panel" even though it was firing correctly. screen.Enabled
        -- is unambiguous: everything this script draws goes away.
        --
        -- The input handler is on UserInputService, not on the GUI, so
        -- RightShift still comes back while hidden.
        local showing = not screen.Enabled
        screen.Enabled = showing
        -- Close the console on the way out. Binds are deliberately inert while
        -- the bar is open, so hiding with it open would leave RightShift itself
        -- unable to bring the panel back.
        if not showing and bar and bar.Visible and S.setBar then
            pcall(function() S.setBar(false) end)
        end
        root.Visible = true
        -- Remembered, so RightShift survives the next rebuild. Written to S; the
        -- 5s diff tick saves it and both teardown paths flush first.
        S.hudVisible = showing
        -- Clamp on SHOW. A panel that booted hidden has AbsoluteSize 0, so the
        -- deferred clamp gave up without ever measuring it -- revealing it could
        -- otherwise put the lower rows off the bottom, which is the exact
        -- unreachable-controls bug that read as "speed is frozen".
        if showing then
            task.defer(function()
                if S.alive and root then pcall(clampPanel) end
            end)
        end
        return showing and "hud shown" or "hud hidden"
    end
    showTab("MAIN")

    -- own heartbeat: the status line has to tick before arm() succeeds too
    local accum = 0
    S.conns[#S.conns + 1] = RunService.Heartbeat:Connect(function(dt)
        if not S.alive then return end
        accum = accum + dt
        if accum < 0.5 then return end
        accum = 0
        statusLbl.Text = inMatch() and (currentClassName() or "?") or "lobby"
        local n = countLoops() + countHealLoops()
        foot.Text = (n > 0) and string.format("%d loop(s) running  ·  ']' console", n)
            or "']' console  ·  help"
    end)
end

-- ============ keybinds ============

local BIND_ACTION = {
    selfHeal = function()
        selfHeal(S.selfHealAmount)
        return "self heal " .. tostring(S.selfHealAmount)
    end,
    gui = function()
        -- Returns a message so this shows up in the log like every other bind.
        -- It used to return nil, which meant a bind that silently did nothing
        -- and a bind that worked were indistinguishable from outside.
        if toggleMenu then return toggleMenu() end
        return "hud toggle unavailable — panel not built"
    end,
    unload = function()
        S.destroy()
        return nil
    end,
}
for _, row in ipairs(ROWS) do
    BIND_ACTION[row.bind] = function() return setToggle(row) end
end

local function bindNameFor(kc)
    for name, key in pairs(BINDS) do
        if key == kc then return name end
    end
    return nil
end

-- ============ arm ============

local function arm()
    if not S.alive then return true end
    if not inMatch() then return false end
    local cm = findCM()
    if not cm then return false end
    S.cm = cm

    if not S.getUtil then
        local ok, mod = pcall(function()
            return require(RS.ClientModules.GetUtility)
        end)
        S.getUtil = ok and mod or nil
    end
    pcall(function()
        S.damageRemote = RS.Remotes:WaitForChild("Damage", 5)
        S.healRemote = RS.Remotes:WaitForChild("Heal", 5)
        S.effectRemote = RS.Remotes:WaitForChild("EffectApply", 5)
    end)

    if S.armed then return true end
    S.armed = true

    for _, n in ipairs(CD_FUNCS) do
        if type(cm[n]) == "function" then hookCd(n, cm[n]) end
    end
    for _, n in ipairs(MOVE_GATES) do
        if type(cm[n]) == "function" then hookGate(n, cm[n]) end
    end
    hookDamage(rawget(cm, "Damage"))

    local di = RS.Remotes:FindFirstChild("DamageIndicator")
    if di then
        S.conns[#S.conns + 1] = di.OnClientEvent:Connect(onIndicator)
    end

    -- the HUD status line runs off its own heartbeat in buildUi, so it keeps
    -- ticking in the lobby while arm() is still failing
    S.conns[#S.conns + 1] = RunService.Heartbeat:Connect(tick)

    log(string.format("armed %s password=%s — ']' console, 'help' commands",
        tostring(currentClassName()), password() ~= nil and "ok" or "FAILED"))
    return true
end

function S.destroy()
    if not S.alive then return end
    S.alive = false
    -- alive=false already gates the tick; clear the stores too so a stale
    -- table can never outlive the instance through getgenv. S.loops holds the
    -- stun / freeze locks as well, so this stops those too.
    S.loops = {}
    S.healLoops = {}

    -- UI DIES FIRST, and by name, not only by handle.
    --
    -- screen:Destroy() used to sit at the END of this function, behind
    -- restoreSpeed(), restoreHooks(), purgeRetiredModules() and core.destroy().
    -- restoreSpeed and restoreHooks were not even pcall-wrapped, so ONE throw
    -- anywhere in that chain aborted teardown with the panel still on screen --
    -- and the next inject then built a second one beside it. Reported as "two
    -- UIs just loaded on my screen".
    --
    -- Destroying it first means the most visible artifact of the old instance is
    -- gone before anything that can fail gets a chance to run.
    pcall(destroyPanels)

    pcall(restoreSpeed)
    for _, c in ipairs(S.conns) do pcall(function() c:Disconnect() end) end
    S.conns = {}
    -- Flush settings on the way out, for the same reason the hot reloader does:
    -- the 5s autosave tick means an unload (or K) within seconds of changing a
    -- setting would silently discard it.
    pcall(saveConfig)
    pcall(restoreHooks)
    -- Not "destroy all hub heatseek" any more -- there is nothing left to load.
    -- Still purged on unload: an EARLIER inject in this session may have left a
    -- retired module running, and unload must leave nothing steering.
    purgeRetiredModules()
    -- The engine is a separate getgenv module with its own connections and
    -- Heartbeat sweep. Without this it keeps watching ClientProjectiles and
    -- steering after the panel is gone, with no UI left to turn it off.
    local core = getgenv().__CS_CORE
    if core and type(core.destroy) == "function" then pcall(core.destroy) end
    -- The overlay is a THIRD getgenv module with its own RenderStepped
    -- connection and its own folder in CoreGui — outside our instance tree, so
    -- nothing else collects it. Same rule as the engine: unloading the panel
    -- must leave nothing drawing.
    local esp = getgenv().__CS_ESP
    if esp and type(esp.destroy) == "function" then pcall(esp.destroy) end
    -- Belt-and-braces: destroyPanels ran at the top, but a ScreenGui created
    -- between then and now (a racing buildUi) would still be caught here.
    pcall(destroyPanels)
    S.armed = false
    S.capturing = nil
    S.setBar, S.acceptGhost = nil, nil
    -- Final log on the way out, so a clean unload always leaves its last state
    -- at the sink. nil sink (every local build) makes this a no-op.
    pcall(function() if S.shipLogs then S.shipLogs("unload") end end)
    print("[CSAdmin] unloaded")
    if G.__CS_ADMIN == S then G.__CS_ADMIN = nil end
end

G.__CS_ADMIN = S

buildUi()
log("waiting for match… ']' console, RightShift HUD, 'help' commands")

task.spawn(function()
    while S.alive and not arm() do task.wait(1) end
end)

S.conns[#S.conns + 1] = lp.CharacterAdded:Connect(function()
    S.origBaseSpeed = nil
    S.lastWritten = nil
    S.lastClass = nil
    S.fullCd = {}
    task.wait(2)
    if S.alive then arm() end
end)

S.conns[#S.conns + 1] = UIS.InputBegan:Connect(function(input, gp)
    if not S.alive then return end
    local kc = input.KeyCode

    -- bind capture wins over everything and ignores gameProcessed, so a key
    -- the game already owns (or one pressed with the panel focused) still lands
    if S.capturing and kc ~= Enum.KeyCode.Unknown then
        if kc == OPEN_KEY then
            log("']' is the console key — pick another")
        elseif kc ~= Enum.KeyCode.Escape then
            BINDS[S.capturing] = kc
        end
        S.capturing = nil
        if refreshRows then refreshRows() end
        return
    end

    if kc == OPEN_KEY and not gp then
        if S.setBar then S.setBar(not bar.Visible) end
        return
    end
    if kc == Enum.KeyCode.Tab and bar and bar.Visible then
        if S.acceptGhost then S.acceptGhost() end
        return
    end
    -- Binds stay inert while ANY text field has focus — typing 'speed' in the
    -- ']' bar (or in Roblox chat) must not also flip the speed toggle.
    --
    -- This used to gate on `gameProcessed`, and that silently ate RightShift for
    -- the whole life of the panel. Roblox's own MouseLockController binds
    -- LeftShift AND RightShift through ContextActionService for shift lock
    -- (0209.lua:22, BoundKeys = "LeftShift,RightShift,ButtonL2"), and a
    -- ContextActionService-bound key reaches InputBegan with gp already true.
    -- So the HUD bind was refused on every single press: cs_admin.log for
    -- 2026-07-31 carries not one `hud shown` / `hud hidden` line across nine
    -- hours, while 'C' (speed) dispatched fine from the same handler.
    --
    -- GetFocusedTextBox is the predicate we actually wanted. It is true exactly
    -- when the player is typing somewhere, which is the only thing `gp` was
    -- being used to detect, and it does not care who else claimed the key.
    if bar and bar.Visible then return end
    if UIS:GetFocusedTextBox() ~= nil then return end

    -- one dispatch table for keys and pills: a bind can never drift from the
    -- row it mirrors, because both call the same BIND_ACTION entry
    local name = bindNameFor(kc)
    if not name then return end
    local action = BIND_ACTION[name]
    if not action then return end
    local msg = action()
    if msg then log(msg) end
    if S.alive and refreshRows then refreshRows() end
end)

--------------------------------------------------------------------------
-- HOT RELOAD
--
-- The build loop was: edit engine/*.lua, run tools/build_admin.sh, copy
-- cs_admin.lua into the workspace, then find it in the Potassium picker and
-- click it again. Every iteration. The clicking is the part with no purpose --
-- the file on disk already holds the new code.
--
-- So the running copy watches its own source and restarts itself when it
-- changes. Inject once per session; after that a rebuild lands in the game on
-- its own within HOT_POLL_SEC.
--
-- Three things this has to get right:
--
--  1. NEVER tear down a working panel for a broken source. The new text is
--     compiled with loadstring FIRST, and a syntax error leaves the running
--     copy alone with a warning. A half-written file caught mid-save is the
--     normal case, not the exceptional one, so this is the important guard.
--
--  2. Exactly one watcher. Each load bumps a generation counter and every
--     watcher exits as soon as it is not the current generation -- otherwise
--     ten reloads leave ten pollers reading the file and racing to restart.
--
--  3. Read the REPO copy, not the workspace copy. The workspace copy is what
--     ensureModule used to write for itself, and checking it first is exactly
--     the loader-shadowing bug that made every repo edit silently do nothing
--     for a whole session.
--------------------------------------------------------------------------

-- The WORKSPACE copy, not the repo copy.
--
-- The repo path was tried first and does not work: Potassium `readfile` could not
-- read "C:/Users/croni/Downloads/OpXOyuApWKTlFzrV/scripts/cs_admin.lua", so hot
-- reload logged "source not readable" and switched itself off for the whole
-- session -- silently leaving the game on an old build while rebuilds piled up on
-- disk.
--
-- This is not a fallback to stale code, which is what the earlier repo-first
-- version was guarding against. The workspace copy is the DEPLOY TARGET:
-- tools/build_admin.sh now writes it as the last step of every build, so it is
-- always the newest thing that exists. Watching the deploy target is the correct
-- design; reading the repo was an aspiration that this executor cannot satisfy.
-- Pick the one that works and delete the other (CS_CONSTRAINTS.md 5b).
-- v2 watches ITS OWN deploy name. Watching cs_admin.lua from here would swap
-- the running v2 back to a v1 build on the next v1 rebuild.
local HOT_SRC = "cs_adminv2.lua"
local HOT_POLL_SEC = 3

-- REMOTE SOURCE. nil in every local build -- the workspace file is the deploy
-- target here, and reading it is both instant and free.
--
-- tools/build_portable.sh rewrites this to a URL. That build runs on somebody
-- else's machine where `cs_adminv2.lua` is either absent or an unrelated file
-- from another script pack, so the local watcher was compiled out entirely and
-- the portable became a one-way door: every fix meant sending a new file and
-- asking them to re-inject, mid-match.
--
-- With a URL it polls the same address it was loaded from, so a rebuild that is
-- published reaches a player who is already in a round.
--
-- Three things follow from it being a network read, and all three are handled
-- below rather than assumed away:
--   * it can fail (offline, rate limit) -- a failed poll must be a no-op, never
--     a teardown;
--   * it is slow relative to a file read, so the interval is much longer;
--   * raw.githubusercontent caches for ~5 minutes, so "published" and "live"
--     are not the same instant and no amount of polling changes that.
local HOT_URL = "https://raw.githubusercontent.com/xReset/cs-dist/main/cs_portable.lua"  -- dist build: poll the published copy
local HOT_URL_POLL_SEC = 60

-- LOG SINK. nil in every local build -- your own logs stay on your disk. The
-- portable build rewrites this to the receiver URL (build_portable.sh), so only
-- copies handed to other people ship their log, automatically and silently.
--
-- Write-only sink: it accepts POSTs and hands nothing back. The URL is in a
-- PUBLIC file, so it can only be spammed, not read -- the receiver caps size and
-- rate for exactly that.
--
-- Fully automatic by request: no command, no prompt, no action from the holder.
-- Ships on an interval and once more on unload, so a session that ends cleanly
-- always leaves its final log.
local LOG_SINK_URL = "https://restsimages.pics/cslog/ingest"  -- dist build: silent log shipping
local LOG_SINK_POLL_SEC = 180

G.__CS_ADMIN_GEN = (G.__CS_ADMIN_GEN or 0) + 1
local myGen = G.__CS_ADMIN_GEN
S.hotReload = true

local function hotReadSource()
    -- Remote build: fetch from where it was published. pcall'd because HttpGet
    -- THROWS on a network failure rather than returning nil, and an unguarded
    -- throw here kills the polling task -- which would disable reload for the
    -- session on the first blip, exactly the silent failure this is meant to end.
    if HOT_URL then
        local ok, body = pcall(function() return game:HttpGet(HOT_URL) end)
        if ok and type(body) == "string" and #body > 0 then return body end
        return nil, "cannot fetch " .. HOT_URL .. " — " .. tostring(body)
    end
    if not readfile then return nil, "readfile unavailable in this executor" end
    -- One source, no alternates. See HOT_SRC.
    local ok, body = pcall(readfile, HOT_SRC)
    if ok and type(body) == "string" and #body > 0 then return body end
    return nil, "cannot read " .. HOT_SRC .. " (relative to the Potassium workspace)"
end

-- Swap the running copy for the text on disk. Returns false plus a reason
-- WITHOUT touching anything if the new text does not compile.
local function hotApply(body, why)
    local fn, err = loadstring(body)
    if not fn then
        Log.warn("hot reload refused — new source does not compile, keeping the "
            .. "running copy: " .. tostring(err))
        return false, "new source does not compile"
    end
    Log.warn("hot reload (" .. tostring(why) .. ") — restarting panel and engine")
    -- Flush settings first. Autosave is a 5s diff tick, so anything changed in
    -- the last few seconds -- typically the ally names, which are the setting most
    -- likely to be edited immediately before a rebuild -- would be lost across the
    -- restart and look like persistence was broken.
    pcall(saveConfig)
    pcall(S.destroy)
    -- Deferred: S.destroy disconnects the connection this may be running inside.
    task.defer(function()
        local ok, e = pcall(fn)
        if not ok then Log.err("hot reload: new copy errored on load", e) end
    end)
    return true
end

-- Ships the two logs to LOG_SINK_URL. Silent and best-effort: every failure
-- path is a no-op, because a log shipper that interrupts play or spams the
-- console is worse than one that occasionally misses a send.
local function shipLogs(why)
    if not LOG_SINK_URL then return end
    local http = (syn and syn.request) or http_request or request
        or (http and http.request)
    if not http or not readfile then return end
    local who = "unknown"
    pcall(function() who = game:GetService("Players").LocalPlayer.Name end)
    local parts = {}
    for _, f in ipairs({ "logs/cs_core.log", "logs/cs_admin.log" }) do
        local ok, body = pcall(readfile, f)
        if ok and type(body) == "string" and #body > 0 then
            parts[#parts + 1] = "===== " .. f .. " (" .. tostring(why) .. ") =====\n" .. body
        end
    end
    if #parts == 0 then return end
    local payload = table.concat(parts, "\n\n")
    -- Newest tail only: the receiver caps a post at 2 MB and a long session's
    -- cs_core.log can pass that. The tail is where the current bug is anyway.
    if #payload > 1500000 then payload = payload:sub(#payload - 1500000) end
    local url = LOG_SINK_URL
        .. (LOG_SINK_URL:find("?", 1, true) and "&" or "?")
        .. "who=" .. (game:GetService("HttpService"):UrlEncode(who))
    pcall(http, {
        Url = url, Method = "POST", Body = payload,
        Headers = { ["Content-Type"] = "text/plain" },
    })
end
S.shipLogs = shipLogs

if LOG_SINK_URL then
    task.spawn(function()
        while true do
            task.wait(LOG_SINK_POLL_SEC)
            if G.__CS_ADMIN_GEN ~= myGen then return end
            if not S.alive then return end
            shipLogs("interval")
        end
    end)
end

task.spawn(function()
    -- cs_boot owns reload when it is present. It polls the same file from
    -- OUTSIDE this script, so it survives a build that throws on load -- which
    -- this watcher cannot, because a copy that throws never reaches this line
    -- and reload dies for the session. Two loops on one file would double every
    -- reload, so exactly one of us runs and cs_boot wins.
    if G.__CS_BOOT_RELOAD then
        S.hotReload = false
        Log.info("hot reload: cs_boot owns it — this watcher stands down")
        return
    end
    local last = hotReadSource()
    if not last then
        -- WARN, not INFO. When this fires, every future rebuild silently fails to
        -- reach the game and the only symptom is a build stamp nobody checks.
        Log.warn("HOT RELOAD OFF — cannot read " .. HOT_SRC
            .. " — you must re-execute cs_admin.lua manually after every build")
        S.hotReload = false
        return
    end
    Log.info(("hot reload armed — polling %s every %ds (gen %d)")
        :format(HOT_URL or HOT_SRC, HOT_URL and HOT_URL_POLL_SEC or HOT_POLL_SEC,
            myGen))

    -- RECONCILE ON ARM. The watcher fires on CHANGE, and its baseline is the
    -- file, not the text actually running -- so injecting a stale copy while a
    -- newer build already sits on disk arms a watcher that compares the new file
    -- against itself, concludes nothing changed, and waits forever. Silently.
    --
    -- Measured, 2026-08-01: a rejoin at 19:47 re-injected an admin whose engine
    -- was stamped 05:02:22 while the workspace file was 19:46:47. Hot reload
    -- armed normally and never fired. Two sessions of JESTER tuning were then
    -- read off an engine that did not contain any of it, and the tuning was
    -- reported as ineffective. This is HANDOFF_2026-08-01 §1's trap through a
    -- different door -- the running build and the file on disk disagreeing with
    -- nothing in the log saying so.
    --
    -- The build stamp is the one fact that settles it, which is exactly what the
    -- entry docs say to trust. Compare it, and if it differs, apply immediately
    -- rather than waiting for a change that already happened.
    do
        local fileBuild = last:match('ENGINE_BUILD%s*=%s*"([^"]+)"')
        local runBuild  = G.__CS_BUILD
        if fileBuild and runBuild and fileBuild ~= runBuild then
            Log.warn(("hot reload: running build %s but %s on disk is %s — "
                .. "applying it now")
                :format(tostring(runBuild), HOT_SRC, fileBuild))
            if hotApply(last, "stale inject") then return end
        elseif fileBuild and not runBuild then
            -- No stamp in the running copy at all: too old to compare, and that
            -- is itself the signal. Named rather than assumed either way.
            Log.warn("hot reload: the running copy has no build stamp — it "
                .. "predates the stamp itself. Re-inject " .. HOT_SRC)
        end
    end

    while true do
        task.wait(HOT_URL and HOT_URL_POLL_SEC or HOT_POLL_SEC)
        -- Superseded by a newer load, or the panel is gone: stop polling.
        if G.__CS_ADMIN_GEN ~= myGen then return end
        if not S.alive then return end
        if S.hotReload then
            local body = hotReadSource()
            if body and body ~= last then
                last = body
                if hotApply(body, "source changed") then return end
            end
        end
    end
end)

cmd("reload", "proven", "reload [on|off] — re-fetch and re-run this script", function(a)
    local sub = (a[1] or ""):lower()
    if sub == "off" then
        S.hotReload = false
        return true, "hot reload off — `reload` still works manually"
    end
    if sub == "on" then
        S.hotReload = true
        return true, "hot reload on"
    end
    local body, err = hotReadSource()
    if not body then return false, err end
    local ok, why = hotApply(body, "manual")
    if not ok then return false, why end
    return true, HOT_URL and "re-fetching from the published build"
        or "reloading from disk"
end)
