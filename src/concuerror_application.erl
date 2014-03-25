%% -*- erlang-indent-level: 2 -*-

-module(concuerror_application).

-export([start_application/2]).

-include("concuerror.hrl").

% Load and start OTP application. The problem is simple:
% - application_controller is ultimately responsible for loading and executing the application code.
% - application_controller starts early in the Erlang boot process and is hence not instrumented. (I 
%   suspect trying to instrument it would make everything fail).
% - application_controller's spawn calls thus do not result in the loader being called.
% - Sadness

% If no OTP application to start, do nothing.
-spec start_application(atom(), processes()) -> ok. 

start_application(undefined, _) ->
  ok;


% If there is an OTP application to start.
start_application(ApplicationName, Instrumented) ->
  %io:format("Called to start application ~p~n", [ApplicationName]),
  % First find the app file.
  case code:where_is_file(atom_to_list(ApplicationName) ++ ".app") of
    non_existing ->
      io:format("Application file not found"),
      throw(opt_error);
    Name ->
      % Convert it to an Erlang list structure
      case prim_consult(Name) of
       {ok, AppDescr} ->
          %io:format("Got application ~p~n", [AppDescr]),
          [{application, ApplicationName, OptList}] = AppDescr, 
          Modules = proplists:get_value(modules, OptList),
          Applications = proplists:get_value(applications, OptList),
          % Load dependencies
          load_other_apps(Applications, Instrumented),
          % Compile and load modules for the current application
          compile_modules(Modules, Instrumented),
          % Load the application
          io:format("[concuerror_application]: Before starting application~p: ~p~n", [Name, registered()]),
          application:load(AppDescr),
          % Start the application
          application:start(ApplicationName),
          io:format("[concuerror_application]: After starting application~p: ~p~n", [Name, registered()]);
          %io:format("Started thus far: ~p~n", [application:loaded_applications()]);
       {error, Reason} ->
          io:format("Error reading application file ~p~n", [Reason])
       end
  end,
  ok.

% Load dependencies. This will not handle circular dependencies but hope
load_other_apps([], _Instrumented) ->
  ok;
load_other_apps([App|Rest], Instrumented) ->
  LoadedApps = [Name || {Name, _, _} <- application:loaded_applications()],
  ok = case lists:member(App, LoadedApps) of
    true -> ok;
    _ -> start_application(App, Instrumented)
  end,
  load_other_apps(Rest, Instrumented).

% Go about compiling these modules
compile_modules(Modules, Instrumented) ->
  [compile_module(Module, Instrumented) || Module <- Modules],
  ok.

compile_module(Module, Instrumented) ->
  case code:is_loaded(Module) of
    {file, _} -> io:format("~p already loaded~n", [Module]),
            ok;
    false -> concuerror_loader:load(Module, Instrumented)
  end.
% ------------------------------------------------------------
% Stolen from Erlang code
% ------------------------------------------------------------
file_binary_to_list(Bin) ->
    Enc = case epp:read_encoding_from_binary(Bin) of
              none -> epp:default_encoding();
              Encoding -> Encoding
          end,
    case catch unicode:characters_to_list(Bin, Enc) of
        String when is_list(String) ->
            {ok, String};
        _ ->
            error
    end.

prim_consult(FullName) ->
    case erl_prim_loader:get_file(FullName) of
	{ok, Bin, _} ->
            case file_binary_to_list(Bin) of
                {ok, String} ->
                    case erl_scan:string(String) of
                        {ok, Tokens, _EndLine} ->
                            prim_parse(Tokens, []);
                        {error, Reason, _EndLine} ->
                            {error, Reason}
                    end;
                error ->
                    error
            end;
	error ->
	    {error, enoent}
    end.

prim_parse(Tokens, Acc) ->
    case lists:splitwith(fun(T) -> element(1,T) =/= dot end, Tokens) of
	{[], []} ->
	    {ok, lists:reverse(Acc)};
	{Tokens2, [{dot,_} = Dot | Rest]} ->
	    case erl_parse:parse_term(Tokens2 ++ [Dot]) of
		{ok, Term} ->
		    prim_parse(Rest, [Term | Acc]);
		{error, _R} = Error ->
		    Error
	    end;
	{Tokens2, []} ->
	    case erl_parse:parse_term(Tokens2) of
		{ok, Term} ->
		    {ok, lists:reverse([Term | Acc])};
		{error, _R} = Error ->
		    Error
	    end
    end.
