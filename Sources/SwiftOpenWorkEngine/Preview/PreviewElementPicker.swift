import Foundation
import CoreGraphics

/// An element the user clicked in the preview while picking, and what to tell the agent about it.
///
/// "Make *this* bigger" is how people point at a page. Text alone makes the agent guess which of
/// forty buttons was meant; a selector, the element's markup and its text are enough to grep for,
/// and a cropped screenshot shows what "this" looks like.
public struct PickedElement: Equatable, Sendable {
    public var selector: String
    public var tag: String
    /// The element's outer HTML, cut to `PreviewElementPicker.maxHTML` characters.
    public var html: String
    /// Visible text, cut to `PreviewElementPicker.maxText` characters.
    public var text: String
    public var pageURL: String
    /// Where it was on screen, in the web view's coordinates.
    public var frame: CGRect

    public init(selector: String, tag: String, html: String, text: String, pageURL: String, frame: CGRect) {
        self.selector = selector
        self.tag = tag
        self.html = html
        self.text = text
        self.pageURL = pageURL
        self.frame = frame
    }

    /// Parse the page script's `{kind: 'pick', …}` message. Nil for anything else.
    public init?(message body: [String: Any]) {
        guard body["kind"] as? String == "pick",
              let selector = body["selector"] as? String, !selector.isEmpty else { return nil }
        func number(_ key: String) -> CGFloat { CGFloat((body[key] as? NSNumber)?.doubleValue ?? 0) }
        self.init(
            selector: selector,
            tag: body["tag"] as? String ?? "",
            html: String((body["html"] as? String ?? "").prefix(PreviewElementPicker.maxHTML)),
            text: String((body["text"] as? String ?? "").prefix(PreviewElementPicker.maxText)),
            pageURL: body["url"] as? String ?? "",
            frame: CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
        )
    }

    /// The block that goes into the message box; the user writes what to change around it.
    public var promptText: String {
        var lines = ["About this element on \(pageURL.isEmpty ? "the preview" : pageURL):", "- selector: `\(selector)`"]
        let flatText = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if !flatText.isEmpty { lines.append("- text: \"\(flatText)\"") }
        if !html.isEmpty { lines.append("```html\n\(html)\n```") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The area to screenshot: the element with a margin, kept inside `bounds`. Nil when the
    /// element has no visible area there.
    public func cropRect(in bounds: CGRect, margin: CGFloat = 8) -> CGRect? {
        let padded = frame.insetBy(dx: -margin, dy: -margin).intersection(bounds)
        guard !padded.isNull, padded.width >= 2, padded.height >= 2 else { return nil }
        return padded.integral
    }
}

public enum PreviewElementPicker {
    public static let maxHTML = 1_500
    public static let maxText = 300

    /// Injected on demand, not at load: it highlights what the pointer is over, swallows the next
    /// click (so a button is picked, not pressed), posts the element and removes itself. Escape
    /// cancels. `window.__sowPickerStop` lets the app cancel it too.
    public static let startScript = #"""
    (function () {
      if (window.__sowPickerStop) { window.__sowPickerStop(); }
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sowPreview;
      if (!handler) { return false; }
      var esc = (window.CSS && CSS.escape) ? CSS.escape : function (s) { return String(s).replace(/[^\w-]/g, '\\$&'); };
      function selectorFor(el) {
        if (el.id) { return '#' + esc(el.id); }
        if (el === document.body || el === document.documentElement) { return el.tagName.toLowerCase(); }
        var parts = [];
        while (el && el.nodeType === 1 && el !== document.body && el !== document.documentElement && parts.length < 5) {
          if (el.id) { parts.unshift('#' + esc(el.id)); break; }
          var part = el.tagName.toLowerCase();
          var classes = Array.prototype.filter.call(el.classList, function (c) { return c.length < 40; }).slice(0, 2);
          if (classes.length) { part += '.' + classes.map(esc).join('.'); }
          var parent = el.parentElement;
          if (parent) {
            var same = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === el.tagName; });
            if (same.length > 1) { part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')'; }
          }
          parts.unshift(part);
          el = parent;
        }
        return parts.join(' > ');
      }
      var box = document.createElement('div');
      box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;display:none;border:2px solid #3B82F6;background:rgba(59,130,246,0.12);border-radius:3px;box-sizing:border-box';
      var label = document.createElement('div');
      label.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;display:none;background:#3B82F6;color:#fff;font:11px -apple-system,system-ui,sans-serif;padding:2px 6px;border-radius:3px;white-space:nowrap';
      document.documentElement.appendChild(box);
      document.documentElement.appendChild(label);
      var current = null;
      function move(event) {
        var el = event.target;
        if (!(el instanceof Element) || el === box || el === label) { return; }
        current = el;
        var r = el.getBoundingClientRect();
        box.style.display = 'block';
        box.style.left = r.left + 'px'; box.style.top = r.top + 'px';
        box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
        label.textContent = el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
        label.style.display = 'block';
        label.style.left = Math.max(0, r.left) + 'px';
        label.style.top = (r.top >= 20 ? r.top - 20 : r.bottom + 2) + 'px';
      }
      function block(event) { event.preventDefault(); event.stopPropagation(); }
      function stop() {
        document.removeEventListener('mousemove', move, true);
        document.removeEventListener('click', pick, true);
        ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick'].forEach(function (t) { document.removeEventListener(t, block, true); });
        document.removeEventListener('keydown', key, true);
        box.remove(); label.remove();
        window.__sowPickerStop = null;
      }
      function pick(event) {
        block(event);
        var el = current || event.target;
        if (!(el instanceof Element)) { return; }
        var r = el.getBoundingClientRect();
        stop();
        handler.postMessage({
          kind: 'pick', selector: selectorFor(el), tag: el.tagName.toLowerCase(),
          html: (el.outerHTML || '').slice(0, 1500), text: (el.innerText || '').trim().slice(0, 300),
          x: r.left, y: r.top, width: r.width, height: r.height, url: String(location.href)
        });
      }
      function key(event) {
        if (event.key === 'Escape') { block(event); stop(); handler.postMessage({ kind: 'pickCancelled' }); }
      }
      document.addEventListener('mousemove', move, true);
      document.addEventListener('click', pick, true);
      ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick'].forEach(function (t) { document.addEventListener(t, block, true); });
      document.addEventListener('keydown', key, true);
      window.__sowPickerStop = stop;
      return true;
    })();
    """#

    public static let stopScript = "if (window.__sowPickerStop) { window.__sowPickerStop(); }"
}
