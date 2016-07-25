-- Copyright (C) 2014 Jing Ye (yejingx), UPYUN Inc.
-- Copyright (C) 2014 Monkey Zhang (timebug), UPYUN Inc.

local lock  = require "resty.lock"
local cjson = require "cjson.safe"

local str_sub    = string.sub
local str_format = string.format
local lower      = string.lower
local byte       = string.byte
local floor      = math.floor
local sqrt       = math.sqrt
local tab_sort   = table.sort
local tab_concat = table.concat
local tab_insert = table.insert
local unpack     = unpack

local get_phase = ngx.get_phase
local worker_id = ngx.worker.id
local tcp       = ngx.socket.tcp
local localtime = ngx.localtime
local re_find   = ngx.re.find
local re_match  = ngx.re.match
local re_gmatch = ngx.re.gmatch
local mutex     = ngx.shared.mutex
local state     = ngx.shared.state
local shd_config= ngx.shared.config
local log       = ngx.log
local now       = ngx.now
local update_time = ngx.update_time

local INFO = ngx.INFO
local ERR  = ngx.ERR
local WARN = ngx.WARN

local resty_redis, resty_mysql, ngx_upstream


local _M = { _VERSION = "0.11",
             STATUS_OK = 0, STATUS_UNSTABLE = 1, STATUS_ERR = 2 }

local CHECKUP_TIMER_KEY = "checkups:timer"
local CHECKUP_LAST_CHECK_TIME_KEY = "checkups:last_check_time"
local CHECKUP_TIMER_ALIVE_KEY = "checkups:timer_alive"
local SHD_CONFIG_VERSTION_KEY = "config_version"
local SKEYS_KEY = "checkups:skeys"
local SHD_CONFIG_PREFIX = "shd_config"

local PEER_STATUS_PREFIX = "checkups:peer_status:"

local upstream = {}
local peer_id_dict = {}
local ups_status_timer_created
local cluster_status = {}


local function get_lock(key)
    local lock = lock:new("locks")
    local elapsed, err = lock:lock(key)
    if not elapsed then
        log(WARN, "failed to acquire the lock: ", key, ", ", err)
        return nil, err
    end

    return lock
end


local function release_lock(lock)
    local ok, err = lock:unlock()
    if not ok then
        log(WARN, "failed to unlock: ", err)
    end
end


local function table_dup(ori_tab)
    if type(ori_tab) ~= "table" then
        return ori_tab
    end
    local new_tab = {}
    for k, v in pairs(ori_tab) do
        if type(v) == "table" then
            new_tab[k] = table_dup(v)
        else
            new_tab[k] = v
        end
    end
    return new_tab
end


local function update_peer_status(srv, sensibility)
    local peer_key = srv.peer_key
    local status_key = PEER_STATUS_PREFIX .. peer_key
    local status_str, err = state:get(status_key)

    if err then
        log(ERR, "get old status ", status_key, " ", err)
        return
    end

    local old_status, err
    if status_str then
        old_status, err = cjson.decode(status_str)
        if err then
            log(WARN, "decode old status error: ", err)
        end
    end

    if not old_status then
        old_status = {
            status = _M.STATUS_OK,
            fail_num = 0,
            lastmodified = localtime(),
        }
    end

    local status = srv.status
    if status == _M.STATUS_OK then
        if old_status.status ~= _M.STATUS_OK then
            old_status.lastmodified = localtime()
            old_status.status = _M.STATUS_OK
        end
        old_status.fail_num = 0
    else  -- status == _M.STATUS_ERR or _M.STATUS_UNSTABLE
        old_status.fail_num = old_status.fail_num + 1

        if old_status.status ~= status and
            old_status.fail_num >= sensibility then
            old_status.status = status
            old_status.lastmodified = localtime()
        end
    end

    for k, v in pairs(srv.statuses) do
        old_status[k] = v
    end

    local ok, err = state:set(status_key, cjson.encode(old_status))
    if not ok then
        log(ERR, "failed to set new status ", err)
    end
end


local function update_upstream_status(ups_status, sensibility)
    if not ups_status then
        return
    end

    for _, srv in ipairs(ups_status) do
        update_peer_status(srv, sensibility)
    end
end


local function check_res(res, check_opts)
    if res then
        local typ = check_opts.typ

        if typ == "http" and type(res) == "table"
            and res.status then
            local status = tonumber(res.status)
            local http_opts = check_opts.http_opts
            if http_opts and http_opts.statuses and
                http_opts.statuses[status] == false then
                return false
            end
        end
        return true
    end

    return false
end


local function _gcd(a, b)
    while b ~= 0 do
        a, b = b, a % b
    end

    return a
end


local function _gen_key(skey, srv)
    return str_format("%s:%s:%d", skey, srv.host, srv.port)
end


local function _gen_shd_key(skey)
    return str_format("%s:%s", SHD_CONFIG_PREFIX, skey)
end


local function _extract_srv_host_port(name)
    local m = re_match(name, [[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(?::([0-9]+))?]], "jo")
    if not m then
        return
    end

    local host, port = m[1], m[2] or 80
    return host, port
end


local function get_srv_status(skey, srv)
    local server_status = cluster_status[skey]
    if not server_status then
        return _M.STATUS_OK
    end

    local srv_key = str_format("%s:%d", srv.host, srv.port)
    local srv_status = server_status[srv_key]
    local fail_timeout = srv.fail_timeout or 10

    if srv_status and srv_status.lastmodify + fail_timeout > now() then
        return srv_status.status
    end

    return _M.STATUS_OK
end


local function set_srv_status(skey, srv, failed)
    local server_status = cluster_status[skey]
    if not server_status then
        server_status = {}
        cluster_status[skey] = server_status
    end

    -- The default max_fails is 0, which differs from nginx upstream module(1).
    local max_fails = srv.max_fails or 0
    local fail_timeout = srv.fail_timeout or 10
    if max_fails == 0 then  -- disables the accounting of attempts
        return
    end

    local time_now = now()
    local srv_key = str_format("%s:%d", srv.host, srv.port)
    local srv_status = server_status[srv_key]
    if not srv_status then  -- first set
        srv_status = {
            status = _M.STATUS_OK,
            failed_count = 0,
            lastmodify = time_now
        }
        server_status[srv_key] = srv_status
    elseif srv_status.lastmodify + fail_timeout < time_now then -- srv_status expired
        srv_status.status = _M.STATUS_OK
        srv_status.failed_count = 0
        srv_status.lastmodify = time_now
    end

    if failed then
        srv_status.failed_count = srv_status.failed_count + 1

        if srv_status.failed_count >= max_fails then
            local ups = upstream.checkups[skey]
            for level, cls in pairs(ups.cluster) do
                for _, s in ipairs(cls.servers) do
                    local k = str_format("%s:%d", s.host, s.port)
                    local st = server_status[k]
                    -- not the last ok server
                    if not st or st.status == _M.STATUS_OK and k ~= srv_key then
                        srv_status.status = _M.STATUS_ERR
                        return
                    end
                end
            end
        end
    end
end


function _M.calc_gcd_weight(servers)
    -- calculate the GCD, maximum weight and weight sum value from a set of servers
    local gcd, max_weight, weight_sum = 0, 0, 0

    for _, srv in ipairs(servers) do
        if not srv.weight or type(srv.weight) ~= "number" or srv.weight < 1 then
            srv.weight = 1
        end

        if not srv.effective_weight then
            srv.effective_weight = srv.weight
        end

        if srv.effective_weight > max_weight then
            max_weight = srv.effective_weight
        end

        weight_sum = weight_sum + srv.effective_weight
        gcd = _gcd(srv.effective_weight, gcd)
    end

    return gcd, max_weight, weight_sum
end


function _M.reset_round_robin_state(cls)
    local rr = { index = 0, current_weight = 0 }
    rr.gcd, rr.max_weight, rr.weight_sum = _M.calc_gcd_weight(cls.servers)
    cls.rr = rr
end


function _M.select_round_robin_server(ckey, cls, verify_server_status, bad_servers)
    -- The algo below may look messy, but is actually very simple it calculates
    -- the GCD  and subtracts it on every iteration, what interleaves endpoints
    -- and allows us not to build an iterator every time we readjust weights.
    -- https://github.com/mailgun/vulcan/blob/master/loadbalance/roundrobin/roundrobin.go
    local err_msg = "round robin: no servers available"
    local servers = cls.servers

    if type(servers) ~= "table" or not next(servers) then
        return nil, nil, "round robin: no servers in this cluster"
    end

    if type(bad_servers) ~= "table" then
        bad_servers = {}
    end

    local srvs_len = #servers
    if srvs_len == 1 then
        local srv = servers[1]
        if not verify_server_status or verify_server_status(srv, ckey) then
            if not bad_servers[1] then
                return srv, 1
            end
        end

        return nil, nil, err_msg
    end

    local rr = cls.rr
    local index, current_weight = rr.index, rr.current_weight
    local gcd, max_weight, weight_sum = rr.gcd, rr.max_weight, rr.weight_sum
    local failed_count = 1

    repeat
        index = index % srvs_len + 1
        if index == 1 then
            current_weight = current_weight - gcd
            if current_weight <= 0 then
                current_weight = max_weight
            end
        end

        local srv = servers[index]
        if srv.effective_weight >= current_weight then
            cls.rr.index, cls.rr.current_weight = index, current_weight
            if not bad_servers[index] then
                if verify_server_status then
                    if verify_server_status(srv, ckey) then
                        return srv, index
                    else
                        if srv.effective_weight > 1 then
                            srv.effective_weight = 1
                            _M.reset_round_robin_state(cls)
                            local rr = cls.rr
                            gcd, max_weight, weight_sum = rr.gcd, rr.max_weight, rr.weight_sum
                            index, current_weight, failed_count = 0, 0, 0
                        end
                        failed_count = failed_count + 1
                    end
                else
                    return srv, index
                end
            else
                failed_count = failed_count + 1
            end
        end
    until failed_count > weight_sum

    return nil, nil, err_msg
end


local function try_server(skey, ups, srv, callback, args, try)
    try = try or 1
    local peer_key = _gen_key(skey, srv)
    local peer_status = cjson.decode(state:get(PEER_STATUS_PREFIX .. peer_key))
    local res, err

    if peer_status == nil or peer_status.status ~= _M.STATUS_ERR then
        for i = 1, try, 1 do
            res, err = callback(srv.host, srv.port, unpack(args))
            if check_res(res, ups) then
                return res
            end
        end
    end

    return nil, err
end


local function hash_value(data)
    local key = 0
    local c

    data = lower(data)
    for i = 1, #data do
        c = data:byte(i)
        key = key * 31 + c
        key = key % 2^32
    end

    return key
end


local function try_cluster_consistent_hash(skey, ups, cls, callback, args, hash_key)
    local server_len = #cls.servers
    if server_len == 0 then
        return nil, true, "no server available"
    end

    local hash = hash_value(hash_key)
    local p = floor((hash % 1024) / floor(1024 / server_len)) % server_len + 1

    -- try hashed node
    local res, err = try_server(skey, ups, cls.servers[p], callback, args)
    if res then
        return res
    end

    -- try backup node
    local hash_backup_node = cls.hash_backup_node or 1
    local q = (p + hash % hash_backup_node + 1) % server_len + 1
    if p ~= q then
        local try = cls.try or #cls.servers
        res, err = try_server(skey, ups, cls.servers[q], callback, args, try - 1)
        if res then
            return res
        end
    end

    -- continue to next level
    return nil, true, err
end


local try_servers_round_robin = function(ckey, cls, verify_server_status, callback, opts)
    local try, check_res, check_opts, srv_flag, skey =
        opts.try, opts.check_res, opts.check_opts, opts.srv_flag, opts.skey
    local args = opts.args or {}

    if not check_res then
        check_res = function(res)
            if res then
                return true
            end
            return false
        end
    end

    local bad_servers = {}
    local err
    for i = 1, #cls.servers, 1 do
        local srv, index, _err = _M.select_round_robin_server(ckey, cls, verify_server_status, bad_servers)
        if not srv then
            return nil, try, _err
        else
            local res, _err
            if srv_flag then
                res, _err = callback(srv.host, srv.port, unpack(args))
            else
                res, _err = callback(srv, ckey)
            end

            if check_res(res, check_opts) then
                if srv.effective_weight ~= srv.weight then
                    srv.effective_weight = srv.weight
                    _M.reset_round_robin_state(cls)
                end
                return res
            elseif skey then
                set_srv_status(skey, srv, true)
            end

            if srv.effective_weight > 1 then
                srv.effective_weight = floor(sqrt(srv.effective_weight))
                _M.reset_round_robin_state(cls)
            end

            try = try - 1
            if try < 1 then
                return nil, nil, _err
            end

            bad_servers[index] = true
            err = _err
        end
    end

    return nil, try, err
end


local function try_cluster_round_robin(skey, ups, cls, callback, args, try_again)
    local srvs_len = #cls.servers

    local try
    if try_again then
        try = try_again
    else
        try = cls.try or srvs_len
    end

    local verify_server_status = function(srv)
        local peer_key = _gen_key(skey, srv)
        local peer_status = cjson.decode(state:get(PEER_STATUS_PREFIX .. peer_key))
        if (peer_status == nil or peer_status.status ~= _M.STATUS_ERR)
            and get_srv_status(skey, srv) == _M.STATUS_OK then
            return true
        end
        return
    end

    local opts = {
        try = try,
        check_res = check_res,
        check_opts = ups,
        srv_flag = true,
        args = args,
        skey = skey,
    }
    local res, try, err = try_servers_round_robin(nil, cls, verify_server_status, callback, opts)
    if res then
        return res
    end

    -- continue to next level
    if try and try > 0 then
        return nil, try, err
    end

    return nil, nil, err
end


function _M.try_cluster_round_robin(clusters, verify_server_status, callback, opts)
    local cluster_key = opts.cluster_key

    local err
    for _, ckey in ipairs(cluster_key) do
        local cls = clusters[ckey]
        if type(cls) == "table" and type(cls.servers) == "table" and next(cls.servers) then
            local res, _try, _err = try_servers_round_robin(ckey, cls, verify_server_status, callback, opts)
            if res then
                return res
            end

            if not _try or _try < 1 then
                return nil, _err
            end

            opts.try = _try
            err = _err
        end
    end

    return nil, err or "no servers available"
end


local function try_cluster(skey, ups, cls, callback, opts, try_again)
    local mode = ups.mode
    local args = opts.args or {}
    if mode == "hash" then
        local hash_key = opts.hash_key or ngx.var.uri
        return try_cluster_consistent_hash(skey, ups, cls, callback, args, hash_key)
    else
        return try_cluster_round_robin(skey, ups, cls, callback, args, try_again)
    end
end


function _M.ready_ok(skey, callback, opts)
    opts = opts or {}
    local ups = upstream.checkups[skey]
    if not ups then
        return nil, "unknown skey " .. skey
    end

    local res, err, cont, try_again

    -- try by key
    if opts.cluster_key then
        for _, cls_key in ipairs({ opts.cluster_key.default,
            opts.cluster_key.backup }) do
            local cls = ups.cluster[cls_key]
            if cls then
                res, cont, err = try_cluster(skey, ups, cls, callback, opts, try_again)
                if res then
                    return res, err
                end

                -- continue to next key?
                if not cont then break end

                if type(cont) == "number" then
                    if cont < 1 then
                        break
                    else
                        try_again = cont
                    end
                end
            end
        end
        return nil, err or "no upstream available"
    end

    -- try by level
    for level, cls in ipairs(ups.cluster) do
        res, cont, err = try_cluster(skey, ups, cls, callback, opts, try_again)
        if res then
            return res, err
        end

        -- continue to next level?
        if not cont then break end

        if type(cont) == "number" then
            if cont < 1 then
                break
            else
                try_again = cont
            end
        end
    end
    return nil, err or "no upstream available"
end


local heartbeat = {
    general = function (host, port, ups)
        local id = host .. ':' .. port

        local sock = tcp()
        sock:settimeout(ups.timeout * 1000)
        local ok, err = sock:connect(host, port)
        if not ok then
            log(ERR, "failed to connect: ", id, ", ", err)
            return _M.STATUS_ERR, err
        end

        sock:setkeepalive()

        return _M.STATUS_OK
    end,

    redis = function (host, port, ups)
        local id = host .. ':' .. port

        if not resty_redis then
            local ok
            ok, resty_redis = pcall(require, "resty.redis")
            if not ok then
                log(ERR, "failed to require resty.redis")
                return _M.STATUS_ERR, "failed to require resty.redis"
            end
        end

        local red, err = resty_redis:new()
        if not red then
            log(WARN, "failed to new redis: ", err)
            return _M.STATUS_ERR, err
        end

        red:set_timeout(ups.timeout * 1000)

        local redis_err = { status = _M.STATUS_ERR, replication = cjson.null }
        local ok, err = red:connect(host, port)
        if not ok then
            log(ERR, "failed to connect redis: ", id, ", ", err)
            return redis_err, err
        end

        local res, err = red:ping()
        if not res then
            log(ERR, "failed to ping redis: ", id, ", ", err)
            return redis_err, err
        end

        local replication = {}
        local statuses = {
            status = _M.STATUS_OK ,
            replication = replication
        }

        local res, got_all_info = {}, false

        local info, err = red:info("replication")
        if not info then
            info, err = red:info()
            if not info then
                replication.err = err
                return statuses
            end

            got_all_info = true
        end

        tab_insert(res, info)

        if not got_all_info then
            local info, err = red:info("server")
            if info then
                tab_insert(res, info)
            end
        end

        res = tab_concat(res)

        red:set_keepalive(10000, 100)

        local iter, err = re_gmatch(res, [[([a-zA-Z_]+):(.+?)\r\n]], "jo")
        if not iter then
            replication.err = err
            return statuses
        end

        local replication_field = {
            role                           = true,
            master_host                    = true,
            master_port                    = true,
            master_link_status             = true,
            master_link_down_since_seconds = true,
            master_last_io_seconds_ago     = true,
        }

        local other_field = {
            redis_version = true,
        }

        while true do
            local m, err = iter()
            if err then
                replication.err = err
                return statuses
            end

            if not m then
                break
            end

            if replication_field[lower(m[1])] then
                replication[m[1]] = m[2]
            end

            if other_field[lower(m[1])] then
                statuses[m[1]] = m[2]
            end
        end

        if replication.master_link_status == "down" then
            statuses.status = _M.STATUS_UNSTABLE
            statuses.msg = "master link status: down"
        end

        return statuses
    end,

    mysql = function (host, port, ups)
        local id = host .. ':' .. port

        if not resty_mysql then
            local ok
            ok, resty_mysql = pcall(require, "resty.mysql")
            if not ok then
                log(ERR, "failed to require resty.mysql")
                return _M.STATUS_ERR, "failed to require resty.mysql"
            end
        end

        local db, err = resty_mysql:new()
        if not db then
            log(WARN, "failed to new mysql: ", err)
            return _M.STATUS_ERR, err
        end

        db:set_timeout(ups.timeout * 1000)

        local ok, err, errno, sqlstate = db:connect{
            host = host,
            port = port,
            database = ups.name,
            user = ups.user,
            password = ups.pass,
            max_packet_size = 1024*1024
        }

        if not ok then
            log(ERR, "failed to connect: ", id, ", ", err, ": ", errno, " ", sqlstate)
            return _M.STATUS_ERR, err
        end

        db:set_keepalive(10000, 100)

        return _M.STATUS_OK
    end,

    http = function(host, port, ups)
        local id = host .. ':' .. port

        local sock, err = tcp()
        if not sock then
            log(WARN, "failed to create sock: ", err)
            return _M.STATUS_ERR, err
        end

        sock:settimeout(ups.timeout * 1000)
        local ok, err = sock:connect(host, port)
        if not ok then
            log(ERR, "failed to connect: ", id, ", ", err)
            return _M.STATUS_ERR, err
        end

        local opts = ups.http_opts or {}

        local req = opts.query
        if not req then
            sock:setkeepalive()
            return _M.STATUS_OK
        end

        local bytes, err = sock:send(req)
        if not bytes then
            log(ERR, "failed to send request to: ", id, ", ", err)
            return _M.STATUS_ERR, err
        end

        local readline = sock:receiveuntil("\r\n")
        local status_line, err = readline()
        if not status_line then
            log(ERR, "failed to receive status line from: ", id, ", ", err)
            return _M.STATUS_ERR, err
        end

        local statuses = opts.statuses
        if statuses then
            local from, to, err = re_find(status_line,
                [[^HTTP/\d+\.\d+\s+(\d+)]], "joi", nil, 1)
            if not from then
                log(ERR, "bad status line from: ", id, ", ", err)
                return _M.STATUS_ERR, err
            end

            local status = tonumber(str_sub(status_line, from, to))
            if statuses[status] == false then
                return _M.STATUS_ERR, "bad status code"
            end
        end

        sock:setkeepalive()

        return _M.STATUS_OK
    end,
}


local function cluster_heartbeat(skey)
    local ups = upstream.checkups[skey]
    if ups.enable == false or (ups.enable == nil and
        upstream.default_heartbeat_enable == false) then
        return
    end

    local ups_typ = ups.typ or "general"
    local ups_heartbeat = ups.heartbeat
    local ups_sensi = ups.sensibility or 1
    local ups_protected = true
    if ups.protected == false then
        ups_protected = false
    end

    ups.timeout = ups.timeout or 60

    local server_count = 0
    for level, cls in pairs(ups.cluster) do
        if cls.servers and #cls.servers > 0 then
            server_count = server_count + #cls.servers
        end
    end

    local error_count = 0
    local unstable_count = 0
    local srv_available = false
    local ups_status = {}
    for level, cls in pairs(ups.cluster) do
        for _, srv in ipairs(cls.servers) do
            local peer_key = _gen_key(skey, srv)
            local cb_heartbeat = ups_heartbeat or heartbeat[ups_typ] or
                heartbeat["general"]
            local statuses, err = cb_heartbeat(srv.host, srv.port, ups)

            local status
            if type(statuses) == "table" then
                status = statuses.status
                statuses.status = nil
            else
                status = statuses
                statuses = {}
            end

            if not statuses.msg then
                statuses.msg = err or cjson.null
            end

            local srv_status = {
                peer_key = peer_key ,
                status   = status   ,
                statuses = statuses ,
            }

            if status == _M.STATUS_OK then
                update_peer_status(srv_status, ups_sensi)
                srv_status.updated = true
                srv_available = true
                if next(ups_status) then
                    for _, v in ipairs(ups_status) do
                        if v.status == _M.STATUS_UNSTABLE then
                            v.status = _M.STATUS_ERR
                        end
                        update_peer_status(v, ups_sensi)
                    end
                    ups_status = {}
                end
            end

            if status == _M.STATUS_ERR then
                error_count = error_count + 1
                if srv_available then
                    update_peer_status(srv_status, ups_sensi)
                    srv_status.updated = true
                end
            end

            if status == _M.STATUS_UNSTABLE then
                unstable_count = unstable_count + 1
                if srv_available then
                    srv_status.status = _M.STATUS_ERR
                    update_peer_status(srv_status, ups_sensi)
                    srv_status.updated = true
                end
            end

            if srv_status.updated ~= true then
                tab_insert(ups_status, srv_status)
            end
        end
    end

    if next(ups_status) then
        if error_count == server_count then
            if ups_protected then
                ups_status[1].status = _M.STATUS_UNSTABLE
            end
        elseif error_count + unstable_count == server_count then
            tab_sort(ups_status, function(a, b) return a.status < b.status end)
        end

        update_upstream_status(ups_status, ups_sensi)
    end
end


local function active_checkup(premature)
    local ckey = CHECKUP_TIMER_KEY

    update_time() -- flush cache time

    if premature then
        local ok, err = mutex:set(ckey, nil)
        if not ok then
            log(WARN, "failed to update shm: ", err)
        end
        return
    end

    for skey in pairs(upstream.checkups) do
        cluster_heartbeat(skey)
    end

    local interval = upstream.checkup_timer_interval
    local overtime = upstream.checkup_timer_overtime

    state:set(CHECKUP_LAST_CHECK_TIME_KEY, localtime())
    state:set(CHECKUP_TIMER_ALIVE_KEY, true, overtime)

    local ok, err = mutex:set(ckey, 1, overtime)
    if not ok then
        log(WARN, "failed to update shm: ", err)
    end

    local ok, err = ngx.timer.at(interval, active_checkup)
    if not ok then
        log(WARN, "failed to create timer: ", err)
        local ok, err = mutex:set(ckey, nil)
        if not ok then
            log(WARN, "failed to update shm: ", err)
        end
        return
    end
end


local function shd_config_syncer(premature)
    local ckey = CHECKUP_TIMER_KEY .. ":shd_config:" .. worker_id()
    update_time()

    if premature then
        local ok, err = mutex:set(ckey, nil)
        if not ok then
            log(WARN, "failed to update shm: ", err)
        end
        return
    end

    local lock, err = get_lock(SKEYS_KEY)
    if not lock then
        log(WARN, "failed to acquire the lock: ", err)
        return
    end

    local config_version, err = shd_config:get(SHD_CONFIG_VERSTION_KEY)

    if config_version and config_version > upstream.shd_config_version then
        local skeys = shd_config:get(SKEYS_KEY)
        if skeys then
            skeys = cjson.decode(skeys)

            -- delete skey from upstream
            for skey, _ in pairs(upstream.checkups) do
                if not skeys[skey] then
                    upstream.checkups[skey] = nil
                end
            end

            local success = true
            for skey, _ in pairs(skeys) do
                local shd_servers, err = shd_config:get(_gen_shd_key(skey))

                log(INFO, "get ", skey, " from shm: ", shd_servers)

                if shd_servers then
                    shd_servers = cjson.decode(shd_servers)
                    -- add new skey
                    if not upstream.checkups[skey] then
                        upstream.checkups[skey] = {}
                    end

                    upstream.checkups[skey].cluster = table_dup(shd_servers)

                    local ups = upstream.checkups[skey].cluster
                    -- only reset for rr cluster
                    for level, cls in ipairs(ups) do
                        _M.reset_round_robin_state(cls)
                    end
                elseif err then
                    success = false
                    log(WARN, "failed to get from shm: ", err)
                end
            end

            if success then
                upstream.shd_config_version = config_version
            end
        end
    elseif err then
        log(WARN, "failed to get config version from shm")
    end

    release_lock(lock)

    local interval = upstream.shd_config_timer_interval
    local overtime = upstream.checkup_timer_overtime
    local ok, err = mutex:set(ckey, 1, overtime)
    if not ok then
        log(WARN, "failed to update shm: ", err)
    end

    local ok, err = ngx.timer.at(interval, shd_config_syncer)
    if not ok then
        log(WARN, "failed to create timer: ", err)
        local ok, err = mutex:set(ckey, nil)
        if not ok then
            log(WARN, "failed to update shm: ", err)
        end
        return
    end
end


local function ups_status_checker(premature)
    if premature then
        return
    end

    if not ngx_upstream then
        local ok
        ok, ngx_upstream = pcall(require, "ngx.upstream")
        if not ok then
            log(ERR, "ngx_upstream_lua module required")
            return
        end
    end

    local ups_status = {}
    local names = ngx_upstream.get_upstreams()
    -- get current upstream down status
    for _, name in ipairs(names) do
        local srvs = ngx_upstream.get_primary_peers(name)
        for _, srv in ipairs(srvs) do
            ups_status[srv.name] = srv.down and _M.STATUS_ERR or _M.STATUS_OK
        end

        srvs = ngx_upstream.get_backup_peers(name)
        for _, srv in ipairs(srvs) do
            ups_status[srv.name] = srv.down and _M.STATUS_ERR or _M.STATUS_OK
        end
    end

    for skey, ups in pairs(upstream.checkups) do
        for level, cls in pairs(ups.cluster) do
            if not cls.upstream then
                break
            end

            for _, srv in pairs(cls.servers) do
                local peer_key = _gen_key(skey, srv)
                local status_key = PEER_STATUS_PREFIX .. peer_key

                local peer_status, err = state:get(status_key)
                if peer_status then
                    local st = cjson.decode(peer_status)
                    local up_st = ups_status[srv.host .. ':' .. srv.port]
                    local unstable = st.status == _M.STATUS_UNSTABLE
                    if (unstable and up_st == _M.STATUS_ERR) or
                        (not unstable and up_st and st.status ~= up_st) then
                        local up_id = peer_id_dict[peer_key]
                        local down = up_st == _M.STATUS_OK
                        local ok, err = ngx_upstream.set_peer_down(
                            cls.upstream, up_id.backup, up_id.id, down)
                        if not ok then
                            log(ERR, "failed to set peer down", err)
                        end
                    end
                elseif err then
                    log(WARN, "get peer status error ", status_key, " ", err)
                end
            end
        end
    end

    local interval = upstream.ups_status_timer_interval
    local ok, err = ngx.timer.at(interval, ups_status_checker)
    if not ok then
        ups_status_timer_created = false
        log(WARN, "failed to create ups_status_checker: ", err)
    end
end


local function extract_servers_from_upstream(skey, cls)
    local up_key = cls.upstream
    if not up_key then
        return
    end

    cls.servers = cls.servers or {}

    if not ngx_upstream then
        local ok
        ok, ngx_upstream = pcall(require, "ngx.upstream")
        if not ok then
            log(ERR, "ngx_upstream_lua module required")
            return
        end
    end

    local ups_backup = cls.upstream_only_backup
    local srvs_getter = ngx_upstream.get_primary_peers
    if ups_backup then
        srvs_getter = ngx_upstream.get_backup_peers
    end
    local srvs, err = srvs_getter(up_key)
    if not srvs and err then
        log(ERR, "failed to get servers in upstream ", err)
        return
    end

    for _, srv in ipairs(srvs) do
        local host, port = _extract_srv_host_port(srv.name)
        if not host then
            log(ERR, "invalid server name: ", srv.name)
            return
        end
        peer_id_dict[_gen_key(skey, { host = host, port = port })] = {
            id = srv.id, backup = ups_backup and true or false}
        tab_insert(cls.servers, {
            host = host,
            port = port,
            weight = srv.weight,
            max_fails = srv.max_fails,
            fail_timeout = srv.fail_timeout,
        })
    end
end


function _M.prepare_checker(config)
    upstream.start_time = localtime()
    upstream.conf_hash = config.global.conf_hash
    upstream.checkup_timer_interval = config.global.checkup_timer_interval or 5
    upstream.checkup_timer_overtime = config.global.checkup_timer_overtime or 60
    upstream.checkups = {}
    upstream.ups_status_sync_enable = config.global.ups_status_sync_enable
    upstream.ups_status_timer_interval = config.global.ups_status_timer_interval
        or 5
    upstream.checkup_shd_sync_enable = config.global.checkup_shd_sync_enable
    upstream.shd_config_timer_interval = config.global.shd_config_timer_interval
        or upstream.checkup_timer_interval
    upstream.default_heartbeat_enable = config.global.default_heartbeat_enable

    local skeys = {}
    for skey, ups in pairs(config) do
        if type(ups) == "table" and type(ups.cluster) == "table" then
            upstream.checkups[skey] = table_dup(ups)

            for level, cls in pairs(upstream.checkups[skey].cluster) do
                extract_servers_from_upstream(skey, cls)
                _M.reset_round_robin_state(cls)
            end

            if upstream.checkup_shd_sync_enable then
                if shd_config and worker_id then
                    local phase = get_phase()
                    -- if in init_worker phase, only worker 0 can update shm
                    if phase == "init" or
                        phase == "init_worker" and worker_id() == 0 then
                        local key = _gen_shd_key(skey)
                        shd_config:set(key, cjson.encode(upstream.checkups[skey].cluster))
                    end

                    skeys[skey] = 1
                else
                    log(ERR, "checkup_shd_sync_enable is true but " ..
                        "no shd_config nor worker_id found.")
                end
            end
        end
    end

    if upstream.checkup_shd_sync_enable and
        shd_config and worker_id then
        local phase = get_phase()
        -- if in init_worker phase, only worker 0 can update shm
        if phase == "init" or phase == "init_worker" and worker_id() == 0 then
            shd_config:set(SHD_CONFIG_VERSTION_KEY, 0)
            shd_config:set(SKEYS_KEY, cjson.encode(skeys))
        end
        upstream.shd_config_version = 0
    end

    upstream.initialized = true
end


local function get_upstream_status(skey)
    local ups = upstream.checkups[skey]
    if not ups then
        return
    end

    local ups_status = {}

    for level, cls in pairs(ups.cluster) do
        local servers = cls.servers
        ups_status[level] = {}
        if servers and type(servers) == "table" and #servers > 0 then
            for _, srv in ipairs(servers) do
                local peer_key = _gen_key(skey, srv)
                local peer_status = cjson.decode(state:get(PEER_STATUS_PREFIX ..
                                                           peer_key)) or {}
                peer_status.server = peer_key
                if ups.enable == false or (ups.enable == nil and
                    upstream.default_heartbeat_enable == false) then
                    peer_status.status = "unchecked"
                else
                    if not peer_status.status or
                        peer_status.status == _M.STATUS_OK then
                        peer_status.status = "ok"
                    elseif peer_status.status == _M.STATUS_ERR then
                        peer_status.status = "err"
                    else
                        peer_status.status = "unstable"
                    end
                end
                tab_insert(ups_status[level], peer_status)
            end
        end
    end

    return ups_status
end


function _M.get_status()
    local all_status = {}
    for skey in pairs(upstream.checkups) do
        all_status["cls:" .. skey] = get_upstream_status(skey)
    end
    local last_check_time = state:get(CHECKUP_LAST_CHECK_TIME_KEY) or cjson.null
    all_status.last_check_time = last_check_time
    all_status.checkup_timer_alive = state:get(CHECKUP_TIMER_ALIVE_KEY) or false
    all_status.start_time = upstream.start_time
    all_status.conf_hash = upstream.conf_hash or cjson.null
    all_status.shd_config_version = upstream.shd_config_version or cjson.null

    return all_status
end


local function check_update_server_args(skey, level, server)
    if type(skey) ~= "string" then
        return false, "skey must be a string"
    end
    if type(level) ~= "number" and type(level) ~= "string" then
        return false, "level must be string or number"
    end
    if type(server) ~= "table" then
        return false, "server must be a table"
    end
    if not server.host or not server.port then
        return false, "no server.host nor server.port found"
    end

    return true
end


local function do_update_upstream(skey, upstream)
    local skeys = shd_config:get(SKEYS_KEY)
    if not skeys then
        return false, "no skeys found from shm"
    end

    skeys = cjson.decode(skeys)

    local new_ver, ok, err
    new_ver, err = shd_config:incr(SHD_CONFIG_VERSTION_KEY, 1)
    if err then
        log(WARN, "failed to set new version to shm")
        return false, err
    end

    local key = _gen_shd_key(skey)
    ok, err = shd_config:set(key, cjson.encode(upstream))
    if err then
        log(WARN, "failed to set new upstream to shm")
        return false, err
    end

    -- new skey
    if not skeys[skey] then
        skeys[skey] = 1
        local _, err = shd_config:set(SKEYS_KEY, cjson.encode(skeys))
        if err then
            log(WARN, "failed to set new skeys to shm")
            return false, err
        end
        log(INFO, "add new skey to upstreams, ", skey)
    end

    return true
end


function _M.update_upstream(skey, upstream)
    if not upstream or not next(upstream) then
        return false, "can not set empty upstream"
    end

    local ok, err
    for level, cls in pairs(upstream) do
        if not cls or not next(cls) then
            return false, "can not update empty level"
        end

        local servers = cls.servers
        if not servers or not next(servers) then
            return false, "can not update empty servers"
        end

        for _, srv in ipairs(servers) do
            ok, err = check_update_server_args(skey, level, srv)
            if not ok then
                return false, err
            end
        end
    end

    local lock
    lock, err = get_lock(SKEYS_KEY)
    if not lock then
        log(WARN, "failed to acquire the lock: ", err)
        return false, err
    end

    ok, err = do_update_upstream(skey, upstream)

    release_lock(lock)

    return ok, err
end


local function do_delete_upstream(skey)
    local skeys = shd_config:get(SKEYS_KEY)
    if skeys then
        skeys = cjson.decode(skeys)
    else
        return false, "upstream " .. skey .. " not found"
    end

    local key = _gen_shd_key(skey)
    local shd_servers, err = shd_config:get(key)
    if shd_servers then
        local new_ver, ok, err
        new_ver, err = shd_config:incr(SHD_CONFIG_VERSTION_KEY, 1)
        if err then
            log(WARN, "failed to set new version to shm")
            return false, err
        end

        ok, err = shd_config:delete(key)
        if err then
            log(WARN, "failed to set new servers to shm")
            return false, err
        end

        skeys[skey] = nil

        local _, err = shd_config:set(SKEYS_KEY, cjson.encode(skeys))
        if err then
            log(WARN, "failed to set new skeys to shm")
            return false, err
        end
        log(INFO, "delete skey from upstreams, ", skey)
    elseif err then
        return false, err
    else
        return false, "upstream " .. skey .. " not found"
    end

    return true
end


function _M.delete_upstream(skey)
    local lock, ok, err
    lock, err = get_lock(SKEYS_KEY)
    if not lock then
        log(WARN, "failed to acquire the lock: ", err)
        return false, err
    end

    ok, err = do_delete_upstream(skey)

    release_lock(lock)

    return ok, err
end


function _M.get_ups_timeout(skey)
    if not skey then
        return
    end

    local ups = upstream.checkups[skey]
    if not ups then
        return
    end

    local timeout = ups.timeout or 5
    return timeout, ups.send_timeout or timeout, ups.read_timeout or timeout
end


local function create_shd_config_syncer()
    local ckey = CHECKUP_TIMER_KEY .. ":shd_config:" .. worker_id()
    local val, err = mutex:get(ckey)
    if val then
        return
    end

    if err then
        log(WARN, "failed to get key from shm: ", err)
        return
    end

    local ok, err = ngx.timer.at(0, shd_config_syncer)
    if not ok then
        log(WARN, "failed to create shd_config timer: ", err)
        return
    end

    local overtime = upstream.checkup_timer_overtime
    local ok, err = mutex:set(ckey, 1, overtime)
    if not ok then
        log(WARN, "failed to update shm: ", err)
    end
end


function _M.create_checker()
    if not upstream.initialized then
        log(ERR, "create checker failed, call prepare_checker in init_by_lua")
        return
    end

    -- shd config syncer enabled
    if upstream.shd_config_version then
        create_shd_config_syncer()
    end

    local ckey = CHECKUP_TIMER_KEY
    local val, err = mutex:get(ckey)
    if val then
        return
    end

    if err then
        log(WARN, "failed to get key from shm: ", err)
        return
    end

    local lock, err = get_lock(ckey)
    if not lock then
        log(WARN, "failed to acquire the lock: ", err)
        return
    end

    val, err = mutex:get(ckey)
    if val then
        release_lock(lock)
        return
    end

    -- create active checkup timer
    local ok, err = ngx.timer.at(0, active_checkup)
    if not ok then
        log(WARN, "failed to create timer: ", err)
        release_lock(lock)
        return
    end

    if upstream.ups_status_sync_enable and not ups_status_timer_created then
        local ok, err = ngx.timer.at(0, ups_status_checker)
        if not ok then
            log(WARN, "failed to create ups_status_checker: ", err)
            release_lock(lock)
            return
        end
        ups_status_timer_created = true
    end

    local overtime = upstream.checkup_timer_overtime
    local ok, err = mutex:set(ckey, 1, overtime)
    if not ok then
        log(WARN, "failed to update shm: ", err)
    end

    release_lock(lock)
end


return _M
