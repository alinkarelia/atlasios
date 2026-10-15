import WebKit

/// A deliberately tiny appearance channel. It cannot sign in, execute actions,
/// access files or issue API requests. The web content controller retains this
/// object, which keeps only a weak reference to the session.
@MainActor
final class AppearanceMessageHandler: NSObject, WKScriptMessageHandler {
    weak var session: WebSession?

    init(session: WebSession) {
        self.session = session
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        session?.receiveAppearance(message)
    }

    static let observerScript = """
    (() => {
      const update = () => {
        const theme = document.documentElement.dataset.theme;
        if (theme === 'light' || theme === 'dark') {
          window.webkit.messageHandlers.aveliAppearance.postMessage(theme);
        }
      };
      new MutationObserver(update).observe(document.documentElement, {
        attributes: true, attributeFilter: ['data-theme']
      });
      update();
    })();
    """
}
