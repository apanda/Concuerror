%% -*- erlang-indent-level: 2 -*-

-module(concuerror_callback).

%% Interface to concuerror_inspect:
-export([instrumented_top/4]).

%% Interface to scheduler:
-export([spawn_first_process/2, spawn_first_process/1, start_first_process/3, start_instrument_only_process/2, 
         deliver_message/3, wait_actor_reply/2, collect_deadlock_info/1]).

%% Interface for resetting:
-export([process_top_loop/1]).

-export([explain_error/1]).

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
-define(loop, ?flag(10)).
-define(send, ?flag(11)).
-define(exit, ?flag(12)).
-define(trap, ?flag(13)).
-define(undefined, ?flag(14)).
-define(heir, ?flag(15)).
-define(notify, ?flag(16)).

-define(ACTIVE_FLAGS, [?undefined]).

%% -define(DEBUG, true).
-define(DEBUG_FLAGS, lists:foldl(fun erlang:'bor'/2, 0, ?ACTIVE_FLAGS)).

-define(badarg_if_not(A), case A of true -> ok; false -> error(badarg) end).
%%------------------------------------------------------------------------------

-include("concuerror.hrl").


-spec spawn_first_process(options()) -> pid().

spawn_first_process(Options) ->
  spawn_first_process(Options, self()).

-spec spawn_first_process(options(), pid()) -> pid().

spawn_first_process(Options, Sched) ->
  [AfterTimeout, InstantDelivery, Logger, Modules, Processes,
   ReportUnknown, Timeout, Instrumented] =
    concuerror_common:get_properties(
      [after_timeout, instant_delivery, logger, modules, processes,
       report_unknown, timeout, instrumented],
      Options),
  EtsTables = ets:new(ets_tables, [public]),
  ets:insert(EtsTables, {tid,1}),
  Info =
    #concuerror_info{
       after_timeout  = AfterTimeout,
       ets_tables     = EtsTables,
       instant_delivery = InstantDelivery,
       links          = ets:new(links, [bag, public]),
       logger         = Logger,
       modules        = Modules,
       monitors       = ets:new(monitors, [bag, public]),
       processes      = Processes,
       report_unknown = ReportUnknown,
       scheduler      = Sched,
       timeout        = Timeout,
       is_instrument_only = Instrumented
      },
  system_processes_wrappers(Info),
  system_ets_entries(Info),
  P = new_process(Info),
  true = ets:insert(Processes, ?new_process(P, "P")),
  {DefLeader, _} = run_built_in(erlang,whereis,1,[user],Info),
  true = ets:update_element(Processes, P, {?process_leader, DefLeader}),
  P.

-spec start_first_process(pid(), {atom(), atom(), [term()]}, timeout()) -> ok.

start_first_process(Pid, {Module, Name, Args}, Timeout) ->
  Pid ! {start, Module, Name, Args},
  wait_process(Pid, Timeout),
  ok.

-spec start_instrument_only_process(pid(), {atom(), atom(), [term()]}) -> ok.
start_instrument_only_process(Pid, {Module, Name, Args}) ->
  Pid ! {start_instrument, Module, Name, Args},
  ok.


%%------------------------------------------------------------------------------

-spec instrumented_top(Tag      :: instrumented_tag(),
                       Args     :: [term()],
                       Location :: term(),
                       Info     :: concuerror_info()) ->
                          'doit' |
                          {'didit', term()} |
                          {'error', term()} |
                          'skip_timeout'|
                          'instrumented_recv'.

instrumented_top(Tag, Args, Location, #concuerror_info{is_instrument_only=true} = Info) ->
  {Result, NewInfo} = instrumented(Tag, Args, Location, Info),
  put(concuerror_info, NewInfo),
  Result;
instrumented_top(Tag, Args, Location, #concuerror_info{} = Info) ->
  %io:format("Calling ~p ~p ~p ~p~n", [self(), Tag, Args, Location]),
  % Process dictionary
  #concuerror_info{escaped_pdict = Escaped} = Info,
  % Put process dictionary in current environment
  lists:foreach(fun({K,V}) -> put(K,V) end, Escaped),
  % Call instrumented
  {Result, #concuerror_info{} = NewInfo} =
    instrumented(Tag, Args, Location, Info),
  %io:format("Returned ~p ~p ~p ~p~n", [self(), Tag, Args, Location]),
  % On return erase process dictionary store it.
  NewEscaped = erase(),
  % Compute new Concuerror information
  FinalInfo = NewInfo#concuerror_info{escaped_pdict = NewEscaped},
  % Save concuerror information
  put(concuerror_info, FinalInfo),
  % Return the result
  Result;
instrumented_top(Tag, Args, Location, {logger, _, _} = Info) ->
  {Result, _} = instrumented(Tag, Args, Location, Info),
  put(concuerror_info, Info),
  Result.

instrumented(call, [Module, Name, Args], Location, Info) ->
  Arity = length(Args),
  instrumented_aux(Module, Name, Arity, Args, Location, Info);
instrumented(apply, [Fun, Args], Location, Info) ->
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
instrumented('receive', [_PatternFun, _, _, _], 
             _Location, #concuerror_info{is_instrument_only=true}=Info) ->
   %io:format("~p receive action~n", [self()]),
   FakeEvent = #event{actor = self(),
                  label = make_ref()},
   {instrumented_recv, Info#concuerror_info{event=FakeEvent}};
instrumented('receive', [PatternFun, Timeout, ActionFun, _], Location, Info) ->
  case Info of
    #concuerror_info{after_timeout = AfterTimeout} ->
      RealTimeout =
        case Timeout =:= infinity orelse Timeout > AfterTimeout of
          false -> Timeout;
          true -> infinity
        end,
      % Receives are handled differently
      handle_receive(PatternFun, RealTimeout, ActionFun, Location, Info);
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
          % Call function built_in
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
      % If either this is not a built in or is safe/race free
      {Modules, Report} =
        case Info of
          #concuerror_info{modules = M} -> {M, true};
          {logger, _, M} -> {M, false}
        end,
      % Find and load the module.
      ok = concuerror_loader:load(Module, Modules, Report),
      % Return doit and #concuerror_info, which instrumented will eventually return and
      % which concuerror_inspect:instrumented finally takes as a cue to call the right
      % function.
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

built_in(erlang, display, 1, [Term], _Location, Info) ->
  #concuerror_info{logger = Logger} = Info,
  Chars = io_lib:format("~w",[Term]),
  concuerror_logger:print(Logger, standard_io, Chars),
  {{didit, true}, Info};
%% Process dictionary has been restored here. No need to report such ops.
built_in(erlang, get, _Arity, Args, _Location, Info) ->
  {{didit, erlang:apply(erlang,get,Args)}, Info};
%% Instrumented processes may just call pid_to_list (we instrument this builtin
%% for the logger)
built_in(erlang, pid_to_list, _Arity, _Args, _Location, Info) ->
  {doit, Info};
built_in(erlang, system_info, 1, [A], _Location, Info)
  when A =:= os_type;
       A =:= schedulers;
       A =:= logical_processors_available
       ->
  {doit, Info};
%% XXX: Check if its redundant (e.g. link to already linked)
built_in(Module, Name, Arity, Args, Location, #concuerror_info{is_instrument_only=InstrumentOnly}=InfoIn) ->
  % Most built_ins end up here.
  % Start by calling process_loop. process_loop spins waiting for the scheduler
  % to request a step.
  Info = 
    case InstrumentOnly of
      true -> 
        FakeEvent = #event{actor = self(),
                       label = make_ref()},
        InfoIn#concuerror_info{event=FakeEvent};
      false -> process_loop(InfoIn)
    end,
  ?debug_flag(?short_builtin, {'built-in', Module, Name, Arity, Location}),
  %% {Stack, ResetInfo} = reset_stack(Info),
  %% ?debug_flag(?stack, {stack, Stack}),
  #concuerror_info{flags = #process_flags{trap_exit = Trapping}} = LocatedInfo =
    add_location_info(Location, Info#concuerror_info{extra = undefined}),%ResetInfo),
  try
    % Run built-in compute new #concuerror_info from running built in.
    {Value, UpdatedInfo} = run_built_in(Module, Name, Arity, Args, LocatedInfo),
    % The next event might be a message send, look into that
    #concuerror_info{extra = Extra, event = MaybeMessageEvent} = UpdatedInfo,
    % If we have instantaneous message delivery, deliver the message.
    Event = maybe_deliver_message(MaybeMessageEvent, UpdatedInfo),
    ?debug_flag(?builtin, {'built-in', Module, Name, Arity, Value, Location}),
    ?debug_flag(?args, {args, Args}),
    ?debug_flag(?result, {args, Value}),
    EventInfo =
      #builtin_event{
         exiting = Location =:= exit,
         extra = Extra,
         mfargs = {Module, Name, Args},
         result = Value
        },
    % Notify scheduler of event.
    Notification = Event#event{event_info = EventInfo},
    NewInfo = notify(Notification, UpdatedInfo),
    {{didit, Value}, NewInfo}
  catch
    throw:Reason ->
      io:format("Crashing ~p ~p ~p ~p ~p~n", [self(), Name, Arity, Args, Location]),
      io:format("~p~n", [erlang:get_stacktrace()]),
      #concuerror_info{scheduler = Scheduler} = Info,
      ?debug_flag(?loop, crashing),
      exit(Scheduler, {Reason, Module, Name, Arity, Args, Location}),
      receive after infinity -> ok end;
    error:Reason ->
      #concuerror_info{event = FEvent} = LocatedInfo,
      FEventInfo =
        #builtin_event{
           mfargs = {Module, Name, Args},
           status = {crashed, Reason},
           trapping = Trapping
          },
      FNotification = FEvent#event{event_info = FEventInfo},
      io:format("Crashing ~p ~p ~p ~p ~p~n", [self(), Name, Arity, Args, Location]),
      io:format("~p~n", [erlang:get_stacktrace()]),
      receive after 10000->ok end,
      FNewInfo = notify(FNotification, LocatedInfo),
      FinalInfo =
        FNewInfo#concuerror_info{stacktop = {Module, Name, Args, Location}},
      {{error, Reason}, FinalInfo}
  end.

%% Special instruction running control (e.g. send to unknown -> wait for reply)
run_built_in(erlang, demonitor, 1, [Ref], Info) ->
  run_built_in(erlang, demonitor, 2, [Ref, []], Info);
run_built_in(erlang, demonitor, 2, [Ref, Options], #concuerror_info{is_instrument_only=true}=Info) ->
  {erlang:demonitor(Ref, Options), Info};
run_built_in(erlang, demonitor, 2, [Ref, Options], Info) ->
  ?badarg_if_not(is_reference(Ref)),
  #concuerror_info{monitors = Monitors} = Info,
  {Result, NewInfo} =
    case ets:match(Monitors, ?monitor_match_to_target_source_as(Ref)) of
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
      [[Target, Source, As]] ->
        ?badarg_if_not(Source =:= self()),
        true = ets:delete_object(Monitors, ?monitor(Ref, Target, As, active)),
        true = ets:insert(Monitors, ?monitor(Ref, Target, As, inactive)),
        {not lists:member(flush, Options), Info}
    end,
  case lists:member(info, Options) of
    true -> {Result, NewInfo};
    false -> {true, NewInfo}
  end;
run_built_in(erlang, exit, 2, [Pid, Reason],
             #concuerror_info{
                event = #event{event_info = EventInfo} = Event
               } = Info) ->
  ?badarg_if_not(is_pid(Pid)),
  case EventInfo of
    %% Replaying...
    #builtin_event{result = OldResult} -> {OldResult, Info};
    %% New event...
    undefined ->
      Content =
        case Event#event.location =/= exit andalso Reason =:= kill of
          true -> kill;
          false -> {'EXIT', self(), Reason}
        end,
      MessageEvent =
        #message_event{
           cause_label = Event#event.label,
           message = #message{data = Content},
           recipient = Pid,
           type = exit_signal},
      NewEvent = Event#event{special = [{message, MessageEvent}]},
      {true, Info#concuerror_info{event = NewEvent}}
  end;

run_built_in(erlang, group_leader, 0, [],
             #concuerror_info{is_instrument_only=true} = Info) ->
  Leader = erlang:group_leader(),
  {Leader, Info};
run_built_in(erlang, group_leader, 0, [],
             #concuerror_info{processes = Processes} = Info) ->
  Leader = ets:lookup_element(Processes, self(), ?process_leader),
  {Leader, Info};

run_built_in(erlang, group_leader, 2, [GroupLeader, Pid],
             #concuerror_info{is_instrument_only=true} = Info) ->
  ?badarg_if_not(is_pid(GroupLeader) andalso is_pid(Pid)),
  Ret = erlang:group_leader(GroupLeader, Pid),
  {Ret, Info};
run_built_in(erlang, group_leader, 2, [GroupLeader, Pid],
             #concuerror_info{processes = Processes} = Info) ->
  ?badarg_if_not(is_pid(GroupLeader) andalso is_pid(Pid)),
  true = ets:update_element(Processes, Pid, {?process_leader, GroupLeader}),
  {true, Info};

run_built_in(erlang, halt, _, _, Info) ->
  #concuerror_info{event = Event} = Info,
  NewEvent = Event#event{special = [halt]},
  {no_return, Info#concuerror_info{event = NewEvent}};

run_built_in(erlang, is_process_alive, 1, [Pid], Info) ->
  ?badarg_if_not(is_pid(Pid)),
  #concuerror_info{processes = Processes} = Info,
  Return =
    case ets:lookup(Processes, Pid) of
      [] -> ?crash({checking_system_process, Pid});
      [?process_pat_pid_status(Pid, Status)] -> is_active(Status)
    end,
  {Return, Info};

run_built_in(erlang, link, 1, [Pid], Info) ->
  #concuerror_info{
     flags = #process_flags{trap_exit = TrapExit},
     links = Links,
     event = #event{event_info = EventInfo} = Event} = Info,
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
                MessageEvent =
                  #message_event{
                     cause_label = Event#event.label,
                     message = #message{data = {'EXIT', Pid, noproc}},
                     recipient = self()},
                NewEvent = Event#event{special = [{message, MessageEvent}]},
                Info#concuerror_info{event = NewEvent}
            end,
          {true, NewInfo}
      end
  end;

run_built_in(erlang, Name, 0, [], Info)
  when
    Name =:= date;
    Name =:= make_ref;
    Name =:= time
    ->
  #concuerror_info{event = #event{event_info = EventInfo}} = Info,
  Ref =
    case EventInfo of
      %% Replaying...
      #builtin_event{result = OldResult} -> OldResult;
      %% New event...
      undefined -> erlang:apply(erlang,Name,[])
    end,
  {Ref, Info};
run_built_in(erlang, monitor, 2, [Type, Target], #concuerror_info{is_instrument_only=true} = Info) ->
  {erlang:monitor(Type, Target), Info};
run_built_in(erlang, monitor, 2, [Type, Target], Info) ->
  #concuerror_info{
     monitors = Monitors,
     event = #event{event_info = EventInfo} = Event} = Info,
  ?badarg_if_not(Type =:= process),
  {Target, As} =
    case Target of
      P when is_pid(P) -> {Target, Target};
      A when is_atom(A) -> {Target, {Target, node()}};
      {Name, Node} = Local when is_atom(Name), Node =:= node() ->
        {Name, Local};
      {Name, Node} when is_atom(Name) -> ?crash({not_local_node, Node});
      _ -> error(badarg)
    end,
  Ref =
    case EventInfo of
      %% Replaying...
      #builtin_event{result = OldResult} -> OldResult;
      %% New event...
      undefined -> make_ref()
    end,
  Pid =
    case is_pid(Target) of
      true -> Target;
      false ->
        {P1, Info} = run_built_in(erlang, whereis, 1, [Target], Info),
        P1
    end,
  {IsActive, Info} = run_built_in(erlang, is_process_alive, 1, [Pid], Info),
  case IsActive of
    true -> true = ets:insert(Monitors, ?monitor(Ref, Pid, As, active));
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
            Message = #message{data = {'DOWN', Ref, process, As, noproc}},
            MessageEvent =
              #message_event{
                 cause_label = Event#event.label,
                 message = Message,
                 recipient = self()},
            NewEvent = Event#event{special = [{message, MessageEvent}]},
            Info#concuerror_info{event = NewEvent};
          true -> Info
        end
    end,
  {Ref, NewInfo};
run_built_in(erlang, process_info, 2, [Pid, Item], Info) when is_atom(Item) ->
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
  #concuerror_info{
     event = Event,
     processes = Processes,
     timeout = Timeout,
     is_instrument_only = InstrumentOnly} = Info,
  #event{event_info = EventInfo} = Event,
  Parent = self(),
  {Result, NewInfo} =
    case EventInfo of
      %% Replaying...
      #builtin_event{result = OldResult} -> {OldResult, Info};
      %% New event...
      undefined ->
        PassedInfo = reset_concuerror_info(Info),
        ?debug_flag(?spawn, {Parent, spawning_new, PassedInfo}),
        ParentSymbol = ets:lookup_element(Processes, Parent, ?process_symbolic),
        ChildId = ets:update_counter(Processes, Parent, {?process_children, 1}),
        ChildSymbol = io_lib:format("~s.~w",[ParentSymbol, ChildId]),
        P = new_process(PassedInfo),
        true = ets:insert(Processes, ?new_process(P, ChildSymbol)),
        NewResult =
          case lists:member(monitor, SpawnOpts) of
            true -> {P, make_ref()};
            false -> P
          end,
        NewEvent = Event#event{special = [{new, P}]},
        {NewResult, Info#concuerror_info{event = NewEvent}}
    end,
  Pid =
    case lists:member(monitor, SpawnOpts) of
      true ->
        {P1, Ref} = Result,
        #concuerror_info{monitors = Monitors} = Info,
        true = ets:insert(Monitors, ?monitor(Ref, P1, P1, active)),
        P1;
      false ->
        Result
    end,
  case lists:member(link, SpawnOpts) of
    true ->
      #concuerror_info{links = Links} = Info,
      true = ets:insert(Links, ?links(Parent, Pid));
    false -> ok
  end,
  {GroupLeader, _} = run_built_in(erlang, group_leader, 0, [], Info),
  true = ets:update_element(Processes, Pid, {?process_leader, GroupLeader}),
  case InstrumentOnly of
    false ->
      start_first_process(Pid, {Module, Name, Args}, Timeout);
    true ->
      start_instrument_only_process (Pid, {Module, Name, Args})
  end,
  {Result, NewInfo};
run_built_in(erlang, Send, 2, [Recipient, Message], Info)
  when Send =:= '!'; Send =:= 'send' ->
  run_built_in(erlang, send, 3, [Recipient, Message, []], Info);
run_built_in(erlang, send, 3, [Recipient, Message, _Options],
             #concuerror_info{
                event = #event{event_info = EventInfo} = Event
               } = Info) ->
  Pid =
    case is_pid(Recipient) of
      true -> Recipient;
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
           message = #message{data = Message},
           recipient = Pid},
      NewEvent = Event#event{special = [{message, MessageEvent}]},
      ?debug_flag(?send, {send, successful}),
      {Message, Info#concuerror_info{event = NewEvent}}
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
run_built_in(erlang, unlink, 1, [Pid], #concuerror_info{links = Links} = Info) ->
  Self = self(),
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
             #concuerror_info{processes = Processes,
                              is_instrument_only = true} = Info) ->
  case ets:match(Processes, ?process_match_name_to_type(Name)) of
    [] ->
      case whereis(Name) =:= undefined of
        true -> {undefined, Info};
        false -> throw({system_process_not_wrapped, Name})
      end;
    [[wrapped, _]] -> {whereis(Name), Info};
    [[regular, Pid]] -> {Pid, Info};
    [[Type, _Pid]] -> throw({unknown_type, Type})
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
run_built_in(ets, F, _, Args, #concuerror_info{is_instrument_only=true}=Info) ->
  {erlang:apply(ets, F, Args), Info};
run_built_in(ets, new, 2, [Name, Options], Info) ->
  ?badarg_if_not(is_atom(Name)),
  NoNameOptions = [O || O <- Options, O =/= named_table],
  #concuerror_info{
     ets_tables = EtsTables,
     event = #event{event_info = EventInfo},
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
      false ->
        case EventInfo of
          %% Replaying...
          #builtin_event{result = R} -> R;
          %% New event...
          undefined ->
            ets:update_counter(EtsTables, tid, 1)
        end
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
    ;{F,N} =:= {first, 1}
    ;{F,N} =:= {insert, 2}
    ;{F,N} =:= {insert_new, 2}
    ;{F,N} =:= {lookup, 2}
    ;{F,N} =:= {lookup_element, 3}
    ;{F,N} =:= {match, 2}
    ;{F,N} =:= {member, 2}
    ;{F,N} =:= {next,   2}
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
                event = #event{event_info = EventInfo} = Event
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
             message = #message{data = {'ETS-TRANSFER', Tid, Self, GiftData}},
             recipient = Pid},
        NewEvent = Event#event{special = [{message, MessageEvent}]},
        Info#concuerror_info{event = NewEvent}
    end,
  Update = [{?ets_owner, Pid}],
  true = ets:update_element(EtsTables, Tid, Update),
  {true, NewInfo#concuerror_info{extra = Tid}};

run_built_in(Module, Name, Arity, Args, Info)
  when
    {Module, Name, Arity} =:= {erlang, put, 2} ->
  consistent_replay(Module, Name, Arity, Args, Info);

%% For other built-ins check whether replaying has the same result:
run_built_in(Module, Name, Arity, _Args,
             #concuerror_info{report_unknown = true, scheduler = Scheduler}) ->
  ?crash({unknown_built_in, {Module, Name, Arity}}, Scheduler);
run_built_in(Module, Name, Arity, Args, Info) ->
  consistent_replay(Module, Name, Arity, Args, Info).

consistent_replay(Module, Name, Arity, Args, Info) ->
  #concuerror_info{event = Event} = Info,
  #event{event_info = EventInfo, location = Location} = Event,
  NewResult = erlang:apply(Module, Name, Args),
  case EventInfo of
    %% Replaying...
    #builtin_event{mfargs = {M,F,OArgs}, result = OldResult} ->
      case OldResult =:= NewResult of
        true  -> {OldResult, Info};
        false ->
          case M =:= Module andalso F =:= Name andalso Args =:= OArgs of
            true ->
              ?crash({inconsistent_builtin,
                      [Module, Name, Arity, Args, OldResult, NewResult, Location]});
            false ->
              ?crash({unexpected_builtin_change,
                      [Module, Name, Arity, Args, M, F, OArgs, Location]})
          end
      end;
    undefined ->
      {NewResult, Info}
  end.

%%------------------------------------------------------------------------------

maybe_deliver_message(#event{special = Special} = Event, 
                      #concuerror_info{is_instrument_only=InstrumentOnly}=Info) ->
  case proplists:lookup(message, Special) of
    none -> Event;
    {message, MessageEvent} ->
      case InstrumentOnly of
        false ->
          % Is instant_delivery set to true
          #concuerror_info{instant_delivery = InstantDelivery} = Info,
          % Message event: find information about instant delivery
          #message_event{recipient = Recipient, instant = Instant} = MessageEvent,
          % If the message is marked for instant delivery or is addressed to self and
          % instant delivery is enabled.
          % Note Instant is currently always true (assume all processes are local).
          case (InstantDelivery orelse Recipient =:= self()) andalso Instant of
            false -> Event;
            true ->
              #concuerror_info{timeout = Timeout} = Info,
              TrapExit = Info#concuerror_info.flags#process_flags.trap_exit,
              deliver_message(Event, MessageEvent, Timeout, {true, TrapExit})
          end;
        true ->
          #message_event{recipient = Recipient, message = #message{data = Message}} = MessageEvent,
          Recipient ! Message, % Just blindly send for now, until we fix up receive to 
          % be more reasonable about what it receives
          Event
          %#message_event{recipient = Recipient, data 
      end
  end.

-spec deliver_message(event(), message_event(), timeout()) -> event().
% This is called by the scheduler and maybe_deliver_message to deliver a message.
deliver_message(Event, MessageEvent, Timeout) ->
  deliver_message(Event, MessageEvent, Timeout, false).

deliver_message(Event, MessageEvent, Timeout, Instant) ->
  #event{special = Special} = Event,
  #message_event{
     message = Message,
     recipient = Recipient,
     type = Type} = MessageEvent,
  ?debug_flag(?loop, {deliver_message, Message, Instant}),
  Self = self(),
  Notify =
    case Recipient =:= Self of
      true ->
        Recipient ! {trapping, element(2, Instant)},
        1;
      false -> Self
    end,
  Recipient ! {Type, Message, Notify},
  receive
    {trapping, Trapping} ->
      NewMessageEvent = MessageEvent#message_event{trapping = Trapping},
      NewSpecial =
        case already_known_delivery(Message, Special) of
          true -> Special;
          false -> Special ++ [{message_delivered, NewMessageEvent}]
        end,
      Event#event{special = NewSpecial};
    {system_reply, From, Id, Reply, System} ->
      ?debug_flag(?loop, got_system_message),
      case proplists:lookup(message_received, Special) =:= none of
        true ->
          SystemReply =
            #message_event{
               cause_label = Event#event.label,
               message = #message{data = Reply},
               sender = Recipient,
               recipient = From},
          SystemSpecials =
            [{message_delivered, MessageEvent},
             {message_received, Id, fun(_) -> true end},
             {system_communication, System},
             {message, SystemReply}],
          NewEvent = Event#event{special = Special ++ SystemSpecials},
          case Instant =:= false of
            true -> NewEvent;
            false -> deliver_message(NewEvent, SystemReply, Timeout, Instant)
          end;
        false ->
          SystemReply = find_system_reply(Recipient, Special),
          case Instant =:= false of
            true -> Event;
            false -> deliver_message(Event, SystemReply, Timeout, Instant)
          end
      end;
    {'EXIT', _, What} ->
      exit(What)
  after
    Timeout ->
      ?crash({no_response_for_message, Timeout, Recipient})
  end.

already_known_delivery(_, []) -> false;
already_known_delivery(Message, [{message_delivered, Event}|Special]) ->
  #message{id = Id} = Message,
  #message_event{message = #message{id = Del}} = Event,
  Id =:= Del orelse already_known_delivery(Message, Special);
already_known_delivery(Message, [_|Special]) ->
  already_known_delivery(Message, Special).

find_system_reply(System, [{message, #message_event{sender = System} = Message}|_]) ->
  Message;
find_system_reply(System, [_|Special]) ->
  find_system_reply(System, Special).

%%------------------------------------------------------------------------------

-spec wait_actor_reply(event(), timeout()) ->
                          'exited' | 'retry' | {'ok', event()}.

wait_actor_reply(Event, Timeout) ->
  io:format("Wait actor reply called~n"),
  Resp = receive
    exited -> exited;
    {blocked, _} ->  retry;
    #event{} = NewEvent -> {ok, NewEvent};
    {'ETS-TRANSFER', _, _, given_to_scheduler} ->
      wait_actor_reply(Event, Timeout);
    {'EXIT', _, What} ->
      exit(What)
  after
    Timeout -> 
    ?crash({process_did_not_respond, Timeout, Event#event.actor})
  end,
  %io:format("Received ~p~n", [Resp]),
  Resp.

%%------------------------------------------------------------------------------

-spec collect_deadlock_info([pid()]) -> [{pid(), location()}].

collect_deadlock_info(ActiveProcesses) ->
  Map =
    fun(P) ->
        P ! deadlock_poll,
        receive
          {blocked, Location} -> {P, Location}
        end
    end,
  [Map(P) || P <- ActiveProcesses].

%%------------------------------------------------------------------------------

handle_receive(PatternFun, Timeout, _ActionFun, Location, Info) ->
  %% No distinction between replaying/new as we have to clear the message from
  %% the queue anyway...
  %io:format("~p In handle_receive~n", [self()]),
  {MessageOrAfter, ReceiveInfo} =
    has_matching_or_after(PatternFun, Timeout, Location, Info, blocking),
  %io:format("~p has_matching_or_after returns~n", [self()]),
  #concuerror_info{
     event = NextEvent,
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
      #message{data = Data, id = Id} ->
        {[{message_received, Id, PatternFun}], {ok, Data}};
      'after' -> {[], false}
    end,
  Notification =
    NextEvent#event{event_info = ReceiveEvent, special = Special},
  %io:format("~p About to call ActionFun with ~p~n", [self(), CreateMessage]),
  case CreateMessage of
    {ok, D} ->
      ?debug_flag(?receive_, {deliver, D}),
      %io:format("Going to try calling ActionFun to see what happens with msg ~p~n", [D]),
      %ActionFun(D),
      %io:format("Action function returned~n"),
      self() ! D;
      %io:format("Message to deliver~n"),
    false -> ok
  end,
  {skip_timeout, notify(Notification, UpdatedInfo)}.
  %{{didit, Res}, FinalInfo}. 

has_matching_or_after(PatternFun, Timeout, Location, InfoIn, Mode) ->
  {Result, NewOldMessages} = has_matching_or_after(PatternFun, Timeout, InfoIn),
  UpdatedInfo = update_messages(Result, NewOldMessages, InfoIn),
  case Mode of
    non_blocking -> {Result, UpdatedInfo};
    blocking ->
      case Result =:= false of
        true ->
          ?debug_flag(?loop, blocked),
          NewInfo =
            case InfoIn#concuerror_info.status =:= waiting of
              true ->
                % This time round notify the scheduler blocked.
                process_loop(notify({blocked, Location}, UpdatedInfo));
              false ->
                % The first time through receive does not wait in process_loop, no
                % one is waiting gor us to notify. The next time we get here
                % process_loop would have been notified and thus we need to notify it
                % that this process is blocked
                process_loop(set_status(UpdatedInfo, waiting))
            end,
          has_matching_or_after(PatternFun, Timeout, Location, NewInfo, Mode);
        false ->
          ?debug_flag(?loop, ready_to_receive),
          NewInfo = process_loop(InfoIn),
          {FinalResult, FinalNewOldMessages} =
            has_matching_or_after(PatternFun, Timeout, NewInfo),
          FinalInfo = update_messages(Result, FinalNewOldMessages, NewInfo),
          {FinalResult, FinalInfo}
      end
  end.

update_messages(Result, NewOldMessages, Info) ->
  % Not worth searching through old messages put them in a new
  % queue.
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
  % See if there is a message that matches the current pattern.
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
  ?debug_flag(?notify, {notify, Notification}),
  Scheduler ! Notification,
  Info.

-spec process_top_loop(concuerror_info()) -> no_return().

process_top_loop(Info) ->
  % New processes end up here, waiting to be started.
  ?debug_flag(?loop, top_waiting),
  receive
    reset -> process_top_loop(Info);
    {start_instrument, Module, Name, Args} ->
      ?debug_flag(?loop, {start_instrument, Module, Name, Args}),
      put(concuerror_info, Info#concuerror_info{is_instrument_only=true}),
      try
        concuerror_inspect:instrumented(call, [Module, Name, Args], start),
        exit(normal)
      catch
        exit:{?MODULE, _} = Reason -> exit(Reason);
        Class:Reason ->
          ConcuerrorInfo = case erase(concuerror_info) of 
            #concuerror_info{} = CInfo ->
              CInfo;
            _ ->
              exit({process_crashed, Class, Reason, erlang:get_stacktrace()})
          end,
          Stacktrace = fix_stacktrace(ConcuerrorInfo),
          ?debug_flag(?exit, {exit, Class, Reason, Stacktrace}),
          NewReason =
            case Class of
              throw -> {{nocatch, Reason}, Stacktrace};
              error -> {Reason, Stacktrace};
              exit  -> Reason
            end,
          exiting(NewReason, Stacktrace, ConcuerrorInfo)
      end;
    {start, Module, Name, Args} ->
      ?debug_flag(?loop, {start, Module, Name, Args}),
      put(concuerror_info, Info),
      try
        % Call concuerror_inspect:instrumented. concuerror_inspect:instrumented
        % starts by calling instrumented_top, which in turn calls instrumented, which
        % in turn calls instrumented_aux
        %
        % instrumented_aux calls concuerror_loader:load, thus loading any unloaded modules
        % and returns doit, Info. The next time we stop is at the call to a BIF that has not
        % been marked safe.
        % More consicely
        % start -> concuerror_inspect:instrumented(call, ...)
        %       -> instrumented_top % Restores process dictionary, etc.
        %       -> instrumented
        %       -> instrumented_aux -> load if necessary
        %       ... -> built_in
        concuerror_inspect:instrumented(call, [Module,Name,Args], start),
        exit(normal)
      catch
        exit:{?MODULE, _} = Reason -> exit(Reason);
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

new_process(#concuerror_info{is_instrument_only=true}=ParentInfo) ->
  % Start a new process.
  Info = ParentInfo#concuerror_info{notify_when_ready = {self(), false}},
  spawn(fun() -> process_top_loop(Info) end);
new_process(ParentInfo) ->
  % Start a new process.
  Info = ParentInfo#concuerror_info{notify_when_ready = {self(), true}},
  spawn_link(fun() -> process_top_loop(Info) end).

wait_process(Pid, Timeout) ->
  %% Wait for the new process to instrument any code.
  receive
    ready -> ok
  after
    Timeout ->
      exit({concuerror_scheduler, {process_did_not_respond, Timeout, Pid}})
  end.

process_loop(#concuerror_info{notify_when_ready = {Pid, true}} = Info) ->
  ?debug_flag(?loop, notifying_parent),
  % Notify the scheduler that the process is in process_loop/is broken in
  % for the first time.
  Pid ! ready,
  process_loop(Info#concuerror_info{notify_when_ready = {Pid, false}});
process_loop(#concuerror_info{is_instrument_only=true}=InfoIn) ->
  FakeEvent = #event{actor = self(),
                 label = make_ref()},
  Status = InfoIn#concuerror_info.status,
  Info = case Status =:= exited of
    true -> Ninfo = notify({exited, self()}, InfoIn);
    false -> InfoIn
  end,
  Info#concuerror_info{event=FakeEvent};
process_loop(Info) ->
  ?debug_flag(?loop, process_loop),
  receive
    % Receive #event{event_info = EventInfo}
    #event{event_info = EventInfo} = Event ->
      ?debug_flag(?loop, got_event),
      % Get current status
      Status = Info#concuerror_info.status,
      case Status =:= exited of
        true ->
          ?debug_flag(?loop, exited),
          process_loop(notify(exited, Info));
        false ->
          NewInfo = Info#concuerror_info{event = Event},
          case EventInfo of
            undefined ->
              ?debug_flag(?loop, exploring),
              NewInfo;
            _OtherReplay ->
              ?debug_flag(?loop, replaying),
              NewInfo
          end
      end;
    {exit_signal, #message{data = Data} = Message, Notify} ->
      Trapping = Info#concuerror_info.flags#process_flags.trap_exit,
      case is_active(Info) of
        true ->
          case Data =:= kill of
            true ->
              ?debug_flag(?loop, kill_signal),
              catch Notify ! {trapping, Trapping},
              exiting(killed, [], Info#concuerror_info{caught_signal = true});
            false ->
              case Trapping of
                true ->
                  ?debug_flag(?loop, signal_trapped),
                  self() ! {message, Message, Notify},
                  process_loop(Info);
                false ->
                  catch Notify ! {trapping, Trapping},
                  {'EXIT', _From, Reason} = Data,
                  case Reason =:= normal of
                    true ->
                      ?debug_flag(?loop, ignore_normal_signal),
                      process_loop(Info);
                    false ->
                      ?debug_flag(?loop, error_signal),
                      exiting(Reason, [], Info#concuerror_info{caught_signal = true})
                  end
              end
          end;
        false ->
          ?debug_flag(?loop, ignoring_signal),
          catch Notify ! {trapping, Trapping},
          process_loop(Info)
      end;
    {message, Message, Notify} ->
      ?debug_flag(?loop, message),
      Trapping = Info#concuerror_info.flags#process_flags.trap_exit,
      catch Notify ! {trapping, Trapping},
      case is_active(Info) of
        true ->
          ?debug_flag(?loop, enqueueing_message),
          Old = Info#concuerror_info.messages_new,
          NewInfo =
            Info#concuerror_info{
              messages_new = queue:in(Message, Old)
             },
          ?debug_flag(?loop, enqueued_msg),
          case NewInfo#concuerror_info.status =:= waiting of
            true -> NewInfo#concuerror_info{status = running};
            false -> process_loop(NewInfo)
          end;
        false ->
          ?debug_flag(?loop, ignoring_message),
          process_loop(Info)
      end;
    reset ->
      ?debug_flag(?loop, reset),
      NewInfo =
        #concuerror_info{
           ets_tables = EtsTables,
           links = Links,
           monitors = Monitors,
           processes = Processes} = reset_concuerror_info(Info),
      _ = erase(),
      Symbol = ets:lookup_element(Processes, self(), ?process_symbolic),
      ets:insert(Processes, ?new_process(self(), Symbol)),
      {DefLeader, _} = run_built_in(erlang,whereis,1,[user],Info),
      true = ets:update_element(Processes, self(), {?process_leader, DefLeader}),
      ets:match_delete(EtsTables, ?ets_match_mine()),
      ets:match_delete(Links, ?links_match_mine()),
      ets:match_delete(Monitors, ?monitors_match_mine()),
      erlang:hibernate(concuerror_callback, process_top_loop, [NewInfo]);
    deadlock_poll ->
      ?debug_flag(?loop, deadlock_poll),
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
  ?debug_flag(?loop, {going_to_exit, Reason}),
  Info = process_loop(InfoIn),
  Self = self(),
  {MaybeName, Info} =
    run_built_in(erlang, process_info, 2, [Self, registered_name], Info),
  LocatedInfo = #concuerror_info{event = Event} =
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
  ?debug_flag(?loop, exited),
  process_loop(set_status(FinalInfo, exited)).

ets_ownership_exiting_events(Info) ->
  %% XXX:  - transfer ets ownership and send message or delete table
  %% XXX: Mention that order of deallocation/transfer is not monitored.
  #concuerror_info{ets_tables = EtsTables} = Info,
  case ets:match(EtsTables, ?ets_match_owner_to_name_heir(self())) of
    [] -> Info;
    UnsortedTables ->
      Tables = lists:sort(UnsortedTables),
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

handle_monitor({Ref, P, As}, Reason, InfoIn) ->
  Msg = {'DOWN', Ref, process, As, Reason},
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
    {delete        ,1} -> own;
    {delete        ,2} -> write;
    {first         ,_} -> read;
    {give_away     ,_} -> own;
    {info          ,_} -> none;
    {insert        ,_} -> write;
    {insert_new    ,_} -> write;
    {lookup        ,_} -> read;
    {lookup_element,_} -> read;
    {match         ,_} -> read;
    {member        ,_} -> read;
    {next          ,_} -> read;
    {select        ,_} -> read;
    {select_delete ,_} -> write
  end.

%%------------------------------------------------------------------------------

system_ets_entries(#concuerror_info{ets_tables = EtsTables}) ->
  Map = fun(Tid) -> ?new_system_ets_table(Tid, ets:info(Tid, protection)) end,
  ets:insert(EtsTables, [Map(Tid) || Tid <- ets:all(), is_atom(Tid)]).

system_processes_wrappers(Info) ->
  #concuerror_info{processes = Processes} = Info,
  Map =
    fun(Name) ->
        Fun = fun() -> system_wrapper_loop(Name, whereis(Name), Info) end,
        Pid = spawn_link(Fun),
        ?new_system_process(Pid, Name)
    end,
  ets:insert(Processes, [Map(Name) || Name <- registered()]).

system_wrapper_loop(Name, Wrapped, Info) ->
  receive
    Message ->
      case Message of
        {message,
         #message{data = Data, id = Id}, Report} ->
          try
            {F, R} =
              case Name of
                code_server ->
                  case Data of
                    {Call, From, Request} ->
                      check_request(Name, Request),
                      erlang:send(Wrapped, {Call, self(), Request}),
                      receive
                        Msg -> {From, Msg}
                      end
                  end;
                erl_prim_loader ->
                  case Data of
                    {From, Request} ->
                      check_request(Name, Request),
                      erlang:send(Wrapped, {self(), Request}),
                      receive
                        {_, Msg} -> {From, {self(), Msg}}
                      end
                  end;
                error_logger ->
                  %% erlang:send(Wrapped, Data),
                  throw(no_reply);
                file_server_2 ->
                  case Data of
                    {Call, {From, Ref}, Request} ->
                      check_request(Name, Request),
                      erlang:send(Wrapped, {Call, {self(), Ref}, Request}),
                      receive
                        Msg -> {From, Msg}
                      end
                  end;
                init ->
                  {From, Request} = Data,
                  check_request(Name, Request),
                  erlang:send(Wrapped, {self(), Request}),
                  receive
                    Msg -> {From, Msg}
                  end;
                standard_error ->
                  #concuerror_info{logger = Logger} = Info,
                  {From, Reply, _} = handle_io(Data, {standard_error, Logger}),
                  {From, Reply};
                user ->
                  #concuerror_info{logger = Logger} = Info,
                  {From, Reply, _} = handle_io(Data, {standard_io, Logger}),
                  {From, Reply};
                Else ->
                  ?crash({unknown_protocol_for_system, Else})
              end,
            Report ! {system_reply, F, Id, R, Name},
            ok
          catch
            exit:{?MODULE, _} = Reason -> exit(Reason);
            throw:no_reply ->
              Report ! {trapping, false},
              ok;
            Type:Reason ->
              Stacktrace = erlang:get_stacktrace(),
              ?crash({system_wrapper_error, Name, Type, Reason, Stacktrace})
          end
      end
  end,
  system_wrapper_loop(Name, Wrapped, Info).

check_request(code_server, get_path) -> ok;
check_request(code_server, {ensure_loaded, _}) -> ok;
check_request(code_server, {is_cached, _}) -> ok;
check_request(erl_prim_loader, {get_file, _}) -> ok;
check_request(erl_prim_loader, {list_dir, _}) -> ok;
check_request(file_server_2, {get_cwd}) -> ok;
check_request(file_server_2, {read_file_info, _}) -> ok;
check_request(init, {get_argument, _}) -> ok;
check_request(init, get_arguments) -> ok;
check_request(Name, Other) ->
  ?crash({unsupported_request, Name, try element(1,Other) catch _:_ -> Other end}).

reset_concuerror_info(Info) ->
  #concuerror_info{
     after_timeout = AfterTimeout,
     ets_tables = EtsTables,
     instant_delivery = InstantDelivery,
     links = Links,
     logger = Logger,
     modules = Modules,
     monitors = Monitors,
     notify_when_ready = {Pid, _},
     processes = Processes,
     report_unknown = ReportUnknown,
     scheduler = Scheduler,
     timeout = Timeout,
     is_instrument_only = InstrumentOnly
    } = Info,
  #concuerror_info{
     after_timeout = AfterTimeout,
     ets_tables = EtsTables,
     instant_delivery = InstantDelivery,
     links = Links,
     logger = Logger,
     modules = Modules,
     monitors = Monitors,
     notify_when_ready = {Pid, true},
     processes = Processes,
     report_unknown = ReportUnknown,
     scheduler = Scheduler,
     timeout = Timeout,
     is_instrument_only = InstrumentOnly
    }.

%% reset_stack(#concuerror_info{stack = Stack} = Info) ->
%%   {Stack, Info#concuerror_info{stack = []}}.

%% append_stack(Value, #concuerror_info{stack = Stack} = Info) ->
%%   Info#concuerror_info{stack = [Value|Stack]}.

%%------------------------------------------------------------------------------

add_location_info(Location, #concuerror_info{event = Event} = Info) ->
  Info#concuerror_info{event = Event#event{location = Location}}.

set_status(#concuerror_info{processes = Processes} = Info, Status) ->
  MaybeDropName =
    case Status =:= exiting of
      true -> [{?process_name, ?process_name_none}];
      false -> []
    end,
  Updates = [{?process_status, Status}|MaybeDropName],
  true = ets:update_element(Processes, self(), Updates),
  Info#concuerror_info{status = Status}.

is_active(#concuerror_info{caught_signal = CaughtSignal, status = Status}) ->
  not CaughtSignal andalso is_active(Status);
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

%%------------------------------------------------------------------------------

handle_io({io_request, From, ReplyAs, Req}, IOState) ->
  {Reply, NewIOState} = io_request(Req, IOState),
  {From, {io_reply, ReplyAs, Reply}, NewIOState}.

io_request({put_chars, Chars}, {Tag, Data} = IOState) ->
  case is_atom(Tag) of
    true ->
      Logger = Data,
      concuerror_logger:print(Logger, Tag, Chars),
      {ok, IOState}
  end;
io_request({put_chars, M, F, As}, IOState) ->
  try apply(M, F, As) of
      Chars -> io_request({put_chars, Chars}, IOState)
  catch
    _:_ -> {{error, request}, IOState}
  end;
io_request({put_chars, _Enc, Chars}, IOState) ->
    io_request({put_chars, Chars}, IOState);
io_request({put_chars, _Enc, Mod, Func, Args}, IOState) ->
    io_request({put_chars, Mod, Func, Args}, IOState);
%% io_request({get_chars, _Enc, _Prompt, _N}, IOState) ->
%%     {eof, IOState};
%% io_request({get_chars, _Prompt, _N}, IOState) ->
%%     {eof, IOState};
%% io_request({get_line, _Prompt}, IOState) ->
%%     {eof, IOState};
%% io_request({get_line, _Enc, _Prompt}, IOState) ->
%%     {eof, IOState};
%% io_request({get_until, _Prompt, _M, _F, _As}, IOState) ->
%%     {eof, IOState};
%% io_request({setopts, _Opts}, IOState) ->
%%     {ok, IOState};
%% io_request(getopts, IOState) ->
%%     {error, {error, enotsup}, IOState};
%% io_request({get_geometry,columns}, IOState) ->
%%     {error, {error, enotsup}, IOState};
%% io_request({get_geometry,rows}, IOState) ->
%%     {error, {error, enotsup}, IOState};
%% io_request({requests, Reqs}, IOState) ->
%%     io_requests(Reqs, {ok, IOState});
io_request(_, IOState) ->
    {{error, request}, IOState}.

%% io_requests([R | Rs], {ok, IOState}) ->
%%     io_requests(Rs, io_request(R, IOState));
%% io_requests(_, Result) ->
%%     Result.

%%------------------------------------------------------------------------------

-spec explain_error(term()) -> string().

explain_error({checking_system_process, Pid}) ->
  io_lib:format(
    "A process tried to link/monitor/inspect process ~p which was not"
    " started by Concuerror and has no suitable wrapper to work with"
    " Concuerror.~n"
    ?notify_us_msg,
    [Pid]);
explain_error({inconsistent_builtin,
               [Module, Name, Arity, Args, OldResult, NewResult, Location]}) ->
  io_lib:format(
    "While re-running the program, a call to ~p:~p/~p with"
    " arguments:~n  ~p~nreturned a different result:~n"
    "Earlier result: ~p~n"
    "  Later result: ~p~n"
    "Concuerror cannot explore behaviours that depend on~n"
    "data that may differ on separate runs of the program.~n"
    "Location: ~p~n~n",
    [Module, Name, Arity, Args, OldResult, NewResult, Location]);
explain_error({no_response_for_message, Timeout, Recipient}) ->
  io_lib:format(
    "A process took more than ~pms to send an acknowledgement for a message"
    " that was sent to it. (Process: ~p)~n"
    ?notify_us_msg,
    [Timeout, Recipient]);
explain_error({not_local_node, Node}) ->
  io_lib:format(
    "A built-in tried to use ~p as a remote node. Concuerror does not support"
    " remote nodes yet.",
    [Node]);
explain_error({process_did_not_respond, Timeout, Actor}) ->
  io_lib:format(
    "A process took more than ~pms to report a built-in event. You can try to"
    " increase the --timeout limit and/or ensure that there are no infinite"
    " loops in your test. (Process: ~p)",
    [Timeout, Actor]
   );
explain_error({system_wrapper_error, Name, Type, Reason, Stacktrace}) ->
  io_lib:format(
    "Concuerror's wrapper for system process ~p crashed (~p):~n"
    "  Reason:~p~n"
    "Stacktrace:~n"
    " ~p~n"
    ?notify_us_msg,
    [Name, Type, Reason, Stacktrace]);
explain_error({unexpected_builtin_change,
               [Module, Name, Arity, Args, M, F, OArgs, Location]}) ->
  io_lib:format(
    "While re-running the program, a call to ~p:~p/~p with"
    " arguments:~n  ~p~nwas found instead of the original call~n"
    "to ~p:~p/~p with args:~n  ~p~n"
    "Concuerror cannot explore behaviours that depend on~n"
    "data that may differ on separate runs of the program.~n"
    "Location: ~p~n~n",
    [Module, Name, Arity, Args, M, F, length(OArgs), OArgs, Location]);
explain_error({unknown_protocol_for_system, System}) ->
  io_lib:format(
    "A process tried to send a message to system process ~p. Concuerror does"
    " not currently support communication with this process. Please contact the"
    " developers for more information.",[System]);
explain_error({unknown_built_in, {Module, Name, Arity}}) ->
  io_lib:format(
    "No special handling found for built-in ~p:~p/~p. Run without"
    " --report_unknown or contact the developers to add support for it.",
    [Module, Name, Arity]);
explain_error({unsupported_request, Name, Type}) ->
  io_lib:format(
    "A process send a request of type '~p' to ~p. This type of"
    " request has not been checked to ensure it always returns the same"
    " result.~n"
    ?notify_us_msg,
    [Type, Name]).
