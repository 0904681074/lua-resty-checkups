# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket;
use Cwd qw(cwd);

#repeat_each(2);

workers(4);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_socket_log_errors off;
    lua_package_path "$pwd/../lua-resty-lock/?.lua;$pwd/lib/?.lua;$pwd/t/lib/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict state 10m;
    lua_shared_dict mutex 1m;
    lua_shared_dict locks 1m;

    server {
        listen 12354;
        location = /status {
            return 200;
        }
    }

    server {
        listen 12355;
        location = /status {
            return 404;
        }
    }

    server {
        listen 12360;
        location = /status {
            return 404;
        }
    }

    init_by_lua '
        local config = require "config_api"
        local checkups = require "resty.checkups"
        checkups.prepare_checker(config)
    ';

};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
#no_diff();
no_long_string();

run_tests();

__DATA__

=== TEST 1: get status
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_log off;
        content_by_lua '
            local checkups = require "resty.checkups"
            local cjson = require "cjson.safe"
            checkups.create_checker()
            ngx.sleep(1)
            local st = cjson.decode(checkups.get_status())
            ngx.say(st["api"].cls[1][1].status)
            ngx.say(st["api"].cls[1][2].status)
            ngx.say(st["api"].cls[1][3].status)
            ngx.say(st["api"].cls[1][3].msg)
            ngx.say(st["api"].cls[2][1].status)
            ngx.say(st["api"].cls[2][2].status)
            ngx.say(st["api"].cls[2][2].msg)
        ';
    }
--- request
GET /t
--- response_body
0
0
1
connection refused
0
1
connection refused
--- grep_error_log eval: qr/cb_heartbeat\(\): failed to connect: 127.0.0.1:\d+ connection refused/
--- grep_error_log_out
cb_heartbeat(): failed to connect: 127.0.0.1:12356 connection refused
cb_heartbeat(): failed to connect: 127.0.0.1:12361 connection refused


=== TEST 2: get status with passive
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_log off;
        content_by_lua '
            local checkups = require "resty.checkups"
            local cjson = require "cjson.safe"
            checkups.create_checker()
            ngx.sleep(1)
            local st = cjson.decode(checkups.get_status())
            ngx.say(st["api"].cls[1][1].status)
            ngx.say(st["api"].cls[1][2].status)
            ngx.say(st["api"].cls[1][3].status)
            ngx.say(st["api"].cls[1][3].msg)
            ngx.say(st["api"].cls[2][1].status)
            ngx.say(st["api"].cls[2][2].status)
            ngx.say(st["api"].cls[2][2].msg)

            local cb_err = function(host, port)
                ngx.say(host .. ":" .. port .. " " .. "ERR")
            end
            checkups.ready_ok("api", cb_err)

            local st = cjson.decode(checkups.get_status())
            ngx.say(st["api"].cls[1][1].status)
            ngx.say(st["api"].cls[1][1].msg)
        ';
    }
--- request
GET /t
--- response_body
0
0
1
connection refused
0
1
connection refused
127.0.0.1:12354 ERR
127.0.0.1:12355 ERR
0
null
--- grep_error_log eval: qr/cb_heartbeat\(\): failed to connect: 127.0.0.1:\d+ connection refused/
--- grep_error_log_out
cb_heartbeat(): failed to connect: 127.0.0.1:12356 connection refused
cb_heartbeat(): failed to connect: 127.0.0.1:12361 connection refused


=== TEST 3: clear fail counter
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_log off;
        content_by_lua '
            local checkups = require "resty.checkups"
            local cjson = require "cjson.safe"
            checkups.create_checker()
            ngx.sleep(1)

            local cb_err = function(host, port)
                ngx.say(host .. ":" .. port .. " " .. "ERR")
            end
            checkups.ready_ok("api", cb_err)

            local st = cjson.decode(checkups.get_status())
            ngx.say(st["api"].cls[1][1].status)
            ngx.say(st["api"].cls[1][1].msg)

            ngx.sleep(2)
            local st = cjson.decode(checkups.get_status())
            ngx.say(st["api"].cls[1][1].status)
            ngx.say(st["api"].cls[1][1].msg)
        ';
    }
--- request
GET /t
--- response_body
127.0.0.1:12354 ERR
127.0.0.1:12355 ERR
0
null
0
null
--- grep_error_log eval: qr/cb_heartbeat\(\): failed to connect: 127.0.0.1:\d+ connection refused/
--- grep_error_log_out
cb_heartbeat(): failed to connect: 127.0.0.1:12356 connection refused
cb_heartbeat(): failed to connect: 127.0.0.1:12361 connection refused
cb_heartbeat(): failed to connect: 127.0.0.1:12356 connection refused
cb_heartbeat(): failed to connect: 127.0.0.1:12361 connection refused
--- timeout: 10


=== TEST 4: acc fail timeout
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        access_log off;
        content_by_lua '
            local checkups = require "resty.checkups"
            local cjson = require "cjson.safe"
            checkups.create_checker()
            ngx.sleep(1)

            local cb_err = function(host, port)
                ngx.say(host .. ":" .. port .. " " .. "ERR")
            end
            checkups.ready_ok("api", cb_err)

            local st = cjson.decode(checkups.get_status())
            ngx.say(st["api"].cls[1][1].acc_fail_num)

            ngx.sleep(4)
            local st = cjson.decode(checkups.get_status())
            ngx.say(st["api"].cls[1][1].acc_fail_num)
        ';
    }
--- request
GET /t
--- response_body
127.0.0.1:12354 ERR
127.0.0.1:12355 ERR
1
0
--- grep_error_log eval: qr/cb_heartbeat\(\): failed to connect: 127.0.0.1:\d+ connection refused|max acc fails reached 127.0.0.1:\d+/
--- grep_error_log_out
cb_heartbeat(): failed to connect: 127.0.0.1:12356 connection refused
cb_heartbeat(): failed to connect: 127.0.0.1:12361 connection refused
max acc fails reached 127.0.0.1:12354
max acc fails reached 127.0.0.1:12355
cb_heartbeat(): failed to connect: 127.0.0.1:12356 connection refused
cb_heartbeat(): failed to connect: 127.0.0.1:12361 connection refused
cb_heartbeat(): failed to connect: 127.0.0.1:12356 connection refused
cb_heartbeat(): failed to connect: 127.0.0.1:12361 connection refused
--- timeout: 10
