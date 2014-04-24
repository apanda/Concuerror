import networkx as nx
import sys
import re
DEP_REGEX='\\{(\d+), (\w+)\\}'
def printed_analysis(G, entry_nodes, exit_node, n_lines):
  print "Entry nodes"
  print entry_nodes
  print "Exit node"
  print exit_node
  print "-----------------------------"
  paths = [(entry_node, nx.has_path(G, source = entry_node, target= exit_node)) for entry_node in entry_nodes]
  print paths
  valid_entries = map(lambda (a, b): a, filter(lambda (a, b): b, paths))
  print [(entry_node, nx.shortest_path_length(G, entry_node, exit_node)) for entry_node in valid_entries]
  print "%d of %d entry_nodes have path"%(len(valid_entries), len(entry_nodes))
  print "Included lines"
  print "-------------------------------------------------"
  for valid_path in valid_entries:
    print "%s: %s"%(valid_path, n_lines[valid_path][1])
  print "Excluded lines"
  print "-------------------------------------------------"
  invalid_entries = map(lambda (a, b): a, filter(lambda (a, b): not b, paths))
  for valid_path in invalid_entries:
    print "%s: %s"%(valid_path, n_lines[valid_path][1])
  all_nodes = 0
  path_nodes = 0
  for node in G.nodes():
    if node == exit_node:
      continue
    all_nodes += 1
    if nx.has_path(G, node, exit_node):
      path_nodes += 1
  print "%d of %d nodes with paths"%(path_nodes, all_nodes)
def to_dot(G, entry_nodes, exit_node, n_lines):
  G2= nx.to_agraph(G)
  for node in G2.nodes():
    if not nx.has_path(G2, node, exit_node):
      G2.remove_node(node)
  for entry in entry_nodes:
    G2.get_node(entry).attr['shape'] = 'diamond'
    G2.get_node(entry).attr['color'] = 'orange'
  G2.get_node(exit_node).attr['shape'] = 'octagon'
  G2.get_node(exit_node).attr['color'] = 'red'
  G2.write("graph.dot")
def is_channel(proc):
  return proc.startswith('{')
def read_graph(fname):
  n_lines = {}
  step_is_channel = {}
  f = open(fname)
  lines = f.readlines()
  lines = filter(lambda l: not l.startswith('-----'), lines)
  G = nx.DiGraph()
  dep_len = []
  entry_nodes = []
  exit_node = None
  for l in lines:
    parts = l.split('\001')
    step = parts[0]
    proc = parts[1]
    type = parts[2]
    loc = parts[3]
    deps = re.findall(DEP_REGEX, parts[4])
    deps = filter(lambda (x, y): x != '0', deps)
    step_is_channel[step] = is_channel(proc)
    if proc == 'P' and type.startswith('send') and '$gen' in type:
        deps = filter(lambda (x, y): y != 'proc_step', deps)
        entry_nodes.append(step)
    if proc == 'P' and type.startswith('timeout'):
        deps = filter(lambda (x, y): y != 'proc_step', deps)
        entry_nodes.append(step)
    deps = filter(lambda (x, y): not step_is_channel[x], deps)
    n_lines[step] = (proc, type, loc, deps)
    dep_len.append((step, len(deps)))
    G.add_node(step, dict([('proc', proc), ('type', type), ('loc', loc)]))
    for (dep_node, dep_type) in deps:
      G.add_edge(dep_node, step, dict([('type', dep_type)]))
    if proc == 'P' and loc == 'exit':
      # Don't care beyond here, break
      exit_node = step
      break
  if not exit_node:
    print "Exit node not found, dying"
    return None
  return (G, entry_nodes, exit_node, n_lines)

if __name__ == "__main__":
  tup = read_graph(sys.argv[1])
  printed_analysis(*tup)
  to_dot(*tup)
