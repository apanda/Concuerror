import erlastic
import bert
import sys
from collections import defaultdict, deque
def receive_filter(inp):
  return inp[2][0] == erlastic.Atom('receive_event')
def send_filter(inp):
  return inp[-1] != None
if len(sys.argv) < 2:
  print >>sys.stderr, "Usage: %s file"%(sys.argv[0])
trace = open(sys.argv[1], 'rb').read()
decoder = bert.BERTDecoder()
trace = decoder.decode(trace)
receive_events = filter(receive_filter, trace)
special_events = filter(send_filter, trace)
messages_sent = defaultdict(deque)
processes = []
participants = []
event_count = defaultdict(lambda: 0)
for event in trace:
  participants.append(str(event[1]))
  event_count[str(event[1])] += 1
participants = set(participants)
for msg in special_events:
  if msg[-1][0][0] == erlastic.Atom('message'):
    # At least it is a message
    sender = msg[1]
    special = msg[-1][0]
    body = str(special[1][3][1])
    receiver = str(special[1][5])
    messages_sent[(receiver, body)].append(msg)
    processes.append(receiver)
processes = set(processes)
total = 0
found = 0
relationships = {}
for rec_msg in receive_events:
  receiver = str(rec_msg[1])
  rec_event = rec_msg[2]
  body = str(rec_event[1][1])
  total += 1
  ref = rec_msg[-3]
  if messages_sent.has_key((receiver, body)) and len(messages_sent[(receiver, body)]) > 0:
    msg = messages_sent[(receiver, body)].popleft()
    relationships[msg[-3]] = ref
    #if len(messages_sent[(receiver, body)]) != 1:
      #print >>sys.stderr, "More than 1 matching event %s %s %d"%(receiver, body, len(messages_sent[(receiver, body)]))
    found += 1
print "Matched %d/%d events"%(found, total)
print "%d participants"%(len(participants))
print "%d participants"%(len(filter(lambda k: event_count[k] > 1, participants)))
print [(k, event_count[k]) for k in sorted(filter(lambda k: event_count[k] > 1, participants))]
  #else:
    #print "Found for %s %s"%(str(receiver), str(body))
