import erlastic
import bert
import sys
from collections import defaultdict, deque

def send_filter(inp):
  return inp[-1] != None and inp[-1][0][0] == erlastic.Atom('message')
def recv_filter(inp):
  return inp[2][0] == erlastic.Atom('receive_event')
def spawn_filter(inp):
  return inp[-1] != None and \
    len(filter(lambda i: i[0] == erlastic.Atom('new'), inp[-1])) > 0

def is_after(inp):
  return inp[2][0] == erlastic.Atom('receive_event') and inp[2][1] == 'after'

if len(sys.argv) < 2:
  print >>sys.stderr, "Usage: %s file"%(sys.argv[0])

trace = open(sys.argv[1], 'rb').read()
decoder = bert.BERTDecoder()
trace = decoder.decode(trace)


filtered_trace = filter(lambda ev: send_filter(ev) or recv_filter(ev) or spawn_filter(ev), \
        trace)
ordered_trace = zip(xrange(len(filtered_trace)), filtered_trace)
event_dict = {}
for (idx, event) in ordered_trace:
  id = event[3]
  event_dict[str(id)] = (idx, event)


send_events = filter(send_filter, trace)
# Lookup event by ID
# Lookup msg by send event ID
msg_dict = {}
for msg in send_events:
  id = msg[-1][0][1][3][2]
  msg_dict[str(id)] = msg[3]

# What order do processes show up in the trace, and when
seen_actors = []
process_by_appearance = []
for event in trace:
  actor = str(event[1])
  if actor not in seen_actors:
     process_by_appearance.append(actor)
     seen_actors.append(actor)
process_first_seen = {}
process_last_seen = {}
num_interesting = defaultdict(lambda: 0)
for (idx, event) in ordered_trace:
  actor = str(event[1])
  process_last_seen[str(actor)] = idx
  if send_filter(event) or recv_filter(event):
    num_interesting[actor] += 1
  if str(actor) not in process_first_seen:
    process_first_seen[actor] = idx
process_by_appearance = filter(lambda actor: num_interesting[actor] > 0, process_by_appearance)
#process_by_appearance = process_by_appearance[1:]
filtered_order = filter(lambda (idx, ev): send_filter(ev) or recv_filter(ev) or spawn_filter(ev), \
        ordered_trace)

# Start drawing, first compute size
YMARGIN = 50
XMARGIN = 50
PIXEL_PER_SEQ = min(6.0, max(1.25, 1400.0 / float(len(ordered_trace))))
canvas_width = len(ordered_trace) * PIXEL_PER_SEQ + 8.0 + XMARGIN
canvas_height = 920
total_time = ordered_trace[-1][0]
width_per_step = canvas_width/total_time
height_per_process = (canvas_height - YMARGIN) /(2 + len(process_by_appearance))
print "Canvas %f x %d"%(canvas_width, canvas_height)
print "%d processes survived culling"%(len(process_by_appearance))
import cairo
import math
surface = cairo.PDFSurface("timeline.pdf", canvas_width, canvas_height)
ctx = cairo.Context (surface)
process_line = {}
ctx.set_source_rgb(0,0,0)
ctx.set_line_width(min(2.0, PIXEL_PER_SEQ/2.0))
ctx.set_font_size(6.0)

# Draw process timelines
for pidx in xrange(len(process_by_appearance)):
  y = (1 + pidx) * height_per_process + YMARGIN
  actor = process_by_appearance[pidx]
  start_idx = process_first_seen[actor]
  ctx.move_to(10, y)
  ctx.show_text(str(actor))
  process_line[actor] = y
  end_idx = process_last_seen[actor]
  #print "%s %d %d"%(actor, start_idx, end_idx)
  xstart = XMARGIN + (start_idx * PIXEL_PER_SEQ)
  xend = XMARGIN + (end_idx * PIXEL_PER_SEQ)
  #print "(%d %d) -> (%d %d)"%(xstart, y, xend, y)
  ctx.move_to(xstart, y)
  ctx.line_to(xend, y)
  ctx.stroke()

# Draw potentially related events
ctx.set_font_size(2.0)
recv_order = filter(lambda (idx, ev): recv_filter(ev), filtered_order)
ctx.set_source_rgb(0.8, 0.8, 0.8)
#ctx.set_dash([1, 1])
ctx.set_line_width(min(1.0, PIXEL_PER_SEQ/4.0))
for (idx, ev) in recv_order:
  if not ev[-1]:
    continue
  recv_actor = str(ev[1])
  msg_received = filter(lambda x: x[0] == erlastic.Atom('message_received'), ev[-1])
  if recv_actor not in process_line:
    continue
  dest_x = XMARGIN + (idx * PIXEL_PER_SEQ)
  dest_y = process_line[recv_actor]
  if len(msg_received) == 0:
    continue # Don't know message sender
  message_id = str(msg_received[0][1])
  if len(filter(lambda x: x[0] == erlastic.Atom('possible_message_receives'), ev[-1])) == 0:
    continue
  potential_receives = filter(lambda x: x[0] == erlastic.Atom('possible_message_receives'), ev[-1])[0][1]
  potential_receives = filter(lambda x: str(x) != message_id, potential_receives)
  for msg in potential_receives:
    message_id = str(msg)
    message_event = str(msg_dict[message_id])
    (send_idx, send_event) = event_dict[message_event]
    send_event_recipient = send_event[-1][0][1][5]
    assert(str(send_event_recipient) == recv_actor)
    send_actor = str(send_event[1])
    if send_actor not in process_line:
      continue
    src_x = XMARGIN + (send_idx * PIXEL_PER_SEQ)
    src_y = process_line[send_actor]
    ctx.move_to(src_x, src_y)
    ctx.line_to(dest_x, dest_y)
    ctx.stroke()

# Draw send and receive blobs
for (idx, ev) in filtered_order:
  actor = str(ev[1])
  if actor not in process_line:
    continue
  actor_y = process_line[actor]
  x = XMARGIN + (idx * PIXEL_PER_SEQ)
  if send_filter(ev):
    ctx.set_source_rgb(240.0/255.0, 159.0/255.0, 71.0/255.0)
  elif recv_filter(ev):
    if is_after(ev):
      ctx.set_source_rgb(10.0/255.0, 32.0/255.0, 42.0/255.0)
    else:
      ctx.set_source_rgb(141.0/255.0, 160.0/255.0, 203.0/255.0)
  elif spawn_filter(ev):
    ctx.set_source_rgb(168.0/255.0, 69.0/255.0, 22.0/255.0)
  ctx.arc(x, actor_y, min(2.5, PIXEL_PER_SEQ*2), 0, 2 * math.pi)
  ctx.fill()
  if send_filter(ev):
    #body = ev[-1][0]
    body = ev[-1][0][1][3][1][-1]
    if hasattr(body, '__iter__') and erlastic.Atom('put_chars') in body:
      continue
    ctx.save()
    ctx.move_to(x, actor_y - PIXEL_PER_SEQ * 2)
    ctx.rotate(-1.0 * math.pi/2)
    body = str(body)
    body = body.replace('Atom', '')
    ctx.show_text(str(body)[:20])
    ctx.restore()

# Draw causal lines between sends and receives
ctx.set_source_rgb(0, 0, 0)
ctx.set_dash([1, 1])
ctx.set_line_width(min(2.0, PIXEL_PER_SEQ/2.0))
for (idx, ev) in recv_order:
  if not ev[-1]:
    continue
  recv_actor = str(ev[1])
  msg_received = filter(lambda x: x[0] == erlastic.Atom('message_received'), ev[-1])
  if len(msg_received) == 0:
    continue # Don't know message sender
  message_id = str(msg_received[0][1])
  message_event = str(msg_dict[message_id])
  (send_idx, send_event) = event_dict[message_event]
  send_actor = str(send_event[1])
  if send_actor not in process_line or recv_actor not in process_line:
    continue
  src_x = XMARGIN + (send_idx * PIXEL_PER_SEQ)
  src_y = process_line[send_actor]
  dest_x = XMARGIN + (idx * PIXEL_PER_SEQ)
  dest_y = process_line[recv_actor]
  ctx.move_to(src_x, src_y)
  ctx.line_to(dest_x, dest_y)
  ctx.stroke()

# Draw causal lines between spawn and spawned processes
ctx.set_source_rgb(168.0/255.0, 69.0/255.0, 22.0/255.0)
ctx.set_dash([1, 2, 1, 1])
ctx.set_line_width(min(2.0, PIXEL_PER_SEQ/2.0))
spawn_order = filter(lambda (idx, ev): spawn_filter(ev), filtered_order)
for (idx, ev) in spawn_order:
  orig_actor = str(ev[1])
  new_spec = filter(lambda i: i[0] == erlastic.Atom('new'), ev[-1])[0]
  new_actor = str(new_spec[1])
  if orig_actor not in process_line or new_actor not in process_line:
    continue
  src_x = XMARGIN + (idx * PIXEL_PER_SEQ)
  src_y = process_line[orig_actor]
  dest_x = XMARGIN + (process_first_seen[new_actor]* PIXEL_PER_SEQ)
  dest_y = process_line[new_actor]
  ctx.move_to(src_x, src_y)
  ctx.line_to(dest_x, dest_y)
  ctx.stroke()

surface.show_page()
