local files  = require 'files'
local furi   = require 'file-uri'
local config = require 'config'
local rpath  = require 'workspace.require-path'
local client = require 'client'
local lang   = require 'language'
local guide  = require 'parser.guide'

local function findInsertRow(uri)
    local text  = files.getText(uri)
    local state = files.getState(uri)
    local lines = state.lines
    local fmt   = {
        pair = false,
        quot = '"',
        col  = nil,
    }
    local hasFounded
    for i = 0, #lines do
        local ln = lines[i]
        local lnText = text:match('[^\r\n]*', ln)
        if not lnText:find('require', 1, true) then
            if hasFounded then
                return i, fmt
            end
            if  not lnText:match '^local%s'
            and not lnText:match '^%s*$'
            and not lnText:match '^%-%-' then
                return i, fmt
            end
        else
            hasFounded = true
            local lpPos = lnText:find '%('
            if lpPos then
                fmt.pair = true
            else
                fmt.pair = false
            end
            local quot = lnText:match [=[(['"])]=]
            fmt.quot = quot or fmt.quot
            local eqPos = lnText:find '='
            if eqPos then
                fmt.col = eqPos
            end
        end
    end
    return 0, fmt
end

local function askAutoRequire(visiblePaths)
    local selects = {}
    local nameMap = {}
    for _, visible in ipairs(visiblePaths) do
        local expect = visible.expect
        local select = lang.script(expect)
        if not nameMap[select] then
            nameMap[select] = expect
            selects[#selects+1] = select
        end
    end
    local disable = lang.script.COMPLETION_DISABLE_AUTO_REQUIRE
    selects[#selects+1] = disable

    local result = client.awaitRequestMessage('Info'
        , lang.script.COMPLETION_ASK_AUTO_REQUIRE
        , selects
    )
    if not result then
        return
    end
    if result == disable then
        client.setConfig {
            {
                key    = 'Lua.completion.autoRequire',
                action = 'set',
                value  = false,
            }
        }
        return
    end
    return nameMap[result]
end

local function applyAutoRequire(uri, row, name, result, fmt)
    local quotedResult = ('%q'):format(result)
    if fmt.quot == "'" then
        quotedResult = ([['%s']]):format(quotedResult:sub(2, -2)
            :gsub([[']], [[\']])
            :gsub([[\"]], [["]])
        )
    end
    if fmt.pair then
        quotedResult = ('(%s)'):format(quotedResult)
    else
        quotedResult = (' %s'):format(quotedResult)
    end
    local sp = ' '
    local text = ('local %s'):format(name)
    if fmt.col and fmt.col > #text then
        sp = (' '):rep(fmt.col - #text - 1)
    end
    text = ('local %s%s= require%s\n'):format(name, sp, quotedResult)
    client.editText(uri, {
        {
            start  = guide.positionOf(row, 0),
            finish = guide.positionOf(row, 0),
            text   = text,
        }
    })
end

return function (data)
    local uri    = data.uri
    local target = data.target
    local name   = data.name
    local state  = files.getState(uri)
    if not state then
        return
    end

    local path = furi.decode(target)
    local visiblePaths = rpath.getVisiblePath(path, config.get 'Lua.runtime.path')
    if not visiblePaths or #visiblePaths == 0 then
        return
    end
    table.sort(visiblePaths, function (a, b)
        return #a.expect < #b.expect
    end)

    local result = askAutoRequire(visiblePaths)
    if not result then
        return
    end

    local offset, fmt = findInsertRow(uri)
    applyAutoRequire(uri, offset, name, result, fmt)
end
