import AppKit
import WebKit

let templatePath = "/Users/openclaw/Projects/BeeChat-v5/Sources/App/Resources/TranscriptTemplate.html"
let html = try! String(contentsOfFile: templatePath, encoding: .utf8)

final class Probe: NSObject, WKScriptMessageHandler {
    var web: WKWebView!
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.name == "bcReady" else { return }
        print("== bcReady fired ==")
        step1()
    }
    func run(_ label: String, _ js: String, _ next: @escaping () -> Void) {
        web.evaluateJavaScript(js) { res, err in
            if let e = err { print("[\(label)] THREW: \(e.localizedDescription)") }
            else { print("[\(label)] OK -> \(String(describing: res))") }
            next()
        }
    }
    func step1() {
        // EXACTLY what WebTranscriptView emits for a topic switch
        let js = #"window.bc.setTopic({"topicId":"t1","messages":[{"id":"m1","role":"user","html":"<p>hello</p>","timeLabel":"10:00"}],"canLoadEarlier":false})"#
        run("setTopic(object)", js) { self.step2() }
    }
    func step2() {
        run("count .msg after setTopic", "document.querySelectorAll('.msg').length") { self.step3() }
    }
    func step3() {
        // EXACTLY what WebTranscriptView emits for an upsert
        let js = #"window.bc.upsertMessages({"messages":[{"id":"m2","role":"assistant","html":"<p>reply</p>","timeLabel":"10:01"}],"canLoadEarlier":false})"#
        run("upsertMessages(object)  <-- host's actual call", js) { self.step4() }
    }
    func step4() {
        // What the template signature actually wants
        let js = #"window.bc.upsertMessages([{"id":"m3","role":"assistant","html":"<p>reply2</p>"}], false)"#
        run("upsertMessages(array,bool) <-- template's signature", js) { self.step5() }
    }
    func step5() {
        run("final .msg count", "document.querySelectorAll('.msg').length") {
            print("== done ==")
            exit(0)
        }
    }
}

let app = NSApplication.shared
let probe = Probe()
let cc = WKUserContentController()
for n in ["bcReady","bcLink","bcImage","bcLoadEarlier","bcCopyMessage"] { cc.add(probe, name: n) }
let cfg = WKWebViewConfiguration(); cfg.userContentController = cc
let web = WKWebView(frame: NSRect(x:0,y:0,width:900,height:700), configuration: cfg)
probe.web = web
let win = NSWindow(contentRect: NSRect(x:0,y:0,width:900,height:700), styleMask: [.titled], backing: .buffered, defer: false)
win.contentView = web
win.orderFrontRegardless()
web.loadHTMLString(html, baseURL: nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("TIMEOUT"); exit(1) }
app.run()
