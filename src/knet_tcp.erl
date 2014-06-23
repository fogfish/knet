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
%%   client-server tcp/ip konduit
%%
%% @todo
%%   * bind to interface / address
%%   * send stats signal (before data (clean up stats handling))
-module(knet_tcp).
-behaviour(pipe).

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

%% internal state
-record(fsm, {
   stream = undefined :: #stream{}  %% tcp packet stream
  ,sock   = undefined :: port()     %% tcp/ip socket
  ,active = true      :: once | true | false  %% socket activity (pipe internally uses active once)
  ,pool   = 0         :: integer()  %% socket acceptor pool size
  ,trace  = undefined :: pid()      %% trace / debug / stats functor 
  ,so     = undefined :: any()      %% socket options


  % ,peer = undefined :: any()    %% peer address  
  % ,addr = undefined :: any()    %% local address

  % ,so          = [] :: [any()]                 %% socket options
  % ,timeout     = [] :: [{atom(), timeout()}]   %% socket timeouts 
  % ,session     = undefined   :: tempus:t()     %% session start time-stamp
  % ,t_hibernate = undefined   :: tempus:timer() %% socket hibernate timeout
  % % ,t_io        = undefined   :: temput:timer() %% socket i/o timeout

  % ,trace       = undefined :: pid()          %% latency trace process

  %  %% data streams
  % ,recv        = undefined :: any()          %% recv data stream
  % ,send        = undefined :: any()          %% send data stream

}).

%% iolist guard
-define(is_iolist(X),   is_binary(X) orelse is_list(X)).


%%%------------------------------------------------------------------
%%%
%%% Factory
%%%
%%%------------------------------------------------------------------   

start_link(Opts) ->
   pipe:start_link(?MODULE, Opts ++ ?SO_TCP, []).

%%
init(Opts) ->
   % Stream  = opts:val(stream, raw, Opts),
   % Timeout = opts:val(timeout, [], Opts), %% @todo: take timeout opts 
   {ok, 'IDLE',
      #fsm{
         stream  = io_new(Opts)
        ,pool    = opts:val(pool, 0, Opts)
        ,trace   = opts:val(trace, undefined, Opts)
        ,active  = opts:val(active, Opts)
        ,so      = Opts
        % 
        %
        % ,timeout = Timeout
        % ,t_hibernate = opts:val(hibernate, undefined, Timeout)
        % % ,t_io        = opts:val(io,        undefined, Timeout) 
        % ,trace   = opts:val(trace, undefined, Opts)
        % ,recv    = knet_stream:new(Stream)
        % ,send    = knet_stream:new(Stream)        
      }
   }.

%%
free(Reason, State) ->
   io_log(fin, Reason, State#fsm.stream),
   (catch gen_tcp:close(State#fsm.sock)),
   ok. 

%% 
ioctl(socket,   S) -> 
   S#fsm.sock.

%%%------------------------------------------------------------------
%%%
%%% IDLE
%%%
%%%------------------------------------------------------------------   

%%
%%
'IDLE'({listen, Uri}, Pipe, S) ->
   Port = uri:port(Uri),
   ok   = pns:register(knet, {tcp, {any, Port}}, self()),
   % socket opts for listener socket requires {active, false}
   SOpt = opts:filter(?SO_TCP_ALLOWED, S#fsm.so),
   Opts = [{active, false}, {reuseaddr, true} | lists:keydelete(active, 1, SOpt)],
   case gen_tcp:listen(Port, Opts) of
      {ok, Sock} -> 
         ?access_log(#log{prot=tcp, dst=Uri, req=listen}),
         _ = pipe:a(Pipe, {tcp, {any, Port}, listen}),
         %% create acceptor pool
         Sup = knet:whereis(acceptor, Uri),
         ok  = lists:foreach(
            fun(_) ->
               {ok, _} = supervisor:start_child(Sup, [Uri])
            end,
            lists:seq(1, S#fsm.pool)
         ),
         {next_state, 'LISTEN', S#fsm{sock = Sock}};
      {error, Reason} ->
         ?access_log(#log{prot=tcp, dst=Uri, req=listen, rsp=Reason}),
         pipe:a(Pipe, {tcp, {any, Port}, {terminated, Reason}}),
         {stop, Reason, S}
   end;

%%
%%
'IDLE'({connect, Uri}, Pipe, State) ->
   Host = scalar:c(uri:get(host, Uri)),
   Port = uri:get(port, Uri),
   SOpt = opts:filter(?SO_TCP_ALLOWED, State#fsm.so),
   Tout = pair:lookup([timeout, peer], ?SO_TIMEOUT, State#fsm.so),
   T    = os:timestamp(),
   case gen_tcp:connect(Host, Port, SOpt, Tout) of
      {ok, Sock} ->
         {ok, Peer} = inet:peername(Sock),
         Stream = io_ttl(io_tth(io_connect(T, Sock, State#fsm.stream))),
         pipe:a(Pipe, {tcp, self(), {established, Peer}}),
         knet:trace(State#fsm.trace, {tcp, connect, tempus:diff(T)}),
         {next_state, 'ESTABLISHED', tcp_ioctl(State#fsm{stream=Stream, sock=Sock})};

      {error, Reason} ->
         ?access_log(#log{prot=tcp, dst=Uri, req=syn, rsp=Reason}),
         pipe:a(Pipe, {tcp, {Host, Port}, {terminated, Reason}}),
         {stop, Reason, State}
   end;


%%
'IDLE'({accept, Uri}, Pipe, State) ->
   Port  = uri:get(port, Uri),
   LSock = pipe:ioctl(pns:whereis(knet, {tcp, {any, Port}}), socket),
   T     = os:timestamp(),   
   case gen_tcp:accept(LSock) of
      %% connection is accepted
      {ok, Sock} ->
         {ok,    _} = supervisor:start_child(knet:whereis(acceptor, Uri), [Uri]),
         {ok, Peer} = inet:peername(Sock),
         Stream = io_ttl(io_tth(io_connect(T, Sock, State#fsm.stream))),
         pipe:a(Pipe, {tcp, self(), {established, Peer}}),
         knet:trace(State#fsm.trace, {tcp, connect, tempus:diff(T)}),
         {next_state, 'ESTABLISHED', tcp_ioctl(State#fsm{stream=Stream, sock=Sock})};

      %% listen socket is closed
      {error, closed} ->
         {stop, normal, State};

      %% unable to accept connection  
      {error, Reason} ->
         {ok, _} = supervisor:start_child(knet:whereis(acceptor, Uri), [Uri]),
         Stream  = io_log(syn, Reason, State#fsm.stream),
         pipe:a(Pipe, {tcp, self(), {terminated, Reason}}),      
         {stop, Reason, State#fsm{stream=Stream}}
   end;

%%
'IDLE'(shutdown, _Pipe, S) ->
   {stop, normal, S}.


%%%------------------------------------------------------------------
%%%
%%% LISTEN
%%%
%%%------------------------------------------------------------------   

'LISTEN'(shutdown, _Pipe, S) ->
   {stop, normal, S};

'LISTEN'(_Msg, _Pipe, S) ->
   {next_state, 'LISTEN', S}.


%%%------------------------------------------------------------------
%%%
%%% ESTABLISHED
%%%
%%%------------------------------------------------------------------   

'ESTABLISHED'({tcp_error, _, Reason}, Pipe, State) ->
   pipe:b(Pipe, {tcp, self(), {terminated, Reason}}),   
   {stop, Reason, State};
   
'ESTABLISHED'({tcp_closed, _}, Pipe, State) ->
   pipe:b(Pipe, {tcp, self(), {terminated, normal}}),
   {stop, normal, State};

'ESTABLISHED'({tcp, _, Pckt}, Pipe, State) ->
   %% What one can do is to combine {active, once} with gen_tcp:recv().
   %% Essentially, you will be served the first message, then read as many as you 
   %% wish from the socket. When the socket is empty, you can again enable 
   %% {active, once}.
   %% TODO: flexible flow control + explicit read
   {_, Stream} = io_recv(Pckt, Pipe, State#fsm.stream),
   knet:trace(State#fsm.trace, {tcp, packet, byte_size(Pckt)}),
   {next_state, 'ESTABLISHED', tcp_ioctl(State#fsm{stream=Stream})};

'ESTABLISHED'(shutdown, _Pipe, State) ->
   % pipe:b(Pipe, {tcp, self(), {terminated, normal}}),
   {stop, normal, State};

'ESTABLISHED'({ttl, Pack}, Pipe, State) ->
   case io_ttl(Pack, State#fsm.stream) of
      {eof, Stream} ->
         pipe:b(Pipe, {tcp, self(), {terminated, timeout}}),
         {stop, normal, State#fsm{stream=Stream}};
      {_,   Stream} ->
         {next_state, 'ESTABLISHED', State#fsm{stream=Stream}}
   end;

'ESTABLISHED'(hibernate, _, #fsm{stream=Sock}=State) ->
   ?DEBUG("knet [tcp]: suspend ~p", [Sock#stream.peer]),
   {next_state, 'HIBERNATE', State, hibernate};

'ESTABLISHED'(Msg, Pipe, State)
 when ?is_iolist(Msg) ->
   try
      {_, Stream} = io_send(Msg, State#fsm.sock, State#fsm.stream),
      {next_state, 'ESTABLISHED', State#fsm{stream=Stream}}
   catch _:{badmatch, {error, Reason}} ->
      pipe:b(Pipe, {tcp, self(), {terminated, Reason}}),
      {stop, Reason, State}
   end.

%%%------------------------------------------------------------------
%%%
%%% HIBERNATE
%%%
%%%------------------------------------------------------------------   

'HIBERNATE'(Msg, Pipe, State) ->
   ?DEBUG("knet [tcp]: resume ~p", [Sock#stream.peer]),
   'ESTABLISHED'(Msg, Pipe, State#fsm{stream=io_tth(State#fsm.stream)}).

%%%------------------------------------------------------------------
%%%
%%% private
%%%
%%%------------------------------------------------------------------   

%%
%% new socket stream
io_new(SOpt) ->
   #stream{
      send = pstream:new(opts:val(stream, raw, SOpt))
     ,recv = pstream:new(opts:val(stream, raw, SOpt))
     ,ttl  = pair:lookup([timeout, ttl], ?SO_TTL, SOpt)
     ,tth  = pair:lookup([timeout, tth], ?SO_TTH, SOpt)
     ,ts   = os:timestamp()
   }.

%%
%% set stream address(es)
io_connect(T, Port, #stream{}=Sock) ->
   {ok, Peer} = inet:peername(Port),
   {ok, Addr} = inet:sockname(Port),
   io_log(syn, sack, T,  Sock#stream{peer = Peer, addr = Addr, tss = os:timestamp(), ts = os:timestamp()}).

%%
%% log stream event
io_log(Req, Reason, #stream{}=Sock) ->
   io_log(Req, Reason, Sock#stream.ts, Sock).

io_log(Req, Reason, T, #stream{}=Sock) ->
   Pack = knet_stream:packets(Sock#stream.recv) + knet_stream:packets(Sock#stream.send),
   Byte = knet_stream:octets(Sock#stream.recv)  + knet_stream:octets(Sock#stream.send),
   ?access_log(#log{prot=tcp, src=Sock#stream.peer, dst=Sock#stream.addr, req=Req, rsp=Reason, 
                    byte=Byte, pack=Pack, time=tempus:diff(T)}),
   Sock.

%%
%% set hibernate timeout
io_tth(#stream{}=Sock) ->
   Sock#stream{
      tth = tempus:timer(Sock#stream.tth, hibernate)
   }.

%%
%% set time-to-live timeout
io_ttl(#stream{}=Sock) ->
   erlang:element(2, io_ttl(-1, Sock)). 

io_ttl(N, #stream{}=Sock) ->
   case knet_stream:packets(Sock#stream.recv) + knet_stream:packets(Sock#stream.send) of
      %% stream activity
      X when X > N ->
         {active, Sock#stream{ttl = tempus:timer(Sock#stream.ttl, {ttl, X})}};
      %% no stream activity
      _ ->
         {eof, Sock}
   end.

%%
%% recv packet
io_recv(Pckt, Pipe, #stream{}=Sock) ->
   ?DEBUG("knet [tcp] ~p: recv ~p~n~p", [self(), Sock#stream.peer, Pckt]),
   {Msg, Recv} = pstream:decode(Pckt, Sock#stream.recv),
   lists:foreach(fun(X) -> pipe:b(Pipe, {tcp, self(), X}) end, Msg),
   {active, Sock#stream{recv=Recv}}.

%%
%% send packet
io_send(Msg, Pipe, #stream{}=Sock) ->
   ?DEBUG("knet [tcp] ~p: send ~p~n~p", [self(), Sock#stream.peer, Msg]),
   {Pckt, Send} = pstream:encode(Msg, Sock#stream.send),
   lists:foreach(fun(X) -> ok = gen_tcp:send(Pipe, X) end, Pckt),
   {active, Sock#stream{send=Send}}.



%%
%% set socket i/o control flags
tcp_ioctl(#fsm{active=true}=State) ->
   ok = inet:setopts(State#fsm.sock, [{active, once}]),
   State;
tcp_ioctl(#fsm{}=State) ->
   State.
