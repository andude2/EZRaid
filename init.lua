local mq = require('mq')
local ImGui = require('ImGui')
local json = require('dkjson')

local raid_hud = require('EZRaid.raid_hud')

-- EZRaid: Live PC raid layout, invites, and assignment

local M = {}

-- State
M.state = {
    windowOpen = true,
    isRunning = true,
    statusText = '',
    groupsToDisplay = 12, -- 1-12
    invitePacingMs = 150, -- per-invite wait before confirm attempt
    roster = {},          -- list of known PC names
    desiredLayout = {},   -- [1..12][1..6] = name
    savedLayouts = {},    -- name -> layout table
    _newRosterName = '',
    _saveName = '',
    theme = {
        enabled = true,
        alpha = 1.0,
        windowRounding = 6.0,
        frameRounding = 6.0,
        grabRounding = 6.0,
        colors = {
            WindowBg      = {0.10, 0.10, 0.12, 1.00},
            ChildBg       = {0.08, 0.08, 0.10, 0.90},
            FrameBg       = {0.16, 0.18, 0.22, 1.00},
            FrameBgHovered= {0.20, 0.24, 0.30, 1.00},
            FrameBgActive = {0.24, 0.28, 0.36, 1.00},
            Button        = {0.18, 0.44, 0.42, 0.95},
            ButtonHovered = {0.22, 0.56, 0.54, 1.00},
            ButtonActive  = {0.16, 0.36, 0.34, 1.00},
            Header        = {0.18, 0.44, 0.42, 0.80},
            HeaderHovered = {0.22, 0.56, 0.54, 0.90},
            HeaderActive  = {0.16, 0.36, 0.34, 0.90},
            Text          = {0.88, 0.92, 0.98, 1.00},
        }
    },
}

local function printf(fmt, ...)
    if mq.printf then mq.printf(fmt, ...) else print(string.format(fmt, ...)) end
end

local function initLayout()
    for g=1,12 do M.state.desiredLayout[g] = M.state.desiredLayout[g] or {} end
end

local function normalize_name(s)
    if not s then return '' end
    local t = s:gsub('%s+', '')
    return t
end

-- Persistence
local function config_path()
    local base = mq.configDir or (mq.luaDir and mq.luaDir() or '.')
    return string.format('%s/ezraid.json', base)
end

local function save_all()
    local payload = {
        roster = M.state.roster,
        savedLayouts = M.state.savedLayouts,
        invitePacingMs = M.state.invitePacingMs,
        theme = M.state.theme,
    }
    local text = json.encode(payload, {indent=true}) or '{}'
    local f, err = io.open(config_path(), 'w')
    if not f then M.state.statusText = 'Save failed: '..tostring(err); return end
    f:write(text)
    f:close()
    M.state.statusText = 'Saved settings.'
end

local function load_all()
    local f = io.open(config_path(), 'r')
    if not f then return end
    local data = f:read('*a') or ''
    f:close()
    local obj = json.decode(data) or {}
    M.state.roster = obj.roster or {}
    M.state.savedLayouts = obj.savedLayouts or {}
    if type(obj.invitePacingMs) == 'number' then M.state.invitePacingMs = obj.invitePacingMs end
    if type(obj.theme) == 'table' then M.state.theme = obj.theme end
    M.state.statusText = 'Loaded settings.'
end

-- Queue for non-blocking actions
local queue = {}
local function q_cmd(cmd)
    table.insert(queue, {kind='cmd', cmd=cmd})
end
local function q_wait(ms)
    table.insert(queue, {kind='wait', wake=os.clock() + (ms/1000.0)})
end
local function q_func(fn)
    table.insert(queue, {kind='func', fn=fn})
end

local function process_queue()
    if #queue == 0 then return end
    local item = queue[1]
    if item.kind == 'wait' then
        if os.clock() < item.wake then return end
        table.remove(queue, 1)
        return
    elseif item.kind == 'cmd' then
        mq.cmd(item.cmd)
        table.remove(queue, 1)
        return
    elseif item.kind == 'func' then
        pcall(item.fn)
        table.remove(queue, 1)
        return
    end
end

-- Raid window helpers
local function openRaidWindow()
    q_func(function()
        if not mq.TLO.Window('RaidWindow').Open() then
            mq.TLO.Window('RaidWindow').DoOpen()
        end
    end)
    q_wait(300)
end

local function raidUnlock()
    openRaidWindow()
    q_cmd('/notify RaidWindow RAID_UnLockButton LeftMouseUp')
    q_wait(250)
end

local function raidLock()
    openRaidWindow()
    q_cmd('/notify RaidWindow RAID_LockButton LeftMouseUp')
    q_wait(250)
end

local function notInGroupIndexByName(name)
    local list = mq.TLO.Window('RaidWindow').Child('RAID_NotInGroupPlayerList')
    if not list or list() == 0 then return nil end
    local count = list.Items() or 0
    for i=1, count do
        local cell = list.List(i, 2)()
        if cell and tostring(cell):lower() == tostring(name):lower() then return i end
    end
    return nil
end

local function assignFromNotInGroup(name, groupNum)
    q_func(function()
        -- function body executed by queue step
        local idx = notInGroupIndexByName(name)
        if not idx then return end
        mq.cmdf('/notify RaidWindow RAID_NotInGroupPlayerList ListSelect %d', idx)
    end)
    q_wait(120)
    q_cmd(string.format('/notify RaidWindow RAID_Group%dButton LeftMouseUp', tonumber(groupNum) or 1))
    q_wait(180)
end

local function inviteToRaid(name)
    -- Send invite, then quickly attempt a non-blocking confirm.
    q_cmd(string.format('/raidinvite %s', name))
    -- Short gap to allow the confirmation dialog to appear, if any.
    local pace = tonumber(M.state.invitePacingMs or 150) or 150
    if pace < 20 then pace = 20 end
    if pace > 2000 then pace = 2000 end
    q_wait(pace)
    -- Multiple quick confirmation attempts to improve reliability across UIs.
    local function try_confirm()
        local wnd = mq.TLO.Window('ConfirmationDialogBox')
        if wnd and wnd.Open() then
            -- Try via direct UI handle first
            local candidates = {'CD_Yes_Button','Yes_Button','CD_OK_Button','OK_Button'}
            for _, child in ipairs(candidates) do
                local ok = pcall(function()
                    local c = wnd.Child(child)
                    if c and c() then c.LeftMouseUp() end
                end)
                -- Fallback /notify as well
                mq.cmdf('/notify ConfirmationDialogBox %s leftmouseup', child)
            end
        end
    end
    -- Perform several spaced attempts without blocking long.
    for i=1,6 do
        q_func(try_confirm)
        q_wait(120)
    end
end

local function raid_member_lookup()
    local set = {}
    local okCount, raidCount = pcall(function()
        if not mq.TLO.Raid or not mq.TLO.Raid.Members then return 0 end
        return tonumber(mq.TLO.Raid.Members() or 0) or 0
    end)
    local count = (okCount and raidCount) or 0
    if not count or count <= 0 then return set end
    for i=1, count do
        local okMember, member = pcall(function() return mq.TLO.Raid.Member(i) end)
        if okMember and member then
            local name
            pcall(function()
                name = member.CleanName and member.CleanName() or member.Name and member.Name()
            end)
            if not name or name == '' then
                local okAlt, alt = pcall(function() return member.Name and member.Name() end)
                if okAlt and alt and alt ~= '' then name = alt end
            end
            if name and name ~= '' then
                local cleaned = normalize_name(tostring(name))
                if cleaned ~= '' then
                    set[cleaned:lower()] = cleaned
                end
            end
        end
    end
    return set
end

local function wait_for_invitees(target_names, opts)
    opts = opts or {}
    local poll_ms = tonumber(opts.poll_ms or 500) or 500
    if poll_ms < 50 then poll_ms = 50 end

    local timeout_ms = tonumber(opts.timeout_ms or 0) or 0
    local deadline = nil
    if timeout_ms > 0 then
        deadline = os.clock() + (timeout_ms / 1000.0)
    end

    local keys, display = {}, {}
    local total = 0
    for _, name in ipairs(target_names or {}) do
        local cleaned = normalize_name(name)
        if cleaned ~= '' then
            local key = cleaned:lower()
            if not keys[key] then
                keys[key] = true
                display[key] = cleaned
                total = total + 1
            end
        end
    end

    if total == 0 then
        if opts.on_complete then
            q_func(function() opts.on_complete({}, false, 0) end)
        end
        return
    end

    local function check()
        local present = raid_member_lookup()
        local missing = {}
        for key, _ in pairs(keys) do
            if not present[key] then
                table.insert(missing, display[key] or key)
            end
        end

        if #missing == 0 then
            if opts.on_complete then opts.on_complete({}, false, total) end
            return
        end

        if deadline and os.clock() >= deadline then
            if opts.on_complete then opts.on_complete(missing, true, total) end
            return
        end

        M.state.statusText = string.format('Waiting for %d invitee(s) to join raid: %s', #missing, table.concat(missing, ', '))
        q_wait(poll_ms)
        q_func(check)
    end

    q_func(check)
end

local function enqueue_group_assignment(total_targets, missing_names)
    missing_names = missing_names or {}
    raidLock()
    raidLock()
    for attempt=1, 8 do
        for g=1,12 do
            local group = M.state.desiredLayout[g]
            if group then
                for s=1,6 do
                    local name = group[s]
                    if name and name ~= '' then
                        assignFromNotInGroup(name, g)
                    end
                end
            end
        end
        q_wait(250)
    end
    raidUnlock()
    q_func(function()
        if #missing_names > 0 then
            M.state.statusText = string.format('Assigned raid groups; missing %d invitee(s): %s', #missing_names, table.concat(missing_names, ', '))
        else
            M.state.statusText = string.format('Invited %d and arranged raid.', total_targets or 0)
        end
    end)
end


-- Utilities
-- Normalize a peer name to TitleCase-ish (match SmartLoot behavior)
local function normalize_peer_name(peer)
    if not peer or peer == '' then return '' end
    local p = tostring(peer)
    p = p:match('^%s*(.-)%s*$') or p
    if p == '' then return '' end
    p = p:lower()
    return p:sub(1,1):upper() .. p:sub(2)
end

local function layout_unique_list()
    local set, out = {}, {}
    for g=1,12 do
        for s=1,6 do
            local n = M.state.desiredLayout[g] and M.state.desiredLayout[g][s]
            if n and n ~= '' and not set[n] then set[n] = true; table.insert(out, n) end
        end
    end
    table.sort(out, function(a,b) return a:lower() < b:lower() end)
    return out
end

-- Actions
-- Forward declare helpers used by scanners/UI
local add_to_roster

local function scan_current_raid()
    -- Clears current layout and fills it using the live raid composition.
    initLayout()
    for g=1,12 do M.state.desiredLayout[g] = {} end

    local function get_member_name(member)
        if not member then return nil end
        local nm
        local ok1, v1 = pcall(function() return member.CleanName and member.CleanName() end)
        if ok1 and v1 and v1 ~= '' then nm = v1 end
        if not nm then
            local ok2, v2 = pcall(function() return member.Name and member.Name() end)
            if ok2 and v2 and v2 ~= '' then nm = v2 end
        end
        return nm and tostring(nm) or nil
    end

    local count = 0
    local okc, rc = pcall(function()
        return (mq.TLO.Raid and mq.TLO.Raid.Members and tonumber(mq.TLO.Raid.Members() or 0)) or 0
    end)
    count = (okc and rc) or 0
    if not count or count <= 0 then
        M.state.statusText = 'No raid detected.'
        return
    end

    -- Bucket names by group number 1..12
    local placed = 0
    local maxGroup = 1
    for i=1, count do
        local mem = mq.TLO.Raid and mq.TLO.Raid.Member and mq.TLO.Raid.Member(i)
        if mem and mem() then
            local name = get_member_name(mem)
            local grp = nil
            local okg, gv = pcall(function() return mem.Group and tonumber(mem.Group() or 0) end)
            grp = (okg and gv) or 0
            if grp == 0 or not grp then grp = 1 end
            if grp < 1 then grp = 1 end
            if grp > 12 then grp = 12 end
            if name and name ~= '' then
                -- place into next empty slot in this group
                for s=1,6 do
                    if not M.state.desiredLayout[grp][s] then
                        M.state.desiredLayout[grp][s] = name
                        placed = placed + 1
                        if grp > maxGroup then maxGroup = grp end
                        break
                    end
                end
                -- ensure on roster for convenience
                add_to_roster(name)
            end
        end
    end
    M.state.groupsToDisplay = math.max(M.state.groupsToDisplay or 12, maxGroup)
    M.state.statusText = string.format('Scanned raid: placed %d member(s) into layout.', placed)
end

function M.apply_layout()
    raidLock()
    -- Attempt assignment for every filled slot; relies on NotInGroup list
    for g=1,12 do
        for s=1,6 do
            local name = M.state.desiredLayout[g][s]
            if name and name ~= '' then assignFromNotInGroup(name, g) end
        end
    end
    raidUnlock()
    M.state.statusText = 'Applied layout to raid.'
end

function M.form_raid_from_layout()
    local lst = layout_unique_list()
    if #lst == 0 then M.state.statusText = 'No names in layout.'; return end
    raidUnlock()
    for _, n in ipairs(lst) do
        inviteToRaid(n)
    end
    raidLock()
    -- Arrange with retries: lock is required for move buttons in some clients
    raidLock()
    for attempt=1, 8 do
        for g=1,12 do
            for s=1,6 do
                local name = M.state.desiredLayout[g][s]
                if name and name ~= '' then assignFromNotInGroup(name, g) end
            end
        end
        q_wait(250)
    end
    raidUnlock()
    M.state.statusText = string.format('Invited %d and arranged raid.', #lst)
end

-- Save/load layout
local function save_current_layout(name)
    name = normalize_name(name)
    if name == '' then M.state.statusText = 'Enter a layout name.'; return end
    local out = {}
    for g=1,12 do
        out[g] = {}
        for s=1,6 do out[g][s] = M.state.desiredLayout[g] and M.state.desiredLayout[g][s] or nil end
    end
    M.state.savedLayouts[name] = out
    save_all()
    M.state.statusText = string.format('Saved layout "%s".', name)
end

local function load_layout(name)
    local layout = M.state.savedLayouts[name]
    if not layout then M.state.statusText = 'Layout not found.'; return end
    M.state.desiredLayout = layout
    M.state.statusText = string.format('Loaded layout "%s".', name)
end

-- Theme helpers (scoped to EZRaid only)
local function _color4(tbl)
    return tbl[1] or 1, tbl[2] or 1, tbl[3] or 1, tbl[4] or 1
end

local function push_theme()
    local t = M.state.theme or {}
    if not t.enabled then return {vars=0, colors=0} end
    local pushed = {vars=0, colors=0}
    if t.alpha then ImGui.PushStyleVar(ImGuiStyleVar.Alpha, t.alpha); pushed.vars = pushed.vars + 1 end
    if t.windowRounding then ImGui.PushStyleVar(ImGuiStyleVar.WindowRounding, t.windowRounding); pushed.vars = pushed.vars + 1 end
    if t.frameRounding then ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding, t.frameRounding); pushed.vars = pushed.vars + 1 end
    if t.grabRounding then ImGui.PushStyleVar(ImGuiStyleVar.GrabRounding, t.grabRounding); pushed.vars = pushed.vars + 1 end

    local c = t.colors or {}
    local function pc(idx, key)
        local arr = c[key]; if not arr then return end
        ImGui.PushStyleColor(idx, _color4(arr)); pushed.colors = pushed.colors + 1
    end
    pc(ImGuiCol.WindowBg,      'WindowBg')
    pc(ImGuiCol.ChildBg,       'ChildBg')
    pc(ImGuiCol.FrameBg,       'FrameBg')
    pc(ImGuiCol.FrameBgHovered,'FrameBgHovered')
    pc(ImGuiCol.FrameBgActive, 'FrameBgActive')
    pc(ImGuiCol.Button,        'Button')
    pc(ImGuiCol.ButtonHovered, 'ButtonHovered')
    pc(ImGuiCol.ButtonActive,  'ButtonActive')
    pc(ImGuiCol.Header,        'Header')
    pc(ImGuiCol.HeaderHovered, 'HeaderHovered')
    pc(ImGuiCol.HeaderActive,  'HeaderActive')
    pc(ImGuiCol.Text,          'Text')
    return pushed
end

local function pop_theme(pushed)
    if not pushed then return end
    for i=1,(pushed.colors or 0) do ImGui.PopStyleColor() end
    for i=1,(pushed.vars or 0) do ImGui.PopStyleVar() end
end

local function delete_layout(name)
    if not M.state.savedLayouts[name] then return end
    M.state.savedLayouts[name] = nil
    save_all()
    M.state.statusText = string.format('Deleted layout "%s".', name)
end

-- Roster helpers
local function roster_contains(name)
    for _, v in ipairs(M.state.roster) do if v:lower() == name:lower() then return true end end
    return false
end

add_to_roster = function(name)
    name = normalize_name(name)
    if name == '' then return end
    if not roster_contains(name) then table.insert(M.state.roster, name); table.sort(M.state.roster, function(a,b) return a:lower()<b:lower() end); save_all() end
end

local function remove_from_roster(name)
    local t = {}
    for _, v in ipairs(M.state.roster) do if v:lower() ~= name:lower() then table.insert(t, v) end end
    M.state.roster = t
    save_all()
end

local function in_layout(name)
    for g=1,12 do for s=1,6 do if M.state.desiredLayout[g][s] == name then return true end end end
    return false
end

local function unassigned_from_roster()
    local out = {}
    for _, n in ipairs(M.state.roster) do if not in_layout(n) then table.insert(out, n) end end
    return out
end

-- Connected peers discovery (Mono -> DanNet -> EQBC)
local function get_connected_peers()
    local result = {}
    local seen = {}

    -- MQ2Mono (E3) first
    local okMono, isMono = pcall(function() return mq.TLO.Plugin and mq.TLO.Plugin('MQ2Mono') and mq.TLO.Plugin('MQ2Mono').IsLoaded() end)
    if okMono and isMono then
        local okQ, peersStr = pcall(function() return mq.TLO.MQ2Mono and mq.TLO.MQ2Mono.Query and mq.TLO.MQ2Mono.Query('e3,E3Bots.ConnectedClients')() end)
        if okQ and peersStr and peersStr ~= '' then
            for peer in tostring(peersStr):gmatch('([^,]+)') do
                peer = peer:match('^%s*(.-)%s*$')
                if peer and peer ~= '' then
                    local nm = normalize_peer_name(peer)
                    if nm ~= '' and not seen[nm] then seen[nm]=true; table.insert(result, nm) end
                end
            end
        end
    end

    -- DanNet next
    local okDN, dnLoaded = pcall(function() return mq.TLO.Plugin and mq.TLO.Plugin('MQ2DanNet') and mq.TLO.Plugin('MQ2DanNet').IsLoaded() end)
    if okDN and dnLoaded then
        local okD, peersStr = pcall(function() return mq.TLO.DanNet and mq.TLO.DanNet.Peers and mq.TLO.DanNet.Peers() end)
        if okD and peersStr and peersStr ~= '' then
            for peer in tostring(peersStr):gmatch('([^|]+)') do
                peer = peer:match('^%s*(.-)%s*$')
                if peer and peer ~= '' then
                    local nm = normalize_peer_name(peer)
                    if nm ~= '' and not seen[nm] then seen[nm]=true; table.insert(result, nm) end
                end
            end
        end
    end

    -- EQBC last
    local okEQ, eqbcAvail = pcall(function() return mq.TLO.EQBC ~= nil end)
    if okEQ and eqbcAvail then
        local okE, peersStr = pcall(function() return mq.TLO.EQBC.Names() end)
        if okE and peersStr and peersStr ~= '' then
            for peer in tostring(peersStr):gmatch('([^%s,]+)') do
                peer = peer:match('^%s*(.-)%s*$')
                if peer and peer ~= '' then
                    local nm = normalize_peer_name(peer)
                    if nm ~= '' and not seen[nm] then seen[nm]=true; table.insert(result, nm) end
                end
            end
        end
    end

    table.sort(result, function(a,b) return a:lower() < b:lower() end)
    return result
end

local function scan_connected_peers_to_roster()
    local peers = get_connected_peers() or {}
    local added = 0
    for _, p in ipairs(peers) do
        if not roster_contains(p) then add_to_roster(p); added = added + 1 end
    end
    M.state.statusText = string.format('Scanned connected peers: %d found, %d added to roster.', #peers, added)
end

-- UI
local function draw_ui()
    initLayout()
    if not M.state.windowOpen then return end

    ImGui.SetNextWindowSize(860, 560, ImGuiCond.FirstUseEver)
    local _themeStack = push_theme()
    local isOpen, shouldDraw = ImGui.Begin('EZRaid', M.state.windowOpen)
    if not isOpen then
        M.state.windowOpen = false
        ImGui.End()
        pop_theme(_themeStack)
        return
    end
    if not shouldDraw then
        ImGui.End()
        pop_theme(_themeStack)
        return
    end

    -- Top row
    if ImGui.Button('Apply Layout To Raid') then M.apply_layout() end
    ImGui.SameLine()
    if ImGui.Button('Form Raid (Invite + Arrange)') then M.form_raid_from_layout() end
    ImGui.SameLine()
    if ImGui.Button('Scan Current Raid') then scan_current_raid() end
    ImGui.SameLine()
    local hudLabel = raid_hud.is_visible() and 'Hide Raid HUD' or 'Show Raid HUD'
    if ImGui.Button(hudLabel) then raid_hud.toggle() end
    ImGui.SameLine()
    local gear = (Icons and (Icons.FA_COG or Icons.FA_GEAR)) or 'Settings'
    if ImGui.SmallButton(gear) then ImGui.OpenPopup('EZRaid_Settings') end
    if M.state.statusText ~= '' then ImGui.SameLine(); ImGui.TextColored(0.6,0.9,0.6,1.0, M.state.statusText) end

    ImGui.Separator()

    local availW = ImGui.GetWindowContentRegionWidth()
    local leftW = math.floor(availW * 0.33)

    -- Left pane: Roster and actions
    ImGui.BeginChild('EZRaidLeft', ImVec2(leftW, 620), true)
    ImGui.Text('Saved Layouts')
    ImGui.SameLine()
    if ImGui.SmallButton('Reload') then load_all() end
    M.state._saveName = select(1, ImGui.InputTextWithHint('##layoutname', 'Add New Layout', M.state._saveName))
    ImGui.SameLine()
    if ImGui.SmallButton('Save') then save_current_layout(M.state._saveName) end

    local names = {}
    for k,_ in pairs(M.state.savedLayouts or {}) do table.insert(names, k) end
    table.sort(names)
    if ImGui.BeginTable('SavedLayouts', 3, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
        ImGui.TableSetupColumn('Name', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Load', ImGuiTableColumnFlags.WidthFixed, 60)
        ImGui.TableSetupColumn('Delete', ImGuiTableColumnFlags.WidthFixed, 70)
        ImGui.TableHeadersRow()
        for _, n in ipairs(names) do
            ImGui.TableNextRow()
            ImGui.TableNextColumn(); ImGui.Text(tostring(n))
            ImGui.TableNextColumn(); if ImGui.SmallButton('Load##'..n) then load_layout(n) end
            ImGui.TableNextColumn(); if ImGui.SmallButton('Delete##'..n) then delete_layout(n) end
        end
        ImGui.EndTable()
    end
    ImGui.Separator()
    ImGui.Text('Roster (PC Names)')
    ImGui.SameLine()
    if ImGui.SmallButton('Scan Connected PCs') then scan_connected_peers_to_roster() end
    ImGui.PushItemWidth(leftW - 120)
    M.state._newRosterName = select(1, ImGui.InputTextWithHint('##newroster', 'Add Name', M.state._newRosterName))
    ImGui.PopItemWidth()
    ImGui.SameLine()
    if ImGui.SmallButton('Add') then add_to_roster(M.state._newRosterName); M.state._newRosterName = '' end

    if ImGui.BeginTable('RosterTable', 2, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
        ImGui.TableSetupColumn('Name', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Remove', ImGuiTableColumnFlags.WidthFixed, 70)
        ImGui.TableHeadersRow()
        for _, name in ipairs(M.state.roster) do
            ImGui.TableNextRow()
            ImGui.TableNextColumn(); ImGui.Text(tostring(name))
            ImGui.TableNextColumn(); if ImGui.SmallButton('Remove##'..name) then remove_from_roster(name) end
        end
        ImGui.EndTable()
    end




    ImGui.EndChild()

    ImGui.SameLine()

    -- Right pane: Raid layout grid
    ImGui.BeginChild('EZRaidRight', ImVec2(0, 620), true)
    ImGui.Text('# of Groups:')
    ImGui.SameLine()
    local options = {'1','2','3','4','5','6','7','8','9','10','11','12'}
    ImGui.PushItemWidth(60)
    local cur = M.state.groupsToDisplay or 12
    local newIdx, changed = ImGui.Combo('##EZGroupsToDisplay', cur, options, #options)
    ImGui.PopItemWidth()
    if changed and newIdx then M.state.groupsToDisplay = math.max(1, math.min(12, newIdx)) end

    ImGui.Separator()
    local cols = 4
    local totalGroups = math.max(1, math.min(12, M.state.groupsToDisplay or 12))
    if ImGui.BeginTable('EZRaidGrid', cols, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
        local rows = math.ceil(totalGroups / cols)
        for row=0, rows-1 do
            ImGui.TableNextRow()
            for col=1, cols do
                ImGui.TableNextColumn()
                local g = row*cols + col
                if g > totalGroups then
                    ImGui.Dummy(0,0)
                else
                    ImGui.PushID('ez_group_'..tostring(g))
                    ImGui.Text(string.format('Group %d', g))
                    if ImGui.BeginTable('G'..tostring(g), 2, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.SizingFixedFit) then
                        ImGui.TableSetupColumn('#', ImGuiTableColumnFlags.WidthFixed, 18)
                        ImGui.TableSetupColumn('Member', ImGuiTableColumnFlags.WidthStretch)
                        ImGui.TableHeadersRow()
                        for slot=1,6 do
                            ImGui.PushID(slot)
                            ImGui.TableNextRow()
                            ImGui.TableNextColumn(); ImGui.Text(tostring(slot))
                            ImGui.TableNextColumn()
                            local current = M.state.desiredLayout[g][slot]
                            if current and current ~= '' then
                                if ImGui.SmallButton(tostring(current)..'##rm') then M.state.desiredLayout[g][slot] = nil end
                                if ImGui.IsItemHovered() then ImGui.SetTooltip('Click to remove') end
                            else
                                if ImGui.SmallButton('Add##add') then ImGui.OpenPopup('pick') end
                                if ImGui.BeginPopup('pick') then
                                    local avail = unassigned_from_roster()
                                    if #avail == 0 then
                                        ImGui.TextDisabled('No roster entries. Add names on the left.')
                                    else
                                        for _, n in ipairs(avail) do
                                            if ImGui.MenuItem(n) then M.state.desiredLayout[g][slot] = n; ImGui.CloseCurrentPopup() end
                                        end
                                    end
                                    ImGui.Separator()
                                    ImGui.Text('Manual Entry:')
                                    ImGui.SameLine()
                                    M.state._manualEntry = select(1, ImGui.InputText('##manual', M.state._manualEntry or ''))
                                    if ImGui.Button('Set##manualbtn') then
                                        local nm = normalize_name(M.state._manualEntry or '')
                                        if nm ~= '' then M.state.desiredLayout[g][slot] = nm; add_to_roster(nm); M.state._manualEntry = '' end
                                        ImGui.CloseCurrentPopup()
                                    end
                                    ImGui.EndPopup()
                                end
                            end
                            ImGui.PopID()
                        end
                        ImGui.EndTable()
                    end
                    if ImGui.SmallButton('Clear##grp'..tostring(g)) then M.state.desiredLayout[g] = {} end
                    ImGui.PopID()
                end
            end
        end
        ImGui.EndTable()
    end

    ImGui.EndChild()

    -- Settings popup (theming + pacing)
    if ImGui.BeginPopup('EZRaid_Settings') then
        ImGui.Text('Settings')
        ImGui.Separator()

        -- Invite pacing
        ImGui.Text('Invite Pacing (ms)')
        ImGui.PushItemWidth(220)
        do
            local curPace = tonumber(M.state.invitePacingMs or 150) or 150
            local newPace, changed = ImGui.SliderInt('##ez_invpace', curPace, 20, 2000)
            if changed then
                M.state.invitePacingMs = newPace
                save_all()
            end
        end
        ImGui.PopItemWidth()

        ImGui.Separator()
        ImGui.Text('Theme (EZRaid Only)')
        -- Presets
        do
            M._theme_presets = M._theme_presets or {
                { name = 'Teal Dark', theme = { enabled=true, alpha=1.0, windowRounding=6.0, frameRounding=6.0, grabRounding=6.0,
                    colors={ WindowBg={0.10,0.10,0.12,1.00}, ChildBg={0.08,0.08,0.10,0.92}, Text={0.88,0.92,0.98,1.00},
                             Button={0.18,0.44,0.42,0.95}, ButtonHovered={0.22,0.56,0.54,1.00}, ButtonActive={0.16,0.36,0.34,1.00},
                             FrameBg={0.16,0.18,0.22,1.00}, FrameBgHovered={0.20,0.24,0.30,1.00}, FrameBgActive={0.24,0.28,0.36,1.00},
                             Header={0.18,0.44,0.42,0.85}, HeaderHovered={0.22,0.56,0.54,0.95}, HeaderActive={0.16,0.36,0.34,0.95} } } },
                { name = 'Rose', theme = { enabled=true, alpha=1.0, windowRounding=8.0, frameRounding=8.0, grabRounding=8.0,
                    colors={ WindowBg={0.11,0.09,0.11,1.00}, ChildBg={0.09,0.07,0.09,0.92}, Text={0.96,0.90,0.96,1.00},
                             Button={0.58,0.25,0.38,0.95}, ButtonHovered={0.74,0.31,0.48,1.00}, ButtonActive={0.46,0.20,0.31,1.00},
                             FrameBg={0.20,0.14,0.18,1.00}, FrameBgHovered={0.28,0.18,0.24,1.00}, FrameBgActive={0.32,0.20,0.26,1.00},
                             Header={0.58,0.25,0.38,0.85}, HeaderHovered={0.74,0.31,0.48,0.95}, HeaderActive={0.46,0.20,0.31,0.95} } } },
                { name = 'High Contrast', theme = { enabled=true, alpha=1.0, windowRounding=4.0, frameRounding=4.0, grabRounding=4.0,
                    colors={ WindowBg={0.02,0.02,0.02,1.00}, ChildBg={0.02,0.02,0.02,0.95}, Text={1.00,1.00,1.00,1.00},
                             Button={0.20,0.60,0.95,0.95}, ButtonHovered={0.28,0.70,1.00,1.00}, ButtonActive={0.16,0.50,0.85,1.00},
                             FrameBg={0.08,0.08,0.08,1.00}, FrameBgHovered={0.14,0.14,0.14,1.00}, FrameBgActive={0.18,0.18,0.18,1.00},
                             Header={0.20,0.60,0.95,0.85}, HeaderHovered={0.28,0.70,1.00,0.95}, HeaderActive={0.16,0.50,0.85,0.95} } } },
                { name = 'Minimal', theme = { enabled=true, alpha=1.0, windowRounding=2.0, frameRounding=2.0, grabRounding=2.0,
                    colors={ WindowBg={0.12,0.12,0.12,1.00}, ChildBg={0.12,0.12,0.12,0.95}, Text={0.92,0.92,0.92,1.00},
                             Button={0.28,0.28,0.28,0.95}, ButtonHovered={0.36,0.36,0.36,1.00}, ButtonActive={0.22,0.22,0.22,1.00},
                             FrameBg={0.18,0.18,0.18,1.00}, FrameBgHovered={0.24,0.24,0.24,1.00}, FrameBgActive={0.28,0.28,0.28,1.00},
                             Header={0.28,0.28,0.28,0.85}, HeaderHovered={0.36,0.36,0.36,0.95}, HeaderActive={0.22,0.22,0.22,0.95} } } },
            }
            local function deepcopy(tbl)
                if type(tbl) ~= 'table' then return tbl end
                local out = {}
                for k,v in pairs(tbl) do out[k] = deepcopy(v) end
                return out
            end
            ImGui.Text('Presets:')
            ImGui.SameLine()
            for _, p in ipairs(M._theme_presets) do
                ImGui.PushID(p.name)
                if ImGui.SmallButton(p.name) then M.state.theme = deepcopy(p.theme); save_all() end
                ImGui.PopID()
                ImGui.SameLine()
            end
            ImGui.NewLine()
        end
        local t = M.state.theme
        local en = t.enabled and true or false
        local newEn = ImGui.Checkbox('Enable Custom Theme', en)
        if newEn ~= en then t.enabled = newEn; save_all() end
        ImGui.Text('Alpha')
        ImGui.PushItemWidth(220)
        local newAlpha, aChanged = ImGui.SliderFloat('##ez_th_alpha', t.alpha or 1.0, 0.0, 1.0)
        ImGui.PopItemWidth()
        if aChanged then if newAlpha < 0 then newAlpha=0 elseif newAlpha>1 then newAlpha=1 end; t.alpha = newAlpha; save_all() end

        ImGui.Text('Rounding')
        ImGui.PushItemWidth(220)
        local wr, wrC = ImGui.SliderFloat('##ez_wr', t.windowRounding or 6.0, 0.0, 16.0)
        local fr, frC = ImGui.SliderFloat('##ez_fr', t.frameRounding or 6.0, 0.0, 16.0)
        local gr, grC = ImGui.SliderFloat('##ez_gr', t.grabRounding or 6.0, 0.0, 16.0)
        ImGui.PopItemWidth()
        if wrC then t.windowRounding = math.max(0, math.min(16, wr)) end
        if frC then t.frameRounding  = math.max(0, math.min(16, fr)) end
        if grC then t.grabRounding   = math.max(0, math.min(16, gr)) end
        if wrC or frC or grC then save_all() end

        if ImGui.CollapsingHeader('Advanced Colors') then
            local function color_editor(label, key)
                local col = t.colors[key] or {1,1,1,1}
                local r,g,b,a = col[1], col[2], col[3], col[4]
                local changed = false
                if ImGui.ColorEdit4 then
                    r,g,b,a, changed = ImGui.ColorEdit4(label, r,g,b,a)
                else
                    ImGui.Text(label)
                    ImGui.SameLine(); ImGui.PushItemWidth(60); r, rc = ImGui.InputFloat('##ez_r'..key, r, 0.01, 0.1, '%.2f'); ImGui.PopItemWidth(); changed = changed or rc
                    ImGui.SameLine(); ImGui.PushItemWidth(60); g, gc = ImGui.InputFloat('##ez_g'..key, g, 0.01, 0.1, '%.2f'); ImGui.PopItemWidth(); changed = changed or gc
                    ImGui.SameLine(); ImGui.PushItemWidth(60); b, bc = ImGui.InputFloat('##ez_b'..key, b, 0.01, 0.1, '%.2f'); ImGui.PopItemWidth(); changed = changed or bc
                    ImGui.SameLine(); ImGui.PushItemWidth(60); a, ac = ImGui.InputFloat('##ez_a'..key, a, 0.01, 0.1, '%.2f'); ImGui.PopItemWidth(); changed = changed or ac
                end
                if changed then
                    t.colors[key] = {math.max(0,math.min(1,r)), math.max(0,math.min(1,g)), math.max(0,math.min(1,b)), math.max(0,math.min(1,a))}
                    save_all()
                end
            end
            color_editor('WindowBg', 'WindowBg')
            color_editor('ChildBg', 'ChildBg')
            color_editor('Text', 'Text')
            color_editor('Button', 'Button')
            color_editor('ButtonHovered', 'ButtonHovered')
            color_editor('ButtonActive', 'ButtonActive')
            color_editor('FrameBg', 'FrameBg')
            color_editor('FrameBgHovered', 'FrameBgHovered')
            color_editor('FrameBgActive', 'FrameBgActive')
            color_editor('Header', 'Header')
            color_editor('HeaderHovered', 'HeaderHovered')
            color_editor('HeaderActive', 'HeaderActive')
        end

        if ImGui.Button('Close') then ImGui.CloseCurrentPopup() end
        ImGui.EndPopup()
    end
    ImGui.End()
    pop_theme(_themeStack)
end

-- Binds and init
mq.bind('/ezraid', function(args)
    local sub = args or ''
    sub = sub:match('%S+') or ''
    sub = sub:lower()
    if sub == '' or sub == 'show' then
        M.state.windowOpen = true
    elseif sub == 'hide' then
        M.state.windowOpen = false
    elseif sub == 'toggle' then
        M.state.windowOpen = not M.state.windowOpen
    else
        if mq and mq.cmd then
            mq.cmd('/echo Usage: /ezraid [show|hide|toggle]')
        end
    end
end)

local function init()
    initLayout()
    pcall(load_all)
    pcall(raid_hud.init)
end

init()
mq.imgui.init('ezraid_ui', draw_ui)
mq.imgui.init('ezraid_hud', raid_hud.draw)

printf('[EZRaid] Loaded. Use /ezraid to open the window.')

-- Keep script alive while UI is open
while M.state.isRunning do
    process_queue()
    mq.delay(25)
end

pcall(raid_hud.cleanup)

return M
