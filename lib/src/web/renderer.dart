library cs61a_scheme.web.renderer;

import 'dart:async';
import 'dart:html';
import 'dart:js';

import 'package:markdown/markdown.dart' as md;

import 'package:cs61a_scheme/cs61a_scheme_extra.dart';
import 'package:cs61a_scheme/highlight.dart';

import 'theming.dart';

void render(Widget widget, Element container) {
  new _Renderer(container, context['jsPlumb']).render(widget);
}

class _Renderer {
  Element container;
  JsObject jsPlumb;
  Iterable connections;

  static int anchorCount = 0;

  _Renderer(this.container, JsObject masterJsPlumb) {
    jsPlumb = masterJsPlumb.callMethod('getInstance');
    container.classes.add('render');
  }

  List<StreamSubscription> subs = [];

  void render(Widget widget) {
    var oldSubscriptions = subs;
    subs = [];
    connections = null;
    trueAnchorIds = {};
    anchorDirections = {};
    Element el = convert(widget);
    container.text = "";
    for (StreamSubscription sub in oldSubscriptions) {
      sub.cancel();
    }
    container.append(el);
    subs.add(widget.onUpdate.listen(([_]) {
      render(widget);
    }));
    if (connections != null) {
      refreshConnections();
      subs.add(onThemeChange.listen(([_]) {
        refreshConnections();
      }));
    }
  }

  void refreshConnections() {
    if (connections == null) return;
    var base = new JsObject.jsify({
      'endpoint': [
        'Dot',
        {'radius': 3}
      ],
      'connector': 'StateMachine',
      'overlays': [
        [
          'Arrow',
          {'length': 10, 'width': 7, 'foldback': 0.55, 'location': 1}
        ]
      ],
      'paintStyle': {'strokeStyle': '#bebebe', 'lineWidth': 1},
      'endpointStyles': [
        {'fillStyle': '#bebebe'},
        {'fillStyle': 'transparent'},
      ]
    });
    jsPlumb?.callMethod('reset');
    jsPlumb?.callMethod('setContainer', [container]);
    jsPlumb?.callMethod('setDraggable', [false]);
    for (var c in connections) {
      jsPlumb?.callMethod('connect', [new JsObject.jsify(c), base]);
    }
    jsPlumb?.callMethod('repaintEverything');
    new Future.delayed(const Duration(milliseconds: 50), () {
      jsPlumb?.callMethod('repaintEverything');
    });
    if (jsPlumb != null) {
      subs.add(window.onResize.listen((e) {
        new Future.delayed(const Duration(milliseconds: 50), () {
          jsPlumb.callMethod('repaintEverything');
        });
      }));
    }
  }

  Map<int, String> trueAnchorIds = {};
  Map<int, Direction> anchorDirections = {};

  Element convert(Widget widget, [bool spaced = false]) {
    Element node = _convertRaw(widget, spaced);
    if (widget.spacer || spaced) {
      node.style.visibility = 'hidden';
      return node;
    }
    for (Direction dir in widget.anchoredDirections) {
      int id = widget.anchor(dir).id;
      anchorDirections[id] = dir;
      node.id = 'anchoredElement${anchorCount++}';
      trueAnchorIds[id] = node.id;
    }
    return node;
  }

  Element _convertRaw(Widget widget, [bool spaced = false]) {
    if (widget is MarkdownWidget) return convertMarkdown(widget, spaced);
    if (widget is Visualization) return convertVisualization(widget, spaced);
    if (widget is Button) return convertButton(widget, spaced);
    if (widget is Diagram) return convertDiagram(widget, spaced);
    if (widget is FrameElement) return convertFrameElement(widget, spaced);
    if (widget is Row) return convertRow(widget, spaced);
    if (widget is TextWidget) return convertTextElement(widget, spaced);
    if (widget is Block) return convertBlock(widget, spaced);
    if (widget is BlockGrid) return convertBlockGrid(widget, spaced);
    if (widget is Anchor) return convertAnchor(widget, spaced);
    if (widget is Binding) return convertBinding(widget, spaced);
    if (widget is Strike) return convertStrike(widget, spaced);
    throw new SchemeException("Cannot render $widget");
  }

  Element convertMarkdown(MarkdownWidget mark, [bool spaced = false]) {
    String html = md.markdownToHtml(mark.text,
        extensionSet: md.ExtensionSet.gitHubFlavored, inlineOnly: mark.inline);
    Element element = new Element.span();
    element.appendHtml(html,
        validator: new NodeValidatorBuilder.common()
          ..allowNavigation(new _AnyUriPolicy()));
    for (var link in element.querySelectorAll('a')) {
      String href = link.attributes['href'];
      if (href?.startsWith(':') ?? false) {
        link.attributes.remove('href');
        link.classes.add('button');
        link.onClick.listen((e) => mark.runLink(href.substring(1)));
      } else {
        link.attributes['target'] = '_blank';
      }
    }
    for (var code in element.querySelectorAll('code')) {
      var styled = highlight(code.innerHtml);
      code.setInnerHtml(styled, validator: new NodeValidatorBuilder.common());
    }
    element.classes.add('markdown');
    return element;
  }

  Element convertVisualization(Visualization viz, [bool spaced = false]) {
    DivElement wrapper = new DivElement()..classes = ['visualization'];
    wrapper.append(convert(viz.currentDiagram));
    DivElement footer = new DivElement()..classes = ['footer'];
    for (Widget item in viz.buttonRow) {
      footer.append(convert(item));
    }
    wrapper.append(footer);
    return wrapper;
  }

  Element convertButton(Button button, [bool spaced = false]) {
    DivElement element = new DivElement()..classes = ['button'];
    element.append(convert(button.inside));
    subs.add(element.onClick.listen((event) {
      button.click();
    }));
    return element;
  }

  Element convertDiagram(Diagram diagram, [bool spaced = false]) {
    TableElement table = new TableElement()..classes = ['diagram'];
    TableRowElement tr = new TableRowElement();
    TableCellElement frames = new TableCellElement()..classes = ['frames'];
    TableCellElement objects = new TableCellElement()..classes = ['objects'];
    tr.append(frames);
    tr.append(objects);
    table.append(tr);
    for (FrameElement frame in diagram.frames) {
      frames.append(convert(frame, spaced || diagram.spacer));
    }
    for (Widget row in diagram.rows) {
      objects.append(convert(row, spaced || diagram.spacer));
    }
    connections = diagram.arrows.map(makeConnection);
    return table;
  }

  Element convertFrameElement(FrameElement frame, [bool spaced = false]) {
    DivElement div = new DivElement();
    div.id = 'frame${frame.id}';
    div.classes.add(frame.active ? 'current-frame' : 'other-frame');
    DivElement header = new DivElement();
    String name = frame.id == 0 ? 'Global frame' : 'f${frame.id}';
    String parent = "";
    if (frame.parentId != null && frame.parentId != 0) {
      var m = frame.fromMacro ? 'macro, ' : '';
      parent =
          '&nbsp;<span class="parent">[${m}parent=f${frame.parentId}]</span>';
    } else if (frame.fromMacro) {
      parent = '&nbsp;<span class="parent">[macro]</span>';
    }
    header.innerHtml = '<b>$name</b>&nbsp;${frame.tag ?? ''}$parent';
    div.append(header);
    for (Binding binding in frame.bindings) {
      div.append(convert(binding, spaced || frame.spacer));
    }
    return div;
  }

  Element convertBinding(Binding binding, [bool spaced = false]) {
    DivElement div = new DivElement()..className = 'binding';
    if (binding.isReturn) div.classes.add('return');
    div.innerHtml = '${binding.symbol}&nbsp;';
    SpanElement span = new SpanElement()..className = 'align-right';
    div.append(span);
    span.append(convert(binding.value, spaced || binding.spacer));
    return div;
  }

  Element convertRow(Row row, [bool spaced = false]) {
    DivElement div = new DivElement()..className = 'row';
    for (Widget element in row.elements) {
      div.append(convert(element, spaced || row.spacer));
    }
    return div;
  }

  Element convertTextElement(TextWidget text, [bool spaced = false]) {
    return new SpanElement()..text = text.text;
  }

  Element convertBlock(Block block, [bool spaced = false]) {
    DivElement div = new DivElement();
    div.classes = ['block', block.type];
    div.append(convert(block.inside, spaced || block.spacer));
    return div;
  }

  Element convertBlockGrid(BlockGrid blockGrid, [bool spaced = false]) {
    if (blockGrid.rowCount != 1) {
      throw new SchemeException("Multiple BlockGrid rows not yet implemented");
    }
    DivElement div = new DivElement();
    div.className = 'block-grid';
    for (Block block in blockGrid.rowAt(0)) {
      div.append(convert(block, spaced || blockGrid.spacer));
    }
    return div;
  }

  Element convertAnchor(Anchor anchor, [bool spaced = false]) {
    if (spaced) {
      return new SpanElement()..innerHtml = '&nbsp';
    }
    String htmlAnchorId = 'trueAnchor${anchorCount++}';
    trueAnchorIds[anchor.id] = htmlAnchorId;
    anchorDirections[anchor.id] = null;
    return new SpanElement()
      ..id = htmlAnchorId
      ..innerHtml = '&nbsp;';
  }

  Element convertStrike(Strike strike, [bool spaced = false]) {
    return new SpanElement()
      ..innerHtml = '-'
      ..classes = ['strike'];
  }

  List<num> _anchorForDirection(Direction dir) {
    if (dir == Direction.left) return [0, 0.5, 1, 0, 0, 0];
    if (dir == Direction.topLeft) return [0, 0, 1, 0, 0, 0];
    if (dir == Direction.top) return [0.5, 0, 1, 0, 0, 0];
    if (dir == Direction.bottomLeft) return [0, 1, 1, 0, 0, 0];
    if (dir == Direction.bottom) return [0.5, 1, 1, 0, 0, 0];
    if (dir == Direction.right) return [1, 0.5, 1, 0, 0, 0];
    if (dir == Direction.topRight) return [1, 0, 1, 0, 0, 0];
    if (dir == Direction.bottomRight) return [1, 1, 1, 0, 0, 0];
    return [0.5, 0.5, 1, 0, 0, 0];
  }

  makeConnection(Arrow arrow) {
    String startId = 'anchor${arrow.start.id}';
    String endId = 'anchor${arrow.end.id}';
    var leftAnchor = [0.5, 0.5, 1, 0, 0, 0];
    var rightAnchor = [0.5, 0.5, 1, 0, 0, 0];
    if (trueAnchorIds.containsKey(arrow.start.id)) {
      startId = trueAnchorIds[arrow.start.id];
      leftAnchor = _anchorForDirection(anchorDirections[arrow.start.id]);
    }
    if (trueAnchorIds.containsKey(arrow.end.id)) {
      endId = trueAnchorIds[arrow.end.id];
      rightAnchor = _anchorForDirection(anchorDirections[arrow.end.id]);
    }
    var connection = {
      'source': startId,
      'target': endId,
      'anchors': [leftAnchor, rightAnchor],
    };
    return connection;
  }
}

class _AnyUriPolicy implements UriPolicy {
  @override
  bool allowsUri(String uri) => true;
}