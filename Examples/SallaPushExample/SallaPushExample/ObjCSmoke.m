// Compile-time check of the Objective-C surface of SallaPush and SallaPushCore: every @objc selector is called here,
// once with real arguments and once with nil for each object parameter (SallaPush ignores those with a warning).
// The app never calls this class; building the example is the test.
@import SallaPush;
@import UIKit;
@import UserNotifications;

@interface SallaPushObjCSmoke : NSObject <SallaPushUserObserver, SallaPushSubscriptionObserver,
                                          SallaPushPermissionObserver, SallaPushClickListener,
                                          SallaPushForegroundLifecycleListener>
@end

@implementation SallaPushObjCSmoke

#pragma mark - Lifecycle, consent and identity

+ (void)startWithLaunchOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    [SallaPush initialize:@"00000000-0000-4000-8000-000000000001" withLaunchOptions:launchOptions];

    SallaPushConfiguration *configuration = [[SallaPushConfiguration alloc] init];
    configuration.appGroupIdentifier = @"group.com.salla.push.example";
    configuration.logLevel = SallaPushLogLevelInfo;
    configuration.apnsEnvironment = SallaPushAPNsEnvironmentAutomatic;
    configuration.appVersion = @"1.0";
    configuration.autoClearBadge = YES;
    configuration.autoUpdateBadge = YES;
    configuration.clearTagsOnLogout = YES;
    configuration.registerForRemoteNotificationsOnInit = YES;
    configuration.openLaunchURLs = NO;
    configuration.requiresUserConsent = NO;
    SallaPushConfiguration *copied = [[configuration copyWithZone:nil] copy];
    (void)copied.appGroupIdentifier;
    (void)copied.logLevel;
    switch (copied.apnsEnvironment) {
        case SallaPushAPNsEnvironmentAutomatic:
        case SallaPushAPNsEnvironmentSandbox:
        case SallaPushAPNsEnvironmentProduction:
            break;
    }
    (void)copied.appVersion;
    (void)copied.autoClearBadge;
    (void)copied.autoUpdateBadge;
    (void)copied.clearTagsOnLogout;
    (void)copied.registerForRemoteNotificationsOnInit;
    (void)copied.openLaunchURLs;
    (void)copied.requiresUserConsent;
    [SallaPush initialize:@"00000000-0000-4000-8000-000000000001" withLaunchOptions:launchOptions configuration:copied];

    (void)SallaPush.isInitialized;
    (void)SallaPush.sdkVersion;
    (void)SallaPush.appId;

    [SallaPush setConsentRequired:YES];
    [SallaPush setConsentGiven:YES];

    [SallaPush loginWithExternalId:@"42" identityToken:@"identity-token"];
    [SallaPush logout];
}

#pragma mark - User, tags and subscription

- (void)useUserAndSubscription {
    SallaPushUser *user = SallaPush.User;
    (void)user.externalId;
    (void)user.isLoggedIn;
    [user addTagWithKey:@"add_to_cart" value:@"1790000000000"];
    [user addTags:@{@"last_purchase": @"1790000000000", @"total_cart_amount": @"250"}];
    [user removeTag:@"add_to_cart"];
    [user removeTags:@[@"last_purchase", @"total_cart_amount"]];
    NSDictionary<NSString *, NSString *> *tags = [user getTags];
    (void)tags.count;
    [user setLanguage:@"ar"];
    [user setLanguage:nil];
    [user addObserver:self];
    [user removeObserver:self];

    SallaPushSubscription *subscription = user.pushSubscription;
    (void)subscription.id;
    (void)subscription.token;
    (void)subscription.optedIn;
    [subscription optIn];
    [subscription optOut];
    [subscription addObserver:self];
    [subscription removeObserver:self];
}

#pragma mark - Notifications

- (void)useNotifications {
    SallaPushNotifications *notifications = SallaPush.Notifications;
    (void)notifications.permission;
    (void)notifications.permissionStatus;
    (void)notifications.canRequestPermission;
    [notifications requestPermissionWithFallbackToSettings:YES completion:^(BOOL granted) {
        (void)granted;
    }];
    [notifications requestPermissionWithFallbackToSettings:NO completion:nil];
    [notifications registerForProvisionalAuthorizationWithCompletion:^(BOOL granted) {
        (void)granted;
    }];
    [notifications refreshPermission];
    [notifications addPermissionObserver:self];
    [notifications removePermissionObserver:self];
    [notifications registerForRemoteNotifications];
    [notifications addClickListener:self];
    [notifications removeClickListener:self];
    [notifications addForegroundLifecycleListener:self];
    [notifications removeForegroundLifecycleListener:self];
    [notifications clearAll];
}

- (void)forwardDeviceToken:(NSData *)deviceToken error:(NSError *)error {
    [SallaPush.Notifications didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];
    [SallaPush.Notifications didFailToRegisterForRemoteNotificationsWithError:error];
}

- (void)forwardNotification:(UNNotification *)notification response:(UNNotificationResponse *)response {
    SallaPushNotifications *notifications = SallaPush.Notifications;
    UNNotificationPresentationOptions options = UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList;
    BOOL presentedBySallaPush = [notifications willPresentNotification:notification presentationOptions:&options];
    BOOL openedBySallaPush = [notifications didReceiveNotificationResponse:response];
    NSDictionary *userInfo = notification.request.content.userInfo;
    BOOL received = [notifications didReceiveRemoteNotification:userInfo];
    BOOL isSallaPush = [notifications isSallaPushNotification:userInfo];
    (void)presentedBySallaPush;
    (void)openedBySallaPush;
    (void)received;
    (void)isSallaPush;

    SallaPushNotification *parsed = [notifications parse:userInfo];
    [self readNotification:parsed];

    SallaPushNotificationCenterDelegate *delegate = notifications.notificationCenterDelegate;
    SallaPushNotificationCenterDelegate *ownDelegate = [[SallaPushNotificationCenterDelegate alloc] init];
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [delegate userNotificationCenter:center willPresentNotification:notification
               withCompletionHandler:^(UNNotificationPresentationOptions presentationOptions) {
        (void)presentationOptions;
    }];
    [ownDelegate userNotificationCenter:center didReceiveNotificationResponse:response withCompletionHandler:^{
    }];
}

- (void)readNotification:(SallaPushNotification *)notification {
    (void)notification.notificationId;
    (void)notification.title;
    (void)notification.subtitle;
    (void)notification.body;
    (void)notification.imageURL;
    (void)notification.launchURL;
    (void)notification.additionalData;
    (void)notification.badge;
    (void)notification.sound;
    (void)notification.threadId;
    (void)notification.rawPayload;
    (void)[notification stringForKey:@"type"];
    (void)[notification numberForKey:@"id"];
    switch (notification.source) {
        case SallaPushPayloadSourceNative:
        case SallaPushPayloadSourceCompat:
            break;
    }
}

#pragma mark - Logging

- (void)useDebug {
    SallaPushDebug *debug = SallaPush.Debug;
    debug.logLevel = SallaPushLogLevelVerbose;
    (void)debug.logLevel;
    [debug setLogHandlerWithLevel:SallaPushLogLevelError handler:^(SallaPushLogEntry *entry) {
        (void)entry.level;
        (void)entry.category;
        (void)entry.code;
        (void)entry.message;
        (void)entry.metadata;
        (void)entry.date;
    }];
    [debug setLogHandlerWithLevel:SallaPushLogLevelWarn handler:nil];
    debug.logLevel = SallaPushLogLevelOff;
    debug.logLevel = SallaPushLogLevelError;
    debug.logLevel = SallaPushLogLevelWarn;
    debug.logLevel = SallaPushLogLevelDebug;
}

#pragma mark - Nil arguments

// Objective-C, React Native and Flutter callers can pass nil where the Swift API takes an object; each call below is
// logged (WARN api.invalid_argument or token.invalid) and ignored.
+ (void)callEveryObjectParameterWithNil {
    NSString *noString = nil;
    NSData *noData = nil;
    NSError *noError = nil;
    NSDictionary *noDictionary = nil;
    NSArray *noArray = nil;
    SallaPushConfiguration *noConfiguration = nil;
    UNNotification *noNotification = nil;
    UNNotificationResponse *noResponse = nil;
    id<SallaPushUserObserver> noUserObserver = nil;
    id<SallaPushSubscriptionObserver> noSubscriptionObserver = nil;
    id<SallaPushPermissionObserver> noPermissionObserver = nil;
    id<SallaPushClickListener> noClickListener = nil;
    id<SallaPushForegroundLifecycleListener> noForegroundListener = nil;

    [SallaPush initialize:noString withLaunchOptions:nil];
    [SallaPush initialize:noString withLaunchOptions:nil configuration:noConfiguration];
    [SallaPush loginWithExternalId:noString identityToken:noString];

    [SallaPush.User addTagWithKey:noString value:noString];
    [SallaPush.User addTags:noDictionary];
    [SallaPush.User removeTag:noString];
    [SallaPush.User removeTags:noArray];
    [SallaPush.User addObserver:noUserObserver];
    [SallaPush.User removeObserver:noUserObserver];
    [SallaPush.User.pushSubscription addObserver:noSubscriptionObserver];
    [SallaPush.User.pushSubscription removeObserver:noSubscriptionObserver];

    SallaPushNotifications *notifications = SallaPush.Notifications;
    [notifications addPermissionObserver:noPermissionObserver];
    [notifications removePermissionObserver:noPermissionObserver];
    [notifications didRegisterForRemoteNotificationsWithDeviceToken:noData];
    [notifications didFailToRegisterForRemoteNotificationsWithError:noError];
    (void)[notifications willPresentNotification:noNotification presentationOptions:NULL];
    [notifications didReceiveNotificationResponse:noResponse];
    [notifications didReceiveRemoteNotification:noDictionary];
    (void)[notifications isSallaPushNotification:noDictionary];
    (void)[notifications parse:noDictionary];
    [notifications addClickListener:noClickListener];
    [notifications removeClickListener:noClickListener];
    [notifications addForegroundLifecycleListener:noForegroundListener];
    [notifications removeForegroundLifecycleListener:noForegroundListener];
}

#pragma mark - Observers and listeners

- (void)onUserStateDidChangeWithState:(SallaPushUserChangedState *)state {
    (void)state.previous.externalId;
    (void)state.current.isLoggedIn;
}

- (void)onLoginFailure:(SallaPushLoginFailure)failure {
    switch (failure) {
        case SallaPushLoginFailureTokenRejected:
        case SallaPushLoginFailureInvalidRequest:
            break;
    }
}

- (void)onPushSubscriptionDidChangeWithState:(SallaPushSubscriptionChangedState *)state {
    (void)state.previous.id;
    (void)state.current.token;
    (void)state.current.optedIn;
}

- (void)onNotificationPermissionDidChange:(BOOL)permission {
    (void)permission;
}

- (void)onClickWithEvent:(SallaPushClickEvent *)event {
    (void)event.result.actionId;
    (void)event.result.url;
    [self readNotification:event.notification];
}

- (void)onWillDisplayWithEvent:(SallaPushWillDisplayEvent *)event {
    [event preventDefault];
    if (event.isPrevented) {
        [event.notification display];
    }
}

@end
