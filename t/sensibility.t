# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket;
use Cwd qw(cwd);
use Test::Nginx::Socket 'no_plan';

#repeat_each(2);

workers(4);

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
            return 200;
        }
    }

    server {
        listen 12360;
        location = /status {
            return 200;
        }
    }

    init_by_lua '
        local config = require "config_api"
        local checkups = require "resty.checkups"
        config.api.sensibility = 2
        checkups.init(config)
        checkups.prepare_checker(config)
    ';

    init_worker_by_lua '
        local checkups = require "resty.checkups"
        checkups.create_checker()
    ';

};

$ENV{TEST_NGINX_CHECK_LEAK} = 1;
$ENV{TEST_NGINX_USE_HUP} = 1;
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
            ngx.sleep(1)
            local st = checkups.get_status()
            ngx.say(st["cls:api"][1][1].status)
            ngx.say(st["cls:api"][1][1].fail_num)
            ngx.say(st["cls:api"][1][2].status)
            ngx.say(st["cls:api"][1][2].fail_num)
            ngx.say(st["cls:api"][1][3].status)
            ngx.say(st["cls:api"][1][3].fail_num)
            ngx.say(st["cls:api"][1][3].msg)
            ngx.say(st["cls:api"][2][1].status)
            ngx.say(st["cls:api"][2][2].status)
            ngx.say(st["cls:api"][2][2].msg)

            ngx.sleep(2)

            st = checkups.get_status()
            ngx.say(st["cls:api"][1][1].status)
            ngx.say(st["cls:api"][1][1].fail_num)
            ngx.say(st["cls:api"][1][3].status)
            ngx.say(st["cls:api"][1][3].fail_num)
            ngx.say(st["cls:api"][1][3].msg)
        ';
    }
--- request
GET /t
--- response_body
ok
0
ok
0
ok
1
connection refused
ok
ok
connection refused
ok
0
err
2
connection refused
--- grep_error_log eval: qr/cb_heartbeat\(\): failed to connect: 127.0.0.1:\d+, connection refused/
--- grep_error_log_out
cb_heartbeat(): failed to connect: 127.0.0.1:12356, connection refused
cb_heartbeat(): failed to connect: 127.0.0.1:12361, connection refused
cb_heartbeat(): failed to connect: 127.0.0.1:12356, connection refused
cb_heartbeat(): failed to connect: 127.0.0.1:12361, connection refused
--- timeout: 10
