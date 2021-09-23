local files          = require 'files'
local searcher       = require 'core.searcher'
local await          = require 'await'
local define         = require 'proto.define'
local vm             = require 'vm'
local util           = require 'utility'
local guide          = require 'parser.guide'
local infer          = require 'core.infer'

-- TODO: Fields that are functions aren't highlighted as a function
-- TODO: Methods aren't classified as such
-- TODO: Differentiate global variables from static locals
-- TODO: Classes referenced in other files than where they are defined aren't classified as such

local Care = {}
Care['getglobal'] = function (source)
    local isLib = vm.isGlobalLibraryName(source[1])
    local isFunc = (source.value and source.value.type == 'function') or
		           (source.next and source.next.type == 'call')
    local type = isFunc and define.TokenTypes['function'] or define.TokenTypes.variable
    local modifier = isLib and define.TokenModifiers.defaultLibrary or define.TokenModifiers.static

    return {
        start      = source.start,
        finish     = source.finish,
        type       = type,
        modifieres = modifier,
    }
end
Care['setglobal'] = Care['getglobal']
Care['setmethod'] = Care['getmethod']
Care['getfield'] = function (source)
    local field = source.field
    if not field then
        return
    end
    if infer.hasType(source.field, 'function') then
        return {
            start      = field.start,
            finish     = field.finish,
            type       = define.TokenTypes['function'],
        }
    end
    if source.dot and (not source.next or source.next.type ~= "call") then
        return {
            start      = field.start,
            finish     = field.finish,
            type       = define.TokenTypes.property,
        }
    end
end
Care['setfield'] = Care['getfield']
Care['tablefield'] = function (source)
    local field = source.field
    if not field then
        return
    end
    return {
        start      = field.start,
        finish     = field.finish,
        type       = define.TokenTypes.property,
        modifieres = define.TokenModifiers.declaration,
    }
end
Care['getlocal'] = function (source)
    local loc = source.node
    local value = loc.value
    -- 1. 值为函数的局部变量 | Local variable whose value is a function
    if loc.refs then
        for _, ref in ipairs(loc.refs) do
            if ref.value and ref.value.type == 'function' then
                return {
                    start      = source.start,
                    finish     = source.finish,
                    type       = define.TokenTypes['function'],
                }
            end
        end
    end
    -- 2. 对象 | Object
    if  source.parent.type == 'getmethod'
	or  source.parent.type == 'setmethod'
    and source.parent.node == source then
        return
    end
    -- 3. 特殊变量 | Special variable
    if source[1] == '_ENV'
    or source[1] == 'self' then
        return
    end
    -- 4. 函数的参数 | Function parameters
    if loc.parent and loc.parent.type == 'funcargs' then
        return {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.parameter,
            modifieres = define.TokenModifiers.declaration,
        }
    end
    
    if infer.hasType(loc, 'function') then
		return {
			start      = source.start,
			finish     = source.finish,
			type       = define.TokenTypes['function'],
			modifieres = source.type == 'setlocal' and define.TokenModifiers.declaration or nil,
		}
	end
	-- 2. Class declaration
	if loc.bindDocs then
		for _, doc in ipairs(loc.bindDocs) do
			if doc.type == "doc.class" and doc.bindSources then
				for _, src in ipairs(doc.bindSources) do
					if src == loc then
						return {
							start      = source.start,
							finish     = source.finish,
							type       = define.TokenTypes.class,
						}
					end
				end
			end
		end
	end
    -- 5. const 变量 | Const variable
    if loc.attrs then
        for _, attr in ipairs(loc.attrs) do
            local name = attr[1]
            if name == 'const' then
                return {
                    start      = source.start,
                    finish     = source.finish,
                    type       = define.TokenTypes.variable,
                    modifieres = define.TokenModifiers.static,
                }
            elseif name == 'close' then
                return {
                    start      = source.start,
                    finish     = source.finish,
                    type       = define.TokenTypes.variable,
                    modifieres = define.TokenModifiers.abstract,
                }
            end
        end
    end
    -- 6. 函数调用 | Function call
    if  source.parent.type == 'call'
    and source.parent.node == source then
        return
    end
	local isLocal = loc.parent ~= guide.getRoot(loc)
    -- 7. 其他 | Other
    return {
        start      = source.start,
        finish     = source.finish,
        type       = define.TokenTypes.variable,
		modifieres = isLocal and define.TokenModifiers['local'] or define.TokenModifiers.static,
    }
end
Care['setlocal'] = Care['getlocal']
Care['local'] = function (source) -- Local declaration, i.e. "local x", "local y = z", or "local function() end"
    if source[1] == '_ENV'
    or source[1] == 'self' then
        return
    end
    if source.parent and source.parent.type == 'funcargs' then
        return {
            start      = source.start,
            finish     = source.finish,
            type       = define.TokenTypes.parameter,
            modifieres = define.TokenModifiers.declaration,
        }
    end
    if source.value then
        if source.value.type == "function" or infer.hasType(source.value, 'function') then
            -- Function declaration, either a new one or an alias for another one
            return {
                start      = source.start,
                finish     = source.finish,
                type       = define.TokenTypes['function'],
                modifieres = define.TokenModifiers.declaration,
            }
        end
    end
	if source.value and source.value.type == 'table' and source.bindDocs then
		for _, doc in ipairs(source.bindDocs) do
			if doc.type == "doc.class" then
                -- Class declaration (explicit)
				return {
					start      = source.start,
					finish     = source.finish,
					type       = define.TokenTypes.class,
					modifieres = define.TokenModifiers.declaration,
				}
			end
		end
    end
	if source.attrs then
        for _, attr in ipairs(source.attrs) do
            local name = attr[1]
            if name == 'const' then
                return {
                    start      = source.start,
                    finish     = source.finish,
                    type       = define.TokenTypes.variable,
                    modifieres = define.TokenModifiers.declaration | define.TokenModifiers.static,
                }
            elseif name == 'close' then
                return {
                    start      = source.start,
                    finish     = source.finish,
                    type       = define.TokenTypes.variable,
                    modifieres = define.TokenModifiers.declaration | define.TokenModifiers.abstract,
                }
            end
        end
	else
		local isLocal = source.parent ~= guide.getRoot(source)

		return {
			start      = source.start,
			finish     = source.finish,
			type       = define.TokenTypes.variable,
			modifieres = isLocal and define.TokenModifiers['local'] or define.TokenModifiers.static,
		}
    end
end
Care['doc.return.name'] = function (source)
    return {
        start  = source.start,
        finish = source.finish,
        type   = define.TokenTypes.parameter,
    }
end
Care['doc.tailcomment'] = function (source)
    return {
        start  = source.start,
        finish = source.finish,
        type   = define.TokenTypes.comment,
    }
end
Care['doc.type.name'] = function (source)
    if source.typeGeneric then
        return {
            start  = source.start,
            finish = source.finish,
            type   = define.TokenTypes.macro,
        }
    end
end

Care['nonstandardSymbol.comment'] = function (source)
    return {
        start  = source.start,
        finish = source.finish,
        type   = define.TokenTypes.comment,
    }
end
Care['nonstandardSymbol.continue'] = function (source)
    return {
        start  = source.start,
        finish = source.finish,
        type   = define.TokenTypes.keyword,
    }
end

local function buildTokens(uri, results)
    local tokens = {}
    local lastLine = 0
    local lastStartChar = 0
    for i, source in ipairs(results) do
        local startPos  = files.position(uri, source.start, 'left')
        local finishPos = files.position(uri, source.finish, 'right')
        local line      = startPos.line
        local startChar = startPos.character
        local deltaLine = line - lastLine
        local deltaStartChar
        if deltaLine == 0 then
            deltaStartChar = startChar - lastStartChar
        else
            deltaStartChar = startChar
        end
        lastLine = line
        lastStartChar = startChar
        -- see https://microsoft.github.io/language-server-protocol/specifications/specification-3-16/#textDocument_semanticTokens
        local len = i * 5 - 5
        tokens[len + 1] = deltaLine
        tokens[len + 2] = deltaStartChar
        tokens[len + 3] = finishPos.character - startPos.character -- length
        tokens[len + 4] = source.type
        tokens[len + 5] = source.modifieres or 0
    end
    return tokens
end

return function (uri, start, finish)
    local ast   = files.getState(uri)
    local lines = files.getLines(uri)
    local text  = files.getText(uri)
    if not ast then
        return nil
    end

    local results = {}
    local mark = {}
    guide.eachSourceBetween(ast.ast, start, finish, function (source)
        if mark[source] then
            return -- already tokenized; don't want to produce duplicates
        end
        local method = Care[source.type]
        if not method then
            return
        end
        local result = method(source)
        if result then
            mark[source] = true
            results[#results+1] = result
        end
        await.delay()
    end)

    for _, comm in ipairs(ast.comms) do
        if comm.type == 'comment.cshort' then
            results[#results+1] = {
                start  = comm.start,
                finish = comm.finish,
                type   = define.TokenTypes.comment,
            }
        end
    end

    table.sort(results, function (a, b)
        return a.start < b.start
    end)

    local tokens = buildTokens(uri, results)

    return tokens
end
