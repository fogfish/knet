%%
%%   Copyright 2012 Dmitry Kolesnikov, All Rights Reserved
%%   Copyright 2012 Mario Cardona, All Rights Reserved
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%       http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%
%%  @description
%%     
%%
-module(knet_ssl_tests).
%%-include_lib("eunit/include/eunit.hrl").

-define(PORT, 8443). %%
-define(DATA, <<"0123456789abcdef">>).
-define(SRV_OPTS, [
   {certfile, "../test/cert.pem"},
   {keyfile,  "../test/key.pem"}
]).
-define(CLI_OPTS, [
    {ciphers, [{rsa, rc4_128, sha}]}
]).

%%
%% tcp/ip loop
loop(init, []) -> 
   {ok, undefined};
loop({ssl, Peer, {recv, Data}}, S) ->
   {stop, normal, {send, Peer, Data}, S};
loop(_, S) ->
   {next_state, loop, S}.

%%
%% spawn tcp/ip server
tcp_srv(Addr) ->
   ssl:start(),
   knet:start(),
   %lager:set_loglevel(lager_console_backend, debug),
   % start listener konduit
   {ok, _} = case pns:whereis(knet, {ssl4, listen, Addr}) of
      undefined ->
         konduit:start_link({fabric, nil, nil, [
            {knet_ssl, [inet, {{listen, ?SRV_OPTS}, Addr}]}
         ]});   
      Pid -> 
         {ok, Pid}
   end,
   % start acceptor
   {ok, _} = konduit:start_link({fabric, nil, nil, [
      {knet_ssl,   [inet, {{accept, []}, Addr}]},
      {fun loop/2, []}
   ]}).

%%
%%
server_fsm_test() ->
   tcp_srv({any, ?PORT}),
   % start client-side test 
   {ok, Sock} = ssl:connect(
   	{127,0,0,1}, 
   	?PORT, 
   	[binary, {active, false} | ?CLI_OPTS]
   ),
   ok = ssl:send(Sock, ?DATA),
   {ok, ?DATA} = ssl:recv(Sock, 0),
   ssl:close(Sock).


client_fsm_test() ->
   tcp_srv({any, ?PORT}),
   Peer = {{127,0,0,1}, ?PORT},
   {ok, Pid} = konduit:start_link({fabric, nil, self(), [
      {knet_ssl, [inet, {{connect, ?CLI_OPTS}, Peer}]}
   ]}),
   {ssl, Peer, established} = konduit:recv(Pid),
   konduit:send(Pid, {send, Peer, ?DATA}),
   {ssl, Peer, {recv, ?DATA}} = konduit:recv(Pid),
   {ok, Stat} = konduit:ioctl(iostat, knet_ssl, Pid),
   {tcp,  _} = lists:keyfind(tcp,  1, Stat),
   {ssl,  _} = lists:keyfind(ssl,  1, Stat),
   {recv, _} = lists:keyfind(recv, 1, Stat),
   {send, _} = lists:keyfind(send, 1, Stat),
   {ttrx, _} = lists:keyfind(ttrx, 1, Stat),
   {ttwx, _} = lists:keyfind(ttwx, 1, Stat),
   {ssl, Peer, terminated} = konduit:recv(Pid),
   ok.


