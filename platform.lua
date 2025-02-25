local script = ...

local function findExePath()
    local n = 0
    while arg[n-1] do
        n = n - 1
    end
    return arg[n]
end

local exePath = findExePath()
local exeDir  = exePath:match('(.+)[/\\][%w_.-]+$')
local dll     = package.cpath:match '[/\\]%?%.([a-z]+)'
package.cpath = ('%s/?.%s;%s'):format(exeDir, dll, package.cpath)
local bee     = package.searchpath('bee', package.cpath)
if not bee then
    error('Can not find bee.dll? cpath = ' .. tostring(package.cpath))
end
local ok, err = package.loadlib(bee, 'luaopen_bee_platform')
if not ok then
    error(([[It doesn't seem to support your OS, please build it in your OS, see https://github.com/sumneko/vscode-lua/wiki/Build
errorMsg: %s
exePath:  %s
exeDir:   %s
dll:      %s
cpath:    %s
]]):format(
    err,
    exePath,
    exeDir,
    dll,
    package.cpath
))
end

local currentPath = debug.getinfo(1, 'S').source:sub(2)
local fs = require 'bee.filesystem'
local rootPath = fs.path(currentPath):remove_filename():string()
if dll == 'dll' then
    rootPath = rootPath:gsub('/', '\\')
    package.path  = rootPath .. script .. '\\?.lua'
          .. ';' .. rootPath .. script .. '\\?\\init.lua'
else
    rootPath = rootPath:gsub('\\', '/')
    package.path  = rootPath .. script .. '/?.lua'
          .. ';' .. rootPath .. script .. '/?/init.lua'
end

package.searchers[2] = function (name)
    local filename, err = package.searchpath(name, package.path)
    if not filename then
        return err
    end
    local f = io.open(filename)
    local buf = f:read '*a'
    f:close()
    local relative = filename:sub(#rootPath + 1)
    local init, err = load(buf, '@' .. relative)
    if not init then
        return err
    end
    return init, filename
end
