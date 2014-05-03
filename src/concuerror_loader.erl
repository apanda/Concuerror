%% -*- erlang-indent-level: 2 -*-

-module(concuerror_loader).

-export([load/3, load_binary/4]).

-define(flag(A), (1 bsl A)).

-define(call, ?flag(1)).
-define(result, ?flag(2)).
-define(detail, ?flag(3)).

-define(ACTIVE_FLAGS, [?result]).

%% -define(DEBUG, true).
%% -define(DEBUG_FLAGS, lists:foldl(fun erlang:'bor'/2, 0, ?ACTIVE_FLAGS)).
-include("concuerror.hrl").

-spec load(module(), ets:tid(), boolean()) -> 'ok'.

load(Module, Instrumented, Report) ->
  case ets:lookup(Instrumented, Module) of
    [] ->
      ?debug_flag(?call, {load, Module}),
      {Beam, Filename} =
        case code:which(Module) of
          preloaded ->
            {Module, BeamBinary, F} = code:get_object_code(Module),
            {BeamBinary, F};
          F ->
            {F, F}
        end,
      try_report(Report, Module, Instrumented),
      load_binary(Module, Filename, Beam, Instrumented),
      maybe_instrumenting_myself(Module, Instrumented, Report);
    [{Module, false}] when Report ->
      try_report(Report, Module, Instrumented);
    _ -> ok
  end.

try_report(Report, Module, Instrumented) ->
  ets:insert(Instrumented, {Module, Report}),
  case Report of
    false -> ok;
    true ->
      case ets:lookup(Instrumented, {logger}) of
        [{_,Logger}] ->
          Format = "Instrumenting: ~p~n",
          ?log(Logger, ?linfo, Format, [Module]),
          ok;
        [] -> ok
      end
  end.

-spec load_binary(module(), string(), beam_lib:beam(), ets:tid()) -> 'ok'.

load_binary(Module, Filename, Beam, Instrumented) ->
  Core = get_core(Beam),
  InstrumentedCore =
    case Module =:= concuerror_inspect of
      true -> Core;
      false ->
        true = ets:insert(Instrumented, {{current}, Module}),
        concuerror_instrumenter:instrument(Core, Instrumented)
    end,
  Ret =  compile:forms(InstrumentedCore, [from_core, report_errors, binary]),
  case Ret of
    {ok, _, _} -> ok;
    error -> io:format("Compile error for ~p~n", [Module]);
    {error, _Errors, _} -> io:format("Compile error for ~p~n", [Module])
  end,
  {ok, _, NewBinary} = Ret,
  {module, Module} = code:load_binary(Module, Filename, NewBinary),
  ok.

get_core(Beam) ->
  {ok, {Module, [{abstract_code, ChunkInfo}]}} =
    beam_lib:chunks(Beam, [abstract_code]),
  case ChunkInfo of
    {_, Chunk} ->
      {ok, Module, Core} = compile:forms(Chunk, [binary, to_core0]),
      Core;
    no_abstract_code ->
      ?debug_flag(?detail, {adding_debug_info, Module}),
      {ok, {Module, [{compile_info, CompileInfo}]}} =
        beam_lib:chunks(Beam, [compile_info]),
      {source, File} = proplists:lookup(source, CompileInfo),
      {options, CompileOptions} = proplists:lookup(options, CompileInfo),
      Filter =
        fun(Option) ->
            case Option of
              {Tag, _} -> lists:member(Tag, [d, i]);
              _ -> false
            end
        end,
      CleanOptions = lists:filter(Filter, CompileOptions),
      Options = [debug_info, report_errors, binary, to_core0|CleanOptions],
      {ok, Module, Core} = compile:file(File, Options),
      Core
  end.

maybe_instrumenting_myself(Module, Instrumented, Report) ->
  case Module =:= concuerror_inspect of
    false -> ok;
    true ->
      Additional = concuerror_callback,
      load(Additional, Instrumented, Report)
  end.
