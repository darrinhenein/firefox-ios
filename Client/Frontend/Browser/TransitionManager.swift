/* This Source Code Form is subject to the terms of the Mozilla Public
* License, v. 2.0. If a copy of the MPL was not distributed with this
* file, You can obtain one at http://mozilla.org/MPL/2.0/. */

@objc
class TransitionOptions {
    var container: UIView? = nil
    var moving: UIView? = nil
    var fromView: UIViewController? = nil
    var toView: UIViewController? = nil
}

@objc
protocol Transitionable : class {
    func transitionablePreShow(transitionable: Transitionable, options: TransitionOptions)
    func transitionablePreHide(transitionable: Transitionable, options: TransitionOptions)
    func transitionableWillHide(transitionable: Transitionable, options: TransitionOptions)
    func transitionableWillShow(transitionable: Transitionable, options: TransitionOptions)
    func transitionableWillComplete(transitionable: Transitionable, options: TransitionOptions)
}

@objc
class TransitionManager: UIPercentDrivenInteractiveTransition, UIViewControllerAnimatedTransitioning, UIViewControllerInteractiveTransitioning, UIViewControllerTransitioningDelegate {

    var show = false
    var interactive = false

    override init() {
        super.init()
    }

    func animateTransition(transitionContext: UIViewControllerContextTransitioning) {
        let fromView = transitionContext.viewControllerForKey(UITransitionContextFromViewControllerKey)!
        let toView = transitionContext.viewControllerForKey(UITransitionContextToViewControllerKey)!

        let container = transitionContext.containerView()
        if show {
            container.insertSubview(toView.view, aboveSubview: fromView.view)
        }

        var options = TransitionOptions()
        options.container = container
        options.fromView = fromView
        options.toView = toView

        if let to = toView as? Transitionable {
            if let from = fromView as? Transitionable {
                to.transitionableWillHide(to, options: options)
                from.transitionableWillShow(from, options: options)

                let duration = self.transitionDuration(transitionContext)

                to.transitionablePreShow(to, options: options)
                from.transitionablePreHide(from, options: options)

                UIView.animateWithDuration(duration, delay: 0, usingSpringWithDamping: 0.95, initialSpringVelocity: 0, options: nil, animations: { () -> Void in
                        to.transitionableWillShow(to, options: options)
                        from.transitionableWillHide(from, options: options)
                    }, completion: { finished in
                        if(transitionContext.transitionWasCancelled()){
                            println("transition cancelled")
                            transitionContext.completeTransition(false)
                        }
                        else {
                            println("transition completed")
                            to.transitionableWillComplete(to, options: options)
                            from.transitionableWillComplete(from, options: options)
                            transitionContext.completeTransition(true)
                        }
                        self.interactive = false
                })

            }
        }
    }

    func animationControllerForDismissedController(dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        self.show = false
        return self
    }

    func animationControllerForPresentedController(presented: UIViewController, presentingController presenting: UIViewController, sourceController source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        self.show = true
        return self
    }

    func interactionControllerForPresentation(animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        // if our interactive flag is true, return the transition manager object
        // otherwise return nil
        return self.interactive ? self : nil
    }

    func interactionControllerForDismissal(animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        return self.interactive ? self : nil
    }


    func handleScroll(pan: UIPanGestureRecognizer){

        let translation = pan.translationInView(pan.view!)

        let d =  translation.y / (CGRectGetHeight(pan.view!.bounds))

        switch (pan.state) {

        case .Began:
            // set our interactive flag to true
//            self.interactive = true

            // trigger the start of the transition
//            self.sourceViewController.performSegueWithIdentifier("presentMenu", sender: self)
            break

        case .Changed:
            println("changed:", d)
            self.updateInteractiveTransition(d)
            break

        default: // .Ended, .Cancelled, .Failed ...
            println("default:", d)
            if d < 0.5 {
                self.cancelInteractiveTransition()
            } else {
                self.finishInteractiveTransition()
            }

        }
    }

    func transitionDuration(transitionContext: UIViewControllerContextTransitioning) -> NSTimeInterval {
        return 0.35
    }
}
