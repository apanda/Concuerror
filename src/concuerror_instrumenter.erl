%% -*- erlang-indent-level: 2 -*-

-module(concuerror_instrumenter).

-export([instrument/2]).

-define(inspect, concuerror_inspect).

-define(flag(A), (1 bsl A)).

-define(input, ?flag(1)).
-define(output, ?flag(2)).

-define(ACTIVE_FLAGS, [?input, ?output]).

%% -define(DEBUG_FLAGS, lists:foldl(fun erlang:'bor'/2, 0, ?ACTIVE_FLAGS)).
-include("concuerror.hrl").

-spec instrument(cerl:cerl(), ets:tid()) -> cerl:cerl().

instrument(CoreCode, Instrumented) ->
  ?if_debug(Stripper = fun(Tree) -> cerl:set_ann(Tree, []) end),
  ?debug_flag(?input, "~s\n",
              [cerl_prettypr:format(cerl_trees:map(Stripper, CoreCode))]),
  {R, {Instrumented, _}} =
    cerl_trees:mapfold(fun mapfold/2, {Instrumented, 1}, CoreCode),
  ?debug_flag(?output, "~s\n",
              [cerl_prettypr:format(cerl_trees:map(Stripper, R))]),
  R.

mapfold(Tree, {Instrumented, Var}) ->
  Type = cerl:type(Tree),
  NewTree =
    case Type of
      apply ->
        Op = cerl:apply_op(Tree),
        case cerl:is_c_fname(Op) of
          true -> Tree;
          false ->
            OldArgs = cerl:make_list(cerl:apply_args(Tree)),
            inspect(apply, [Op, OldArgs], Tree)
        end;
      call ->
        Module = cerl:call_module(Tree),
        Name = cerl:call_name(Tree),
        Args = cerl:call_args(Tree),
        case is_safe(Module, Name, length(Args), Instrumented) of
          true -> Tree;
          false ->
            inspect(call, [Module, Name, cerl:make_list(Args)], Tree)
        end;
      'receive' ->
        Timeout = cerl:receive_timeout(Tree),
        % Action here is really what is done for the after clause.
        Fun = receive_matching_fun(Tree),
        ReceiveAction = receive_case_statement(Tree, Fun, Timeout),
        % Step 1: Call ?inspect:instrumented with the match function and timeout
        % to see what succeeds.
        % apanda: OK, so now we instead just call inspect with 2 functions and hope
        % this works
        inspect('receive', [Fun, Timeout, ReceiveAction, receive_original(Tree)], Tree);
      _ -> Tree
    end,
  NewVar =
    case Type of
      'receive' -> Var + 2;
      _ -> Var
    end,
  {NewTree, {Instrumented, NewVar}}.

inspect(Tag, Args, Tree) ->
  CTag = cerl:c_atom(Tag),
  CArgs = cerl:make_list(Args),
  cerl:update_tree(Tree, call,
                   [[cerl:c_atom(?inspect)],
                    [cerl:c_atom(instrumented)],
                    [CTag, CArgs, cerl:abstract(cerl:get_ann(Tree))]]).

% apanda: Sometimes we just need the original
receive_original(InTree) ->
  ToVar = cerl:c_var(timeout),
  Tree = case cerl:receive_timeout(InTree) =:= cerl:c_atom(infinity) of
    false ->
      cerl:update_c_receive(InTree,
                           cerl:receive_clauses(InTree),
                           ToVar,
                           cerl:receive_action(InTree));
    true -> InTree
  end,
  cerl:update_tree(Tree, 'fun', [[ToVar], [Tree]]).

% apanda: Generate a function which receives messages etc.
modify_receive_clause(Clause, MatchFun, Timeout) ->
  Pats = cerl:clause_pats(Clause),
  Guard = cerl:clause_guard(Clause),
  Body = cerl:clause_body(Clause),
  % Poor man's assertion, number of patterns in clause are 1
  1 = length(Pats),
  [PatBodyInternal] = Pats,
  PatBody = case cerl:is_c_alias(PatBodyInternal) of
    true -> cerl:alias_var(PatBodyInternal);
    false -> PatBodyInternal
  end,
  %io:format("Pattern body is ~p~n", [PatBody]),
  CallToRecord = cerl:update_tree(Clause, call,
                                  [[cerl:c_atom(?inspect)],
                                   [cerl:c_atom(instrumented_recv)],
                                   [PatBody, MatchFun, Timeout]]),
  FinalBody = cerl:update_tree(Clause, seq, [[CallToRecord], [Body]]),
  cerl:update_c_clause(Clause, Pats, Guard, FinalBody).

receive_case_statement(InTree, MatchFun, Timeout) ->
  OriginalClauses = cerl:receive_clauses(InTree),
  Clauses = lists:map(fun (C) -> 
                              modify_receive_clause(C, MatchFun, Timeout)
                      end, 
                      OriginalClauses), 
  Tree = 
  case cerl:receive_timeout(InTree) =:= cerl:c_atom(infinity) of
    true ->
      cerl:update_c_receive(InTree,
                 Clauses,
                 cerl:receive_timeout(InTree),
                 cerl:receive_action(InTree));
    false ->
      AfterBody = cerl:receive_action(InTree),
      CallToRecordAfter = cerl:update_tree(AfterBody, call,
                                           [[cerl:c_atom(?inspect)],
                                            [cerl:c_atom(instrumented_after)],
                                            [MatchFun, Timeout]]),
      NewAfterBody = cerl:update_tree(AfterBody, seq, [[CallToRecordAfter], [AfterBody]]),
      cerl:update_c_receive(InTree,
                 Clauses,
                 cerl:receive_timeout(InTree),
                 NewAfterBody)
  end,
  cerl:update_tree(Tree, 'fun', [[], [Tree]]).

receive_matching_fun(Tree) ->
  Msg = cerl:c_var(message),
  Clauses = extract_patterns(cerl:receive_clauses(Tree)),
  Body = cerl:update_tree(Tree, 'case', [[Msg], Clauses]),
  cerl:update_tree(Tree, 'fun', [[Msg], [Body]]).

extract_patterns(Clauses) ->
  extract_patterns(Clauses, []).
% At the end just add an extra one for the case where none of the
% clauses are matched so we return false
extract_patterns([], Acc) ->
  Pat = [cerl:c_var(message)],
  Guard = cerl:c_atom(true),
  Body = cerl:c_atom(false),
  lists:reverse([cerl:c_clause(Pat, Guard, Body)|Acc]);
% Extracting clause patterns starts by replacing all bodys with true
extract_patterns([Tree|Rest], Acc) ->
  Body = cerl:c_atom(true),
  Pats = cerl:clause_pats(Tree),
  Guard = cerl:clause_guard(Tree),
  extract_patterns(Rest, [cerl:update_c_clause(Tree, Pats, Guard, Body)|Acc]).

is_safe(Module, Name, Arity, Instrumented) ->
  case
    cerl:is_literal(Module) andalso
    cerl:is_literal(Name)
  of
    false -> false;
    true ->
      NameLit = cerl:concrete(Name),
      ModuleLit = cerl:concrete(Module),
      case erlang:is_builtin(ModuleLit, NameLit, Arity) of
        true ->
          (ModuleLit =:= erlang
           andalso
             (erl_internal:guard_bif(NameLit, Arity)
              orelse erl_internal:arith_op(NameLit, Arity)
              orelse erl_internal:bool_op(NameLit, Arity)
              orelse erl_internal:comp_op(NameLit, Arity)
              orelse erl_internal:list_op(NameLit, Arity)
             )
          ) orelse
            ModuleLit =:= binary
            orelse
            ModuleLit =:= unicode
            orelse %% The rest are defined in concuerror.hrl
            lists:member({ModuleLit, NameLit, Arity}, ?RACE_FREE_BIFS);
        false ->
          %% This special test is needed as long as erlang:apply/3 is not
          %% classified as a builtin in case we instrument erlang before we find
          %% a call to it. We need to not instrument it in erlang.erl itself,
          %% though.
          (ets:lookup_element(Instrumented, {current}, 2) =:= erlang
           orelse
           {ModuleLit, NameLit, Arity} =/= {erlang, apply, 3})
            andalso
            ets:lookup(Instrumented, ModuleLit) =/= []
      end
  end.
