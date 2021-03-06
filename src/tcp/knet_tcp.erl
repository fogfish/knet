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
%%   tcp/ip protocol konduit
-module(knet_tcp).
-behaviour(pipe).
-compile({parse_transform, category}).

-include("knet.hrl").

-export([
   start_link/1, 
   init/1, 
   free/2, 
   ioctl/2,
   'IDLE'/3, 
   'LISTEN'/3, 
   'ESTABLISHED'/3,
   'HIBERNATE'/3
]).

%%
%% internal state
-record(state, {
   socket   = undefined :: #socket{}
  ,flowctl  = true      :: once | true | integer()  %% flow control strategy
  ,so       = undefined :: knet:opts()
}).

%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   pipe:start_link(?MODULE, maps:merge(?SO_TCP, Opts), []).

%%
init(SOpt) ->
   [either ||
      knet_gen_tcp:socket(SOpt),
      cats:unit('IDLE',
         #state{
            socket  = _
           ,flowctl = lens:get(lens:at(active), SOpt)
           ,so      = SOpt
         }
      )
   ].

%%
free(_Reason, _State) ->
   ok.

%% 
ioctl(socket, #state{socket = Sock}) -> 
   Sock.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%   This is the default state that each connection starts in before 
%%%   the process of establishing it begins. This state is fictional.
%%%   It represents the situation where there is no connection between
%%%   peers either hasn't been created yet, or has just been destroyed.
%%%
%%%------------------------------------------------------------------   

%%
%%
'IDLE'({connect, Uri}, Pipe, #state{} = State0) ->
   case 
      [either ||
         connect(Uri, State0),
         time_to_live(_),
         time_to_hibernate(_),
         time_to_packet(0, _),
         pipe_to_side_a(Pipe, established, _),
         config_flow_ctrl(_)
      ]
   of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         error_to_side_a(Pipe, Reason, State0),
         {next_state, 'IDLE', State0}
   end;

%%
%%
'IDLE'({listen, Uri}, Pipe, #state{} = State0) ->
   case
      [either ||
         listen(Uri, State0),
         spawn_acceptor_pool(Uri, _),
         pipe_to_side_b(Pipe, listen, _)
      ]
   of
      {ok, State1} ->
         {next_state, 'LISTEN', State1};
      {error, Reason} ->
         error_to_side_b(Pipe, Reason, State0),
         {next_state, 'IDLE', State0}
   end;

%%
%%
'IDLE'({accept, Uri}, Pipe, #state{} = State0) ->
   case
      [either ||
         accept(Uri, State0),
         spawn_acceptor(Uri, _),
         time_to_live(_),
         time_to_hibernate(_),
         time_to_packet(0, _),
         pipe_to_side_b(Pipe, established, _),
         config_flow_ctrl(_)
      ]
   of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, closed} ->
         {stop, normal, State0};
      {error, enoent} ->
         error_to_side_b(Pipe, enoent, State0),
         {stop, normal, State0};
      {error, Reason} ->
         spawn_acceptor(Uri, State0),
         error_to_side_b(Pipe, Reason, State0),
         {stop, Reason, State0}
   end;

'IDLE'({sidedown, a, _}, _, State) ->
   {stop, normal, State};

'IDLE'(tth, _, State) ->
   {next_state, 'IDLE', State};

'IDLE'(ttl, _, State) ->
   {next_state, 'IDLE', State};

'IDLE'({ttp, _}, _, State) ->
   {next_state, 'IDLE', State};

'IDLE'({packet, _}, _, State) ->
   {reply, {error, ecomm}, 'IDLE', State}.


%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%   A peer is waiting to receive a connection request (syn)
%%%
%%%------------------------------------------------------------------   

'LISTEN'(_Msg, _Pipe, State) ->
   {next_state, 'LISTEN', State}.


%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%   The steady state of an open TCP connection. Peers can exchange 
%%%   data. It will continue until the connection is closed for one 
%%%   reason or another.
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({sidedown, a, _}, _Pipe, State0) ->
   {stop, normal, State0};

'ESTABLISHED'({tcp_error, _, Reason}, Pipe, #state{} = State0) ->
   case
      [either ||
         close(Reason, State0),
         error_to_side_b(Pipe, Reason, _)
      ]
   of
      {ok, State1} -> 
         {next_state, 'IDLE', State1};
      {error, Reason} -> 
         {stop, Reason, State0}
   end;

'ESTABLISHED'({tcp_closed, Port}, Pipe, #state{} = State) ->
   'ESTABLISHED'({tcp_error, Port, normal}, Pipe, State);

%%
%%
'ESTABLISHED'({tcp_passive, Port}, Pipe, #state{} = State0) ->
   case stream_flow_ctrl(Pipe, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({tcp_error, Port, Reason}, Pipe, State0)
   end;

'ESTABLISHED'({active, N}, Pipe, #state{} = State0) ->
   case config_flow_ctrl(State0#state{flowctl = N}) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({tcp_error, undefined, Reason}, Pipe, State0)
   end;

%%
%%
'ESTABLISHED'({tcp, Port, Pckt}, Pipe, #state{} = State0) ->
   case stream_recv(Pipe, Pckt, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({tcp_error, Port, Reason}, Pipe, State0)
   end;


'ESTABLISHED'({ttp, Pack}, Pipe, #state{} = State0) ->
   case time_to_packet(Pack, State0) of
      {ok, State1} ->
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         'ESTABLISHED'({tcp_error, undefined, Reason}, Pipe, State0)
   end;

'ESTABLISHED'(tth, _, State) ->
   {next_state, 'HIBERNATE', State, hibernate};

'ESTABLISHED'(ttl, Pipe, State) ->
   'ESTABLISHED'({tcp_error, undefined, normal}, Pipe, State);

'ESTABLISHED'({packet, Pckt}, Pipe, #state{} = State0) ->
   case stream_send(Pipe, Pckt, State0) of
      {ok, State1} ->
         pipe:ack(Pipe, ok),
         {next_state, 'ESTABLISHED', State1};
      {error, Reason} ->
         pipe:ack(Pipe, {error, Reason}),
         'ESTABLISHED'({tcp_error, undefined, Reason}, Pipe, State0)
   end.

%%%------------------------------------------------------------------
%%%
%%% HIBERNATE
%%%
%%%------------------------------------------------------------------   

'HIBERNATE'(Msg, Pipe, #state{} = State0) ->
   % ?DEBUG("knet [tcp]: resume ~p",[Stream#stream.peer]),
   {ok, State1} = time_to_hibernate(State0),
   'ESTABLISHED'(Msg, Pipe, State1).

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% 
connect(Uri, #state{socket = Sock} = State) ->
   T = os:timestamp(),
   [either ||
      Socket <- knet_gen_tcp:connect(Uri, Sock),
      knet_gen:trace(connect, tempus:diff(T), Socket),
      cats:unit(State#state{socket = Socket})
   ].

listen(Uri, #state{socket = Sock} = State) ->
   [either ||
      Socket <- knet_gen_tcp:listen(Uri, Sock),
      cats:unit(State#state{socket = Socket})
   ].

accept(Uri, #state{so = #{listen := LSock}} = State) ->
   T    = os:timestamp(),
   %% Note: this is a design decision to inject listen socket pid via socket options
   Sock = pipe:ioctl(LSock, socket),
   [either ||
      Socket <- knet_gen_tcp:accept(Uri, Sock),
      knet_gen:trace(connect, tempus:diff(T), Socket),
      cats:unit(State#state{socket = Socket})
   ].

close(_Reason, #state{socket = Sock} = State) ->
   [either ||
      knet_gen_tcp:close(Sock),
      cats:unit(State#state{socket = _})
   ].

%%
%% socket timeout
time_to_live(#state{so = SOpt} = State) ->
   [option || 
      lens:get(lens:c(lens:at(timeout, #{}), lens:at(ttl)), SOpt), 
      tempus:timer(_, ttl)
   ],
   {ok, State}.

time_to_hibernate(#state{so = SOpt} = State) ->
   [option ||
      lens:get(lens:c(lens:at(timeout, #{}), lens:at(tth)), SOpt), 
      tempus:timer(_, tth)
   ],
   {ok, State}.

time_to_packet(N, #state{socket = Sock, so = SOpt} = State) ->
   case knet_gen_tcp:getstat(Sock, packet) of
      X when X > N orelse N =:= 0 ->
         [option ||
            lens:get(lens:c(lens:at(timeout, #{}), lens:at(ttp)), SOpt), 
            tempus:timer(_, {ttp, X})
         ],
         {ok, State};
      _ ->
         {error, timeout}
   end.

%%
%%
config_flow_ctrl(#state{flowctl = true, socket = Sock} = State) ->
   knet_gen_tcp:setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
   {ok, State};
config_flow_ctrl(#state{flowctl = once, socket = Sock} = State) ->
   knet_gen_tcp:setopts(Sock, [{active, once}]),
   {ok, State};
config_flow_ctrl(#state{flowctl = N, socket = Sock} = State) ->
   knet_gen_tcp:setopts(Sock, [{active, N}]),
   {ok, State#state{flowctl = N}}.

%%
%% socket up/down link i/o
stream_flow_ctrl(_Pipe, #state{flowctl = true, socket = Sock} = State) ->
   % ?DEBUG("[tcp] flow control = ~p", [true]),
   %% we need to ignore any error for i/o setup, otherwise
   %% it will crash the process while data reside in mailbox
   knet_gen_tcp:setopts(Sock, [{active, ?CONFIG_IO_CREDIT}]),
   {ok, State};
stream_flow_ctrl(Pipe, #state{flowctl = once} = State) ->
   % ?DEBUG("[tcp] flow control = ~p", [once]),
   %% do nothing, client must send flow control message 
   pipe:b(Pipe, {tcp, self(), passive}),
   {ok, State};
stream_flow_ctrl(Pipe, #state{flowctl = _N} = State) ->
   % ?DEBUG("[tcp] flow control = ~p", [_N]),
   %% do nothing, client must send flow control message
   pipe:b(Pipe, {tcp, self(), passive}),
   {ok, State}.

%%
%%
pipe_to_side_a(Pipe, Event, #state{socket = Sock} = State) ->
   [either ||
      knet_gen_tcp:peername(Sock),
      cats:unit(pipe:a(Pipe, {tcp, self(), {Event, _}})),
      cats:unit(State)
   ].

pipe_to_side_b({pipe, _, undefined} = Pipe, Event, State) ->
   % this is required when pipe has single side
   pipe_to_side_a(Pipe, Event, State);
pipe_to_side_b(Pipe, Event, #state{socket = Sock} = State) ->
   [either ||
      knet_gen_tcp:peername(Sock),
      cats:unit(pipe:b(Pipe, {tcp, self(), {Event, _}})),
      cats:unit(State)
   ].


%%
%%
error_to_side_a(Pipe, normal, #state{} = State) ->
   pipe:a(Pipe, {tcp, self(), eof}),
   {ok, State};
error_to_side_a(Pipe, Reason, #state{} = State) ->
   pipe:a(Pipe, {tcp, self(), {error, Reason}}),
   {ok, State}.

error_to_side_b({pipe, _, undefined} = Pipe, Reason, State) ->
   % this is required when pipe has single side
   error_to_side_a(Pipe, Reason, State);
error_to_side_b(Pipe, normal, #state{} = State) ->
   pipe:b(Pipe, {tcp, self(), eof}),
   {ok, State};
error_to_side_b(Pipe, Reason, #state{} = State) ->
   pipe:b(Pipe, {tcp, self(), {error, Reason}}),
   {ok, State}.


%%
stream_send(_Pipe, Pckt, #state{socket = Sock} = State) ->
   [either ||
      knet_gen_tcp:send(Sock, Pckt),
      cats:unit(State#state{socket = _})
   ].

%%
stream_recv(Pipe, Pckt, #state{socket = Sock} = State) ->
   [either ||
      knet_gen:trace(packet, byte_size(Pckt), Sock),
      knet_gen_tcp:recv(Sock, Pckt),
      stream_uplink(Pipe, _, _),
      cats:unit(State#state{socket = _})
   ].

stream_uplink(Pipe, Pckt, Socket) ->
   lists:foreach(fun(X) -> pipe:b(Pipe, {tcp, self(), X}) end, Pckt),
   {ok, Socket}.

%%
%%
spawn_acceptor(Uri, #state{so = #{acceptor := Sup} = SOpt} = State) ->
   {ok, _} = supervisor:start_child(Sup, [Uri, SOpt]),
   {ok, State}.

spawn_acceptor_pool(Uri, #state{so = #{acceptor := Sup} = SOpt} = State) ->
   Opts = SOpt#{listen => self()},
   lists:foreach(
      fun(_) ->
         {ok, _} = supervisor:start_child(Sup, [Uri, Opts])
      end,
      lists:seq(1, lens:get(lens:at(backlog, 5), SOpt))
   ),
   {ok, State}.


