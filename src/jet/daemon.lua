local cjson = require'cjson'
local ev = require'ev'
local socket = require'socket'
local jsocket = require'jet.socket'
local tinsert = table.insert
local tremove = table.remove
local tconcat = table.concat
local tsort = table.sort
local print = print
local pairs = pairs
local ipairs = ipairs
local assert = assert
local pcall = pcall
local type = type
local error = error
local require = require
local tostring = tostring
local jencode = cjson.encode
local jdecode = cjson.decode
local jnull = cjson.null

module('jet.daemon')

local log = function(...)
  print('jetd',...)
end

local info = function(...)
  log('info',...)
end

local crit = function(...)
  log('err',...)
end

local debug = function(...)
  log('debug',...)
end

local invalid_params = function(data)
  local err = {
    code = -32602,
    message = 'Invalid params',
    data = data
  }
  return err
end


local create_daemon = function(options)
  
  
  -- holds all (jet.socket.wrapped) clients index by client itself
  local clients = {}
  local nodes = {}
  local states = {}
  local leaves = {}
  local routes = {}
  
  local route_message = function(client,message)
    local route = routes[message.id]
    if route then
      routes[message.id] = nil
      message.id = route.id
      route.receiver:queue(message)
    else
      log('unknown route id:',jencode(message))
    end
  end
  
  local publish = function(notification)
    --   debug('publish',jencode(notification))
    local path = notification.path
    for client in pairs(clients) do
      for fetch_id,matcher in pairs(client.fetchers) do
        if matcher(path) then
          client:queue
          {
            method = fetch_id,
            params = notification
          }
        end
      end
    end
  end
  
  local flush_clients = function()
    for client in pairs(clients) do
      client:flush()
    end
  end
  
  local matcher = function(match,unmatch)
    local f
    if not unmatch and #match == 1 then
      local match = match[1]
      f = function(path)
        return path:match(match)
      end
    elseif type(match) == 'table' and type(unmatch) == 'table' then
      f = function(path)
        for _,unmatch in ipairs(unmatch) do
          if path:match(unmatch) then
            return false
          end
        end
        for _,match in ipairs(match) do
          if path:match(match) then
            return true
          end
        end
      end
    else
      f = function(path)
        for _,match in ipairs(match) do
          if path:match(match) then
            return true
          end
        end
      end
    end
    assert(f and type(f) == 'function')
    return f
  end
  
  local checked = function(params,key,typename)
    local p = params[key]
    if p ~= nil then
      if typename then
        if type(p) == typename then
          return p
        else
          error(invalid_params{wrong_type=key,got=params})
        end
      else
        return p
      end
    else
      error(invalid_params{missing_param=key,got=params})
    end
  end
  
  local optional = function(params,key,typename)
    local p = params[key]
    if p then
      if typename then
        if type(p) == typename then
          return p
        else
          error(invalid_params{wrong_type=key,got=params})
        end
      else
        return p
      end
    end
  end
  
  local post = function(client,message)
    local notification = message.params
    local path = checked(notification,'path','string')
    local event = checked(notification,'event','string')
    local data = checked(notification,'data','table')
    local leave = leaves[path]
    if leave then
      if event == 'change' then
        for k,v in pairs(data) do
          leave.element[k] = v
        end
      end
      publish(notification)
    else
      local error = invalid_params{invalid_path=path}
      if message.id then
        client:queue
        {
          id = message.id,
          error = error
        }
      else
        log('post failed',jencode(message))
      end
    end
  end
  
  local fetch = function(client,message)
    local params = message.params
    local id = checked(params,'id','string')
    local match = checked(params,'match','table')
    local unmatch = optional(params,'unmatch','table')
    local matcher = matcher(match,unmatch)
    local notifications = {}
    if not client.fetchers[id] then
      for path in pairs(nodes) do
        if matcher(path) then
          local notification = {
            method = id,
            params = {
              path = path,
              event = 'add',
              data = {
                type = 'node'
              }
            }
          }
          tinsert(notifications,notification)
        end
      end
      local compare_path_length = function(not1,not2)
        return #not1.params.path < #not2.params.path
      end
      tsort(notifications,compare_path_length)
      for path,leave in pairs(leaves) do
        if matcher(path) then
          local notification = {
            method = id,
            params = {
              path = path,
              event = 'add',
              data = leave.element
            }
          }
          tinsert(notifications,notification)
        end
      end
    end
    client.fetchers[id] = matcher
    if message.id then
      client:queue
      {
        id = message.id,
        result = {}
      }
    end
    for _,notification in ipairs(notifications) do
      client:queue(notification)
    end
  end
  
  local unfetch = function(client,message)
    local params = message.params
    local id = checked(params,'id','string')
    client.fetchers[id] = nil
  end
  
  local set = function(client,message)
    local params = message.params
    local path = checked(params,'path','string')
    local value = checked(params,'value')
    local leave = leaves[path]
    if leave and leave.element.type == 'state' then
      local id
      if message.id then
        id = message.id..tostring(client)
        assert(not routes[id])
        -- save route to forward reply
        routes[id] = {
          receiver = client,
          id = message.id
        }
      end
      leave.client:queue
      {
        id = id,-- maybe nil
        method = path,
        params = {
          value = value
        }
      }
    else
      local error
      if leave then
        error = invalid_params{path_is_not_state=path}
      else
        error = invalid_params{invalid_path=path}
      end
      if message.id then
        client:queue
        {
          id = message.id,
          error = error
        }
      end
      log('set failed',jencode(error))
    end
  end
  
  local call = function(client,message)
    local params = message.params
    local path = checked(params,'path','string')
    local args = optional(params,'args','table')
    local leave = leaves[path]
    if leave and leave.element.type == 'method' then
      local id
      if message.id then
        id = message.id..tostring(client)
        assert(not routes[id])
        -- save route to forward reply
        routes[id] = {
          receiver = client,
          id = message.id
        }
      end
      leave.client:queue
      {
        id = id,-- maybe nil
        method = path,
        params = args
      }
    else
      local error
      if leave then
        error = invalid_params{path_is_not_method=path}
      else
        error = invalid_params{invalid_path=path}
      end
      if message.id then
        client:queue
        {
          id = message.id,
          error = error
        }
      end
      log('call failed',jencode(error))
    end
  end
  
  local increment_nodes = function(path)
    local parts = {}
    for part in path:gmatch('[^/]+') do
      tinsert(parts,part)
    end
    for i=1,#parts-1 do
      local path = tconcat(parts,'/',1,i)
      local count = nodes[path]
      if count then
        nodes[path] = count+1
      else
        --         print('new node',path)
        nodes[path] = 1
        publish
        {
          event = 'add',
          path = path,
          data = {
            type = 'node'
          }
        }
      end
      --      print('node',node,nodes[path])
    end
  end
  
  local decrement_nodes = function(path)
    local parts = {}
    for part in path:gmatch('[^/]+') do
      tinsert(parts,part)
    end
    for i=#parts-1,1,-1 do
      local path = tconcat(parts,'/',1,i)
      local count = nodes[path]
      if count > 1 then
        nodes[path] = count-1
        --         print('node',path,nodes[path])
      else
        nodes[path] = nil
        --         print('delete node',path)
        publish
        {
          event = 'remove',
          path = path,
          data = {
            type = 'node'
          }
        }
      end
    end
  end
  
  local add = function(client,message)
    local params = message.params
    local path = checked(params,'path','string')
    if nodes[path] or leaves[path] then
      error(invalid_params{occupied_path = path})
    end
    increment_nodes(path)
    local element = checked(params,'element','table')
    if not element.type then
      error(invalid_params{missing_param ='element.type',got=params})
    end
    local leave = {
      client = client,
      element = element
    }
    leaves[path] = leave
    publish
    {
      path = path,
      event = 'add',
      data = element
    }
  end
  
  local remove = function(client,message)
    local params = message.params
    local path = checked(params,'path','string')
    if not leaves[path] then
      error(invalid_params{invalid_path = path})
    end
    local element = assert(leaves[path].element)
    leaves[path] = nil
    publish
    {
      path = path,
      event = 'remove',
      data = element
    }
    decrement_nodes(path)
  end
  
  local config = function(client,message)
    local params = message.params
    if params.peer then
      client = nil
      for client_ in pairs(clients) do
        print(client_.name,params.peer)
        if client_.name == params.peer then
          client = client_
          break
        end
      end
      if not client then
        error('unknown client')
      end
    else
      client.name = params.name
    end
    client.debug = params.debug
  end
  
  local sync = function(f)
    local sc = function(client,message)
      local ok,result = pcall(f,client,message)
      if message.id then
        if ok then
          client:queue
          {
            id = message.id,
            result = result or {}
          }
        else
          local error
          if type(result) == 'table' and result.code and result.message then
            error = result
          else
            error = {
              code = -32603,
              message = 'Internal error',
              data = result
            }
          end
          client:queue
          {
            id = message.id,
            error = error
          }
        end
      elseif not ok then
        log('sync '..message.method..' failed',jencode(result))
      end
    end
    return sc
  end
  
  local async = function(f)
    local ac = function(client,message)
      local ok,err = pcall(f,client,message)
      if message.id then
        if not ok then
          local error
          if type(err) == 'table' and err.code and err.message then
            error = err
          else
            error = {
              code = -32603,
              message = 'Internal error',
              data = err
            }
          end
          client:queue
          {
            id = message.id,
            error = err
          }
        end
      elseif not ok then
        log('async '..message.method..' failed:',jencode(err))
      end
    end
    return ac
  end
  
  local services = {
    add = sync(add),
    remove = sync(remove),
    config = sync(config),
    call = async(call),
    set = async(set),
    fetch = async(fetch),
    unfetch = sync(unfetch),
    post = sync(post),
    echo = sync(function(client,message)
        return message.params
      end)
  }
  
  local dispatch_request = function(client,message)
    local error
    assert(message.method)
    local service = services[message.method]
    if service then
      local ok,err = pcall(service,client,message)
      if ok then
        return
      else
        if type(err) == 'table' and err.code and err.message then
          error = err
        else
          error = {
            code = -32603,
            message = 'Internal error',
            data = err
          }
        end
      end
    else
      error = {
        code = -32601,
        message = 'Method not found',
        data = message.method
      }
    end
    client:queue
    {
      id = message.id,
      error = error
    }
  end
  
  local dispatch_notification = function(client,message)
    local service = services[message.method]
    if service then
      local ok,err = pcall(service,client,message)
      if not ok then
        log('dispatch_notification error:',jencode(err))
      end
    end
  end
  
  local dispatch_single_message = function(client,message)
    if message.id then
      if message.method then
        dispatch_request(client,message)
      elseif message.result or message.error then
        route_message(client,message)
      else
        client:queue
        {
          id = message.id,
          error = {
            code = -32600,
            message = 'Invalid Request',
            data = message
          }
        }
        log('message not dispatched:',jencode(message))
      end
    elseif message.method then
      dispatch_notification(client,message)
    else
      log('message not dispatched:',jencode(message))
    end
  end
  
  local dispatch_message = function(client,message,err)
    local ok,err = pcall(
      function()
        if message then
          if client.debug then
            debug(client.name or 'unnamed client','->',jencode(message))
          end
          if message == jnull then
            client:queue
            {
              error = {
                code = -32600,
                message = 'Invalid Request',
                data = 'message is null'
              }
            }
          elseif #message > 0 then
            for i,message in ipairs(message) do
              dispatch_single_message(client,message)
            end
          else
            dispatch_single_message(client,message)
          end
        else
          client:queue
          {
            error = {
              code  = -32700,
              messsage = 'Parse error'
            }
          }
        end
      end)
    if not ok then
      crit('dispatching message',jencode(message),err)
    end
    flush_clients()
  end
  
  local options = options or {}
  local port = options.port or 11122
  local loop = options.loop or ev.Loop.default
  
  local create_client = function(ops)
    local client = {}
    client.release = function()
      if client then
        client.fetchers = {}
        for path,leave in pairs(leaves) do
          if leave.client == client then
            publish
            {
              event = 'remove',
              path = path,
              data = {
                type = leave.element.type
              }
            }
            decrement_nodes(path)
            leaves[path] = nil
          end
        end
        flush_clients()
        ops.close()
        clients[client] = nil
        client = nil
      end
    end
    client.close = function(_)
      client:flush()
      ops.close()
    end
    client.queue = function(_,message)
      if not client.messages then
        client.messages = {}
      end
      tinsert(client.messages,message)
    end
    local send = ops.send
    client.flush = function(_)
      if client.messages then
        local num = #client.messages
        local message
        if num == 1 then
          message = client.messages[1]
        elseif num > 1 then
          message = client.messages
        else
          assert(false,'messages must contain at least one element if not nil')
        end
        if client.debug then
          debug(client.name or 'unnamed client','<-',jencode(message))
        end
        send(message)
        client.messages = nil
      end
    end
    client.fetchers = {}
    return client
  end
  
  local listener
  local accept_tcp = function(loop,accept_io)
    local sock = listener:accept()
    if not sock then
      log('accepting client failed')
      return
    end
    local jsock = jsocket.wrap(sock)
    local client = create_client
    {
      close = function() jsock:close() end,
      send = function(msg) jsock:send(msg) end
    }
    jsock:on_message(function(_,...)
        dispatch_message(client,...)
      end)
    jsock:on_close(function(_,...)
        client:release()
      end)
    jsock:on_error(function(_,...)
        err('socket error',...)
        client:release()
      end)
    jsock:read_io():start(loop)
    clients[client] = client
  end
  
  local accept_websocket = function(ws)
    local client = create_client
    {
      close = function()
        ws:close()
      end,
      send = function(msg)
        ws:send(jencode(msg))
      end,
    }
    ws:on_message(function(_,msg,opcode)
        if opcode == 1 then
          dispatch_message(client,jdecode(msg))
        end
      end)
    ws:on_close(function(_,...)
        client:release()
      end)
    ws:on_error(function(_,...)
        err('socket error',...)
        client:release()
      end)
    clients[client] = client
  end
  
  local listen_io
  local websocket_server
  
  local daemon = {
    start = function()
      listener = assert(socket.bind('*',port))
      listener:settimeout(0)
      listen_io = ev.IO.new(
        accept_tcp,
        listener:getfd(),
      ev.READ)
      listen_io:start(loop)
      
      if options.ws_port then
        local websocket_ok,err = pcall(function()
            websocket_server = require'websocket'.server.ev.listen
            {
              port = options.ws_port,
              protocols = {
                jet = accept_websocket
              }
            }
          end)
        if not websocket_ok then
          print('Could not start websocket server',err)
        end
      end
    end,
    stop = function()
      listen_io:stop(loop)
      listener:close()
      for _,client in pairs(clients) do
        client:close()
      end
      if websocket_server then
        websocket_server:close()
      end
    end
  }
  
  return daemon
end

return {
  new = create_daemon
}


