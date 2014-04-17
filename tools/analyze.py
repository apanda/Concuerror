import networkx as nx
import sys
import re
DEP_REGEX='\\{(\d+), (\w+)\\}'
def analyze(fname):
  n_lines = {}
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
    if proc == 'P' and type.startswith('send') and '$gen' in type:
        deps = filter(lambda (x, y): y != 'proc_step', deps)
        entry_nodes.append(step)
        n_lines[step] = type
    if proc == 'P' and type.startswith('timeout'):
        deps = filter(lambda (x, y): y != 'proc_step', deps)
        entry_nodes.append(step)
        n_lines[step] = type
    dep_len.append((step, len(deps)))
    G.add_node(step, dict([('proc', proc), ('type', type), ('loc', loc)]))
    for (dep_node, dep_type) in deps:
      G.add_edge(dep_node, step, dict([('type', dep_type)]))
    if proc == 'P' and loc == 'exit':
      # Don't care beyond here, break
      exit_node = step
      break
  print "Total deps = %d, relevant deps = %d"%(len(dep_len), len(filter(lambda (s, p):  p != 1, dep_len)))
  print "Entry nodes"
  print entry_nodes
  print "-----------------------------"
  paths = [(entry_node, nx.has_path(G, source = entry_node, target= exit_node)) for entry_node in entry_nodes]
  print paths
  valid_entries = map(lambda (a, b): a, filter(lambda (a, b): b, paths))
  print [(entry_node, nx.shortest_path_length(G, entry_node, exit_node)) for entry_node in valid_entries]
  print "%d of %d entry_nodes have path"%(len(valid_entries), len(entry_nodes))
  print "Included lines"
  print "-------------------------------------------------"
  for valid_path in valid_entries:
    print "%s: %s"%(valid_path, n_lines[valid_path])
  print "Excluded lines"
  print "-------------------------------------------------"
  invalid_entries = map(lambda (a, b): a, filter(lambda (a, b): not b, paths))
  for valid_path in invalid_entries:
    print "%s: %s"%(valid_path, n_lines[valid_path])
  all_nodes = 0
  path_nodes = 0
  for node in G.nodes():
    if node == exit_node:
      continue
    all_nodes += 1
    if nx.has_path(G, node, exit_node):
      path_nodes += 1
  print "%d of %d nodes with paths"%(path_nodes, all_nodes)
  #deps_to_keep = map(lambda (s, p): s, filter(lambda (s, p):  p != 1, dep_len))
  #G2 = G.copy()
  #nodes_to_keep = []
  #for node in G2.nodes():
    #if len(G2.predecessors(node)) != 1 or len(G2.successors(node)) != 1:
      ##if node not in deps_to_keep:
        ##print node, G2.predecessors(node), G2.successors(node)
      #nodes_to_keep.append(node)
  #nodes_to_keep = set(nodes_to_keep)
  #print "Marked %d nodes as required"%(len(nodes_to_keep))
  #for node in G2.nodes():
    #if node in nodes_to_keep or \
       #len(set(G2.predecessors(node)).intersection(nodes_to_keep)) != 0 or\
       #len(set(G2.successors(node)).intersection(nodes_to_keep)) != 0:
      #continue
    #G2.remove_node(node)
  #print "Original graph had %d nodes, new one has %d"%(len(G.nodes()), len(G2.nodes()))
  #import matplotlib
  #matplotlib.use('pdf')
  #import matplotlib.pyplot as plt
  #plt.figure(figsize=(1600, 1600))
  #nx.draw_networkx(G2, node_size=10, style='dotted', with_labels=False)
  #plt.axis('off')
  #plt.savefig("prov.pdf")

if __name__ == "__main__":
  analyze(sys.argv[1])
