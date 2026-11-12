import Foundation

/// 组装 Markdown 阅读器的本地 HTML。JS/CSS 全部来自 Bundle，不走网络。
enum MarkdownHTMLTemplate {
    private final class BundleToken: NSObject {}

    private struct Assets: Sendable {
        let css: String
        let marked: String
        let purify: String
        let highlight: String
    }

    private static let assets: Assets? = loadAssets()

    static func make(markdown: String) -> String {
        let base64 = Data(markdown.utf8).base64EncodedString()
        guard let assets else {
            return fallbackHTML(markdown: markdown)
        }

        let css = escapeClosingTag(assets.css, tag: "style")
        let marked = escapeClosingTag(assets.marked, tag: "script")
        let purify = escapeClosingTag(assets.purify, tag: "script")
        let highlight = escapeClosingTag(assets.highlight, tag: "script")

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; font-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'none'; media-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none';">
        <style>\(css)</style>
        </head>
        <body>
        <main id="content"></main>
        <script>\(marked)</script>
        <script>\(purify)</script>
        <script>\(highlight)</script>
        <script>
        (function () {
          var content = document.getElementById("content");
          var base64 = "\(base64)";

          function post(message) {
            try {
              if (window.webkit && window.webkit.messageHandlers &&
                  window.webkit.messageHandlers.documentReader) {
                window.webkit.messageHandlers.documentReader.postMessage(message);
              }
            } catch (error) {}
          }

          function decodeBase64(value) {
            var binary = atob(value);
            var bytes = new Uint8Array(binary.length);
            for (var i = 0; i < binary.length; i++) {
              bytes[i] = binary.charCodeAt(i);
            }
            return new TextDecoder("utf-8").decode(bytes);
          }

          function copyCode(text, button) {
            var original = button.textContent;
            button.textContent = "已复制";
            window.setTimeout(function () {
              button.textContent = original;
            }, 1200);
            post({ type: "copy", text: text });
            if (navigator.clipboard && navigator.clipboard.writeText) {
              navigator.clipboard.writeText(text).catch(function () {});
            }
          }

          function decorateTables() {
            content.querySelectorAll("table").forEach(function (table) {
              var wrap = document.createElement("div");
              wrap.className = "table-wrap";
              table.parentNode.insertBefore(wrap, table);
              wrap.appendChild(table);
            });
          }

          function decorateCodeBlocks() {
            content.querySelectorAll("pre > code").forEach(function (code) {
              var pre = code.parentElement;
              var languageClass = Array.prototype.find.call(
                code.classList,
                function (name) { return name.indexOf("language-") === 0; }
              );
              var language = languageClass
                ? languageClass.slice("language-".length).toLowerCase()
                : "";
              var supported = language &&
                language !== "text" &&
                language !== "plaintext" &&
                language !== "plain" &&
                window.hljs &&
                hljs.getLanguage(language);

              if (supported) {
                try {
                  hljs.highlightElement(code);
                } catch (error) {}
              } else {
                code.classList.add("no-highlight");
              }

              var wrapper = document.createElement("div");
              wrapper.className = "code-block";
              pre.parentNode.insertBefore(wrapper, pre);

              var header = document.createElement("div");
              header.className = "code-block-header";

              var label = document.createElement("span");
              label.textContent = language || "code";

              var button = document.createElement("button");
              button.className = "copy-code";
              button.type = "button";
              button.textContent = "复制";
              button.addEventListener("click", function () {
                copyCode(code.textContent || "", button);
              });

              header.appendChild(label);
              header.appendChild(button);
              wrapper.appendChild(header);
              wrapper.appendChild(pre);
            });
          }

          function buildTOC() {
            var headings = Array.prototype.map.call(
              content.querySelectorAll("h1, h2, h3"),
              function (heading, index) {
                var id = "document-heading-" + index;
                heading.id = id;
                return {
                  level: Number(heading.tagName.slice(1)),
                  text: heading.textContent || "",
                  id: id
                };
              }
            );
            window.__documentHeadings = headings;
            window.scrollToHeading = function (id) {
              var element = document.getElementById(id);
              if (element) {
                element.scrollIntoView({ behavior: "smooth", block: "start" });
              }
            };
            post({ type: "toc", items: headings });
          }

          try {
            var markdown = decodeBase64(base64);
            marked.setOptions({ gfm: true, breaks: false });
            var rendered = marked.parse(markdown);
            content.innerHTML = DOMPurify.sanitize(rendered, {
              USE_PROFILES: { html: true },
              ADD_ATTR: ["target", "rel"]
            });
            content.querySelectorAll("a").forEach(function (link) {
              link.setAttribute("rel", "noopener noreferrer");
            });
            decorateTables();
            decorateCodeBlocks();
            buildTOC();
            post({ type: "ready" });
          } catch (error) {
            content.textContent = markdown || "";
            post({ type: "error", message: String(error && error.message ? error.message : error) });
          }
        })();
        </script>
        </body>
        </html>
        """
    }

    static var hasBundledAssets: Bool { assets != nil }

    private static func loadAssets() -> Assets? {
        guard let css = load("reader", "css"),
              let marked = load("marked.min", "js"),
              let purify = load("purify.min", "js"),
              let highlight = load("highlight.min", "js") else {
            return nil
        }
        return Assets(css: css, marked: marked, purify: purify, highlight: highlight)
    }

    private static func load(_ name: String, _ ext: String) -> String? {
        let bundles = [Bundle(for: BundleToken.self), Bundle.main]
        for bundle in bundles {
            let url = bundle.url(
                forResource: name,
                withExtension: ext,
                subdirectory: "DocumentReader"
            ) ?? bundle.url(forResource: name, withExtension: ext)
            if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    private static func escapeClosingTag(_ text: String, tag: String) -> String {
        text.replacingOccurrences(
            of: "</\(tag)",
            with: "<\\/\(tag)",
            options: [.caseInsensitive]
        )
    }

    private static func fallbackHTML(markdown: String) -> String {
        let escaped = markdown
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{font:16px -apple-system;padding:18px;white-space:pre-wrap}</style>
        </head><body><main>\(escaped)</main></body></html>
        """
    }
}
