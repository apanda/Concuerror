%% -*- erlang-indent-level: 2 -*-

-module(concuerror_timer).

-export([send_event_after/3, send_after/3, cancel_timer/1]).

-spec send_event_after(module(), timeout(), atom()) -> pid(). 

send_event_after(Who, When, What) ->
  Pid = spawn(fun() -> internal_send_event_after(Who, When, What) end),
  Pid.

internal_send_event_after(Who, When, What) ->
  receive
    cancel -> ok
    after When ->
      gen_fsm:send_event(Who, What)
  end.

-spec send_after(timeout(), pid(), any()) -> pid(). 

send_after(When, Who, What) ->
  Pid = spawn(fun() -> internal_send_after(Who, When, What) end),
  {ok, Pid}.

internal_send_after(Who, When, What) ->
  receive
    cancel -> ok
    after When ->
      Who ! What
  end.

-spec cancel_timer(pid()) -> ok.

cancel_timer(Pid) -> 
  Pid ! cancel,
  {ok, cancel}.
