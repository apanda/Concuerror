%% -*- erlang-indent-level: 2 -*-

-module(concuerror_options).

-export([parse_cl/1, filter_options/2, finalize/1]).

-include("concuerror.hrl").

-define(DEFAULT_VERBOSITY, ?lprogress).
-define(DEFAULT_PRINT_DEPTH, 20).

-spec parse_cl([string()]) -> options().

parse_cl(CommandLineArgs) ->
  try
    parse_cl_aux(CommandLineArgs)
  catch
    throw:opt_error -> {exit, error}
  end.

parse_cl_aux(CommandLineArgs) ->
  case getopt:parse(getopt_spec(), CommandLineArgs) of
    {ok, {Options, OtherArgs}} ->
      case {proplists:get_bool(help, Options),
            proplists:get_bool(version, Options)} of
        {true,_} ->
          cl_usage(),
          {exit, completed};
        {_,true} ->
          cl_version(),
          {exit, completed};
        {false, false} ->
          case OtherArgs =:= [] of
            true -> ok;
            false ->
              opt_warn("Ignoring: ~s", [string:join(OtherArgs, " ")], Options)
          end,
          Options
      end;
    {error, Error} ->
      case Error of
        {missing_option_arg, Option} ->
          opt_error("no argument given for --~s", [Option]);
        _Other ->
          opt_error(getopt:format_error([], Error))
      end
  end.

getopt_spec() ->
  %% We are storing additional info in the options spec. Filter these before
  %% running getopt.
  %% Options long name is the same as the inner representation atom for
  %% consistency.
  [{Key, Short, atom_to_list(Key), Type, Help} ||
    {Key, _Classes, Short, Type, Help} <- options()].

options() ->
  [{module, [frontend], $m, atom,
    "The module containing the main test function."}
  ,{test, [frontend], $t, {atom, test},
    "The name of the 0-arity function that starts the test."}
  ,{output, [logger], $o, {string, "results.txt"},
    "Output file where Concuerror shall write the results of the analysis."}
  ,{provenance, [scheduler], $p, {string, "provenance.txt"},
    "Output file where Concuerror shall write provenance information."}
  ,{instrumented, [scheduler, process], undefined, {boolean, false},
    "Run instrumented process only, no DPOR or other exploration"}
  ,{help, [frontend], $h, undefined,
    "Display this information."}
  ,{version, [frontend], undefined, undefined,
    "Display version information about Concuerror."}
  ,{pa, [frontend, logger], undefined, string,
    "Add directory at the front of Erlang's code path."}
  ,{pz, [frontend, logger], undefined, string,
    "Add directory at the end of Erlang's code path."}
  ,{file, [frontend], $f, string,
    "Explicitly load a file (.beam or .erl). (A .erl file should not require"
    " any command line compile options.)"}
  ,{verbosity, [logger], $v, integer,
    io_lib:format("Sets the verbosity level (0-~p). [default: ~p]",
                  [?MAX_VERBOSITY, ?DEFAULT_VERBOSITY])}
  ,{quiet, [frontend], $q, undefined,
    "Do not write anything to standard output. Equivalent to -v 0."}
  ,{print_depth, [logger, scheduler], undefined, {integer, ?DEFAULT_PRINT_DEPTH},
    "Specifies the max depth for any terms printed in the log (behaves just as"
    " the extra argument of ~W and ~P argument of io:format/3. If you want more"
    " info about a particular piece of data consider using erlang:display/1"
    " and check the standard output section instead."}
  ,{symbolic, [logger], $s, {boolean, true},
    "Use symbolic names for process identifiers in the output traces."}
  ,{depth_bound, [logger, scheduler], undefined, {integer, 5000},
    "The maximum number of events allowed in a trace. Concuerror will stop"
    " exploration beyond this limit."}
  ,{after_timeout, [logger, process], $a, {integer, infinity},
    "Assume that 'after' clause timeouts higher or equal to the specified value"
    " will never be triggered."}
  ,{instant_delivery, [logger, process], undefined, {boolean, false},
    "Assume that messages and signals are delivered immediately, when sent to a"
    " process on the same node."}
  ,{allow_first_crash, [logger, scheduler], undefined, {boolean, false},
    "If not enabled, Concuerror will immediately exit if the first interleaving"
    " contains errors."}
  ,{ignore_error, [logger, scheduler], undefined, atom,
    "Concuerror will not report errors of the specified kind: 'crash' (all"
    " process crashes, see also next option for more refined control), 'deadlock'"
    " (processes waiting at a receive statement), 'depth_bound'."}
  ,{treat_as_normal, [logger, scheduler], undefined, {atom, normal},
    "Specify exit reasons that are considered 'normal' and not reported as"
    " crashes. Useful e.g. when analyzing supervisors ('shutdown' is probably"
    " also a normal exit reason in this case)."}
  ,{timeout, [logger, process, scheduler], undefined, {integer, ?MINIMUM_TIMEOUT},
    "How many ms to wait before assuming a process to be stuck in an infinite"
    " loop between two operations with side-effects. Setting it to -1 makes"
    " Concuerror wait indefinitely. Otherwise must be >= " ++
      integer_to_list(?MINIMUM_TIMEOUT) ++ "."}
  ,{assume_racing, [logger, scheduler], undefined, {boolean, true},
    "If there is no info about whether a specific pair of built-in operations"
    " may race, assume that they do indeed race. Set this to false to detect"
    " missing dependency info."}
  ,{non_racing_system, [logger, scheduler], undefined, atom,
    "Assume that any messages sent to the specified system process (specified"
    " by registered name) are not racing with each-other. Useful for reducing"
    " the number of interleavings when processes have calls to io:format/1,2 or"
    " similar."}
  ,{report_unknown, [logger, process], undefined, {boolean, false},
    "Report built-ins that are not explicitly classified by Concuerror as"
    " racing or race-free. Otherwise, Concuerror expects such built-ins to"
    " always return the same result."}
  %% ,{bound, [logger, scheduler], $b, "bound", {integer, -1},
  %%   "Preemption bound (-1 for infinite)."}

   %% The following options won't make it to the getopt script
  ,{target, [logger, scheduler]} %% Generated from module and test or given explicitly
  ,{files, [logger]}             %% List of included files (to be shown in the log)
  ,{modules, [logger, process]}  %% Ets table of instrumented modules
  ,{processes, [logger, process]}%% Ets table containing processes under concuerror
  ,{logger, [process]}
  ,{frontend, []}
  ].

-spec filter_options(atom(), {atom(), term()}) -> boolean().

filter_options(Mode, {Key, _}) ->
  OptInfo = lists:keyfind(Key, 1, options()),
  lists:member(Mode, element(2, OptInfo)).

cl_usage() ->
  getopt:usage(getopt_spec(), "./concuerror").

cl_version() ->
  io:format(standard_error, "Concuerror v~s~n",[?VSN]),
  ok.

-spec finalize(options()) -> options().

finalize(Options) ->
  case code:is_sticky(ets) of
    true ->
      opt_error("Concuerror must be able to reload sticky modules."
                " Use the command-line script or start Erlang with -nostick.");
    false ->
      Finalized =
        finalize_aux(proplists:unfold(Options)),
      case proplists:get_value(target, Finalized, undefined) of
        {M,F,B} when is_atom(M), is_atom(F), is_list(B) ->
          MissingDefaults =
            add_missing_defaults(
              [{verbosity, ?DEFAULT_VERBOSITY},
               {non_racing_system, []},
               {ignore_error, []}], Finalized),
          add_missing_getopt_defaults(MissingDefaults);
        _ ->
          opt_error("The module containing the main test function has not been"
                    " specified.")
      end
  end.

finalize_aux(Options) ->
  Modules = [{modules, ets:new(modules, [public])}],
  case lists:keytake(file, 1, Options) of
    false -> finalize(Options, Modules);
    {value, Tuple, RestOptions} ->
      finalize([Tuple|RestOptions], Modules)
  end.

finalize([], Acc) -> Acc;
finalize([{quiet, true}|Rest], Acc) ->
  case proplists:is_defined(verbosity, Rest) of
    true -> opt_error("--verbosity defined after --quiet");
    false -> ok
  end,
  finalize(Rest, [{verbosity, 0},{quiet,true}|Acc]);
finalize([{Key, V}|Rest], Acc)
  when
    Key =:= ignore_error;
    Key =:= non_racing_system;
    Key =:= treat_as_normal ->
  AlwaysAdd =
    case Key of
      treat_as_normal -> [normal];
      _ -> []
    end,
  Values = [V|AlwaysAdd] ++ proplists:get_all_values(Key, Rest),
  NewRest = proplists:delete(Key, Rest),
  finalize(NewRest, [{Key, lists:usort(Values)}|Acc]);
finalize([{verbosity, N}|Rest], Acc) ->
  Sum = lists:sum([N|proplists:get_all_values(verbosity, Rest)]),
  Verbosity = min(Sum, ?MAX_VERBOSITY),
  NewRest = proplists:delete(verbosity, Rest),
  finalize(NewRest, [{verbosity, Verbosity}|Acc]);
finalize([{Key, Value}|Rest], Acc)
  when Key =:= file; Key =:= pa; Key =:=pz ->
  case Key of
    file ->
      Modules = proplists:get_value(modules, Acc),
      Files = [Value|proplists:get_all_values(file, Rest)],
      {LoadedFiles, MoreOptions} = compile_and_load(Files, Modules),
      NewRest = proplists:delete(file, Rest),
      finalize(NewRest ++ MoreOptions, [{files, LoadedFiles}|Acc]);
    Else ->
      PathAdd =
        case Else of
          pa -> fun code:add_patha/1;
          pz -> fun code:add_pathz/1
        end,
      case PathAdd(Value) of
        true -> ok;
        {error, bad_directory} ->
          opt_error("could not add ~s to code path", [Value])
      end,
      finalize(Rest, Acc)
  end;
finalize([{Key, Value}|Rest], Acc) ->
  case proplists:is_defined(Key, Acc) of
    true ->
      Format = "multiple instances of --~s defined. Using last value: ~p.",
      opt_warn(Format, [Key, Value], Acc ++ Rest);
    false ->
      ok
  end,
  case Key of
    module ->
      case proplists:get_value(test, Rest, 1) of
        Name when is_atom(Name) ->
          NewRest = proplists:delete(test, Rest),
          finalize(NewRest, [{target, {Value, Name, []}}|Acc]);
        _ -> opt_error("The name of the test function is missing")
      end;
    OKey when OKey =:= output; OKey =:= provenance ->
      case file:open(Value, [write]) of
        {ok, IoDevice} ->
          finalize(Rest, [{OKey, {IoDevice, Value}}|Acc]);
        {error, _} ->
          opt_error("could not open file ~s for writing", [Value])
      end;
    timeout ->
      case Value of
        -1 ->
          finalize(Rest, [{Key, infinity}|Acc]);
        N when is_integer(N), N >= ?MINIMUM_TIMEOUT ->
          finalize(Rest, [{Key, N}|Acc]);
        _Else ->
          opt_error("--~s value must be -1 (infinite) or >= "
                    ++ integer_to_list(?MINIMUM_TIMEOUT), [Key])
      end;
    test ->
      case Rest =:= [] of
        true -> finalize(Rest, Acc);
        false -> finalize(Rest ++ [{Key, Value}], Acc)
      end;
    _ ->
      finalize(Rest, [{Key, Value}|Acc])
  end.

compile_and_load(Files, Modules) ->
  compile_and_load(Files, Modules, {[],[]}).

compile_and_load([], _Modules, {Acc, MoreOpts}) ->
  {lists:sort(Acc), MoreOpts};
compile_and_load([File|Rest], Modules, {Acc, MoreOpts}) ->
  case filename:extension(File) of
    ".erl" ->
      case compile:file(File, [binary, debug_info, report_errors]) of
        {ok, Module, Binary} ->
          Default = code:which(Module),
          case Default =:= non_existing of
            true -> ok;
            false ->
              opt_warn("file ~s shadows the default ~s", [File, Default], [])
          end,
          ok = concuerror_loader:load_binary(Module, File, Binary, Modules),
          NewMoreOpts = try Module:concuerror_options() catch _:_ -> [] end,
          compile_and_load(Rest, Modules, {[File|Acc], NewMoreOpts++MoreOpts});
        error ->
          Format = "could not compile ~s (try to add the .beam file instead)",
          opt_error(Format, [File])
      end;
    ".beam" ->
      case beam_lib:chunks(File, []) of
        {ok, {Module, []}} ->
          ok = concuerror_loader:load_binary(Module, File, File, Modules),
          NewMoreOpts = try Module:concuerror_options() catch _:_ -> [] end,
          compile_and_load(Rest, Modules, {[File|Acc], NewMoreOpts++MoreOpts});
        Else ->
          opt_error(beam_lib:format_error(Else))
      end;
    _Other ->
      opt_error("~s is not a .erl or .beam file", [File])
  end.

add_missing_defaults([], Options) -> Options;
add_missing_defaults([{Key, _} = Default|Rest], Options) ->
  case proplists:is_defined(Key, Options) of
    true -> add_missing_defaults(Rest, Options);
    false -> [Default|add_missing_defaults(Rest, Options)]
  end.

add_missing_getopt_defaults(Opts) ->
  MissingDefaults =
    [{Key, Default} ||
      {Key, _Classes, _Short, {_, Default}, _Help} <- options(),
      not proplists:is_defined(Key, Opts)
    ],
  MissingDefaults ++ Opts.

-spec opt_error(string()) -> no_return().

opt_error(Format) ->
  opt_error(Format, []).

opt_error(Format, Data) ->
  io:format(standard_error, "concuerror: ERROR: " ++ Format ++ "~n", Data),
  io:format(standard_error, "concuerror: Use --help for more information.\n", []),
  throw(opt_error).

opt_warn(Format, Data, MaybeQuiet) ->
  case proplists:is_defined(quiet, MaybeQuiet) of
    true -> ok;
    false ->
      io:format(standard_error, "concuerror: WARNING: " ++ Format ++ "~n", Data)
  end.
