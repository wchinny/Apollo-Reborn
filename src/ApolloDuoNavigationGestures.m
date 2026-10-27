#import "ApolloDuoNavigationGestures.h"
#import "ApolloDuoSplitView.h"
#import "ApolloCommon.h"
#import <objc/runtime.h>

// Apollo's pans use the whole navigation surface for edge checks. On Duo a
// visible pane can start well inside that surface, and the outer stack is a
// containment host. Qualify a right pan at the *pane's* left content edge,
// then drive Back on that exact navigation controller with the finger, the
// way Apollo's own edge pan does elsewhere. At the feed root the same gesture
// reveals the subreddit drawer. Calling the native pop entry point keeps the
// author's feed/thread restoration animation where the split replaces the pop.
// Keep row swipe actions elsewhere, and honor Apollo's navigation-gesture opt-out.
static BOOL ApolloDuoBackSwipeCanNavigate(UINavigationController *navigation) {
    BOOL eligible = ApolloDeviceIsDuo() && navigation.viewIfLoaded.window
        && (navigation.viewControllers.count > 1 || ApolloDuoSplitCanRevealPostsListWithSwipe(navigation))
        && ![NSUserDefaults.standardUserDefaults boolForKey:@"DisableNavigationGestures"]
        && !ApolloDuoSplitIsResizing() && !navigation.transitionCoordinator
        && !navigation.presentedViewController && !navigation.topViewController.presentedViewController
        && !navigation.isBeingDismissed
        && ApolloDuoSplitAllowsNavigationSwipe(navigation)
        && ApolloDuoSplitDetailNavigation(navigation) == navigation;
    if (!eligible) return NO;
    // Sheets can belong to the containing split, tab, or outer navigation
    // controller rather than the pane itself. Never navigate behind one.
    for (UIViewController *parent = navigation.parentViewController; parent; parent = parent.parentViewController) {
        if (parent.presentedViewController || parent.isBeingDismissed || parent.transitionCoordinator) return NO;
    }
    return YES;
}

static BOOL ApolloDuoBackSwipeAcceptsPoint(UINavigationController *navigation, CGPoint point) {
    if (!ApolloDuoBackSwipeCanNavigate(navigation)) return NO;
    UIView *view = navigation.view;
    CGRect pane = ApolloDuoSplitContentFrame(navigation, view);
    if (CGRectIsNull(pane)) {
        CGRect safe = view.safeAreaLayoutGuide.layoutFrame;
        // A full-width landscape screen can inset content for a camera or
        // rounded corner. Back still begins at its physical left edge.
        pane = CGRectMake(CGRectGetMinX(view.bounds), CGRectGetMinY(safe),
                          CGRectGetWidth(view.bounds), CGRectGetHeight(safe));
    }
    if (CGRectIsEmpty(pane) || !CGRectContainsPoint(pane, point)) return NO;
    return point.x <= CGRectGetMinX(pane) + 28.0;
}

// Apollo's delegate hands UIKit whatever sits in the navigation controller's
// typed interactionController slot, as the iPad pane's compact Back relies on
// (ApolloPaneSetNativeInteractiveTransition). Writing it through Swift keeps
// the Optional's retain/release balanced.
extern void ApolloSwiftAssignInteractiveTransition(void *storage, const void *object);
static BOOL ApolloDuoSetInteractiveTransition(UINavigationController *navigation,
                                              UIPercentDrivenInteractiveTransition *transition) {
    Class native = objc_getClass("_TtC6Apollo26ApolloNavigationController");
    if (!native || navigation.class != native) return NO;
    Ivar slot = class_getInstanceVariable(native, "interactionController");
    Ivar previous = class_getInstanceVariable(native, "poppedViewControllers");
    if (!slot || !previous || ivar_getOffset(slot) - ivar_getOffset(previous) != sizeof(void *)) return NO;
    ApolloSwiftAssignInteractiveTransition((uint8_t *)(__bridge void *)navigation + ivar_getOffset(slot),
                                           (__bridge const void *)transition);
    return YES;
}

@interface ApolloDuoBackSwipe : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UINavigationController *navigation;
@property(nonatomic, strong) UIPanGestureRecognizer *pan;
// Set while this pan is the finger behind an interactive pop.
@property(nonatomic, strong) UIPercentDrivenInteractiveTransition *transition;
@end

@implementation ApolloDuoBackSwipe
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    return gesture == self.pan
        && ApolloDuoBackSwipeAcceptsPoint(self.navigation, [touch locationInView:self.navigation.view]);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture != self.pan || !ApolloDuoBackSwipeCanNavigate(self.navigation)) return NO;
    CGPoint velocity = [self.pan velocityInView:self.navigation.view];
    return velocity.x > 0.0 && fabs(velocity.x) > fabs(velocity.y);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    // At the narrow edge strip, give Back priority over row actions and
    // scrolling; away from that strip shouldReceiveTouch: rejects this
    // recognizer outright, so nothing else waits on it. A vertical drag fails
    // it as soon as it moves, and the list scrolls from there. Another pane's
    // Back pan must not wait on this one while this one waits on it.
    return gesture == self.pan && [other isKindOfClass:UIPanGestureRecognizer.class]
        && ![other.delegate isKindOfClass:ApolloDuoBackSwipe.class];
}
- (void)panned:(UIPanGestureRecognizer *)gesture {
    UINavigationController *navigation = self.navigation;
    UIView *view = navigation.view;
    CGFloat width = MAX(1.0, CGRectGetWidth(view.bounds));
    CGFloat progress = MIN(1.0, MAX(0.0, [gesture translationInView:view].x / width));
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            if (!ApolloDuoBackSwipeCanNavigate(navigation)) return;
            if (navigation.viewControllers.count == 1) {
                ApolloLog(@"[DuoSwipe] feed root: reveal subreddit drawer");
                ApolloDuoSplitRevealPostsList(navigation);
                return;
            }
            BOOL animated = !UIAccessibilityIsReduceMotionEnabled();
            UIPercentDrivenInteractiveTransition *transition = [UIPercentDrivenInteractiveTransition new];
            transition.completionCurve = UIViewAnimationCurveEaseOut;
            BOOL interactive = animated && ApolloDuoSetInteractiveTransition(navigation, transition);
            [navigation popViewControllerAnimated:animated];
            // The split replaces some pops with its own column animation (closing a
            // thread beside its feed); those have already run in full.
            if (interactive && navigation.transitionCoordinator.isInteractive) {
                self.transition = transition;
                [transition updateInteractiveTransition:progress];
            } else if (interactive) {
                ApolloDuoSetInteractiveTransition(navigation, nil);
            }
            ApolloLog(@"[DuoSwipe] Back in pane; stack pages=%lu interactive=%d",
                      (unsigned long)navigation.viewControllers.count, self.transition != nil);
            return;
        }
        case UIGestureRecognizerStateChanged:
            [self.transition updateInteractiveTransition:progress];
            return;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            UIPercentDrivenInteractiveTransition *transition = self.transition;
            if (!transition) return;
            self.transition = nil;
            // A flick commits from anywhere; a slower release commits past a
            // third of the way unless the finger was heading back.
            CGFloat velocity = [gesture velocityInView:view].x;
            BOOL commit = gesture.state == UIGestureRecognizerStateEnded
                && (velocity >= 500.0 || (progress >= 0.35 && velocity > -250.0));
            if (commit) [transition finishInteractiveTransition];
            else [transition cancelInteractiveTransition];
            ApolloDuoSetInteractiveTransition(navigation, nil);
            ApolloLog(@"[DuoSwipe] Back %@ at %.0f%% (velocity %.0f)",
                      commit ? @"committed" : @"cancelled", progress * 100.0, velocity);
            return;
        }
        default:
            return;
    }
}
@end

static char kApolloDuoBackSwipe;
BOOL ApolloDuoHasBackSwipe(UINavigationController *navigation) {
    return objc_getAssociatedObject(navigation, &kApolloDuoBackSwipe) != nil;
}

void ApolloDuoInstallBackSwipe(UINavigationController *navigation) {
    if (!ApolloDeviceIsDuo() || !navigation.isViewLoaded || ApolloDuoHasBackSwipe(navigation)) return;
    ApolloDuoBackSwipe *owner = [ApolloDuoBackSwipe new];
    owner.navigation = navigation;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:owner action:@selector(panned:)];
    pan.maximumNumberOfTouches = 1;
    pan.delegate = owner;
    pan.name = @"ApolloReborn.Duo.PaneBack";
    owner.pan = pan;
    objc_setAssociatedObject(navigation, &kApolloDuoBackSwipe, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [navigation.view addGestureRecognizer:pan];
}
