%% -define(DEBUG, true).

%%------------------------------------------------------------------------------
-ifdef(SENSITIVE_DEBUG).
-define(display(A), erlang:display({A, ?MODULE, ?LINE})).
-else.
-define(display(A, B),
        io:format(standard_error,
                  "# ~p ~p l~p: "++A++"~n",
                  [self(), ?MODULE, ?LINE|B])).
-define(display(A), ?display("~w",[A])).
-endif.
%%------------------------------------------------------------------------------
-ifdef(DEBUG_FLAGS).
-ifndef(DEBUG).
-define(DEBUG, true).
-endif.
-endif.
%%------------------------------------------------------------------------------
-ifdef(DEBUG).
-define(debug(A), ?display(A)).
-define(debug(A, B), ?display(A, B)).
-define(if_debug(A), A).
-else.
-define(debug(_A), ok).
-define(debug(_A, _B), ok).
-define(if_debug(_A), ok).
-endif.
%%------------------------------------------------------------------------------
-ifdef(DEBUG_FLAGS).
-define(debug_flag(A, B),
        case (?DEBUG_FLAGS band A) =/= 0 of
            true -> ?display(B);
            false -> ok
        end).
-define(debug_flag(A, B, C),
        case (?DEBUG_FLAGS band A) =/= 0 of
            true ->?display(B, C);
            false -> ok
        end).
-else.
-define(debug_flag(_A, _B), ?debug(_B)).
-define(debug_flag(_A, _B, _C), ?debug(_B, _C)).
-endif.
%%------------------------------------------------------------------------------
-type scheduler() :: pid().
-type logger()    :: pid().
-type options()   :: proplists:proplist().
%%------------------------------------------------------------------------------
%% Logger verbosity
-define(lerror, 0).
-define(lwarn, 1).
-define(linfo, 2).
-define(ldebug, 3).
-define(ltrace, 4).

-define(MAX_VERBOSITY, ?ltrace).
-define(DEFAULT_VERBOSITY, ?linfo).

-define(log(Logger, Level, Format, Data),
        concuerror_logger:log(Logger, Level, Format, Data)).

-define(mf_log(Logger, Level, Format, Data),
        concuerror_logger:log(Logger, Level, "~p:~p " ++ Format,
                              [?MODULE, ?LINE|Data])).

-define(info(Logger, Format, Data),
        ?log(Logger, ?linfo, Format, Data)).

-define(debug(Logger, Format, Data),
        ?mf_log(Logger, ?ldebug, Format, Data)).

-define(trace(Logger, Format, Data),
        ?mf_log(Logger, ?ltrace, Format, Data)).

-define(trace_nl(Logger, Format, Data),
        ?log(Logger, ?ltrace, Format, Data)).

-type log_level() :: ?lerror | ?lwarn | ?linfo | ?ldebug | ?ltrace.

-define(TICKER_TIMEOUT, 500).
%%------------------------------------------------------------------------------
-define(crash(Reason), exit({?MODULE, Reason})).
%%------------------------------------------------------------------------------
%% Scheduler's timeout
-define(MINIMUM_TIMEOUT, 1000).
%%------------------------------------------------------------------------------
-type message_info() :: ets:tid().

-define(new_message_info(Id), {Id, undefined, undefined, undefined}).
-define(message_pattern, 2).
-define(message_sent, 3).
-define(message_delivered, 4).
%%------------------------------------------------------------------------------
-type ets_tables() :: ets:tid().

-define(ets_name_none, 0).
-define(new_ets_table(Tid, Protection),
        {Tid, unknown, unknown, Protection, unknown, true}).
-define(new_system_ets_table(Tid, Protect),
        {Tid, Tid, self(), Protect, unknown, true}).
-define(ets_name, 2).
-define(ets_owner, 3).
-define(ets_protection, 4).
-define(ets_heir, 5).
-define(ets_alive, 6).
-define(ets_match_owner_to_name_heir(Owner), {'_', '$1', Owner, '_', '$2', true}).
-define(ets_match_name(Name), {'$1', Name, '$2', '$3', '_', true}).
-define(ets_match_mine(), {'_', '_', self(), '_', '_', '_'}).
%%------------------------------------------------------------------------------
-type processes() :: ets:tid().
-type symbolic_name() :: string().

-define(process_name_none, 0).
-define(new_process(Pid, Symbolic),
        {Pid, running, ?process_name_none, Symbolic, 0, regular}).
-define(new_system_process(Pid, Name),
        {Pid, running, Name, atom_to_list(Name), 0, system}).
-define(process_pat_pid(Pid),                {Pid,      _,    _, _, _,    _}).
-define(process_pat_pid_name(Pid, Name),     {Pid,      _, Name, _, _,    _}).
-define(process_pat_pid_status(Pid, Status), {Pid, Status,    _, _, _,    _}).
-define(process_pat_pid_kind(Pid, Kind),     {Pid,      _,    _, _, _, Kind}).
-define(process_status, 2).
-define(process_name, 3).
-define(process_symbolic, 4).
-define(process_children, 5).
-define(process_kind, 6).
-define(process_match_name_to_pid(Name),  {'$1',   '_', Name, '_', '_', '_'}).
%%------------------------------------------------------------------------------
-type links() :: ets:tid().

-define(links(Pid1, Pid2), [{Pid1, Pid2, active}, {Pid2, Pid1, active}]).
-define(links_match_mine(), {self(), '_', '_'}).
%%------------------------------------------------------------------------------
-type monitors() :: ets:tid().

-define(monitor(Ref, Target, Source, Status),{Target, {Ref, Source}, Status}).
-define(monitors_match_mine(), {self(), '_', '_'}).
-define(monitor_match_to_target_source(Ref), {'$1', {Ref, '$2'}, active}).
%%------------------------------------------------------------------------------
-type modules() :: ets:tid().
%%------------------------------------------------------------------------------
-type label() :: reference().

-type mfargs() :: {atom(), atom(), [term()]}.
-type receive_pattern_fun() :: fun((term()) -> boolean()).

-type location() :: 'exit' | [non_neg_integer() | {file, string()}].

-type index() :: non_neg_integer().

-record(message, {
          data       :: term(),
          message_id :: reference()
         }).

-type message() :: #message{}.

-record(builtin_event, {
          actor = self()   :: pid(),
          extra            :: term(),
          exiting = false  :: boolean(),
          mfa              :: mfargs(),
          result           :: term(),
          status = ok      :: 'ok' | {'crashed', term()} | 'unknown',
          trapping = false :: boolean()
         }).

-type builtin_event() :: #builtin_event{}.

-record(message_event, {
          cause_label      :: label(),
          message          :: message(),
          patterns = none  :: 'none' | receive_pattern_fun(),
          recipient        :: pid(),
          sender = self()  :: pid(),
          trapping = false :: boolean(),
          type = message   :: 'message' | 'exit_signal'
         }).

-type message_event() :: #message_event{}.

-record(receive_event, {
          %% clause_location :: location(),
          message            :: message() | 'after',
          patterns           :: receive_pattern_fun(),
          recipient = self() :: pid(),
          timeout = infinity :: timeout(),
          trapping = false   :: boolean()
         }).

-type receive_event() :: #receive_event{}.

-record(exit_event, {
          actor = self()            :: pid(),
          links = []                :: [pid()],
          monitors = []             :: [{reference(), pid()}],
          name = ?process_name_none :: ?process_name_none | atom(),
          reason = normal           :: term(),
          stacktrace = []           :: [term()],
          status = running          :: running | waiting,
          trapping = false          :: boolean()
         }).

-type exit_event() :: #exit_event{}.

-type event_info() ::
        builtin_event() |
        exit_event()    |
        message_event() |
        receive_event().

-record(event, {
          actor          :: pid() | {pid(), pid()}, %% Pair: message from/to
          event_info     :: event_info(),
          label          :: label(),
          location       :: location(),
          special = none :: term() %% XXX: Specify
         }).

-type event() :: #event{}.

-type instrumented_tag() :: 'apply' | 'call' | 'receive'.

-type concuerror_warnings() ::
        'none' | {[concuerror_warning_info()], [event()]}.

-type concuerror_warning_info() ::
        {'crash', pid(), index()} |
        {'deadlock', [pid()]} |
        {'sleep_set_block', [pid()]}.

%%------------------------------------------------------------------------------

-define(RACE_FREE_BIFS,
        [{erlang, N, A} ||
            {N, A} <-
                [
                 {atom_to_list,1},
                 {'bor', 2},
                 {binary_to_list, 1},
                 {binary_to_term, 1},
                 {bump_reductions, 1}, %% XXX: This may change
                 {display, 1},
                 {dt_append_vm_tag_data, 1},
                 {dt_spread_tag, 1},
                 {dt_restore_tag,1},
                 {error, 1},
                 {error, 2},
                 {exit, 1},
                 {float_to_list, 1},
                 {function_exported, 3},
                 {integer_to_list,1},
                 {iolist_size, 1},
                 {iolist_to_binary, 1},
                 {list_to_atom, 1},
                 {list_to_integer, 1},
                 {list_to_tuple, 1},
                 {make_fun, 3},
                 {make_tuple, 2},
                 {md5, 1},
                 {phash, 2},
                 {raise, 3},
                 {ref_to_list,1},
                 {setelement, 3},
                 {term_to_binary, 1},
                 {throw, 1},
                 {tuple_to_list, 1}
                ]]
        ++ [{lists, N, A} ||
               {N, A} <-
                   [
                    {keyfind, 3},
                    {keymember, 3},
                    {keysearch, 3},
                    {member, 2},
                    {reverse, 2}
                   ]]
        ++ [{file, N, A} ||
               {N, A} <-
                   [
                    {native_name_encoding, 0}
                   ]]
        ++ [{prim_file, N, A} ||
               {N, A} <-
                   [
                    {internal_name2native, 1}
                   ]]
       ).

-define(DO_NOT_INSTRUMENT,
       [io]).
