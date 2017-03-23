%% @doc
%%   
-module(knet_gen_ssl).
-compile({parse_transform, category}).

-include("knet.hrl").

-export([
   socket/1,
   close/1,
   setopts/2,
   peername/1,
   sockname/1,
   connect/2,
   listen/2,
   accept/2,
   handshake/1,
   send/2,
   recv/1,
   recv/2,
   getstat/2
]).

%%
%% new socket
-spec socket([_]) -> {ok, #socket{}} | {error, _}.

socket(SOpt) ->
   {ok,
      #socket{
         in = pstream:new(opts:val(stream, raw, SOpt)),
         eg = pstream:new(opts:val(stream, raw, SOpt)),
         so = SOpt 
      }
   }.

%%
%%
-spec close(#socket{}) -> {ok, #socket{}} | {error, _}.

close(#socket{sock = undefined} = Socket) ->
   {ok, Socket};

close(#socket{sock = Sock, so = SOpt} = Socket) ->
   [$^||
      ssl:close(Sock),
      socket(SOpt)
   ].

%%
%% set socket options
-spec setopts(#socket{}, [_]) -> {ok, #socket{}} | {error, _}.

setopts(#socket{sock = undefined}, _) ->
   {error, enotconn};
setopts(#socket{sock = Sock} = Socket, Opts) ->
   [$^ ||
      ssl:setopts(Sock, Opts),
      fmap(Socket)
   ].

%%
%% socket options
so_tcp(SOpt) -> opts:filter(?SO_TCP_ALLOWED, SOpt).
so_ssl(SOpt) -> opts:filter(?SO_SSL_ALLOWED, SOpt).
so_ttc(SOpt) -> lens:get(lens:pair(timeout, []), lens:pair(ttc, ?SO_TIMEOUT), SOpt).

%%
%%
-spec peername(#socket{}) -> {ok, uri:uri()} | {error, _}.

peername(#socket{sock = undefined}) ->
   {error, enotconn};
peername(#socket{sock = Sock, peername = undefined}) ->
   [$^ ||
      ssl_peername(Sock),
      fmap(uri:authority(_, uri:new(ssl)))
   ];
peername(#socket{peername = Peername}) ->
   {ok, Peername}.

ssl_peername({tcp, Sock}) -> 
   inet:peername(Sock);
ssl_peername(Sock) -> 
   ssl:peername(Sock).

%%
%%
-spec peername(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

peername(Uri, #socket{} = Socket) ->
   {ok, [$. ||
      uri:authority(Uri),
      uri:authority(_, uri:new(ssl)),
      fmap(Socket#socket{peername = _})
   ]}.

%%
%%
-spec sockname(#socket{}) -> {ok, uri:uri()} | {error, _}.

sockname(#socket{sock = undefined}) ->
   {error, enotconn};
sockname(#socket{sock = Sock, sockname = undefined}) ->
   [$^ ||
      ssl_sockname(Sock),
      fmap(uri:authority(_, uri:new(ssl)))
   ];
sockname(#socket{sockname = Sockname}) ->
   {ok, Sockname}.

ssl_sockname({tcp, Sock}) -> 
   inet:sockname(Sock);
ssl_sockname(Sock) -> 
   ssl:sockname(Sock).


%%
%%
-spec sockname(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

sockname(Uri, #socket{} = Socket) ->
   {ok, [$. ||
      uri:authority(Uri),
      uri:authority(_, uri:new(ssl)),
      fmap(Socket#socket{sockname = _})
   ]}.


%%
%% connect socket
-spec connect(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

connect(Uri, #socket{so = SOpt} = Socket) ->
   {Host, Port} = uri:authority(Uri),
   [$^ ||
      gen_tcp:connect(scalar:c(Host), Port, so_tcp(SOpt), so_ttc(SOpt)),
      fmap(Socket#socket{sock = {tcp, _}}),
      peername(Uri, _)
   ].

%%
%%
-spec listen(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

listen(Uri, #socket{so = SOpt} = Socket) ->
   {_Host, Port} = uri:authority(Uri),
   Ciphers = opts:val(ciphers, cipher_suites(), SOpt),
   Opts    = lists:keydelete(active, 1, so_tcp(SOpt) ++ so_ssl(SOpt)),
   [$^ ||
      ssl:listen(Port, [{active, false}, {reuseaddr, true} ,{ciphers, Ciphers} | Opts]),
      fmap(Socket#socket{sock = _}),
      sockname(Uri, _),
      peername(Uri, _)  %% @todo: ???
   ].

%%
%%
-spec accept(uri:uri(), #socket{}) -> {ok, #socket{}} | {error, _}.

accept(Uri, #socket{sock = LSock} = Socket) ->
   [$^ ||
      ssl:transport_accept(LSock),
      fmap(Socket#socket{sock = _}),
      sockname(Uri, _),
      fmap(_#socket{peername = undefined})
   ].

%%
%% execute handshake protocol
-spec handshake(#socket{}) -> {ok, #socket{}} | {error, _}.

handshake(#socket{sock = {tcp, Sock}, so = SOpt} = Socket) ->
   [$^ ||
      ssl:connect(Sock, so_ssl(SOpt), so_ttc(SOpt)),
      fmap(Socket#socket{sock = _})
   ];

handshake(#socket{sock = Sock, so = SOpt} = Socket) ->
   [$^ ||
      ssl:ssl_accept(Sock),
      fmap(Socket)
   ].


%%
%%
-spec send(#socket{}, _) -> {ok, #socket{}} | {error, _}.

send(#socket{sock = Sock, eg = Stream0} = Socket, Data) ->
   {Pckt, Stream1} = pstream:encode(Data, Stream0),
   [$^ ||
      either_send(Sock, Pckt),
      fmap(Socket#socket{eg = Stream1})
   ].

either_send(_Sock, []) ->
   ok;
either_send(Sock, [Pckt|Tail]) ->
   [$^ ||
      ssl:send(Sock, Pckt),
      either_send(Sock, Tail)
   ].

%%
%%
-spec recv(#socket{}) -> {ok, [binary()], #socket{}} | {error, _}.
-spec recv(#socket{}, _) -> {ok, [binary()], #socket{}} | {error, _}.

recv(#socket{sock = Sock} = Socket) ->
   [$^ ||
      ssl:recv(Sock, 0),
      recv(Socket, _)
   ].

recv(#socket{in = Stream0} = Socket, Data) ->
   {Pckt, Stream1} = pstream:decode(Data, Stream0),
   {ok, Pckt, Socket#socket{in = Stream1}}.

%%
%%
-spec getstat(#socket{}, atom()) -> {ok, _} | {error, _}.

getstat(#socket{in = In, eg = Eg}, packet) ->
   {ok, pstream:packets(In) + pstream:packets(Eg)};

getstat(#socket{in = In, eg = Eg}, octet) ->
   {ok, pstream:octets(In) + pstream:octets(Eg)}.


%%
%% list of valid cipher suites 
-ifdef(CONFIG_NO_ECDH).
cipher_suites() ->
   lists:filter(
      fun(Suite) ->
         string:left(scalar:c(element(1, Suite)), 4) =/= "ecdh"
      end, 
      ssl:cipher_suites()
   ).
-else.
cipher_suites() ->
   ssl:cipher_suites().
-endif.
