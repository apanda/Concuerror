%% -*- erlang-indent-level: 2 -*-

-module(concuerror_callback).

%% Interface to concuerror_inspect:
-export([instrumented_top/4]).

%% Interface to scheduler:
-export([spawn_first_process/1, start_first_process/2]).

%% Interface for resetting:
-export([process_top_loop/1]).

%%------------------------------------------------------------------------------

%% DEBUGGING SETTINGS

-define(flag(A), (1 bsl A)).

-define(builtin, ?flag(1)).
-define(non_builtin, ?flag(2)).
-define(receive_, ?flag(3)).
-define(receive_messages, ?flag(4)).
-define(stack, ?flag(5)).
-define(args, ?flag(6)).
-define(result, ?flag(7)).
-define(spawn, ?flag(8)).
-define(short_builtin, ?flag(9)).
-define(wait, ?flag(10)).
-define(send, ?flag(11)).
-define(exit, ?flag(12)).
-define(trap, ?flag(13)).
-define(undefined, ?flag(14)).
-define(heir, ?flag(15)).

-define(ACTIVE_FLAGS, [?undefined]).

%% -define(DEBUG, true).
-define(DEBUG_FLAGS, lists:foldl(fun erlang:'bor'/2, 0, ?ACTIVE_FLAGS)).

-define(badarg_if_not(A), case A of true -> ok; false -> error(badarg) end).
%%------------------------------------------------------------------------------

-include("concuerror.hrl").

-record(process_flags, {
          trap_exit = false  :: boolean(),
          priority  = normal :: 'low' | 'normal' | 'high' | 'max'
         }).

-record(concuerror_info, {
          'after-timeout'            :: infinite | integer(),
          caught_signal = false      :: boolean(),
          escaped_pdict = []         :: term(),
          ets_tables                 :: ets_tables(),
          exit_reason = normal       :: term(),
          extra                      :: term(),
          flags = #process_flags{}   :: #process_flags{},
          links                      :: links(),
          logger                     :: pid(),
          messages_new = queue:new() :: queue(),
          messages_old = queue:new() :: queue(),
          modules                    :: modules(),
          monitors                   :: monitors(),
          next_event = none          :: 'none' | event(),
          processes                  :: processes(),
          sprocesses                 :: processes(),
          scheduler                  :: pid(),
          stacktop = 'none'          :: 'none' | tuple(),
          status = running           :: 'exited'| 'exiting' | 'running' | 'waiting'
         }).

-type concuerror_info() :: #concuerror_info{}.

%%------------------------------------------------------------------------------

-spec spawn_first_process(options()) -> pid().

spawn_first_process(Options) ->
  [AfterTimeout, Logger, Processes, SProcesses, Modules] =
    get_properties(['after-timeout', logger, processes, sprocesses, modules], Options),
  EtsTables = ets:new(ets_tables, [public]),
  InitialInfo =
    #concuerror_info{
       'after-timeout' = AfterTimeout,
       ets_tables      = EtsTables,
       links           = ets:new(links, [bag, public]),
       logger          = Logger,
       modules         = Modules,
       monitors        = ets:new(monitors, [bag, public]),
       processes       = Processes,
       sprocesses      = SProcesses,
       scheduler       = self()
      },
  system_ets_entries(EtsTables),
  system_processes_wrappers(Processes, SProcesses),
  P = spawn_link(fun() -> process_top_loop(InitialInfo) end),
  true = ets:insert(Processes, ?new_process(P, "P")),
  P.

get_properties(Props, PropList) ->
  get_properties(Props, PropList, []).

get_properties([], _, Acc) -> lists:reverse(Acc);
get_properties([Prop|Props], PropList, Acc) ->
  PropVal = proplists:get_value(Prop, PropList),
  get_properties(Props, PropList, [PropVal|Acc]).

-spec start_first_process(pid(), {atom(), atom(), [term()]}) -> ok.

start_first_process(Pid, {Module, Name, Args}) ->
  Pid ! {start, Module, Name, Args},
  ok.

%%------------------------------------------------------------------------------

-spec instrumented_top(Tag      :: instrumented_tag(),
                       Args     :: [term()],
                       Location :: term(),
                       Info     :: concuerror_info()) ->
                          'doit' |
                          {'didit', term()} |
                          {'error', term()} |
                          'skip_timeout'.

instrumented_top(Tag, Args, Location, #concuerror_info{} = Info) ->
  #concuerror_info{escaped_pdict = Escaped} = Info,
  lists:foreach(fun({K,V}) -> put(K,V) end, Escaped),
  {Result, #concuerror_info{} = NewInfo} =
    instrumented(Tag, Args, Location, Info),
  NewEscaped = erase(),
  FinalInfo = NewInfo#concuerror_info{escaped_pdict = NewEscaped},
  put(concuerror_info, FinalInfo),
  Result;
instrumented_top(Tag, Args, Location, {logger, _, _} = Info) ->
  {Result, _} = instrumented(Tag, Args, Location, Info),
  put(concuerror_info, Info),
  Result.

instrumented(call, [Module, Name, Args], Location, Info) ->
  Arity = length(Args),
  instrumented_aux(Module, Name, Arity, Args, Location, Info);
instrumented(apply, [Fun, Args], Location, Info) ->
  io:format("~p apply: ~p ~p~n", [self(), Fun, Location]),
  case is_function(Fun) of
    true ->
      Module = get_fun_info(Fun, module),
      Name = get_fun_info(Fun, name),
      Arity = get_fun_info(Fun, arity),
      case length(Args) =:= Arity of
        true -> instrumented_aux(Module, Name, Arity, Args, Location, Info);
        false -> {doit, Info}
      end;
    false ->
      {doit, Info}
  end;
instrumented('receive', [PatternFun, Timeout], Location, Info) ->
  case Info of
    #concuerror_info{'after-timeout' = AfterTimeout} ->
      RealTimeout =
        case Timeout =:= infinity orelse Timeout > AfterTimeout of
          false -> Timeout;
          true -> infinity
        end,
      handle_receive(PatternFun, RealTimeout, Location, Info);
    _Logger ->
      {doit, Info}
  end.

instrumented_aux(erlang, apply, 3, [Module, Name, Args], Location, Info) ->
  instrumented_aux(Module, Name, length(Args), Args, Location, Info);
instrumented_aux(Module, Name, Arity, Args, Location, Info)
  when is_atom(Module) ->
  case
    erlang:is_builtin(Module, Name, Arity) andalso
    not lists:member({Module, Name, Arity}, ?RACE_FREE_BIFS)
  of
    true ->
      case Info of
        #concuerror_info{} ->
          built_in(Module, Name, Arity, Args, Location, Info);
        {logger, Processes, _} ->
          case {Module, Name, Arity} =:= {erlang, pid_to_list, 1} of
            true ->
              [Term] = Args,
              try
                Symbol = ets:lookup_element(Processes, Term, ?process_symbolic),
                {{didit, Symbol}, Info}
              catch
                _:_ -> {doit, Info}
              end;
            false ->
              {doit, Info}
          end
      end;
    false ->
      Modules =
        case Info of
          #concuerror_info{modules = M} -> M;
          {logger, _, M} -> M
        end,
      ok = concuerror_loader:load(Module, Modules),
      {doit, Info}
  end;
instrumented_aux({Module, _} = Tuple, Name, Arity, Args, Location, Info) ->
  instrumented_aux(Module, Name, Arity + 1, Args ++ Tuple, Location, Info);
instrumented_aux(_, _, _, _, _, Info) ->
  {doit, Info}.

get_fun_info(Fun, Tag) ->
  {Tag, Info} = erlang:fun_info(Fun, Tag),
  Info.

%%------------------------------------------------------------------------------

%% Instrumented processes may just call pid_to_list (we instrument this builtin
%% for the logger)
built_in(erlang, pid_to_list, _Arity, _Args, _Location, Info) ->
  {doit, Info};
%% Process dictionary has been restored here. No need to report such ops.
built_in(erlang, get, _Arity, Args, _Location, Info) ->
  {{didit, erlang:apply(erlang,get,Args)}, Info};
%% XXX: Check if its redundant (e.g. link to already linked)
built_in(Module, Name, Arity, Args, Location, InfoIn) ->
  io:format("~p built_in ~p ~p ~p ~p [going to wait to process_loop]~n", [self(), Module, Name, Arity, Args]),
  Info = process_loop(InfoIn),
  io:format("~p built_in ~p ~p ~p ~p [stopped waiting on process_loop]~n", [self(), Module, Name, Arity, Args]),
  ?debug_flag(?short_builtin, {'built-in', Module, Name, Arity, Location}),
  %% {Stack, ResetInfo} = reset_stack(Info),
  %% ?debug_flag(?stack, {stack, Stack}),
  #concuerror_info{flags = #process_flags{trap_exit = Trapping}} = LocatedInfo =
    add_location_info(Location, Info#concuerror_info{extra = undefined}),%ResetInfo),
  try
    {Value, UpdatedInfo} = run_built_in(Module, Name, Arity, Args, LocatedInfo),
    #concuerror_info{extra = Extra, next_event = Event} = UpdatedInfo,
    ?debug_flag(?builtin, {'built-in', Module, Name, Arity, Value, Location}),
    ?debug_flag(?args, {args, Args}),
    ?debug_flag(?result, {args, Value}),
    EventInfo =
      #builtin_event{
         exiting = Location =:= exit,
         extra = Extra,
         mfa = {Module, Name, Args},
         result = Value
        },
    Notification = Event#event{event_info = EventInfo},
    NewInfo = notify(Notification, UpdatedInfo),
    {{didit, Value}, NewInfo}
  catch
    throw:Reason ->
      #concuerror_info{scheduler = Scheduler} = Info,
      exit(Scheduler, {Reason, Module, Name, Arity, Args, Location}),
      receive after infinity -> ok end;
    error:Reason ->
      #concuerror_info{next_event = FEvent} = LocatedInfo,
      FEventInfo =
        #builtin_event{
           mfa = {Module, Name, Args},
           status = {crashed, Reason},
           trapping = Trapping
          },
      FNotification = FEvent#event{event_info = FEventInfo},
      FNewInfo = notify(FNotification, LocatedInfo),
      FinalInfo =
        FNewInfo#concuerror_info{stacktop = {Module, Name, Args, Location}},
      {{error, Reason}, FinalInfo}
  end.

% One of the problems with how we are instrumenting is that there are ways to get handles
% to system processes that are not accessed by name, for instance through group_leader(). This
% function attempts to allow translation for this.
translate_pid(Pid, Info) ->
  ?badarg_if_not(is_pid(Pid)),
  #concuerror_info{processes = Processes, sprocesses = SProcesses} = Info,
  case ets:lookup(Processes, Pid) of
      [] -> case ets:lookup(SProcesses, Pid) of
              [] -> Pid;
              [{_, NPid}] -> NPid
            end;
      _ -> Pid
  end.


%% Special instruction running control (e.g. send to unknown -> wait for reply)
run_built_in(erlang, demonitor, 1, [Ref], Info) ->
  run_built_in(erlang, demonitor, 2, [Ref, []], Info);
run_built_in(erlang, demonitor, 2, [Ref, Options], Info) ->
  ?badarg_if_not(is_reference(Ref)),
  #concuerror_info{monitors = Monitors} = Info,
  {Result, NewInfo} =
    case ets:match(Monitors, ?monitor_match_to_target_source(Ref)) of
      [] ->
        PatternFun =
          fun(M) ->
              case M of
                {'DOWN', Ref, process, _, _} -> true;
                _ -> false
              end
          end,
        case lists:member(flush, Options) of
          true ->
            {Match, FlushInfo} =
              has_matching_or_after(PatternFun, infinity, foo, Info, non_blocking),
            {Match =/= false, FlushInfo};
          false ->
            {false, Info}
        end;
      [[Target, Source]] ->
        ?badarg_if_not(Source =:= self()),
        true = ets:delete_object(Monitors, ?monitor(Ref, Target, Source, active)),
        true = ets:insert(Monitors, ?monitor(Ref, Target, Source, inactive)),
        {not lists:member(flush, Options), Info}
    end,
  case lists:member(info, Options) of
    true -> {Result, NewInfo};
    false -> {true, NewInfo}
  end;
run_built_in(erlang, exit, 2, [NPid, Reason],
             #concuerror_info{
                next_event = #event{event_info = EventInfo} = Event
               } = Info) ->
  ?badarg_if_not(is_pid(NPid)),
  Pid = translate_pid(NPid, Info),
  case EventInfo of
    %% Replaying...
    #builtin_event{result = OldResult} -> {OldResult, Info};
    %% New event...
    undefined ->
      Message =
        #message{data = {'EXIT', self(), Reason}, message_id = make_ref()},
      MessageEvent =
        #message_event{
           cause_label = Event#event.label,
           message = Message,
           recipient = Pid,
           type = exit_signal},
      NewEvent = Event#event{special = {message, MessageEvent}},
      {true, Info#concuerror_info{next_event = NewEvent}}
  end;

run_built_in(erlang, halt, _, _, Info) ->
  #concuerror_info{next_event = Event} = Info,
  NewEvent = Event#event{special = halt},
  {no_return, Info#concuerror_info{next_event = NewEvent}};

run_built_in(erlang, is_process_alive, 1, [NPid], Info) ->
  ?badarg_if_not(is_pid(NPid)),
  #concuerror_info{processes = Processes} = Info,
  Pid = translate_pid(NPid, Info),
  Return =
    case ets:lookup(Processes, Pid) of
      [] ->  throw (unknown_process);
      [?process_pat_pid_status(Pid, Status)] -> is_active(Status)
    end,
  {Return, Info};

run_built_in(erlang, link, 1, [NPid], Info) ->
  Pid = translate_pid(NPid, Info),
  #concuerror_info{
     flags = #process_flags{trap_exit = TrapExit},
     links = Links,
     next_event = #event{event_info = EventInfo} = Event} = Info,
  case run_built_in(erlang, is_process_alive, 1, [Pid], Info) of
    {true, Info}->
      Self = self(),
      true = ets:insert(Links, ?links(Self, Pid)),
      {true, Info};
    {false, _} ->
      case TrapExit of
        false -> error(noproc);
        true ->
          NewInfo =
            case EventInfo of
              %% Replaying...
              #builtin_event{} -> Info;
              %% New event...
              undefined ->
                Message =
                  #message{data = {'EXIT', Pid, noproc},
                           message_id = make_ref()},
                MessageEvent =
                  #message_event{
                     cause_label = Event#event.label,
                     message = Message,
                     recipient = self()},
                NewEvent = Event#event{special = {message, MessageEvent}},
                Info#concuerror_info{next_event = NewEvent}
            end,
          {true, NewInfo}
      end
  end;

run_built_in(erlang, make_ref, 0, [], Info) ->
  #concuerror_info{next_event = #event{event_info = EventInfo}} = Info,
  Ref =
    case EventInfo of
      %% Replaying...
      #builtin_event{result = OldResult} -> OldResult;
      %% New event...
      undefined -> make_ref()
    end,
  {Ref, Info};
run_built_in(erlang, monitor, 2, [Type, NPid], Info) ->
  Pid = translate_pid(NPid, Info),
  #concuerror_info{
     monitors = Monitors,
     next_event = #event{event_info = EventInfo} = Event} = Info,
  ?badarg_if_not(Type =:= process andalso is_pid(Pid)),
  Ref =
    case EventInfo of
      %% Replaying...
      #builtin_event{result = OldResult} -> OldResult;
      %% New event...
      undefined -> make_ref()
    end,
  {IsActive, Info} = run_built_in(erlang, is_process_alive, 1, [Pid], Info),
  case IsActive of
    true -> true = ets:insert(Monitors, ?monitor(Ref, Pid, self(), active));
    false -> ok
  end,
  NewInfo =
    case EventInfo of
      %% Replaying...
      #builtin_event{} -> Info;
      %% New event...
      undefined ->
        case IsActive of
          false ->
            Message =
              #message{data = {'DOWN', Ref, process, Pid, noproc},
                       message_id = make_ref()},
            MessageEvent =
              #message_event{
                 cause_label = Event#event.label,
                 message = Message,
                 recipient = self()},
            NewEvent = Event#event{special = {message, MessageEvent}},
            Info#concuerror_info{next_event = NewEvent};
          true -> Info
        end
    end,
  {Ref, NewInfo};
run_built_in(erlang, process_info, 2, [NPid, Item], Info) when is_atom(Item) ->
  Pid = translate_pid(NPid, Info),
  TheirInfo =
    case Pid =:= self() of
      true -> Info;
      false ->
        case process_info(Pid, dictionary) of
          [] -> throw(inspecting_the_process_dictionary_of_a_system_process);
          {dictionary, [{concuerror_info, Dict}]} -> Dict
        end
    end,
  Res =
    case Item of
      dictionary ->
        #concuerror_info{escaped_pdict = Escaped} = TheirInfo,
        Escaped;
      links ->
        #concuerror_info{links = Links} = TheirInfo,
        try ets:lookup_element(Links, Pid, 2)
        catch error:badarg -> []
        end;
      messages ->
        #concuerror_info{messages_new = Queue} = TheirInfo,
        [M || #message{data = M} <- queue:to_list(Queue)];
      registered_name ->
        #concuerror_info{processes = Processes} = TheirInfo,
        [?process_pat_pid_name(Pid, Name)] = ets:lookup(Processes, Pid),
        case Name =:= ?process_name_none of
          true -> [];
          false -> {Item, Name}
        end;
      status ->
        #concuerror_info{status = Status} = TheirInfo,
        Status;
      trap_exit ->
        TheirInfo#concuerror_info.flags#process_flags.trap_exit;
      ExpectsANumber when
          ExpectsANumber =:= heap_size;
          ExpectsANumber =:= reductions;
          ExpectsANumber =:= stack_size;
          false ->
        42;
      _ ->
        throw({unsupported_process_info, Item})
    end,
  {Res, Info};
run_built_in(erlang, register, 2, [Name, Pid],
             #concuerror_info{processes = Processes} = Info) ->
  try
    true = is_atom(Name),
    {true, Info} = run_built_in(erlang, is_process_alive, 1, [Pid], Info),
    [] = ets:match(Processes, ?process_match_name_to_pid(Name)),
    ?process_name_none = ets:lookup_element(Processes, Pid, ?process_name),
    false = undefined =:= Name,
    true = ets:update_element(Processes, Pid, {?process_name, Name}),
    {true, Info}
  catch
    _:_ -> error(badarg)
  end;
run_built_in(erlang, spawn, 3, [M, F, Args], Info) ->
  run_built_in(erlang, spawn_opt, 1, [{M, F, Args, []}], Info);
run_built_in(erlang, spawn_link, 3, [M, F, Args], Info) ->
  run_built_in(erlang, spawn_opt, 1, [{M, F, Args, [link]}], Info);
run_built_in(erlang, spawn_opt, 1, [{Module, Name, Args, SpawnOpts}], Info) ->
  io:format("~p Spawning new process for ~p:~p~n", [self(), Module, Name]),
  #concuerror_info{next_event = Event, processes = Processes} = Info,
  #event{event_info = EventInfo} = Event,
  Parent = self(),
  {Result, NewInfo} =
    case EventInfo of
      %% Replaying...
      #builtin_event{result = OldResult} -> {OldResult, Info};
      %% New event...
      undefined ->
        PassedInfo = init_concuerror_info(Info),
        ?debug_flag(?spawn, {Parent, spawning_new, PassedInfo}),
        ParentSymbol = ets:lookup_element(Processes, Parent, ?process_symbolic),
        ChildId = ets:update_counter(Processes, Parent, {?process_children, 1}),
        ChildSymbol = io_lib:format("~s.~w",[ParentSymbol, ChildId]),
        P = spawn_link(fun() -> process_top_loop(PassedInfo) end),
        true = ets:insert(Processes, ?new_process(P, ChildSymbol)),
        NewResult =
          case lists:member(monitor, SpawnOpts) of
            true -> {P, make_ref()};
            false -> P
          end,
        NewEvent = Event#event{special = {new, P}},
        {NewResult, Info#concuerror_info{next_event = NewEvent}}
    end,
  case lists:member(monitor, SpawnOpts) of
    true ->
      {Pid, Ref} = Result,
      #concuerror_info{monitors = Monitors} = Info,
      true = ets:insert(Monitors, ?monitor(Ref, Pid, Parent, active));
    false ->
      Pid = Result
  end,
  case lists:member(link, SpawnOpts) of
    true ->
      #concuerror_info{links = Links} = Info,
      true = ets:insert(Links, ?links(Parent, Pid));
    false -> ok
  end,
  Pid ! {start, Module, Name, Args},
  {Result, NewInfo};
run_built_in(erlang, Send, 2, [Recipient, Message], Info)
  when Send =:= '!'; Send =:= 'send' ->
  run_built_in(erlang, send, 3, [Recipient, Message, []], Info);
run_built_in(erlang, send, 3, [Recipient, Message, _Options],
             #concuerror_info{
                next_event = #event{event_info = EventInfo} = Event
               } = Info) ->
  Pid =
    case is_pid(Recipient) of
      true -> translate_pid(Recipient, Info);
      false ->
        {P, Info} = run_built_in(erlang, whereis, 1, [Recipient], Info),
        P
    end,
  ?badarg_if_not(is_pid(Pid)),
  case EventInfo of
    %% Replaying...
    #builtin_event{result = OldResult} -> {OldResult, Info};
    %% New event...
    undefined ->
      ?debug_flag(?send, {send, Recipient, Message}),
      MessageEvent =
        #message_event{
           cause_label = Event#event.label,
           message = #message{data = Message, message_id = make_ref()},
           recipient = Pid},
      NewEvent = Event#event{special = {message, MessageEvent}},
      ?debug_flag(?send, {send, successful}),
      {Message, Info#concuerror_info{next_event = NewEvent}}
  end;
run_built_in(erlang, process_flag, 2, [Flag, Value],
             #concuerror_info{flags = Flags} = Info) ->
  {Result, NewInfo} =
    case Flag of
      trap_exit ->
        ?badarg_if_not(is_boolean(Value)),
        {Flags#process_flags.trap_exit,
         Info#concuerror_info{flags = Flags#process_flags{trap_exit = Value}}};
      priority ->
        ?badarg_if_not(lists:member(Value, [low,normal,high,max])),
        {Flags#process_flags.priority,
         Info#concuerror_info{flags = Flags#process_flags{priority = Value}}}
    end,
  {Result, NewInfo};
run_built_in(erlang, unlink, 1, [NPid], #concuerror_info{links = Links} = Info) ->
  Self = self(),
  Pid = translate_pid(NPid, Info),
  [true,true] = [ets:delete_object(Links, L) || L <- ?links(Self, Pid)],
  {true, Info};
run_built_in(erlang, unregister, 1, [Name],
             #concuerror_info{processes = Processes} = Info) ->
  try
    [[Pid]] = ets:match(Processes, ?process_match_name_to_pid(Name)),
    true =
      ets:update_element(Processes, Pid, {?process_name, ?process_name_none}),
    NewInfo = Info#concuerror_info{extra = Pid},
    {true, NewInfo}
  catch
    _:_ -> error(badarg)
  end;
run_built_in(erlang, whereis, 1, [Name],
             #concuerror_info{processes = Processes} = Info) ->
  case ets:match(Processes, ?process_match_name_to_pid(Name)) of
    [] ->
      case whereis(Name) =:= undefined of
        true -> {undefined, Info};
        false -> throw({system_process_not_wrapped, Name})
      end;
    [[Pid]] -> {Pid, Info}
  end;
run_built_in(ets, new, 2, [Name, Options], Info) ->
  ?badarg_if_not(is_atom(Name)),
  NoNameOptions = [O || O <- Options, O =/= named_table],
  #concuerror_info{
     ets_tables = EtsTables,
     next_event = #event{event_info = EventInfo},
     scheduler = Scheduler
    } = Info,
  Named =
    case Options =/= NoNameOptions of
      true ->
        ?badarg_if_not(ets:match(EtsTables, ?ets_match_name(Name)) =:= []),
        true;
      false -> false
    end,
  Tid =
    case EventInfo of
      %% Replaying...
      #builtin_event{extra = Extra} -> Extra;
      %% New event...
      undefined ->
        %% Looks like the last option is the one actually used.
        T = ets:new(Name, NoNameOptions ++ [public]),
        true = ets:give_away(T, Scheduler, given_to_scheduler),
        T
    end,
  ProtectFold =
    fun(Option, Selected) ->
        case Option of
          O when O =:= 'private';
                 O =:= 'protected';
                 O =:= 'public' -> O;
          _ -> Selected
        end
    end,
  Protection = lists:foldl(ProtectFold, protected, NoNameOptions),
  true = ets:insert(EtsTables, ?new_ets_table(Tid, Protection)),
  Ret =
    case Named of
      true -> Name;
      false -> Tid
    end,
  Heir =
    case proplists:lookup(heir, Options) of
      none -> {heir, none};
      Other -> Other
    end,
  Update =
    [{?ets_alive, true},
     {?ets_heir, Heir},
     {?ets_owner, self()},
     {?ets_name, Ret}],
  ets:update_element(EtsTables, Tid, Update),
  ets:delete_all_objects(Tid),
  {Ret, Info#concuerror_info{extra = Tid}};
run_built_in(ets, info, _, [Name|Rest], Info) ->
  try
    Tid = check_ets_access_rights(Name, info, Info),
    {erlang:apply(ets, info, [Tid|Rest]), Info#concuerror_info{extra = Tid}}
  catch
    error:badarg -> {undefined, Info}
  end;
run_built_in(ets, F, N, [Name|Args], Info)
  when
    false
    ;{F,N} =:= {delete, 2}
    ;{F,N} =:= {insert, 2}
    ;{F,N} =:= {insert_new, 2}
    ;{F,N} =:= {lookup, 2}
    ;{F,N} =:= {match, 2}
    ;{F,N} =:= {member, 2}
    ;{F,N} =:= {select, 2}
    ;{F,N} =:= {select, 3}
    ;{F,N} =:= {select_delete, 2}
    ->
  Tid = check_ets_access_rights(Name, {F,N}, Info),
  {erlang:apply(ets, F, [Tid|Args]), Info#concuerror_info{extra = Tid}};
run_built_in(ets, delete, 1, [Name], Info) ->
  Tid = check_ets_access_rights(Name, {delete,1}, Info),
  #concuerror_info{ets_tables = EtsTables} = Info,
  ets:update_element(EtsTables, Tid, [{?ets_alive, false}]),
  ets:delete_all_objects(Tid),
  {true, Info#concuerror_info{extra = Tid}};
run_built_in(ets, give_away, 3, [Name, Pid, GiftData],
             #concuerror_info{
                next_event = #event{event_info = EventInfo} = Event
               } = Info) ->
  Tid = check_ets_access_rights(Name, {give_away,3}, Info),
  #concuerror_info{ets_tables = EtsTables} = Info,
  {Alive, Info} = run_built_in(erlang, is_process_alive, 1, [Pid], Info),
  Self = self(),
  ?badarg_if_not(is_pid(Pid) andalso Pid =/= Self andalso Alive),
  NewInfo =
    case EventInfo of
      %% Replaying. Keep original Message reference.
      #builtin_event{} -> Info;
      %% New event...
      undefined ->
        MessageEvent =
          #message_event{
             cause_label = Event#event.label,
             message =
               #message{
                  data = {'ETS-TRANSFER', Tid, Self, GiftData},
                  message_id = make_ref()},
             recipient = Pid},
        NewEvent = Event#event{special = {message, MessageEvent}},
        Info#concuerror_info{next_event = NewEvent}
    end,
  Update = [{?ets_owner, Pid}],
  true = ets:update_element(EtsTables, Tid, Update),
  {true, NewInfo#concuerror_info{extra = Tid}};
%% run_built_in(ets, Other, N, Args, _Info) ->
%%  throw({uninstrumented, ets, Other, N, Args});

%% For other built-ins check whether replaying has the same result:
run_built_in(Module, Name, Arity, Args, Info) ->
  #concuerror_info{next_event =
                     #event{event_info = EventInfo,
                            location = Location}
                  } = Info,
  NewResult = erlang:apply(Module, Name, Args),
  case EventInfo of
    %% Replaying...
    #builtin_event{mfa = {M,F,OArgs}, result = OldResult} ->
      case OldResult =:= NewResult of
        true  -> {OldResult, Info};
        false ->
          #concuerror_info{logger = Logger} = Info,
          case M =:= Module andalso F =:= Name andalso Args =:= OArgs of
            true ->
              ?log(Logger, ?lerror,
                   "~nWhile re-running the program, a call to ~p:~p/~p with"
                   " arguments:~n  ~p~nreturned a different result:~n"
                   "Earlier result: ~p~n"
                   "  Later result: ~p~n"
                   "Concuerror cannot explore behaviours that depend on~n"
                   "data that may differ on separate runs of the program.~n"
                   "Location: ~p~n~n",
                   [Module, Name, Arity, Args, OldResult, NewResult, Location]),
              throw(inconsistent_builtin_behaviour);
            false ->
              ?log(Logger, ?lerror,
                   "~nWhile re-running the program, a call to ~p:~p/~p with"
                   " arguments:~n  ~p~nwas found instead of the original call~n"
                   "to ~p:~p/~p with args:~n  ~p~n"
                   "Concuerror cannot explore behaviours that depend on~n"
                   "data that may differ on separate runs of the program.~n"
                   "Location: ~p~n~n",
                   [Module, Name, Arity, Args, M, F,
                    length(OArgs), OArgs, Location]),
              throw(inconsistent_builtin_behaviour)
          end
      end;
    undefined ->
      {NewResult, Info}
  end.

%%------------------------------------------------------------------------------

handle_receive(PatternFun, Timeout, Location, Info) ->
  %% No distinction between replaying/new as we have to clear the message from
  %% the queue anyway...
  {MessageOrAfter, ReceiveInfo} =
    has_matching_or_after(PatternFun, Timeout, Location, Info, blocking),
  #concuerror_info{
     next_event = NextEvent,
     flags = #process_flags{trap_exit = Trapping}
    } = UpdatedInfo =
    add_location_info(Location, ReceiveInfo),
  ReceiveEvent =
    #receive_event{
       message = MessageOrAfter,
       patterns = PatternFun,
       timeout = Timeout,
       trapping = Trapping},
  {Special, CreateMessage} =
    case MessageOrAfter of
      #message{data = Data, message_id = Id} ->
        {{message_received, Id, PatternFun}, {ok, Data}};
      'after' -> {none, false}
    end,
  Notification =
    NextEvent#event{event_info = ReceiveEvent, special = Special},
  case CreateMessage of
    {ok, D} ->
      ?debug_flag(?receive_, {deliver, D}),
      self() ! D;
    false -> ok
  end,
  {skip_timeout, notify(Notification, UpdatedInfo)}.

has_matching_or_after(PatternFun, Timeout, Location, InfoIn, Mode) ->
  {Result, NewOldMessages} = has_matching_or_after(PatternFun, Timeout, InfoIn),
  UpdatedInfo = update_messages(Result, NewOldMessages, InfoIn),
  case Mode of
    non_blocking -> {Result, UpdatedInfo};
    blocking ->
      case Result =:= false of
        true ->
          NewInfo =
            case InfoIn#concuerror_info.status =:= waiting of
              true ->
                process_loop(notify({blocked, Location}, UpdatedInfo));
              false ->
                process_loop(set_status(UpdatedInfo, waiting))
            end,
          has_matching_or_after(PatternFun, Timeout, Location, NewInfo, Mode);
        false ->
          NewInfo = process_loop(InfoIn),
          {FinalResult, FinalNewOldMessages} =
            has_matching_or_after(PatternFun, Timeout, NewInfo),
          FinalInfo = update_messages(Result, FinalNewOldMessages, NewInfo),
          {FinalResult, FinalInfo}
      end
  end.

update_messages(Result, NewOldMessages, Info) ->
  case Result =:= false of
    true ->
      Info#concuerror_info{
        messages_new = queue:new(),
        messages_old = NewOldMessages};
    false ->
      Info#concuerror_info{
        messages_new = NewOldMessages,
        messages_old = queue:new()}
  end.

has_matching_or_after(PatternFun, Timeout, Info) ->
  #concuerror_info{messages_new = NewMessages,
                   messages_old = OldMessages} = Info,
  {Result, NewOldMessages} =
    fold_with_patterns(PatternFun, NewMessages, OldMessages),
  AfterOrMessage =
    case Result =:= false of
      false -> Result;
      true ->
        case Timeout =:= infinity of
          false -> 'after';
          true -> false
        end
    end,
  {AfterOrMessage, NewOldMessages}.

fold_with_patterns(PatternFun, NewMessages, OldMessages) ->
  {Value, NewNewMessages} = queue:out(NewMessages),
  ?debug_flag(?receive_, {inspect, Value}),
  case Value of
    {value, #message{data = Data} = Message} ->
      case PatternFun(Data) of
        true  ->
          ?debug_flag(?receive_, matches),
          {Message, queue:join(OldMessages, NewNewMessages)};
        false ->
          ?debug_flag(?receive_, doesnt_match),
          NewOldMessages = queue:in(Message, OldMessages),
          fold_with_patterns(PatternFun, NewNewMessages, NewOldMessages)
      end;
    empty ->
      {false, OldMessages}
  end.

%%------------------------------------------------------------------------------

notify(Notification, #concuerror_info{scheduler = Scheduler} = Info) ->
  io:format("~p notifying ~p ~p~n", [self(), Scheduler, Notification]),
  Scheduler ! Notification,
  Info.

-spec process_top_loop(concuerror_info()) -> no_return().

process_top_loop(Info) ->
  ?debug_flag(?wait, top_waiting),
  io:format("~p in process_top_loop waiting for start~n", [self()]),
  receive
    {start, Module, Name, Args} ->
      ?debug_flag(?wait, {start, Module, Name, Args}),
      io:format("~p told to start ~p:~p~n", [self(), Module, Name]),
      %% It is ok for this load to fail
      concuerror_loader:load(Module, Info#concuerror_info.modules),
      put(concuerror_info, Info),
      try
        erlang:apply(Module, Name, Args),
        exit(normal)
      catch
        Class:Reason ->
          case erase(concuerror_info) of
            #concuerror_info{escaped_pdict = Escaped} = EndInfo ->
              lists:foreach(fun({K,V}) -> put(K,V) end, Escaped),
              Stacktrace = fix_stacktrace(EndInfo),
              ?debug_flag(?exit, {exit, Class, Reason, Stacktrace}),
              NewReason =
                case Class of
                  throw -> {{nocatch, Reason}, Stacktrace};
                  error -> {Reason, Stacktrace};
                  exit  -> Reason
                end,
              exiting(NewReason, Stacktrace, EndInfo);
            _ -> exit({process_crashed, Class, Reason, erlang:get_stacktrace()})
          end
      end
  end.

process_loop(Info) ->
  ?debug_flag(?wait, waiting),
  io:format("~p in process_loop now~n", [self()]),
  receive
    #event{event_info = EventInfo} = Event ->
      io:format("~p in process_loop now, received event ~p~n", [self(), Event]),
      Status = Info#concuerror_info.status,
      case Status =:= exited of
        true ->
          io:format("~p in process_loop now, notifying exit~n", [self()]),
          process_loop(notify(exited, Info));
        false ->
          NewInfo = Info#concuerror_info{next_event = Event},
          case EventInfo of
            undefined ->
              ?debug_flag(?wait, {waiting, exploring}),
              NewInfo;
            _OtherReplay ->
              ?debug_flag(?wait, {waiting, replaying}),
              NewInfo
          end
      end;
    {exit_signal, #message{data = {'EXIT', _From, Reason}} = Message} ->
      Scheduler = Info#concuerror_info.scheduler,
      Trapping = Info#concuerror_info.flags#process_flags.trap_exit,
      case is_active(Info) andalso not Info#concuerror_info.caught_signal of
        true ->
          case Reason =:= kill of
            true ->
              ?debug_flag(?wait, {waiting, kill_signal}),
              Scheduler ! {trapping, Trapping},
              exiting(killed, [], Info#concuerror_info{caught_signal = true});
            false ->
              case Trapping of
                true ->
                  ?debug_flag(?trap, {waiting, signal_trapped}),
                  self() ! {message, Message},
                  process_loop(Info);
                false ->
                  Scheduler ! {trapping, Trapping},
                  case Reason =:= normal of
                    true ->
                      ?debug_flag(?wait, {waiting, normal_signal_ignored}),
                      process_loop(Info);
                    false ->
                      ?debug_flag(?wait, {waiting, exiting_signal}),
                      exiting(Reason, [], Info#concuerror_info{caught_signal = true})
                  end
              end
          end;
        false ->
          Scheduler ! {trapping, Trapping},
          process_loop(Info)
      end;
    {message, Message} ->
      io:format("~p in process_loop now, received message ~p~n", [self(), Message]),
      ?debug_flag(?wait, {waiting, got_message}),
      Scheduler = Info#concuerror_info.scheduler,
      Trapping = Info#concuerror_info.flags#process_flags.trap_exit,
      Scheduler ! {trapping, Trapping},
      io:format("~p in process_loop now, told scheduler (~p) {trapping, ~p}~n", [self(), Scheduler, Trapping]),
      case is_active(Info) of
        true ->
          ?debug_flag(?receive_, {message_enqueued, Message}),
          Old = Info#concuerror_info.messages_new,
          NewInfo =
            Info#concuerror_info{
              messages_new = queue:in(Message, Old)
             },
          case NewInfo#concuerror_info.status =:= waiting of
            true -> NewInfo#concuerror_info{status = running};
            false -> process_loop(NewInfo)
          end;
        false ->
          ?debug_flag(?receive_, {message_ignored, Info#concuerror_info.status}),
          process_loop(Info)
      end;
    reset ->
      ?debug_flag(?wait, {waiting, reset}),
      NewInfo =
        #concuerror_info{
           ets_tables = EtsTables,
           links = Links,
           monitors = Monitors,
           processes = Processes} = init_concuerror_info(Info),
      _ = erase(),
      Symbol = ets:lookup_element(Processes, self(), ?process_symbolic),
      ets:insert(Processes, ?new_process(self(), Symbol)),
      ets:match_delete(EtsTables, ?ets_match_mine()),
      ets:match_delete(Links, ?links_match_mine()),
      ets:match_delete(Monitors, ?monitors_match_mine()),
      erlang:hibernate(concuerror_callback, process_top_loop, [NewInfo]);
    deadlock_poll ->
      Info
  end.

%%------------------------------------------------------------------------------

exiting(Reason, Stacktrace, #concuerror_info{status = Status} = InfoIn) ->
  %% XXX: The ordering of the following events has to be verified (e.g. R16B03):
  %% XXX:  - process marked as exiting, new messages are not delivered, name is
  %%         unregistered
  %% XXX:  - cancel timers
  %% XXX:  - transfer ets ownership and send message or delete table
  %% XXX:  - send link signals
  %% XXX:  - send monitor messages
  Info = process_loop(InfoIn),
  ?debug_flag(?exit, {going_to_exit, Reason}),
  Self = self(),
  {MaybeName, Info} =
    run_built_in(erlang, process_info, 2, [Self, registered_name], Info),
  LocatedInfo = #concuerror_info{next_event = Event} =
    add_location_info(exit, set_status(Info, exiting)),
  #concuerror_info{
     links = LinksTable,
     monitors = MonitorsTable,
     flags = #process_flags{trap_exit = Trapping}} = Info,
  FetchFun =
    fun(Table) ->
        [begin ets:delete_object(Table, E), {D, S} end ||
          {_, D, S} = E <- ets:lookup(Table, Self)]
    end,
  Links = FetchFun(LinksTable),
  Monitors = FetchFun(MonitorsTable),
  Name =
    case MaybeName of
      [] -> ?process_name_none;
      {registered_name, N} -> N
    end,
  Notification =
    Event#event{
      event_info =
        #exit_event{
           links = [L || {L, _} <- Links],
           monitors = [M || {M, _} <- Monitors],
           name = Name,
           reason = Reason,
           stacktrace = Stacktrace,
           status = Status,
           trapping = Trapping
          }
     },
  ExitInfo = add_location_info(exit, notify(Notification, LocatedInfo)),
  FunFold = fun(Fun, Acc) -> Fun(Acc) end,
  FunList =
    [fun ets_ownership_exiting_events/1,
     link_monitor_handlers(fun handle_link/3, Links),
     link_monitor_handlers(fun handle_monitor/3, Monitors)],
  FinalInfo =
    lists:foldl(FunFold, ExitInfo#concuerror_info{exit_reason = Reason}, FunList),
  process_loop(set_status(FinalInfo, exited)).

ets_ownership_exiting_events(Info) ->
  %% XXX:  - transfer ets ownership and send message or delete table
  %% XXX: Mention that order of deallocation/transfer is not monitored.
  #concuerror_info{ets_tables = EtsTables} = Info,
  case ets:match(EtsTables, ?ets_match_owner_to_name_heir(self())) of
    [] -> Info;
    Tables ->
      Fold =
        fun([Tid, HeirSpec], InfoIn) ->
            MFArgs =
              case HeirSpec of
                {heir, none} ->
                  ?debug_flag(?heir, no_heir),
                  [ets, delete, [Tid]];
                {heir, Pid, Data} ->
                  ?debug_flag(?heir, {using_heir, Tid, HeirSpec}),
                  [ets, give_away, [Tid, Pid, Data]]
              end,
            case instrumented(call, MFArgs, exit, InfoIn) of
              {{didit, true}, NewInfo} -> NewInfo;
              {_, OtherInfo} ->
                ?debug_flag(?heir, {problematic_heir, Tid, HeirSpec}),
                {{didit, true}, NewInfo} =
                  instrumented(call, [ets, delete, [Tid]], exit, OtherInfo),
                NewInfo
            end
        end,
      lists:foldl(Fold, Info, Tables)
  end.

handle_link(Link, Reason, InfoIn) ->
  MFArgs = [erlang, exit, [Link, Reason]],
  {{didit, true}, NewInfo} =
    instrumented(call, MFArgs, exit, InfoIn),
  NewInfo.

handle_monitor({Ref, P}, Reason, InfoIn) ->
  Msg = {'DOWN', Ref, process, self(), Reason},
  MFArgs = [erlang, send, [P, Msg]],
  {{didit, Msg}, NewInfo} =
    instrumented(call, MFArgs, exit, InfoIn),
  NewInfo.

link_monitor_handlers(Handler, LinksOrMonitors) ->
  fun(Info) ->
      #concuerror_info{exit_reason = Reason} = Info,
      HandleActive =
        fun({LinkOrMonitor, S}, InfoIn) ->
            case S =:= active of
              true -> Handler(LinkOrMonitor, Reason, InfoIn);
              false -> InfoIn
            end
        end,
      lists:foldl(HandleActive, Info, LinksOrMonitors)
  end.

%%------------------------------------------------------------------------------

check_ets_access_rights(Name, Op, Info) ->
  #concuerror_info{ets_tables = EtsTables} = Info,
  case ets:match(EtsTables, ?ets_match_name(Name)) of
    [] -> error(badarg);
    [[Tid,Owner,Protection]] ->
      Test =
        (Owner =:= self()
         orelse
         case ets_ops_access_rights_map(Op) of
           none  -> true;
           own   -> false;
           read  -> Protection =/= private;
           write -> Protection =:= public
         end),
      ?badarg_if_not(Test),
      Tid
  end.

ets_ops_access_rights_map(Op) ->
  case Op of
    {delete       ,1} -> own;
    {delete       ,2} -> write;
    {give_away    ,_} -> own;
    {info         ,_} -> none;
    {insert       ,_} -> write;
    {insert_new   ,_} -> write;
    {lookup       ,_} -> read;
    {match        ,_} -> read;
    {member       ,_} -> read;
    {select       ,_} -> read;
    {select_delete,_} -> write
  end.

%%------------------------------------------------------------------------------

system_ets_entries(EtsTables) ->
  Map = fun(Tid) -> ?new_system_ets_table(Tid, ets:info(Tid, protection)) end,
  ets:insert(EtsTables, [Map(Tid) || Tid <- ets:all(), is_atom(Tid)]).

system_processes_wrappers(Processes, SProcesses) ->
  Scheduler = self(),
  GroupLeaders = [{Me, erlang:whereis(Me)} || Me <- registered()],
  io:format("Group leader information ~p~n~n", [GroupLeaders]),
  Map =
    fun(Name) ->
        Fun = fun() -> system_wrapper_loop(Name, whereis(Name), Scheduler) end,
        Pid = spawn_link(Fun),
        {whereis(Name), {Pid, Name}}
    end,
  SystemProcesses = [Map(Name) || Name <- registered()],
  ets:insert(Processes, [?new_system_process(Pid, Name) || {_, {Pid, Name}} <- SystemProcesses]),
  ets:insert(SProcesses, [{OldPid, NewPid} || {OldPid, {NewPid, _}} <- SystemProcesses]).

system_wrapper_loop(Name, Wrapped, Scheduler) ->
  receive
    {message,
     #message{data = Data, message_id = Id}} ->
      case Name of
        init ->
          {From, Request} = Data,
          io:format("Sending to init, ~p~n", [Data]),
          erlang:send(Wrapped, {self(), Request}),
          receive
            Msg ->
              Scheduler ! {system_reply, From, Id, Msg},
              ok
          end;
        error_logger ->
          erlang:send(Wrapped, Data),
          Scheduler ! {trapping, false},
          ok;
        _ ->
          case Data of
            {'$gen_call', {From, Mref}, Request} ->
                io:format("Sending to unknown process ~p~n", [Name]),
                io:format("Call is gen_call ~p~n", [Data]),
                NewMsg = {'$gen_call', {self(), Mref}, Request},
                erlang:send(Wrapped, NewMsg),
                receive
                  Msg ->
                    Scheduler ! {system_reply, From, Id, Msg},
                    ok
                end;
             _ -> 
                io:format("Sending to unknown process ~p~n", [Name]),
                io:format("Data is ~p~n", [Data]),
                erlang:send(Wrapped, Data),
                Scheduler ! {trapping, false},
                ok
        end
      end
  end,
  system_wrapper_loop(Name, Wrapped, Scheduler).

init_concuerror_info(Info) ->
  #concuerror_info{
     'after-timeout' = AfterTimeout,
     ets_tables = EtsTables,
     links = Links,
     logger = Logger,
     modules = Modules,
     monitors = Monitors,
     processes = Processes,
     sprocesses = SProcesses,
     scheduler = Scheduler
    } = Info,
  #concuerror_info{
     'after-timeout' = AfterTimeout,
     ets_tables = EtsTables,
     links = Links,
     logger = Logger,
     modules = Modules,
     monitors = Monitors,
     processes = Processes,
     sprocesses = SProcesses,
     scheduler = Scheduler
    }.

%% reset_stack(#concuerror_info{stack = Stack} = Info) ->
%%   {Stack, Info#concuerror_info{stack = []}}.

%% append_stack(Value, #concuerror_info{stack = Stack} = Info) ->
%%   Info#concuerror_info{stack = [Value|Stack]}.

%%------------------------------------------------------------------------------

add_location_info(Location, #concuerror_info{next_event = Event} = Info) ->
  Info#concuerror_info{next_event = Event#event{location = Location}}.

set_status(#concuerror_info{processes = Processes} = Info, Status) ->
  MaybeDropName =
    case Status =:= exiting of
      true -> [{?process_name, ?process_name_none}];
      false -> []
    end,
  Updates = [{?process_status, Status}|MaybeDropName],
  true = ets:update_element(Processes, self(), Updates),
  Info#concuerror_info{status = Status}.

is_active(#concuerror_info{status = Status}) ->
  is_active(Status);
is_active(Status) when is_atom(Status) ->
  (Status =:= running) orelse (Status =:= waiting).

fix_stacktrace(#concuerror_info{stacktop = Top}) ->
  RemoveSelf = lists:keydelete(?MODULE, 1, erlang:get_stacktrace()),
  case lists:keyfind(concuerror_inspect, 1, RemoveSelf) of
    false -> RemoveSelf;
    _ ->
      RemoveInspect = lists:keydelete(concuerror_inspect, 1, RemoveSelf),
      [Top|RemoveInspect]
  end.
