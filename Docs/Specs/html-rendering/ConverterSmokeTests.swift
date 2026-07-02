import Foundation

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    print(cond ? "PASS" : "FAIL", "—", name, cond ? "" : "(\(detail))")
    if !cond { failures += 1 }
}
func para(_ r: ConvertedMessage, _ i: Int = 0) -> String? {
    guard i < r.blocks.count, case .paragraph(let t) = r.blocks[i] else { return nil }
    return String(t.characters)
}

// Q's reported bug: <br> inside inline context
let br = HTMLMessageConverter.convert("<b>text<br>more</b>")
check("C-br: <b>text<br>more</b> keeps line break",
      para(br) == "text\nmore", "got: \(para(br) ?? "nil") blocks: \(br.blocks)")

// C1 plain paragraph
check("C1: plain paragraph", para(HTMLMessageConverter.convert("<p>Hello bee</p>")) == "Hello bee")

// C4 boundary space
check("C4: boundary space survives",
      para(HTMLMessageConverter.convert("bare text with <b>bold</b> tail")) == "bare text with bold tail",
      "got: \(para(HTMLMessageConverter.convert("bare text with <b>bold</b> tail")) ?? "nil")")

// C3 nested intents union (<b><i>) — the bug Q did NOT find
let nested = HTMLMessageConverter.convert("<p><b><i>x</i></b></p>")
var nestedOK = false
if case .paragraph(let t) = nested.blocks[0] {
    let intents = t.runs.compactMap(\.inlinePresentationIntent)
    nestedOK = intents.contains { $0.contains(.emphasized) && $0.contains(.stronglyEmphasized) }
}
check("C3: <b><i>x</i></b> carries BOTH intents", nestedOK)

// C6 pre with language + newlines preserved
let pre = HTMLMessageConverter.convert("<pre><code class=\"language-swift\">let a = 1\nlet b = 2</code></pre>")
if case .codeBlock(let lang, let code) = pre.blocks.first {
    check("C6: pre language tag", lang == "swift", "got \(lang ?? "nil")")
    check("C6: pre newlines preserved", code == "let a = 1\nlet b = 2", "got \(code.debugDescription)")
} else { check("C6: pre → codeBlock", false, "\(pre.blocks)") }

// C8 nested list
let list = HTMLMessageConverter.convert("<ul><li>a</li><li>b<ol><li>c</li></ol></li></ul>")
if case .list(let ordered, let items) = list.blocks.first {
    check("C8: list shape", !ordered && items.count == 2)
} else { check("C8: list", false, "\(list.blocks)") }

// C10 link schemes
let link = HTMLMessageConverter.convert("<p><a href=\"https://x.dev\">ok</a> <a href=\"javascript:alert(1)\">bad</a></p>")
if case .paragraph(let t) = link.blocks[0] {
    let links = t.runs.compactMap(\.link)
    check("C10/C21: https link kept, javascript: dropped",
          links.count == 1 && links[0].absoluteString == "https://x.dev", "\(links)")
}

// C15 entities
check("C15: entities decoded", para(HTMLMessageConverter.convert("<p>&amp; &lt; &#128029;</p>")) == "& < 🐝")

// C19 passthrough
check("C19: <sub>/<mark> passthrough",
      para(HTMLMessageConverter.convert("<p>H<sub>2</sub>O is <mark>wet</mark></p>")) == "H2O is wet",
      "got: \(para(HTMLMessageConverter.convert("<p>H<sub>2</sub>O is <mark>wet</mark></p>")) ?? "nil")")

// C22 table fallthrough
check("C22: table → needsWebView", HTMLMessageConverter.convert("<table><tr><td>x</td></tr></table>").needsWebView)

// C25 unknown tag
check("C25: unknown tag → needsWebView", HTMLMessageConverter.convert("<widget>x</widget>").needsWebView)

// S1 depth bomb
let deep = String(repeating: "<div>", count: 100) + "x" + String(repeating: "</div>", count: 100)
check("S1: depth bomb bails closed", HTMLMessageConverter.convert(deep).needsWebView)

// S2 node bomb (bounded time)
let t0 = Date()
let wide = String(repeating: "<b>x</b>", count: 100_000)
let bomb = HTMLMessageConverter.convert(wide)
check("S2: node bomb bails closed", bomb.needsWebView)
print(String(format: "S2 time: %.0f ms", Date().timeIntervalSince(t0) * 1000))

// C12 hr / empty
check("C12: hr", { if case .rule = HTMLMessageConverter.convert("<hr>").blocks.first { return true }; return false }())
check("C12: empty input", HTMLMessageConverter.convert("").blocks.isEmpty)

// C11 image block
let img = HTMLMessageConverter.convert("<p>before</p><img src=\"https://x.dev/a.png\" alt=\"chart\"><p>after</p>")
check("C11: image block between paragraphs",
      { if img.blocks.count == 3, case .image(let u, let a) = img.blocks[1] {
          return u.absoluteString == "https://x.dev/a.png" && a == "chart" }; return false }(),
      "\(img.blocks)")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
