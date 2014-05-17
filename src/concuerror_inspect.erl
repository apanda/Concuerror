%% -*- erlang-indent-level: 2 -*-

%% This module will never be instrumented. Function instrumented/3 should:
%%  - return the result of a call, if it is called from a non-Concuerror process
%%  - grab concuerror_info and continue to concuerror_callback

-module(concuerror_inspect).

%% Interface to instrumented code:
-export([instrumented/3, instrumented_recv/3, instrumented_after/2]).

-include("concuerror.hrl").

%%------------------------------------------------------------------------------

-spec instrumented(Tag      :: instrumented_tag(),
                   Args     :: [term()],
                   Location :: term()) -> Return :: term().

instrumented(Tag, Args, Location) ->
  Ret =
    case erase(concuerror_info) of
      undefined -> doit;
      Info -> concuerror_callback:instrumented_top(Tag, Args, Location, Info)
    end,
  case Ret of
    doit ->
      case {Tag, Args} of
        {apply, [Fun, ApplyArgs]} ->
          erlang:apply(Fun, ApplyArgs);
        {call, [Module, Name, CallArgs]} ->
          erlang:apply(Module, Name, CallArgs);
        {'receive', [_, Timeout, _, Orig]} ->
          Orig(Timeout)
      end;
    instrumented_recv -> [_, _, Action, _] = Args,
                         Action();
    skip_timeout -> [_, _, _, Orig] = Args,
                    Orig(0);
    {didit, Res} -> Res;
    {error, Reason} -> error(Reason)
  end.
instrumented_recv(Msg, PatternFun, Timeout) ->
  Info = erase(concuerror_info),
  #concuerror_info{is_instrument_only=true, 
                   logger=Logger,
                   scheduler=Sched,
                   event=Event}=Info,
  ?debug(Logger, "~p Received message ~p notifying ~p~n", [self(), Msg, Sched]),
  Message = #message{data=Msg},
  ReceiveEvent = #receive_event{
       message = Message,
       patterns = PatternFun,
       timeout = Timeout,
       trapping = false},
  % special is blank since I don't know what the message ID is here. Patch this up later
  % to include message ID
  NewEvent = Event#event{event_info = ReceiveEvent, special = []},
  Sched ! NewEvent,
  %Info
  put(concuerror_info, Info).
  %io:format("~p Would have logged receiving ~p~n", [self(), Msg]).

instrumented_after(PatternFun, Timeout) ->
  Info = erase(concuerror_info),
  #concuerror_info{is_instrument_only=true, 
                   logger=Logger,
                   scheduler=Sched,
                   event=Event}=Info,
  ?debug(Logger, "~p After notifying ~p~n", [self(), Sched]),
  ReceiveEvent = #receive_event{
       message = 'after',
       patterns = PatternFun,
       timeout = Timeout,
       trapping = false},
  % special is blank since I don't know what the message ID is here. Patch this up later
  % to include message ID
  NewEvent = Event#event{event_info = ReceiveEvent, special = []},
  Sched ! NewEvent,
  %Info
  put(concuerror_info, Info).
  %io:format("~p Would have logged receiving ~p~n", [self(), Msg]).
