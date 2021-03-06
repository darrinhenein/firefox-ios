/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import UIKit
import WebKit
import Storage
import Snap

public let StatusBarHeight: CGFloat = 20 // TODO: Can't assume this is correct. Status bar height is dynamic.
public let ToolbarHeight: CGFloat = 44
private let OKString = NSLocalizedString("OK", comment: "OK button")
private let CancelString = NSLocalizedString("Cancel", comment: "Cancel button")

private let KVOLoading = "loading"
private let KVOEstimatedProgress = "estimatedProgress"

private let HomeURL = "about:home"

class BrowserViewController: UIViewController {
    private var urlBar: URLBarView!
    private var readerModeBar: ReaderModeBarView!
    private var toolbar: BrowserToolbar!
    private var tabManager: TabManager!
    private var homePanelController: HomePanelViewController?
    private var searchController: SearchViewController?
    private var webViewContainer: UIView!
    private let uriFixup = URIFixup()

    var profile: Profile!

    // These views wrap the urlbar and toolbar to provide background effects on them
    private var header: UIView!
    private var footer: UIView!
    private var previousScroll: CGPoint? = nil

    required init(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        didInit()
    }

    override init() {
        super.init(nibName: nil, bundle: nil)
        didInit()
    }

    private func didInit() {
        let defaultURL = NSURL(string: HomeURL)!
        let defaultRequest = NSURLRequest(URL: defaultURL)
        tabManager = TabManager(defaultNewTabRequest: defaultRequest)
    }

    override func preferredStatusBarStyle() -> UIStatusBarStyle {
        return UIStatusBarStyle.LightContent
    }

    override func viewDidLoad() {
        webViewContainer = UIView()
        view.addSubview(webViewContainer)
        webViewContainer.snp_makeConstraints { make in
            make.edges.equalTo(self.view)
            return
        }

        // Setup the URL bar, wrapped in a view to get transparency effect

        urlBar = URLBarView()
        header = wrapInEffect(urlBar)
        view.addSubview(header)

        header.snp_makeConstraints { make in
            make.top.equalTo(self.view.snp_top)
            make.height.equalTo(ToolbarHeight + StatusBarHeight)
            make.leading.trailing.equalTo(self.view)
        }

        // Setup the reader mode control bar. This bar starts not visible with a zero height.

        readerModeBar = ReaderModeBarView(frame: CGRectZero)
        view.addSubview(readerModeBar)
        readerModeBar.hidden = true

        readerModeBar.snp_makeConstraints { make in
            make.top.equalTo(self.header.snp_bottom)
            make.height.equalTo(ToolbarHeight)
            make.leading.trailing.equalTo(self.view)
        }

        // Setup the bottom toolbar

        toolbar = BrowserToolbar()
        footer = wrapInEffect(toolbar)
        view.addSubview(footer)

        footer.snp_makeConstraints { make in
            make.bottom.equalTo(self.view.snp_bottom)
            make.height.equalTo(ToolbarHeight)
            make.leading.trailing.equalTo(self.view)
        }

        urlBar.delegate = self
        readerModeBar.delegate = self
        toolbar.browserToolbarDelegate = self

        tabManager.delegate = self
        tabManager.addTab()
    }

    private func wrapInEffect(view: UIView) -> UIView {
        let effect = UIVisualEffectView(effect: UIBlurEffect(style: UIBlurEffectStyle.ExtraLight))
        view.backgroundColor = UIColor.clearColor()
        effect.addSubview(view)

        view.snp_makeConstraints { make in
            make.edges.equalTo(effect)
            return
        }

        return effect
    }

    private func showHomePanelController(#inline: Bool) {
        if homePanelController == nil {
            homePanelController = HomePanelViewController()
            homePanelController!.profile = profile
            homePanelController!.delegate = self
            homePanelController!.url = tabManager.selectedTab?.url

            view.addSubview(homePanelController!.view)
            addChildViewController(homePanelController!)
        }

        // Remake constraints even if we're already showing the home controller.
        // The home controller may change sizes if we tap the URL bar while on about:home.
        homePanelController!.view.snp_remakeConstraints { make in
            make.top.equalTo(self.urlBar.snp_bottom)
            make.left.right.equalTo(self.view)
            make.bottom.equalTo(inline ? self.toolbar.snp_top : self.view.snp_bottom)
        }
    }

    private func hideHomePanelController() {
        if let controller = homePanelController {
            controller.view.removeFromSuperview()
            controller.removeFromParentViewController()
            homePanelController = nil
        }
    }

    private func updateInContentHomePanel(url: NSURL?) {
        if !urlBar.isEditing {
            if url?.absoluteString == HomeURL {
                showHomePanelController(inline: true)
            } else {
                hideHomePanelController()
            }
        }
    }

    private func showSearchController() {
        if searchController != nil {
            return
        }

        searchController = SearchViewController()
        searchController!.searchEngines = profile.searchEngines
        searchController!.searchDelegate = self
        searchController!.profile = self.profile

        view.addSubview(searchController!.view)
        searchController!.view.snp_makeConstraints { make in
            make.top.equalTo(self.urlBar.snp_bottom)
            make.left.right.bottom.equalTo(self.view)
            return
        }

        addChildViewController(searchController!)
    }

    private func hideSearchController() {
        if let searchController = searchController {
            searchController.view.removeFromSuperview()
            searchController.removeFromParentViewController()
            self.searchController = nil
        }
    }

    private func finishEditingAndSubmit(var url: NSURL) {
        urlBar.updateURL(url)
        urlBar.finishEditing()

        if let tab = tabManager.selectedTab {
            if ReaderMode.isReaderModeURL(url) {
                if let readerMode = tab.getHelper(name: "ReaderMode") as? ReaderMode {
                    // Switch to reader mode immediately when we detect it can be activated. The reader mode will still
                    // call its delegate to let us know its state changed so that we can update the UI.
                    readerMode.activateImmediately = true
                    // We don't show the initial page when opening a reader: url. This will probably change to some overlay on top of the webview.
                    tab.hideContent(animated: false)
                    if let originalURL = ReaderMode.decodeURL(url) {
                        url = originalURL
                    }
                }
            }
            tab.loadRequest(NSURLRequest(URL: url))
        }
    }

    private func addBookmark(url: String, title: String?) {
        let shareItem = ShareItem(url: url, title: title)
        profile.bookmarks.shareItem(shareItem)

        // Dispatch to the main thread to update the UI
        dispatch_async(dispatch_get_main_queue()) { _ in
            self.toolbar.updateBookmarkStatus(true)
        }
    }

    private func removeBookmark(url: String) {
        var bookmark = BookmarkItem(guid: "", title: "", url: url)
        profile.bookmarks.remove(bookmark, success: { success in
            self.toolbar.updateBookmarkStatus(!success)
            }, failure: { err in
                println("Err removing bookmark \(err)")
        })
    }

    override func accessibilityPerformEscape() -> Bool {
        if let selectedTab = tabManager.selectedTab? {
            if selectedTab.canGoBack {
                tabManager.selectedTab?.goBack()
                return true
            }
        }
        return false
    }

    override func observeValueForKeyPath(keyPath: String, ofObject object: AnyObject, change: [NSObject: AnyObject], context: UnsafeMutablePointer<Void>) {
        if object as? WKWebView !== tabManager.selectedTab?.webView {
            return
        }

        switch keyPath {
        case KVOEstimatedProgress:
            urlBar.updateProgressBar(change[NSKeyValueChangeNewKey] as Float)
        case KVOLoading:
            urlBar.updateLoading(change[NSKeyValueChangeNewKey] as Bool)
        default:
            assertionFailure("Unhandled KVO key: \(keyPath)")
        }
    }
}


extension BrowserViewController: URLBarDelegate {
    func urlBarDidPressReload(urlBar: URLBarView) {
        tabManager.selectedTab?.reload()
    }

    func urlBarDidPressStop(urlBar: URLBarView) {
        tabManager.selectedTab?.stop()
    }

    func urlBarDidPressTabs(urlBar: URLBarView) {
        let controller = TabTrayController()
        controller.profile = profile
        controller.tabManager = tabManager
        controller.transitioningDelegate = self
        controller.modalPresentationStyle = .Custom
        presentViewController(controller, animated: true, completion: nil)
    }

    func urlBarDidPressReaderMode(urlBar: URLBarView) {
        if let tab = tabManager.selectedTab {
            if let readerMode = tab.getHelper(name: "ReaderMode") as? ReaderMode {
                if readerMode.state == .Available {
                    // Update the style of the reader mode to what was last configured
                    if let dict = self.profile.prefs.dictionaryForKey(ReaderModeProfileKeyStyle) {
                        if let style = ReaderModeStyle(dict: dict) {
                            readerMode.style = style
                        }
                    }
                    readerMode.enableReaderMode()

//                    hideToolbars(animated: true, completion: { finished in
//                        //self.showReaderModeBar(animated: false)
//                    })
                    self.showReaderModeBar(animated: true)
                } else {
                    readerMode.disableReaderMode()
                    self.hideReaderModeBar(animated: true)
                }
            }
        }
    }

    func urlBar(urlBar: URLBarView, didEnterText text: String) {
        if text.isEmpty {
            hideSearchController()
        } else {
            showSearchController()
            searchController!.searchQuery = text
        }
    }

    func urlBar(urlBar: URLBarView, didSubmitText text: String) {
        var url = uriFixup.getURL(text)

        // If we can't make a valid URL, do a search query.
        if url == nil {
            url = profile.searchEngines.defaultEngine.searchURLForQuery(text)
        }

        // If we still don't have a valid URL, something is broken. Give up.
        if url == nil {
            println("Error handling URL entry: " + text)
            return
        }

        finishEditingAndSubmit(url!)
    }

    func urlBarDidBeginEditing(urlBar: URLBarView) {
        showHomePanelController(inline: false)
    }

    func urlBarDidEndEditing(urlBar: URLBarView) {
        hideSearchController()
        updateInContentHomePanel(tabManager.selectedTab?.url)
    }
}

extension BrowserViewController: BrowserToolbarDelegate {
    func browserToolbarDidPressBack(browserToolbar: BrowserToolbar) {
        tabManager.selectedTab?.goBack()
    }

    func browserToolbarDidLongPressBack(browserToolbar: BrowserToolbar) {
        let controller = BackForwardListViewController()
        controller.listData = tabManager.selectedTab?.backList
        controller.tabManager = tabManager
        presentViewController(controller, animated: true, completion: nil)
    }

    func browserToolbarDidPressForward(browserToolbar: BrowserToolbar) {
        tabManager.selectedTab?.goForward()
    }

    func browserToolbarDidLongPressForward(browserToolbar: BrowserToolbar) {
        let controller = BackForwardListViewController()
        controller.listData = tabManager.selectedTab?.forwardList
        controller.tabManager = tabManager
        presentViewController(controller, animated: true, completion: nil)
    }

    func browserToolbarDidPressBookmark(browserToolbar: BrowserToolbar) {
        if let tab = tabManager.selectedTab? {
            if let url = tab.url?.absoluteString {
                profile.bookmarks.isBookmarked(url,
                    success: { isBookmarked in
                        if isBookmarked {
                            self.removeBookmark(url)
                        } else {
                            self.addBookmark(url, title: tab.title)
                        }
                    },
                    failure: { err in
                        println("Bookmark error: \(err)")
                    }
                )
            } else {
                println("Bookmark error: Couldn't find a URL for this tab")
            }
        } else {
            println("Bookmark error: No tab is selected")
        }
    }

    func browserToolbarDidLongPressBookmark(browserToolbar: BrowserToolbar) {
    }

    func browserToolbarDidPressShare(browserToolbar: BrowserToolbar) {
        if let selected = tabManager.selectedTab {
            if let url = selected.url {
                var shareController = UIActivityViewController(activityItems: [selected.title ?? url.absoluteString!, url], applicationActivities: nil)
                shareController.modalTransitionStyle = .CoverVertical
                presentViewController(shareController, animated: true, completion: nil)
            }
        }
    }
}

extension BrowserViewController: HomePanelViewControllerDelegate {
    func homePanelViewController(homePanelViewController: HomePanelViewController, didSelectURL url: NSURL) {
        finishEditingAndSubmit(url)
    }
}

extension BrowserViewController: SearchViewControllerDelegate {
    func searchViewController(searchViewController: SearchViewController, didSelectURL url: NSURL) {
        finishEditingAndSubmit(url)
    }
}

extension BrowserViewController: UIScrollViewDelegate {
    private func clamp(y: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        if y >= max {
            return max
        } else if y <= min {
            return min
        }
        return y
    }

    private func scrollUrlBar(dy: CGFloat) {
        let newY = clamp(header.transform.ty + dy, min: -ToolbarHeight, max: 0)
        header.transform = CGAffineTransformMakeTranslation(0, newY)

        let percent = 1 - newY / -ToolbarHeight
        urlBar.alpha = percent
    }

    private func scrollToolbar(dy: CGFloat) {
        let newY = clamp(footer.transform.ty - dy, min: 0, max: footer.frame.height)
        footer.transform = CGAffineTransformMakeTranslation(0, newY)
    }

    func scrollViewWillBeginDragging(scrollView: UIScrollView) {
        previousScroll = scrollView.contentOffset
    }

    // Careful! This method can be called multiple times concurrently.
    func scrollViewDidScroll(scrollView: UIScrollView) {
        if var prev = previousScroll {
            if let tab = tabManager.selectedTab {
                if tab.loading {
                    return
                }

                let offset = scrollView.contentOffset
                var delta = CGPoint(x: prev.x - offset.x, y: prev.y - offset.y)
                previousScroll = offset

                if let tab = self.tabManager.selectedTab {
                    let inset = tab.webView.scrollView.contentInset
                    let newInset = clamp(inset.top + delta.y, min: StatusBarHeight, max: ToolbarHeight + StatusBarHeight)

                    tab.webView.scrollView.contentInset = UIEdgeInsetsMake(newInset, 0, clamp(newInset - StatusBarHeight, min: 0, max: ToolbarHeight), 0)
                    tab.webView.scrollView.scrollIndicatorInsets = UIEdgeInsetsMake(newInset - StatusBarHeight, 0, clamp(newInset, min: 0, max: ToolbarHeight), 0)

                    // Adjusting the contentInset will change the scroll position of the page.
                    // We account for that by also adjusting the previousScroll position
                    delta.y += inset.top - newInset
                }

                scrollUrlBar(delta.y)
                scrollToolbar(delta.y)
            }
        }
    }

    func scrollViewWillEndDragging(scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        previousScroll = nil
        if tabManager.selectedTab?.loading ?? false {
            return
        }

        let offset = scrollView.contentOffset
        // If we're moving up, or the header is half onscreen, hide the toolbars
        if velocity.y < 0 || self.header.transform.ty > -self.header.frame.height / 2 {
            showToolbars(animated: true)
        } else {
            hideToolbars(animated: true)
        }
    }

    func scrollViewDidScrollToTop(scrollView: UIScrollView) {
        showToolbars(animated: true)
    }

    private func hideToolbars(#animated: Bool, completion: ((finished: Bool) -> Void)? = nil) {
        UIView.animateWithDuration(animated ? 0.5 : 0.0, animations: { () -> Void in
            self.scrollUrlBar(CGFloat(-1*MAXFLOAT))
            self.scrollToolbar(CGFloat(-1*MAXFLOAT))
            // Reset the insets so that clicking works on the edges of the screen
            if let tab = self.tabManager.selectedTab {
                tab.webView.scrollView.contentInset = UIEdgeInsets(top: StatusBarHeight, left: 0, bottom: 0, right: 0)
                tab.webView.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: StatusBarHeight, left: 0, bottom: 0, right: 0)
            }
        }, completion: completion)
    }

    private func showToolbars(#animated: Bool, completion: ((finished: Bool) -> Void)? = nil) {
        UIView.animateWithDuration(animated ? 0.5 : 0.0, animations: { () -> Void in
            self.scrollUrlBar(CGFloat(MAXFLOAT))
            self.scrollToolbar(CGFloat(MAXFLOAT))
            // Reset the insets so that clicking works on the edges of the screen
            if let tab = self.tabManager.selectedTab {
                tab.webView.scrollView.contentInset = UIEdgeInsets(top: self.header.frame.height + (self.readerModeBar.hidden ? 0 : self.readerModeBar.frame.height), left: 0, bottom: ToolbarHeight, right: 0)
                tab.webView.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: self.header.frame.height + (self.readerModeBar.hidden ? 0 : self.readerModeBar.frame.height), left: 0, bottom: ToolbarHeight, right: 0)
            }
        }, completion: completion)
    }
}

extension BrowserViewController: TabManagerDelegate {
    func tabManager(tabManager: TabManager, didSelectedTabChange selected: Browser?, previous: Browser?) {
        if let wv = selected?.webView {
            webViewContainer.addSubview(wv)
        }

        previous?.webView.navigationDelegate = nil
        //previous?.webView.scrollView.delegate = nil
        selected?.webView.navigationDelegate = self
        //selected?.webView.scrollView.delegate = self
        urlBar.updateURL(selected?.url)
        showToolbars(animated: false)

        toolbar.updateBackStatus(selected?.canGoBack ?? false)
        toolbar.updateFowardStatus(selected?.canGoForward ?? false)
        urlBar.updateProgressBar(Float(selected?.webView.estimatedProgress ?? 0))
        urlBar.updateLoading(selected?.webView.loading ?? false)

        if let readerMode = selected?.getHelper(name: ReaderMode.name()) as? ReaderMode {
            urlBar.updateReaderModeState(readerMode.state)
        } else {
            urlBar.updateReaderModeState(ReaderModeState.Unavailable)
        }

        updateInContentHomePanel(selected?.url)
    }

    func tabManager(tabManager: TabManager, didCreateTab tab: Browser) {
        if let longPressGestureRecognizer = LongPressGestureRecognizer(webView: tab.webView) {
            tab.webView.addGestureRecognizer(longPressGestureRecognizer)
            longPressGestureRecognizer.longPressGestureDelegate = self
        }

        if let readerMode = ReaderMode(browser: tab) {
            readerMode.delegate = self
            tab.addHelper(readerMode, name: ReaderMode.name())

            // TODO: This is a *temporary* way to trigger the reader mode style dialog via 3 taps in the webview. When
            // we know where the Aa button needs to go, all code below can be refactored properly.
            let gestureRecognizer = UITapGestureRecognizer(target: self, action: "SELshowReaderModeStyle:")
            gestureRecognizer.numberOfTapsRequired = 3
            tab.webView.addGestureRecognizer(gestureRecognizer)
        }

        let favicons = FaviconManager(browser: tab, profile: profile)
        tab.addHelper(favicons, name: FaviconManager.name())

        let pm = PasswordManager(browser: tab, profile: profile)
        tab.addHelper(pm, name: PasswordManager.name())
    }

    func tabManager(tabManager: TabManager, didAddTab tab: Browser) {
        urlBar.updateTabCount(tabManager.count)

        webViewContainer.insertSubview(tab.webView, atIndex: 0)
        tab.webView.scrollView.contentInset = UIEdgeInsetsMake(ToolbarHeight + StatusBarHeight, 0, ToolbarHeight, 0)
        tab.webView.scrollView.scrollIndicatorInsets = UIEdgeInsetsMake(ToolbarHeight + StatusBarHeight, 0, ToolbarHeight, 0)
        tab.webView.snp_makeConstraints { make in
            make.top.equalTo(self.view.snp_top)
            make.leading.trailing.bottom.equalTo(self.view)
        }
        tab.webView.addObserver(self, forKeyPath: KVOEstimatedProgress, options: .New, context: nil)
        tab.webView.addObserver(self, forKeyPath: KVOLoading, options: .New, context: nil)
        tab.webView.UIDelegate = self
    }

    func tabManager(tabManager: TabManager, didRemoveTab tab: Browser) {
        urlBar.updateTabCount(tabManager.count)

        tab.webView.removeObserver(self, forKeyPath: KVOEstimatedProgress)
        tab.webView.removeObserver(self, forKeyPath: KVOLoading)
        tab.webView.removeFromSuperview()
    }
}

extension BrowserViewController: WKNavigationDelegate {
    func webView(webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // If we are going to navigate to a new page, hide the reader mode button. Unless we
        // are going to a about:reader page. Then we keep it on screen: it will change status
        // (orange color) as soon as the page has loaded.
        if let absoluteString = webView.URL?.absoluteString {
            // TODO String comparison here because NSURL cannot parse about:reader URLs (1123509)
            if !absoluteString.hasPrefix("about:reader") {
                urlBar.updateReaderModeState(ReaderModeState.Unavailable)
            }
        }
    }

    func webView(webView: WKWebView, didCommitNavigation navigation: WKNavigation!) {
        urlBar.updateURL(webView.URL);
        toolbar.updateBackStatus(webView.canGoBack)
        toolbar.updateFowardStatus(webView.canGoForward)
        showToolbars(animated: false)

        if let url = webView.URL?.absoluteString {
            profile.bookmarks.isBookmarked(url, success: { bookmarked in
                self.toolbar.updateBookmarkStatus(bookmarked)
            }, failure: { err in
                println("Error getting bookmark status: \(err)")
            })
        }

        updateInContentHomePanel(webView.URL)
    }

    func webView(webView: WKWebView, didFinishNavigation navigation: WKNavigation!) {
        let notificationCenter = NSNotificationCenter.defaultCenter()
        var info = [NSObject: AnyObject]()
        info["url"] = webView.URL
        info["title"] = webView.title
        notificationCenter.postNotificationName("LocationChange", object: self, userInfo: info)

        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil)
        // must be followed by LayoutChanged, as ScreenChanged will make VoiceOver
        // cursor land on the correct initial element, but if not followed by LayoutChanged,
        // VoiceOver will sometimes be stuck on the element, not allowing user to move
        // forward/backward. Strange, but LayoutChanged fixes that.
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil)
    }
}

extension BrowserViewController: WKUIDelegate {
    func webView(webView: WKWebView, createWebViewWithConfiguration configuration: WKWebViewConfiguration, forNavigationAction navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // If the page uses window.open() or target="_blank", open the page in a new tab.
        // TODO: This doesn't work for window.open() without user action (bug 1124942).
        let tab = tabManager.addTab(request: navigationAction.request, configuration: configuration)
        return tab.webView
    }

    func webView(webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: () -> Void) {
        tabManager.selectTab(tabManager.getTab(webView))

        // Show JavaScript alerts.
        let title = frame.request.URL.host
        let alertController = UIAlertController(title: title, message: message, preferredStyle: UIAlertControllerStyle.Alert)
        alertController.addAction(UIAlertAction(title: OKString, style: UIAlertActionStyle.Default, handler: { _ in
            completionHandler()
        }))
        presentViewController(alertController, animated: true, completion: nil)
    }

    func webView(webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: (Bool) -> Void) {
        tabManager.selectTab(tabManager.getTab(webView))

        // Show JavaScript confirm dialogs.
        let title = frame.request.URL.host
        let alertController = UIAlertController(title: title, message: message, preferredStyle: UIAlertControllerStyle.Alert)
        alertController.addAction(UIAlertAction(title: OKString, style: UIAlertActionStyle.Default, handler: { _ in
            completionHandler(true)
        }))
        alertController.addAction(UIAlertAction(title: CancelString, style: UIAlertActionStyle.Cancel, handler: { _ in
            completionHandler(false)
        }))
        presentViewController(alertController, animated: true, completion: nil)
    }

    func webView(webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: (String!) -> Void) {
        tabManager.selectTab(tabManager.getTab(webView))

        // Show JavaScript input dialogs.
        let title = frame.request.URL.host
        let alertController = UIAlertController(title: title, message: prompt, preferredStyle: UIAlertControllerStyle.Alert)
        var input: UITextField!
        alertController.addTextFieldWithConfigurationHandler({ (textField: UITextField!) in
            textField.text = defaultText
            input = textField
        })
        alertController.addAction(UIAlertAction(title: OKString, style: UIAlertActionStyle.Default, handler: { _ in
            completionHandler(input.text)
        }))
        alertController.addAction(UIAlertAction(title: CancelString, style: UIAlertActionStyle.Cancel, handler: { _ in
            completionHandler(nil)
        }))
        presentViewController(alertController, animated: true, completion: nil)
    }
}

extension BrowserViewController: ReaderModeDelegate, UIPopoverPresentationControllerDelegate {
    func readerMode(readerMode: ReaderMode, didChangeReaderModeState state: ReaderModeState, forBrowser browser: Browser) {
        // If this reader mode availability state change is for the tab that we currently show, then update
        // the button. Otherwise do nothing and the button will be updated when the tab is made active.
        if tabManager.selectedTab == browser {
            println("DEBUG: New readerModeState: \(state.rawValue)")
            urlBar.updateReaderModeState(state)
        }
    }

    func readerMode(readerMode: ReaderMode, didDisplayReaderizedContentForBrowser browser: Browser) {
        self.showReaderModeBar(animated: true)
        browser.showContent(animated: true)
    }

    func SELshowReaderModeStyle(recognizer: UITapGestureRecognizer) {
        if let readerMode = tabManager.selectedTab?.getHelper(name: "ReaderMode") as? ReaderMode {
            if readerMode.state == ReaderModeState.Active {
                let readerModeStyleViewController = ReaderModeStyleViewController()
                readerModeStyleViewController.delegate = self
                readerModeStyleViewController.readerModeStyle = readerMode.style
                readerModeStyleViewController.modalPresentationStyle = UIModalPresentationStyle.Popover

                let popoverPresentationController = readerModeStyleViewController.popoverPresentationController
                popoverPresentationController?.backgroundColor = UIColor.whiteColor()
                popoverPresentationController?.delegate = self
                popoverPresentationController?.sourceView = self.view
                popoverPresentationController?.sourceRect = CGRect(x: self.view.frame.width/2, y: self.view.frame.height-4, width: 4, height: 4)

                self.presentViewController(readerModeStyleViewController, animated: true, completion: nil)
            }
        }
    }

    // Returning None here makes sure that the Popover is actually presented as a Popover and
    // not as a full-screen modal, which is the default on compact device classes.
    func adaptivePresentationStyleForPresentationController(controller: UIPresentationController) -> UIModalPresentationStyle {
        return UIModalPresentationStyle.None
    }
}

extension BrowserViewController: ReaderModeStyleViewControllerDelegate {
    func readerModeStyleViewController(readerModeStyleViewController: ReaderModeStyleViewController, didConfigureStyle style: ReaderModeStyle) {
        // Persist the new style to the profile
        let encodedStyle: [String:AnyObject] = style.encode()
        profile.prefs.setObject(encodedStyle, forKey: ReaderModeProfileKeyStyle)
        // Change the reader mode style on all tabs that have reader mode active
        for tabIndex in 0..<tabManager.count {
            if let readerMode = tabManager.getTab(tabIndex).getHelper(name: "ReaderMode") as? ReaderMode {
                if readerMode.state == ReaderModeState.Active {
                    readerMode.style = style
                }
            }
        }
    }
}

extension BrowserViewController: LongPressGestureDelegate {
    func longPressRecognizer(longPressRecognizer: LongPressGestureRecognizer, didLongPressElements elements: [LongPressElementType: NSURL]) {
        var actionSheetController = UIAlertController(title: nil, message: nil, preferredStyle: UIAlertControllerStyle.ActionSheet)
        var dialogTitleURL: NSURL?
        if let linkURL = elements[LongPressElementType.Link] {
            dialogTitleURL = linkURL
            var openNewTabAction =  UIAlertAction(title: "Open In New Tab", style: UIAlertActionStyle.Default) { (action: UIAlertAction!) in
                let request =  NSURLRequest(URL: linkURL)
                let tab = self.tabManager.addTab(request: request)
            }
            actionSheetController.addAction(openNewTabAction)

            var copyAction = UIAlertAction(title: "Copy", style: UIAlertActionStyle.Default) { (action: UIAlertAction!) -> Void in
                var pasteBoard = UIPasteboard.generalPasteboard()
                pasteBoard.string = linkURL.absoluteString
            }
            actionSheetController.addAction(copyAction)
        }
        if let imageURL = elements[LongPressElementType.Image] {
            if dialogTitleURL == nil {
                dialogTitleURL = imageURL
            }
            var saveImageAction = UIAlertAction(title: "Save Image", style: UIAlertActionStyle.Default) { (action: UIAlertAction!) -> Void in
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), { () -> Void in
                    var imageData = NSData(contentsOfURL: imageURL)
                    if imageData != nil {
                        UIImageWriteToSavedPhotosAlbum(UIImage(data: imageData!), nil, nil, nil)
                    }
                })
            }
            actionSheetController.addAction(saveImageAction)

            var copyAction = UIAlertAction(title: "Copy Image URL", style: UIAlertActionStyle.Default) { (action: UIAlertAction!) -> Void in
                var pasteBoard = UIPasteboard.generalPasteboard()
                pasteBoard.string = imageURL.absoluteString
            }
            actionSheetController.addAction(copyAction)
        }
        actionSheetController.title = dialogTitleURL!.absoluteString
        var cancelAction = UIAlertAction(title: "Cancel", style: UIAlertActionStyle.Cancel, nil)
        actionSheetController.addAction(cancelAction)
        self.presentViewController(actionSheetController, animated: true, completion: nil)
    }
}

extension BrowserViewController : UIViewControllerTransitioningDelegate {
    func animationControllerForDismissedController(dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return TransitionManager(show: false)
    }

    func animationControllerForPresentedController(presented: UIViewController, presentingController presenting: UIViewController, sourceController source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return TransitionManager(show: true)
    }
}

extension BrowserViewController : Transitionable {
    func transitionableWillShow(transitionable: Transitionable, options: TransitionOptions) {
        view.transform = CGAffineTransformIdentity
        view.alpha = 1
        // Move all the webview's off screen
        for i in 0..<tabManager.count {
            let tab = tabManager.getTab(i)
            tab.webView.frame = CGRect(x: tab.webView.frame.width, y: 0, width: tab.webView.frame.width, height: tab.webView.frame.height)
        }
    }

    func transitionableWillHide(transitionable: Transitionable, options: TransitionOptions) {
        if let cell = options.moving {
            view.transform = CGAffineTransformMakeTranslation(0, cell.frame.origin.y - toolbar.frame.height)
        }
        view.alpha = 0
        // Move all the webview's off screen
        for i in 0..<tabManager.count {
            let tab = tabManager.getTab(i)
            tab.webView.frame = CGRect(x: tab.webView.frame.width, y: 0, width: tab.webView.frame.width, height: tab.webView.frame.height)
        }
    }

    func transitionableWillComplete(transitionable: Transitionable, options: TransitionOptions) {
        // Move all the webview's back on screen
        for i in 0..<tabManager.count {
            let tab = tabManager.getTab(i)
            tab.webView.frame = CGRect(x: 0, y: 0, width: tab.webView.frame.width, height: tab.webView.frame.height)
        }
    }
}

extension BrowserViewController {
    func showReaderModeBar(#animated: Bool) {
        // TODO This needs to come from the database
        readerModeBar.unread = true
        readerModeBar.added = false
        readerModeBar.hidden = false
    }

    func hideReaderModeBar(#animated: Bool) {
        readerModeBar.hidden = true
    }
}

extension BrowserViewController: ReaderModeBarViewDelegate {
    func readerModeBar(readerModeBar: ReaderModeBarView, didSelectButton buttonType: ReaderModeBarButtonType) {
        switch buttonType {
        case .Settings:
            if let readerMode = tabManager.selectedTab?.getHelper(name: "ReaderMode") as? ReaderMode {
                if readerMode.state == ReaderModeState.Active {
                    let readerModeStyleViewController = ReaderModeStyleViewController()
                    readerModeStyleViewController.delegate = self
                    readerModeStyleViewController.readerModeStyle = readerMode.style
                    readerModeStyleViewController.modalPresentationStyle = UIModalPresentationStyle.Popover

                    let popoverPresentationController = readerModeStyleViewController.popoverPresentationController
                    popoverPresentationController?.backgroundColor = UIColor.whiteColor()
                    popoverPresentationController?.delegate = self
                    popoverPresentationController?.sourceView = readerModeBar
                    popoverPresentationController?.sourceRect = CGRect(x: readerModeBar.frame.width/2, y: ToolbarHeight, width: 1, height: 1)
                    popoverPresentationController?.permittedArrowDirections = UIPopoverArrowDirection.Up

                    self.presentViewController(readerModeStyleViewController, animated: true, completion: nil)
                }
            }

        case .MarkAsRead:
            // TODO Persist to database
            readerModeBar.unread = false
        case .MarkAsUnread:
            // TODO Persist to database
            readerModeBar.unread = true

        case .AddToReadingList:
            // TODO Persist to database - The code below needs an update to talk to improved storage layer
            if let tab = tabManager.selectedTab? {
                if var url = tab.url? {
                    if ReaderMode.isReaderModeURL(url) {
                        if let url = ReaderMode.decodeURL(url) {
                            if let absoluteString = url.absoluteString {
                                profile.readingList.add(item: ReadingListItem(url: absoluteString, title: tab.title)) { (success) -> Void in
                                    //readerModeBar.added = true
                                }
                            }
                        }
                    }
                }
            }
            break
        case .RemoveFromReadingList:
            // TODO Persist to database
            break
        }
    }
}
