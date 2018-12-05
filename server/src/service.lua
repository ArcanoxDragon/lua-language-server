local subprocess = require 'bee.subprocess'
local Method     = require 'method'
local fs         = require 'bee.filesystem'
local thread     = require 'thread'
local json       = require 'json'
local parser     = require 'parser'
local matcher    = require 'matcher'


local ErrorCodes = {
	-- Defined by JSON RPC
	ParseError           = -32700,
	InvalidRequest       = -32600,
	MethodNotFound       = -32601,
	InvalidParams        = -32602,
	InternalError        = -32603,
	serverErrorStart     = -32099,
	serverErrorEnd       = -32000,
	ServerNotInitialized = -32002,
	UnknownErrorCode     = -32001,

	-- Defined by the protocol.
	RequestCancelled     = -32800,
}

local mt = {}
mt.__index = mt
mt._input = nil
mt._output = nil
mt._method = nil
mt._file = nil

function mt:_callback(method, params)
    local f = self._method
    if f then
        return f(method, params)
    end
    return nil, '没有注册method'
end

function mt:_send(data)
    local f = self._output
    if not f then
        return
    end
    data.jsonrpc = '2.0'
    local content = json.encode(data)
    local buf = ('Content-Length: %d\r\n\r\n%s'):format(#content, content)
    f(buf)
end

function mt:_doProto(proto)
    local id     = proto.id
    local method = proto.method
    local params = proto.params
    local response, err = self:_callback(method, params)
    if id then
        if response then
            self:_send {
                id = id,
                result = response,
            }
        else
            self:_send {
                id = id,
                error = {
                    code = ErrorCodes.UnknownErrorCode,
                    message = err or ('没有回应：' .. method),
                },
            }
        end
    end
    if response == nil then
        log.error(err or ('没有回应：' .. method))
    end
end

function mt:_buildTextCache()
    if not next(self._need_compile) then
        return
    end
    local list = {}
    for uri in pairs(self._need_compile) do
        list[#list+1] = uri
    end

    local size = 0
    local clock = os.clock()
    for _, uri in ipairs(list) do
        local obj = self:compileText(uri)
        size = size + #obj.text
    end
    local passed = os.clock() - clock
    log.debug(('\n\z
    语法树缓存完成\n\z
    耗时：[%.3f]秒\n\z
    数量：[%d]\n\z
    总大小：[%.3f]kb\n\z
    速度：[%.3f]kb/s\n\z
    内存：[%.3f]kb'):format(
        passed,
        #list,
        size / 1000,
        size / passed / 1000,
        collectgarbage 'count'
    ))
end

function mt:setInput(input)
    self._input = input
end

function mt:setOutput(output)
    self._output = output
end

function mt:read(mode)
    if not self._input then
        return nil
    end
    return self._input(mode)
end

function mt:saveText(uri, version, text)
    local obj = self._file[uri]
    if obj then
        if obj.version >= version then
            return
        end
        obj.version = version
        obj.text = text
        self._need_compile[uri] = true
    else
        self._file[uri] = {
            version = version,
            text = text,
        }
        self._need_compile[uri] = true
    end
end

function mt:loadText(uri)
    local obj = self._file[uri]
    if not obj then
        return nil
    end
    self:compileText(uri)
    return obj.results, obj.lines
end

function mt:compileText(uri)
    local obj = self._file[uri]
    if not obj then
        return nil
    end
    if not self._need_compile[uri] then
        return nil
    end
    self._need_compile[uri] = nil
    local ast = parser:ast(obj.text)
    obj.results = matcher.compile(ast)
    obj.lines   = parser:lines(obj.text)
    return obj
end

function mt:removeText(uri)
    self._file[uri] = nil
    self._need_compile[uri] = nil
end

function mt:setMethod(method)
    self._method = method
end

function mt:runStep()
    local proto = self._input()
    if proto then
        -- 协议内容读取成功后重置
        self._header = nil
        self._idle_clock = os.clock()
        self:_doProto(proto)
        return
    end
    if os.clock() - self._idle_clock >= 1 then
        self:_buildTextCache()
    end
end

function mt:stop()
    self._input = nil
    self._output = nil
end

function mt:listen()
    subprocess.filemode(io.stdin, 'b')
    subprocess.filemode(io.stdout, 'b')
    io.stdin:setvbuf 'no'
    io.stdout:setvbuf 'no'

    thread.require 'proto'

    self:setInput(function ()
        return thread.proto()
    end)
    self:setOutput(function (buf)
        io.write(buf)
    end)
    self:setMethod(function (method, params)
        local optional
        if method:sub(1, 2) == '$/' then
            method = method:sub(3)
            optional = true
        end
        local f = Method[method]
        if f then
            local suc, res, res2 = pcall(f, self, params)
            if suc then
                return res, res2
            else
                return nil, '发生运行时错误：' .. res
            end
        end
        if optional then
            return false
        else
            return nil, '没有注册方法：' .. method
        end
    end)

    while true do
        thread.on_tick()
        self:runStep()
        thread.sleep(0.001)
    end
end

return function ()
    local session = setmetatable({
        _file = {},
        _need_compile = {},
        _header = nil,
        _idle_clock = os.clock(),
    }, mt)
    return session
end
