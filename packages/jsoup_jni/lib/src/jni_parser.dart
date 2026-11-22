// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:jni/jni.dart';
import 'package:jsoup/src/html_parser.dart';
import 'package:jsoup_jni/src/bindings/org/jsoup/Jsoup.dart' as jsoup_lib;
import 'package:jsoup_jni/src/bindings/org/jsoup/nodes/Document.dart';
import 'package:jsoup_jni/src/bindings/org/jsoup/nodes/Element.dart' as jsoup_el;
import 'package:jsoup_jni/src/bindings/org/jsoup/nodes/Node.dart' as jsoup_node;
import 'package:jsoup_jni/src/bindings/org/jsoup/nodes/TextNode.dart' as jsoup_tn;
import 'package:jsoup_jni/src/bindings/org/jsoup/select/Elements.dart' as jsoup_els;
import 'package:jsoup_jni/src/jre_manager.dart';

/// Jsoup-backed [NativeHtmlParser] using JNI.
///
/// Works on Android (JVM already available), Windows, and Linux (requires
/// bundled JRE + Jsoup JAR from the build hook).
class JsoupParser implements NativeHtmlParser {
  /// Creates a Jsoup parser, initializing the JVM if needed.
  ///
  /// On Android the JVM is already running. On desktop platforms this spawns
  /// a JVM with the bundled JRE and Jsoup JAR on the classpath.
  JsoupParser() {
    if (!Platform.isAndroid) {
      JreManager.ensureInitialized();
    }
  }

  /// Views a Jsoup `Elements` (a `java.util.ArrayList<Element>`) through the
  /// `java.util.List` binding. Both are extension types over the same
  /// `JObject`, so this neither creates nor releases a JNI reference.
  static JList<jsoup_el.Element?> _asList(jsoup_els.Elements elements) => elements as JList<jsoup_el.Element?>;

  // Handle store: maps opaque int handles to JNI object references.
  // Elements (including Documents) go in _elements; TextNodes in _textNodes;
  // Elements (node lists) in _nodeLists.
  final Map<int, jsoup_el.Element> _elements = <int, jsoup_el.Element>{};
  final Map<int, jsoup_tn.TextNode> _textNodes = <int, jsoup_tn.TextNode>{};
  final Map<int, jsoup_els.Elements> _nodeLists = <int, jsoup_els.Elements>{};
  int _nextHandle = 1;

  int _addElement(jsoup_el.Element obj) {
    final int handle = _nextHandle++;
    _elements[handle] = obj;
    return handle;
  }

  int _addTextNode(jsoup_tn.TextNode obj) {
    final int handle = _nextHandle++;
    _textNodes[handle] = obj;
    return handle;
  }

  int _addNodeList(jsoup_els.Elements obj) {
    final int handle = _nextHandle++;
    _nodeLists[handle] = obj;
    return handle;
  }

  /// Classify a JNI Node and add it to the appropriate handle map.
  /// Returns the handle and whether it's a text node.
  int _addNode(jsoup_node.Node node) {
    // Try casting to TextNode first (cheaper check via nodeName).
    final String? name = node.nodeName()?.toDartString();
    if (name == '#text') {
      return _addTextNode(node.as(jsoup_tn.TextNode.type, releaseOriginal: true));
    }
    // Default: treat as Element.
    return _addElement(node.as(jsoup_el.Element.type, releaseOriginal: true));
  }

  @override
  String? nodeBaseUri(int handle) {
    final jsoup_node.Node? node = _resolveNode(handle);
    if (node == null) return null;
    try {
      return _readAndRelease(node.baseUri());
    } on JThrowable catch (_) {
      return null;
    }
  }

  @override
  String? nodeAbsUrl(int handle, String key) {
    final jsoup_node.Node? node = _resolveNode(handle);
    if (node == null) return null;
    try {
      final JString jKey = _jstr(key);
      final String? result = _readAndRelease(node.absUrl(jKey));
      jKey.release();
      return result;
    } on JThrowable catch (_) {
      return null;
    }
  }

  @override
  void setNodeBaseUri(int handle, String value) {
    final jsoup_node.Node? node = _resolveNode(handle);
    if (node == null) return;
    try {
      final JString jValue = _jstr(value);
      node.baseUri$1 = jValue;
      jValue.release();
    } on JThrowable catch (_) {
      // Ignore.
    }
  }

  @override
  int createElement(String tag) {
    try {
      final JString jTag = _jstr(tag);
      final el = jsoup_el.Element.new$1(jTag);
      jTag.release();
      return _addElement(el);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  /// Convert a Dart string to JString, use it, then release.
  /// Avoids JGlobalReference leaks from [toJString()].
  static JString _jstr(String s) => s.toJString();

  /// Read a JString as Dart string and immediately release the JNI reference.
  static String? _readAndRelease(JString? js) {
    if (js == null) return null;
    final String s = js.toDartString();
    js.release();
    return s;
  }

  @override
  int parse(String html, {String baseUri = ''}) {
    try {
      final JString jHtml = _jstr(html);
      final JString jBaseUri = _jstr(baseUri);
      final Document? doc = jsoup_lib.Jsoup.parse(jHtml, jBaseUri);
      jHtml.release();
      jBaseUri.release();
      if (doc == null) return -1;
      return _addElement(doc);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  int parseFragment(String html, {String baseUri = ''}) {
    // Jsoup.parse() handles fragments well — returns a full Document.
    return parse(html, baseUri: baseUri);
  }

  @override
  int select(int handle, String selector) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return -1;
    try {
      final JString jSel = _jstr(selector);
      final jsoup_els.Elements? elements = el.select(jSel);
      jSel.release();
      if (elements == null) return -1;
      return _addNodeList(elements);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  int selectFirst(int handle, String selector) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return -1;
    try {
      final JString jSel = _jstr(selector);
      final jsoup_el.Element? result = el.selectFirst(jSel);
      jSel.release();
      if (result == null) return -1;
      return _addElement(result);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  String? attr(int handle, String key) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return null;
    try {
      final JString jKey = _jstr(key);
      final JString? result = el.attr(jKey);
      jKey.release();
      if (result == null) return null;
      final String val = result.toDartString();
      result.release();
      // Jsoup returns empty string for missing attributes.
      if (val.isEmpty && !hasAttr(handle, key)) return null;
      return val;
    } on JThrowable catch (_) {
      return null;
    }
  }

  @override
  bool hasAttr(int handle, String key) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return false;
    try {
      final JString jKey = _jstr(key);
      final bool result = el.hasAttr(jKey);
      jKey.release();
      return result;
    } on JThrowable catch (_) {
      return false;
    }
  }

  @override
  String? text(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return null;
    try {
      return _readAndRelease(el.text());
    } on JThrowable catch (_) {
      return null;
    }
  }

  @override
  String? ownText(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return null;
    try {
      return _readAndRelease(el.ownText());
    } on JThrowable catch (_) {
      return null;
    }
  }

  @override
  String? innerHtml(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return null;
    try {
      // Element.html() returns inner HTML.
      return _readAndRelease(el.html$1());
    } on JThrowable catch (_) {
      return null;
    }
  }

  @override
  String? outerHtml(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return null;
    try {
      return _readAndRelease(el.outerHtml());
    } on JThrowable catch (_) {
      return null;
    }
  }

  @override
  String? tagName(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return null;
    try {
      return _readAndRelease(el.tagName());
    } on JThrowable catch (_) {
      return null;
    }
  }

  @override
  String? id(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return null;
    try {
      final String? result = _readAndRelease(el.id());
      if (result != null && result.isEmpty) return null;
      return result;
    } on JThrowable catch (_) {
      return null;
    }
  }

  @override
  String? className(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return null;
    try {
      return _readAndRelease(el.className());
    } on JThrowable catch (_) {
      return null;
    }
  }

  @override
  bool hasClass(int handle, String name) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return false;
    try {
      final JString jName = _jstr(name);
      final bool result = el.hasClass(jName);
      jName.release();
      return result;
    } on JThrowable catch (_) {
      return false;
    }
  }

  @override
  int size(int handle) {
    final jsoup_els.Elements? list = _nodeLists[handle];
    if (list == null) return -1;
    try {
      return _asList(list).size();
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  int get(int handle, int index) {
    final jsoup_els.Elements? list = _nodeLists[handle];
    if (list == null) return -1;
    try {
      final jsoup_el.Element? el = _asList(list).get(index);
      if (el == null) return -1;
      return _addElement(el);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  int first(int handle) {
    final jsoup_els.Elements? list = _nodeLists[handle];
    if (list == null) return -1;
    try {
      final jsoup_el.Element? el = list.first();
      if (el == null) return -1;
      return _addElement(el);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  int last(int handle) {
    final jsoup_els.Elements? list = _nodeLists[handle];
    if (list == null) return -1;
    try {
      final jsoup_el.Element? el = list.last();
      if (el == null) return -1;
      return _addElement(el);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  int parent(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return -1;
    try {
      final jsoup_el.Element? p = el.parent$1();
      if (p == null) return -1;
      return _addElement(p);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  int children(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return -1;
    try {
      final jsoup_els.Elements? kids = el.children();
      if (kids == null) return -1;
      return _addNodeList(kids);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  int nextSibling(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return -1;
    try {
      final jsoup_el.Element? sib = el.nextElementSibling();
      if (sib == null) return -1;
      return _addElement(sib);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  int prevSibling(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return -1;
    try {
      final jsoup_el.Element? sib = el.previousElementSibling();
      if (sib == null) return -1;
      return _addElement(sib);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  int siblings(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return -1;
    try {
      final jsoup_els.Elements? sibs = el.siblingElements();
      if (sibs == null) return -1;
      return _addNodeList(sibs);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  void setText(int handle, String text) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return;
    try {
      final JString jText = _jstr(text);
      el.text$1(jText);
      jText.release();
    } on JThrowable catch (_) {
      // Ignore.
    }
  }

  @override
  void setHtml(int handle, String html) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return;
    try {
      final JString jHtml = _jstr(html);
      el.html$2(jHtml);
      jHtml.release();
    } on JThrowable catch (_) {
      // Ignore.
    }
  }

  @override
  void remove(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return;
    try {
      el.remove();
    } on JThrowable catch (_) {
      // Ignore.
    }
  }

  @override
  void prepend(int handle, String html) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return;
    try {
      final JString jHtml = _jstr(html);
      el.prepend(jHtml);
      jHtml.release();
    } on JThrowable catch (_) {
      // Ignore.
    }
  }

  @override
  void append(int handle, String html) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return;
    try {
      final JString jHtml = _jstr(html);
      el.append(jHtml);
      jHtml.release();
    } on JThrowable catch (_) {
      // Ignore.
    }
  }

  @override
  void setAttr(int handle, String key, String value) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return;
    try {
      final JString jKey = _jstr(key);
      final JString jValue = _jstr(value);
      el.attr$1(jKey, jValue);
      jKey.release();
      jValue.release();
    } on JThrowable catch (_) {
      // Ignore.
    }
  }

  @override
  void removeAttr(int handle, String key) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return;
    try {
      final JString jKey = _jstr(key);
      el.removeAttr(jKey);
      jKey.release();
    } on JThrowable catch (_) {
      // Ignore.
    }
  }

  @override
  void addClass(int handle, String name) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return;
    try {
      final JString jName = _jstr(name);
      el.addClass(jName);
      jName.release();
    } on JThrowable catch (_) {
      // Ignore.
    }
  }

  @override
  void removeClass(int handle, String name) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return;
    try {
      final JString jName = _jstr(name);
      el.removeClass(jName);
      jName.release();
    } on JThrowable catch (_) {
      // Ignore.
    }
  }

  @override
  String? data(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return null;
    try {
      return _readAndRelease(el.data());
    } on JThrowable catch (_) {
      return null;
    }
  }

  // -- TextNode creation --

  @override
  int createTextNode(String text) {
    try {
      final JString jText = _jstr(text);
      final tn = jsoup_tn.TextNode(jText);
      jText.release();
      return _addTextNode(tn);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  // -- Elements creation --

  @override
  int createElements(List<int> elementHandles) {
    try {
      // Create an empty Jsoup Elements (extends ArrayList<Element>).
      final jElements = jsoup_els.Elements();
      final JList<jsoup_el.Element?> list = _asList(jElements);
      for (final h in elementHandles) {
        final jsoup_el.Element? el = _elements[h];
        if (el == null) continue;
        list.add(el);
      }
      return _addNodeList(jElements);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  // -- Node-level methods --

  @override
  String? nodeName(int handle) {
    // Check elements first, then text nodes.
    final jsoup_el.Element? el = _elements[handle];
    if (el != null) {
      try {
        return _readAndRelease(el.nodeName());
      } on JThrowable catch (_) {
        return null;
      }
    }
    final jsoup_tn.TextNode? tn = _textNodes[handle];
    if (tn != null) {
      try {
        return _readAndRelease(tn.nodeName());
      } on JThrowable catch (_) {
        return null;
      }
    }
    return null;
  }

  jsoup_node.Node? _resolveNode(int handle) {
    // Upcasts between extension types: no new JNI reference.
    return _elements[handle] ?? _textNodes[handle];
  }

  @override
  int childNodeSize(int handle) {
    final jsoup_node.Node? node = _resolveNode(handle);
    if (node == null) return 0;
    try {
      return node.childNodeSize();
    } on JThrowable catch (_) {
      return 0;
    }
  }

  @override
  int childNode(int handle, int index) {
    final jsoup_node.Node? node = _resolveNode(handle);
    if (node == null) return -1;
    try {
      final jsoup_node.Node? child = node.childNode(index);
      if (child == null) return -1;
      return _addNode(child);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  List<int> childNodeHandles(int handle) {
    final jsoup_node.Node? node = _resolveNode(handle);
    if (node == null) return const <int>[];
    try {
      final JList<jsoup_node.Node?>? children = node.childNodes();
      if (children == null) return const <int>[];
      return <int>[
        for (final jsoup_node.Node? child in children.asDart())
          if (child != null) _addNode(child),
      ];
    } on JThrowable catch (_) {
      return const <int>[];
    }
  }

  @override
  bool isTextNode(int handle) => _textNodes.containsKey(handle);

  @override
  int parentNode(int handle) {
    final jsoup_node.Node? node = _resolveNode(handle);
    if (node == null) return -1;
    try {
      final jsoup_node.Node? p = node.parent();
      if (p == null) return -1;
      return _addNode(p);
    } on JThrowable catch (_) {
      return -1;
    }
  }

  @override
  String? nodeOuterHtml(int handle) {
    final jsoup_node.Node? node = _resolveNode(handle);
    if (node == null) return null;
    try {
      return _readAndRelease(node.outerHtml());
    } on JThrowable catch (_) {
      return null;
    }
  }

  @override
  void removeNode(int handle) {
    final jsoup_node.Node? node = _resolveNode(handle);
    if (node == null) return;
    try {
      node.remove();
    } on JThrowable catch (_) {
      // Ignore.
    }
  }

  // -- Element-level: textNodes --

  @override
  List<int> textNodeHandles(int handle) {
    final jsoup_el.Element? el = _elements[handle];
    if (el == null) return const <int>[];
    try {
      final JList<jsoup_tn.TextNode?>? tnList = el.textNodes();
      if (tnList == null) return const <int>[];
      return <int>[
        for (final jsoup_tn.TextNode? tn in tnList.asDart())
          if (tn != null) _addTextNode(tn),
      ];
    } on JThrowable catch (_) {
      return const <int>[];
    }
  }

  // -- TextNode-level methods --

  @override
  String? textNodeText(int handle) {
    final jsoup_tn.TextNode? tn = _textNodes[handle];
    if (tn == null) return null;
    try {
      return _readAndRelease(tn.text());
    } on JThrowable catch (_) {
      return null;
    }
  }

  @override
  void setTextNodeText(int handle, String text) {
    final jsoup_tn.TextNode? tn = _textNodes[handle];
    if (tn == null) return;
    try {
      final JString jText = _jstr(text);
      tn.text$1(jText);
      jText.release();
    } on JThrowable catch (_) {
      // Ignore.
    }
  }

  @override
  String? textNodeWholeText(int handle) {
    final jsoup_tn.TextNode? tn = _textNodes[handle];
    if (tn == null) return null;
    try {
      return _readAndRelease(tn.wholeText);
    } on JThrowable catch (_) {
      return null;
    }
  }

  @override
  bool textNodeIsBlank(int handle) {
    final jsoup_tn.TextNode? tn = _textNodes[handle];
    if (tn == null) return true;
    try {
      return tn.isBlank;
    } on JThrowable catch (_) {
      return true;
    }
  }

  @override
  void free(int handle) {
    _elements.remove(handle)?.release();
    _textNodes.remove(handle)?.release();
    _nodeLists.remove(handle)?.release();
  }

  @override
  void releaseAll() {
    for (final jsoup_el.Element obj in _elements.values) {
      obj.release();
    }
    _elements.clear();
    for (final jsoup_tn.TextNode obj in _textNodes.values) {
      obj.release();
    }
    _textNodes.clear();
    for (final jsoup_els.Elements obj in _nodeLists.values) {
      obj.release();
    }
    _nodeLists.clear();
    _nextHandle = 1;
  }

  @override
  void dispose() {
    releaseAll();
  }
}
