%%
%%   Copyright (c) 2012 - 2013, Dmitry Kolesnikov
%%   Copyright (c) 2012 - 2013, Mario Cardona
%%   All Rights Reserved.
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
%% @description
%%   knet socket pipeline leader
%%
%% @todo
%%   make leader / client protocol to handle crash, etc. 
-module(knet_sock).
-behaviour(kfsm).

-export([
   start_link/3, 
   socket/1,
   init/1, 
   free/2,
   ioctl/2,
   'ACTIVE'/3
]).

%% internal state
-record(fsm, {
   sock   = undefined :: [pid()],  %% socket stack
   owner  = undefined :: pid(),    %% socket owner process
   mode   = undefined :: undefined | transient %% socket owner process
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Type, Owner, Opts) ->
   kfsm:start_link(?MODULE, [Type, Owner, Opts], []).

init([Type, Owner, Opts]) ->
   _ = erlang:process_flag(trap_exit, true),
   _ = erlang:monitor(process, Owner),
   Sock = init_socket(Type, Opts),
   _ = pipe:make(Sock ++ [Owner]),
   {ok, 'ACTIVE', 
      #fsm{
         sock  = Sock,
         owner = Owner,
         mode  = opts:val([transient], undefined, Opts)
      }
   }.

free(_Reason, _) ->
   ok. 

ioctl(_, _) ->
   throw(not_implemented).

%%%------------------------------------------------------------------
%%%
%%% API
%%%
%%%------------------------------------------------------------------   

%%
%% 
socket(Pid) ->
   plib:call(Pid, socket). 


%%%------------------------------------------------------------------
%%%
%%% ACTIVE
%%%
%%%------------------------------------------------------------------   

'ACTIVE'(socket, Tx, S) ->
   plib:ack(Tx, {ok, lists:last(S#fsm.sock)}),
   {next_state, 'ACTIVE', S};

'ACTIVE'({'EXIT', _Pid, normal}, _, #fsm{mode=transient}=S) ->
   % clean-up konduit stack
   free_socket(S#fsm.sock),
   erlang:exit(S#fsm.owner, shutdown),
   {stop, normal, S};

'ACTIVE'({'EXIT', _Pid, normal}, _, S) ->
   % clean-up konduit stack
   free_socket(S#fsm.sock),
   {stop, normal, S};

'ACTIVE'({'EXIT', _Pid, Reason}, _, S) ->
   % clean-up konduit stack
   free_socket(S#fsm.sock),
   erlang:exit(S#fsm.owner, Reason),
   {stop, Reason, S};

'ACTIVE'({'DOWN', _, _, _Owner, Reason}, _, S) ->
   free_socket(S#fsm.sock),
   {stop, Reason, S};

'ACTIVE'(_, _, Sock) ->
   {next_state, 'ACTIVE', Sock}.


%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%% init socket pipeline
init_socket(tcp, Opts) ->
   {ok, A} = knet_tcp:start_link(Opts),
   [A];

init_socket(http, Opts) ->
   {ok, A} = knet_tcp:start_link(Opts),
   {ok, B} = knet_http:start_link(Opts),
   [A, B];

init_socket(_, _Opts) ->
   %% TODO: implement hook for new scheme
   exit(not_implemented).

%% free socket pipeline
free_socket(Sock) ->
   lists:foreach(
      fun(X) -> knet:close(X) end,
      Sock
   ).
