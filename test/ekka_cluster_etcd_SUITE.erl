%%--------------------------------------------------------------------
%% Copyright (c) 2019 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(ekka_cluster_etcd_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(ETCD_PORT, 2379).
-define(OPTIONS, [{server, ["http://127.0.0.1:" ++ integer_to_list(?ETCD_PORT)]},
                  {prefix, "emqxcl"},
                  {version, v2},
                  {node_ttl, 60}
                 ]).

all() -> ekka_ct:all(?MODULE).

init_per_testcase(t_restart_process, Config) ->
    snabbkaffe:fix_ct_logging(),
    ETCDHost = os:getenv("ETCD_HOST", "localhost"),
    io:format(user, ">>>>>>>>> ~p~n", [ETCDHost]),
    case ekka_ct:is_tcp_server_available(ETCDHost, ?ETCD_PORT) of
        true ->
            ct:pal("etcd running at ~p:~w", [ETCDHost, ?ETCD_PORT]),
            application:ensure_all_started(eetcd),
            [{etcd_host, ETCDHost} | Config];
        false ->
            ct:pal("etcd not running at ~p:~w", [ETCDHost, ?ETCD_PORT]),
            {skip, no_etcd}
    end;
init_per_testcase(_TestCase, Config) ->
    ok = meck:new(httpc, [non_strict, passthrough, no_history]),
    Config.

end_per_testcase(t_restart_process, _Config) ->
    application:stop(eetcd);
end_per_testcase(TestCase, _Config) ->
    ok = meck:unload(httpc),
    ekka_ct:cleanup(TestCase).

t_discover(_Config) ->
    Json = <<"{\"node\": {\"nodes\": [{\"key\": \"ekkacl/n1@127.0.0.1\"}]}}">>,
    ok = meck:expect(httpc, request, fun(get, _Req, _Opts, _) -> {ok, 200, Json} end),
    {ok, ['n1@127.0.0.1']} = ekka_cluster_etcd:discover(?OPTIONS).

t_lock(_Config) ->
    ok = meck:expect(httpc, request, fun(put, _Req, _Opts, _) ->
                                             {ok, 200, <<"{\"errorCode\": 0}">>}
                                     end),
    ok = ekka_cluster_etcd:lock(?OPTIONS).

t_unlock(_) ->
    ok = meck:expect(httpc, request, fun(delete, _Req, _Opts, _) ->
                                             {ok, 200, <<"{\"errorCode\": 0}">>}
                                     end),
    ok = ekka_cluster_etcd:unlock(?OPTIONS).

t_register(_) ->
    ok = meck:new(ekka_cluster_sup, [non_strict, passthrough, no_history]),
    ok = meck:expect(ekka_cluster_sup, start_child, fun(_, _) -> {ok, self()} end),
    ok = meck:expect(httpc, request, fun(put, _Req, _Opts, _) ->
                                             {ok, 200, <<"{\"errorCode\": 0}">>}
                                     end),
    ok = ekka_cluster_etcd:register(?OPTIONS),
    ok = meck:unload(ekka_cluster_sup).

t_unregister(_) ->
    ok = meck:expect(httpc, request, fun(delete, _Req, _Opts, _) ->
                                             {ok, 200, <<"{\"errorCode\": 0}">>}
                                     end),
    ok = meck:expect(ekka_cluster_sup, stop_child, fun(_) -> ok end),
    ok = ekka_cluster_etcd:unregister(?OPTIONS),
    ok = meck:unload(ekka_cluster_sup).

t_etcd_set_node_key(_) ->
    ok = meck:expect(httpc, request, fun(put, _Req, _Opts, _) ->
                                             {ok, 200, <<"{\"errorCode\": 0}">>}
                                     end),
    {ok, #{<<"errorCode">> := 0}} = ekka_cluster_etcd:etcd_set_node_key(?OPTIONS).

t_restart_process(Config) ->
    ETCDHost = ?config(etcd_host, Config),
    Options1 = lists:keyreplace(version, 1, ?OPTIONS, {version, v3}),
    Options = lists:keyreplace(server, 1, Options1,
                               {server, ["http://" ++ ETCDHost ++ ":"
                                         ++ integer_to_list(?ETCD_PORT)]}),
    Node = ekka_ct:start_slave(ekka, n1, [{ekka, cluster_discovery, {etcd, Options}}]),
    try
        ok = ekka_ct:wait_running(Node),
        Pid = erpc:call(Node, erlang, whereis, [ekka_cluster_etcd]),
        SupPid = erpc:call(Node, erlang, whereis, [ekka_sup]),
        Ref = monitor(process, Pid),
        SupRef = monitor(process, SupPid),
        exit(Pid, kill),
        receive
            {'DOWN', Ref, process, Pid, _} ->
                ok
        after
            200 -> exit(proc_not_killed)
        end,
        receive
            {'DOWN', SupRef, process, SupPid, _} ->
                exit(supervisor_died)
        after
            200 -> ok
        end,
        ok = ekka_ct:wait_running(Node, 2_000),
        ok
    after
        ok = ekka_ct:stop_slave(Node)
    end,
    ok.
