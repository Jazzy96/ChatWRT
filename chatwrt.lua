module("luci.controller.chatwrt.chatwrt", package.seeall)

local util = require "luci.util"
local http = require "luci.http"
local json = require "luci.jsonc"

-- 从配置文件读取 API 配置
local function get_api_config()
    local f = io.open("/etc/config/chatwrt", "r")
    if f then
        local content = f:read("*all")
        f:close()
        
        local key = content:match("option%s+api_key%s+'(.-)'")
        local base_url = content:match("option%s+api_url%s+'(.-)'")
        
        -- 确保 base_url 以 /v1 结尾
        if base_url then
            base_url = base_url:gsub("/+$", "") -- 移除末尾的斜杠
            if not base_url:match("/v1$") then
                base_url = base_url .. "/v1"
            end
            -- 添加 chat/completions 路径
            local api_url = base_url .. "/chat/completions"
            return key, api_url
        end
    end
    return nil, nil
end

-- 定义 API 配置
local openai_key, openai_url = get_api_config()
if not openai_key or not openai_url then
    log("Warning: Using default API configuration")
    openai_key = "default_key"
    openai_url = "https://api.openai.com/v1"
end

-- 定义全局 log 函数
local function log(msg)
    os.execute("echo '" .. os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. "' >> /tmp/chatwrt.log")
end

-- 添加 read_config 函数定义
local function read_config(file)
    log("Reading config file: " .. file)
    local f = io.open("/etc/config/" .. file)
    if f then
        local content = f:read("*all")
        f:close()
        log("Successfully read config: " .. file)
        return content
    end
    log("Failed to read config: " .. file)
    return "无法读取配置文件"
end

-- 定义可用函数列表
local available_functions = {
    get_wireless_info = {
        description = "获取无线网络配置信息",
        execute = function(params)
            if params and params.interface then
                return util.exec("iwinfo " .. params.interface)
            end
            return util.exec("iwinfo")
        end
    },
    get_mtk_wireless_info = {
        description = "获取MTK无线状态",
        execute = function(params)
            if params and params.interface then
                return util.exec("iwpriv " .. params.interface .. " stat")
            end
            return util.exec("iwpriv ra0 stat")
        end
    },
    get_network_config = {
        description = "获取网络配置",
        execute = function(params)
            if params and params.interface then
                return read_config("network " .. params.interface)
            end
            return read_config("network")
        end
    },
    get_firewall_rules = {
        description = "获取防火墙规则",
        execute = function(params)
            return read_config("firewall")
        end
    },
    get_system_info = {
        description = "获取系统信息",
        execute = function(params)
            if params and params.type == "detailed" then
                return util.exec("ubus call system info && top -bn1")
            end
            return util.exec("ubus call system info")
        end
    },
    get_dhcp_leases = {
        description = "获取DHCP租约信息",
        execute = function()
            return util.exec("cat /tmp/dhcp.leases")
        end
    },
    get_interface_status = {
        description = "获取接口状态",
        execute = function(params)
            if params and params.interface then
                return util.exec("ifconfig " .. params.interface)
            end
            return util.exec("ifconfig")
        end
    },
    get_logs = {
        description = "获取系统日志",
        execute = function(params)
            local cmd = "logread"
            if params then
                if params.type then
                    cmd = cmd .. " | grep " .. params.type
                end
                if params.lines then
                    cmd = cmd .. " | tail -n " .. params.lines
                end
            end
            return util.exec(cmd)
        end
    }
}

-- 定义 call_ai_api 函数
local function call_ai_api(request_data)
    local request_json = json.stringify(request_data)
    log("Request JSON: " .. request_json)
    
    -- 检查必要的变量是否存在
    if not openai_key or not openai_url then
        log("Missing API configuration")
        return nil, "API configuration is missing"
    end
    
    local curl_cmd = string.format(
        'curl -v -s -X POST '..
        '-H "Authorization: Bearer %s" '..
        '-H "Content-Type: application/json" '..
        '-H "Accept: application/json" '..
        '-H "User-Agent: ChatWRT/1.0" '..
        '--max-time 30 '..
        '-d \'%s\' '..
        '"%s" 2>> /tmp/chatwrt.log',
        openai_key,
        request_json:gsub("'", "'\\''"),
        openai_url
    )
    
    log("Executing curl command")
    local response = util.exec(curl_cmd)
    log("Raw response from API: " .. tostring(response))
    
    if not response or response == "" then
        log("Empty response from API")
        return nil, "Empty response from API"
    end
    
    local result = json.parse(response)
    if not result then
        log("Failed to parse API response")
        return nil, "Failed to parse API response"
    end
    
    if result.error then
        log("API returned error: " .. json.stringify(result.error))
        return nil, "API error: " .. (result.error.message or "Unknown error")
    end
    
    return result
end

-- 定义 handle_response 函数
local function handle_response(response, request_body)
    if not response then
        log("Response is nil")
        return nil, "Empty response"
    end
    
    if not response.choices or not response.choices[1] then
        log("Invalid response structure: " .. json.stringify(response))
        return nil, "Invalid response structure"
    end

    local choice = response.choices[1]
    
    if choice.message and choice.message.function_call then
        log("Function call detected: " .. json.stringify(choice.message.function_call))
        
        local func_name = choice.message.function_call.name
        local func = available_functions[func_name]
        
        if func then
            local args = json.parse(choice.message.function_call.arguments or "{}")
            local result = func.execute(args)
            
            table.insert(request_body.messages, {
                role = "function",
                name = func_name,
                content = result
            })
            
            local new_response, err = call_ai_api(request_body)
            if not new_response then
                return nil, err
            end
            return new_response
        end
    end
    
    if choice.message and choice.message.content then
        return response
    end
    
    return nil, "Unexpected response format"
end

function index()
    -- 确保目录存在
    os.execute("mkdir -p /tmp/chatwrt")
    
    -- 直接使用 os.execute 记录日志
    os.execute("echo '" .. os.date("%Y-%m-%d %H:%M:%S") .. " Index function called' >> /tmp/chatwrt.log")
    
    entry({"admin", "services", "chatwrt"}, template("chatwrt/chat"), _("ChatWRT"), 60)
    entry({"admin", "services", "chatwrt", "query"}, call("handle_query"))
    
    os.execute("echo '" .. os.date("%Y-%m-%d %H:%M:%S") .. " Routes registered' >> /tmp/chatwrt.log")
end

function handle_query()
    log("Query handler called")
    
    -- 获取POST数据
    local input = http.content()
    log("Received input: " .. tostring(input))
    
    local request = json.parse(input)
    if not request then
        log("Failed to parse request JSON")
        return
    end
    log("Parsed request: " .. json.stringify(request))

    -- 修改请求体结构
    local request_body = {
        model = "gpt-4o-mini",
        messages = {
            {
                role = "system",
                content = "你是一个路由器配置专家。请使用 function_call 来获取所需的配置信息。"
            },
            {
                role = "user",
                content = request.query
            }
        },
        function_call = "auto",
        functions = {
            {
                name = "get_wireless_info",
                description = "获取无线网络配置和状态信息，包括SSID、信道、带宽等",
                parameters = {
                    type = "object",
                    properties = {
                        interface = {
                            type = "string",
                            description = "无线接口名称，例如 wlan0"
                        }
                    }
                }
            },
            {
                name = "get_mtk_wireless_info",
                description = "获取MTK无线状态信息",
                parameters = {
                    type = "object",
                    properties = {
                        interface = {
                            type = "string",
                            description = "MTK无线接口名称，例如 ra0"
                        }
                    }
                }
            },
            {
                name = "get_network_config",
                description = "获取网络配置信息",
                parameters = {
                    type = "object",
                    properties = {
                        interface = {
                            type = "string",
                            description = "网络接口名称"
                        }
                    }
                }
            },
            {
                name = "get_firewall_rules",
                description = "获取防火墙规则配置",
                parameters = {
                    type = "object",
                    properties = {
                        type = {
                            type = "string",
                            description = "防火墙规则类型，如 rules, zones 等"
                        }
                    }
                }
            },
            {
                name = "get_system_info",
                description = "获取系统信息",
                parameters = {
                    type = "object",
                    properties = {
                        type = {
                            type = "string",
                            enum = {"basic", "detailed"},
                            description = "信息详细程度"
                        }
                    }
                }
            }
        }
    }

    -- 第一次调用 AI,获取需要的函数
    local result, err = call_ai_api(request_body)
    if not result then
        log("API call failed: " .. tostring(err))
        http.write_json({ error = "API 调用失败: " .. tostring(err) })
        return
    end
    
    -- 处理响应
    result, err = handle_response(result, request_body)
    if not result then
        log("Response handling failed: " .. tostring(err))
        http.write_json({ error = "响应处理失败: " .. tostring(err) })
        return
    end
    
    -- 确保响应结构完整
    if not result.choices or 
       not result.choices[1] or 
       not result.choices[1].message or 
       not result.choices[1].message.content then
        log("Invalid final response structure")
        http.write_json({ error = "无效的响应结构" })
        return
    end
    
    -- 返回最终结果
    http.write_json({
        response = result.choices[1].message.content
    })
end
