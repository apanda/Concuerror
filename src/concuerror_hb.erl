%% -*- erlang-indent-level: 2 -*-

-module(concuerror_hb).
-include("concuerror.hrl").

%% User interface
-export([sent_message_filter/1, print_events/2, assign_msg_hb/2, assign_potential_links/2]).

match_received_to_sent(#event{event_info=#receive_event{message='after'}}=Event, SentMessages) ->
  {Event, SentMessages};
match_received_to_sent(#event{event_info=#receive_event{}}=Event, SentMessages) ->
  match_received_to_sent(Event, SentMessages, queue:new());
match_received_to_sent(Event, SentMessages) ->
  {Event, SentMessages}.

message_from_sent(#event{special = Special}) ->
  {message, MsgEvent} = proplists:lookup(message, Special),
  #message_event{recipient = Recipient, message = #message{data = Message, id=ID}} = MsgEvent,
  {Recipient, Message, ID}.

match_received_to_sent(Event = #event{
                         event_info=#receive_event{
                           message=#message{data=Body}=Message,
                           recipient=Receiver,
                           patterns=PatFun} = RecEvent},
                       SentMessages,
                       Acc) ->
  case queue:len(SentMessages) of
    0 -> {Event, Acc};
    _ -> {{value, Sent}, NewSent} = queue:out(SentMessages),
         {Destination, SendBody, ID} = message_from_sent(Sent),
         case Destination =:= Receiver andalso Body =:= SendBody of
           true ->
            NewReceiveEvent = RecEvent#receive_event{message=Message#message{id=ID}},
            NewEvent = Event#event{event_info = NewReceiveEvent, 
                                   special=[{message_received, ID, PatFun}]},
            NewQueue = queue:join(Acc, NewSent),
            {NewEvent, NewQueue};
           false ->
            NewAcc = queue:in(Sent, Acc),
            match_received_to_sent(Event, NewSent, NewAcc)
         end
  end.

potential_filter(Receiver, PatFun, {Recipient, Message, _}) ->
  Receiver =:= Recipient andalso PatFun(Message).

potential_links(#event{
                  event_info=#receive_event{
                    recipient=Receiver,
                    patterns=PatFun
                  }},
                SentMessages) ->
  MatchingSends = 
    lists:filter(fun (M) -> potential_filter(Receiver, PatFun, message_from_sent(M)) end,
              SentMessages),
  lists:map(fun (M) -> {_, _, ID} = message_from_sent(M), ID end, MatchingSends);
potential_links(_, _) ->
  [].

assign_msg_hb([Ev|Rest], SentEvents, Acc) ->
  {NewEv, RemainingSent} = match_received_to_sent(Ev, SentEvents),
  assign_msg_hb(Rest, RemainingSent, [NewEv | Acc]);
assign_msg_hb([], _, Acc) ->
  Acc.

% Assign happens before relationship 
-spec assign_msg_hb(queue:queue(event()), queue:queue(event())) -> queue:queue(event()).
assign_msg_hb(Events, SentEvents) ->
  EventQueue = queue:to_list(Events),
  queue:from_list(lists:reverse(assign_msg_hb(EventQueue, SentEvents, []))).

assign_potential_links([Ev|Rest], SentEvents, Acc) ->
  case potential_links(Ev, SentEvents) of 
    [] -> assign_potential_links(Rest, SentEvents, [Ev|Acc]);
    Links -> #event{special = Special} = Ev, 
             NewSpecial = [{possible_message_receives, Links} | Special],
             assign_potential_links(Rest, SentEvents, [Ev#event{special=NewSpecial} | Acc])
  end;
assign_potential_links([], _, Acc) ->
  lists:reverse(Acc).

% Add metadata to events to indicate all possible sources for a message.
-spec assign_potential_links(queue:queue(event()), queue:queue(event())) -> queue:queue(event()).
assign_potential_links(Events, SentEvents)->
  SentList = queue:to_list(SentEvents), 
  queue:from_list(assign_potential_links(queue:to_list(Events), SentList, [])).

% Output events to a file. The file is BERT encoded.
-spec print_events(io:device(), [event()]) -> ok.
print_events(Dev, Events) ->
  Encoded = bert:encode(Events),
  ok = file:write(Dev, Encoded),
  ok = file:close(Dev).

% Select only sent messages
-spec sent_message_filter(event()) -> boolean().
sent_message_filter(#event{special=Special}) ->
  proplists:lookup(message, Special) =/= none.
