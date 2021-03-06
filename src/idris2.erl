-module(idris2).

%% API exports
-export([main/1, run/1]).

%%====================================================================
%% API functions
%%====================================================================

%% escript Entry point
main(Args) ->
  'Idris.Idris2.Idris.Main':main(Args).

%% Run Idris 2 compiler
run(Args) ->
  'Idris.Idris2.Idris.Main':run(Args).

%%====================================================================
%% Internal functions
%%====================================================================
