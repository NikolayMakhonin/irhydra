// Copyright 2015 Google Inc. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:html';

import 'package:polymer/polymer.dart';

import 'package:saga/src/parser.dart' as parser;
import 'package:ui_utils/xref.dart';
import 'package:ui_utils/bootstrap.dart' as bs;
import 'package:saga/src/flow.dart' as flow;
import 'package:ui_utils/delayed_reaction.dart';
import 'package:saga/src/ui/ir_pane/ir_pane.dart' as ir_pane;

class Graph {
  final blocks;
  final blockTicks = null;

  Graph(this.blocks);
}

timeAndReport(action, name) {
  final stopwatch = new Stopwatch()..start();
  final result = action();
  print("${name} took ${stopwatch.elapsedMilliseconds} ms.");
  return result;
}

@CustomTag('saga-app')
class SagaApp extends PolymerElement {
  @observable var graph;

  var blockRef;
  var flowData;

  /// Constructor used to create instance of SagaApp.
  SagaApp.created() : super.created();

  final _entities = {};

  HtmlElement get code => $['code'];

  /// Called when main-app has been fully prepared (Shadow DOM created,
  /// property observers set up, event listeners attached).
  ready() {
    super.ready();

    lookup(def) {
      /*if (def is flow.Use) {
        return lookup(def.def);
      } if (def is flow.Phi) {
        return "<small>${def}</small>\n" + def.inputs.where((v) => v.def != def).map(lookup).join('\n');
      } else if (def is flow.Select) {
        return [lookup(def.thenValue),
                lookup(def.elseValue),
                lookup(def.inputs[0].def),
                "${def.origin} in ${def.block.origin.name}"].join('\n');
      } else if (def.origin != null) {
        return "${def.origin} in ${def.block.origin.name}";
      }*/
      return def.toString();
    }

    code.onMouseOver.listen((e) {
      final key = e.target.attributes['data-entity'];
      if (key != null) {
        final use = flowData.refUses[_entities[key]];
        if (use != null && use.def != null) {
          final text = lookup(use.def);
          if (text != null) {
            POPOVER.show(e.target, "<pre>${text}</pre>");
          }
        }
      }
    });

    code.onMouseOut.listen((e) {
      final key = e.target.attributes['data-entity'];
      if (key != null) {
        POPOVER.destroy(e.target);
      }
    });

    HttpRequest.getString("code.asm").then((text) {
      final code = timeAndReport(() => parser.parse(text), "parsing");
      render(code);
    });
  }

  render(pcode) {
    var blocks;
    timeAndReport(() {
      flowData = flow.build(pcode);
      blocks = flowData.blocks;
      graph = new Graph(blocks);
    }, "flow analysis");

    timeAndReport(() => updateUI(pcode, blocks), "rendering");
  }

  updateUI(pcode, blocks) {
    blockRef = new XRef((id) {
      return "<pre>" + blocks[id].asm.join('\n') + "</pre>";
    });
    var result = [];

    _entities.clear();

    span(text, type, {entity}) {
      final span = new SpanElement()
        ..text = text
        ..classes.add("asm-${type}");
      if (entity != null) {
        var key = "${_entities.length}";
        span.attributes['data-entity'] = key;
        _entities[key] = entity;
      }
      return span;
    }

    label(text) => span(text, 'label');
    keyword(text) => span(text, 'opcode');

    formatOperand(val) {
      if (val is parser.RegRef) {
        return [span(val.name, 'register', entity: val)];
      } else if (val is parser.Addr) {
        final result = ["["];
        if (val.base != null) result.addAll(formatOperand(val.base));
        if (val.index != null) {
          if (result.isNotEmpty) result.add(" + ");
          result.addAll(formatOperand(val.index));
          if (val.scale != 1) {
            result.add("*${val.scale}");
          }
        }
        if (val.offset != null && val.offset != 0) {
          var negative = false;
          var offset = val.offset;
          if (offset.startsWith("-")) {
            negative = true;
            offset = offset.substring(1);
          }

          result.add(" ${negative ? '-' : '+'} ");
          result.add(span(offset, 'immediate'));
        }
        result.add(']');
        return result;
      } else if (val is parser.Imm) {
        return [span(val.value, 'immediate')];
      } else if (val is parser.CallTarget) {
        final el = span(val.target, 'call-target');

        final delayedHide = new DelayedReaction(delay: const Duration(milliseconds: 150));
        var visible = false;

        doHide(_) {
          delayedHide.schedule(() {
            bs.popover(el).destroy();
            visible = false;
          });
        }

        el.onMouseOver.listen((_) {
          if (!visible) {
            var po = bs.popover(el, {
              "title": '',
              "content": parser.CallTargetAttribute.values.map((attr) => "<button class='${val.attributes.contains(attr) ? 'set' : ''}' data-attr='${attr.name}'>((${attr}))</button>"),
              "trigger": "manual",
              "placement": "top",
              "html": true,
              "container": el
            })..show();
            po.tip.onMouseOver.listen((_) => delayedHide.cancel());
            po.tip.onMouseOut.listen(doHide);
            visible = true;
          } else {
            delayedHide.cancel();
          }
        });
        el.onMouseOut.listen(doHide);

        el.onClick.listen((e) {
          final attrName = e.target.attributes['data-attr'];
          if (attrName != null) {
            final attr = parser.CallTargetAttribute.parse(attrName);
            if (val.attributes.contains(attr)) {
              val.attributes.remove(attr);
            } else {
              val.attributes.add(attr);
            }

            render(pcode);
          }
        });

        return [el];
      } else {
        throw "error: ${val.runtimeType}";
      }
    }

    format(op) {
      if (op.opcode.startsWith("j")) {
        return [keyword(op.opcode), " ", label("->${op.operands.first}")];
      } else {
        final result = [keyword(op.opcode), " "];
        var comma = false;
        for (var operand in op.operands.reversed) {
          if (comma) {
            result.add(", ");
          } else {
            comma = true;
          }
          result.addAll(formatOperand(operand));
        }
        return result;
      }
    }

    for (var block in blocks.values) {
      result.add(label("${block.name}:"));
      if (block.predecessors.length > 1) {
        result.add(" (");
        var comma = false;
        for (var p in block.predecessors) {
          if (comma) result.add(", "); else comma = true;
          result.add(label("${p.name}"));
        }
        result.add(")");
      }
      result.add("\n");
      for (var op in block.asm) {
        result
          ..add("  ")
          ..addAll(format(op))
          ..add("\n");
      }
      result.add("\n");
    }

    code.nodes
      ..clear()
      ..addAll(result.map((v) => v is String ? new Text(v) : v));

    ir_pane.render($['ir'], blocks);
  }

  showBlockAction(event, detail, target) {
    blockRef.show(detail.label, detail.blockId);
  }

  hideBlockAction(event, detail, target) {
    blockRef.hide();
  }
}
