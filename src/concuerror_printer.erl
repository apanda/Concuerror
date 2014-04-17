%% -*- erlang-indent-level: 2 -*-

-module(concuerror_printer).

-export([error_s/2, pretty/3, pretty_s/2, print_p/2]).

-include("concuerror.hrl").

-spec error_s(concuerror_warning_info(), pos_integer()) -> string().

error_s(fatal, _Depth) ->
  io_lib:format("* Concuerror crashed~n", []);
error_s({Type, Info}, Depth) ->
  case Type of
    crash ->
      {Step, P, Reason, Stacktrace} = Info,
      S1 = io_lib:format("* At step ~w process ~p exited abnormally~n", [Step, P]),
      S2 =
        io_lib:format(
          "    Reason:~n"
          "      ~P~n", [Reason, Depth]),
      S3 =
        io_lib:format(
          "    Stacktrace:~n"
          "      ~p~n", [Stacktrace]),
      [S1,S2,S3];
    deadlock ->
      InfoStr =
        [io_lib:format("    ~p ~s~n", [P, location(F, L)]) ||
          {P, [L, {file, F}]} <- Info],
      Format =
        "* Blocked at a 'receive' (when all other processes have exited):~n~s",
      io_lib:format(Format, [InfoStr]);
    depth_bound ->
      io_lib:format("* Reached the depth bound of ~p events~n",[Info]);
    sleep_set_block ->
      io_lib:format("* Nobody woke-up: ~p~n", [Info])
  end.

print_actor({A, B}) ->
  io_lib:format("{~s, ~s}", [A, B]);
print_actor(A) ->
  io_lib:format("~s", [A]).

-spec print_p(io:device(), [{{index(), event()}, [{index(), atom()}]}]) -> ok.

print_p(_Output, []) ->
  ok;
print_p(Output, [Current | Rest]) ->
 {{CurrentIndex, CurrentEvent}, Related} = Current,
 #event{
    actor = Actor,
    event_info = EventInfo, 
    location = Location
 } = CurrentEvent,
 Preamble = 
    io_lib:format("~w\1~s\1~s\1~s", 
        [CurrentIndex, print_actor(Actor), simple_pretty_info(EventInfo), location_string(Location, EventInfo)]),
 Dependencies =  dependency_string(Related, ""),
 io:format(Output, "~s\1[~s]~n", [Preamble, Dependencies]),
 print_p(Output, Rest).

location_string(Location, EventInfo) ->
  case Location of
    [Line, {file, File}] -> io_lib:format("~s",[location_o(File, Line)]);
    exit ->
      case EventInfo of
        #exit_event{} -> "exit";
        _Other -> io_lib:format("exit", [])
      end;
    _ -> ""
  end.

dependency_string([], String) ->
  String;
dependency_string([{Idx, Why} | Rest], "") ->
  dependency_string(Rest, io_lib:format("{~w, ~p}", [Idx, Why]));
dependency_string([{Idx, Why} | Rest], S) ->
  dependency_string(Rest, io_lib:format("~s ,{~w, ~p}", [S, Idx, Why])).

-spec pretty(io:device(), event(), pos_integer()) -> ok.

pretty(Output, I, Depth) ->
  Fun = fun(P, A) -> io:format(Output, P ++ "~n", A) end,
  _ = pretty_aux(I, {Fun, []}, Depth),
  ok.

-type indexed_event() :: {index(), event()}.

-spec pretty_s(event() | indexed_event() | [indexed_event()], pos_integer()) ->
                  [string()].

pretty_s(I, Depth) ->
  {_, Acc} = pretty_aux(I, {fun io_lib:format/2, []}, Depth),
  lists:reverse(Acc).

pretty_aux({I, #event{} = Event}, {F, Acc}, Depth) ->
  #event{
     actor = Actor,
     event_info = EventInfo,
     location = Location
    } = Event,
  TraceString =
    case I =/= 0 of
      true -> io_lib:format("~4w: ", [I]);
      false -> ""
    end,
  ActorString =
    case Actor of
      P when is_pid(P) -> io_lib:format("~p: ",[P]);
      _ -> ""
    end,
  EventString = pretty_info(EventInfo, Depth),
  LocationString =
    case Location of
      [Line, {file, File}] -> io_lib:format("~n    ~s",[location(File, Line)]);
      exit ->
        case EventInfo of
          #exit_event{} -> "";
          _Other -> io_lib:format("~n    (while exiting)", [])
        end;
      _ -> ""
    end,
  R = F("~s~s~s~s", [TraceString, ActorString, EventString, LocationString]),
  {F, [R|Acc]};
pretty_aux(#event{} = Event, FAcc, Depth) ->
  pretty_aux({0, Event}, FAcc, Depth);
pretty_aux(List, FAcc, Depth) when is_list(List) ->
  Fun = fun(Event, Acc) -> pretty_aux(Event, Acc, Depth) end,
  lists:foldl(Fun, FAcc, List).

pretty_info(#builtin_event{mfargs = {erlang, '!', [To, Msg]},
                           status = {crashed, Reason}}, Depth) ->
  io_lib:format("Exception ~W raised by: ~W ! ~W",
                [Reason, Depth, To, Depth, Msg, Depth]);
pretty_info(#builtin_event{mfargs = {M, F, Args},
			   status = {crashed, Reason}}, Depth) ->
  ArgString = pretty_arg(Args, Depth),
  io_lib:format("Exception ~W raised by: ~p:~p(~s)",
                [Reason, Depth, M, F, ArgString]);
pretty_info(#builtin_event{mfargs = {erlang, '!', [To, Msg]},
			   result = Result}, Depth) ->
  io_lib:format("~W = ~w ! ~W", [Result, Depth, To, Msg, Depth]);
pretty_info(#builtin_event{mfargs = {M, F, Args}, result = Result}, Depth) ->
  ArgString = pretty_arg(Args, Depth),
  io_lib:format("~W = ~p:~p(~s)",[Result, Depth, M, F, ArgString]);
pretty_info(#exit_event{reason = Reason}, Depth) ->
  ReasonStr =
    case Reason =:= normal of
      true -> "normally";
      false -> io_lib:format("abnormally (~W)", [Reason, Depth])
    end,
  io_lib:format("exits ~s",[ReasonStr]);
pretty_info(#message_event{} = MessageEvent, Depth) ->
  #message_event{
     message = #message{data = Data},
     recipient = Recipient,
     sender = Sender,
     type = Type
    } = MessageEvent,
  MsgString =
    case Type of
      message -> io_lib:format("Message (~W)", [Data, Depth]);
      exit_signal ->
        Reason =
          case Data of
            {'EXIT', Sender, R} -> R;
            kill -> kill
          end,
        io_lib:format("Exit signal (~W)",[Reason, Depth])
    end,
  io_lib:format("~s from ~p reaches ~p", [MsgString, Sender, Recipient]);
pretty_info(#receive_event{message = Message, timeout = Timeout}, Depth) ->
  case Message of
    'after' ->
      io_lib:format("receive timeout expired after ~p ms", [Timeout]);
     #message{data = Data} ->
      io_lib:format("receives message (~W)", [Data, Depth])
  end.

simple_pretty_info(#builtin_event{status = {crashed, Reason}}) ->
  io_lib:format("exception(~w)",
                [Reason]);
simple_pretty_info(#builtin_event{mfargs = {erlang, '!', [To, Msg]}}) ->
  io_lib:format("send(~w, ~w)", [To, Msg]);
simple_pretty_info(#builtin_event{mfargs = {erlang, spawn_opt, _}}) ->
  io_lib:format("spawn_opt", []);
simple_pretty_info(#builtin_event{mfargs = {M, F, Args}}) ->
  io_lib:format("built_in(~w:~w/~w)",[M, F, length(Args)]);
simple_pretty_info(#exit_event{reason = Reason}) ->
  ReasonStr =
    case Reason =:= normal of
      true -> "normally";
      false -> io_lib:format("abnormally(~w)", [Reason])
    end,
  io_lib:format("exits(~s)",[ReasonStr]);
simple_pretty_info(#message_event{} = MessageEvent) ->
  #message_event{
     message = #message{data = Data, id=Id},
     recipient = _Recipient,
     sender = Sender,
     type = Type
    } = MessageEvent,
  MsgString =
    case Type of
      message -> io_lib:format("~w", [Id]);
      exit_signal ->
        Reason =
          case Data of
            {'EXIT', Sender, R} -> R;
            kill -> kill
          end,
        io_lib:format("~w, exit(~w)",[Id, Reason])
    end,
  io_lib:format("message_deliver(~w, ~s)", [Sender, MsgString]);
simple_pretty_info(#receive_event{message = Message, timeout = Timeout}) ->
  case Message of
    'after' ->
      io_lib:format("timeout(~p)", [Timeout]);
     #message{id = Id} ->
      io_lib:format("message_receive(~w)", [Id])
  end.

pretty_arg(Args, Depth) ->
  pretty_arg(lists:reverse(Args), "", Depth).

pretty_arg([], Acc, _Depth) -> Acc;
pretty_arg([Arg|Args], "", Depth) ->
  pretty_arg(Args, io_lib:format("~W",[Arg, Depth]), Depth);
pretty_arg([Arg|Args], Acc, Depth) ->
  pretty_arg(Args, io_lib:format("~W, ",[Arg, Depth]) ++ Acc, Depth).

location(F, L) ->
  Basename = filename:basename(F),
  io_lib:format("in ~s line ~w", [Basename, L]).

location_o(F, L) ->
  Basename = filename:basename(F),
  io_lib:format("~s(~w)", [Basename, L]).
