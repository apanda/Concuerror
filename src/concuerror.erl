%% -*- erlang-indent-level: 2 -*-

-module(concuerror).

-export([run/1]).

-include("concuerror.hrl").

-spec run(options()) -> 'completed' | 'error'.

run(RawOptions) ->
  Halt = proplists:get_value(halt, RawOptions, false),
  S =
    try
      Options = concuerror_options:finalize(RawOptions),
      Modules = proplists:get_value(modules, Options),
      Processes = ets:new(processes, [public]),
      SProcesses = ets:new(sprocesses, [public, named_table]),
      LoggerOptions =
        [{processes, Processes} |
         [O || O <- Options, concuerror_options:filter_options('logger', O)]
        ],
      ok = concuerror_loader:load(concuerror_logger, Modules),
      Logger = spawn_link(fun() -> concuerror_logger:run(LoggerOptions) end),
      SchedulerOptions = [{processes, Processes}, {sprocesses, SProcesses}, {logger, Logger}|Options],
      {Pid, Ref} =
        spawn_monitor(fun() -> concuerror_scheduler:run(SchedulerOptions) end),
      Reason = receive {'DOWN', Ref, process, Pid, R} -> R end,
      Status =
        case Reason =:= normal of
          true -> completed;
          false ->
            ?log(Logger, ?lerror, "Concuerror crashed!~n~n~s~n~n",
                 [explain(Reason)]),
            error
        end,
      cleanup(Processes),
      ?trace(Logger, "Reached the end!~n",[]),
      concuerror_logger:stop(Logger, Status),
      ets:delete(Processes),
      Status
    catch
      _:_ -> error
    end,
  case Halt of
    true  ->
      ExitStatus =
        case S =:= completed of
          true -> 0;
          false -> 1
        end,
      erlang:halt(ExitStatus);
    false -> S
  end.

explain(Reason) ->
  Stacktrace = erlang:get_stacktrace(),
  try
    case Reason of
      {Module, Info} -> Module:explain_error(Info);
      _ -> error(undef)
    end
  catch
    _:_ ->
      io_lib:format("Reason: ~p~nTrace: ~p~n", [Reason, Stacktrace])
  end.

cleanup(Processes) ->
  Fold = fun(?process_pat_pid(P), true) -> exit(P, kill) end,
  true = ets:foldl(Fold, true, Processes),
  ok.

