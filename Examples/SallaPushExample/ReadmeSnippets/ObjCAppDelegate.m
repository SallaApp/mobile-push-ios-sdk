// docs/REFERENCE.md "Objective-C": the quick start's app delegate in an Objective-C app.
@import SallaPush;
@import UIKit;
@import UserNotifications;

@interface ObjCAppDelegate : UIResponder <UIApplicationDelegate, UNUserNotificationCenterDelegate>
@end

@implementation ObjCAppDelegate

// snippet:objc-app-delegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [SallaPush initialize:@"00000000-0000-4000-8000-000000000001" withLaunchOptions:launchOptions];
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    return YES;
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    [SallaPush.Notifications didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    [SallaPush.Notifications didFailToRegisterForRemoteNotificationsWithError:error];
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
    fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    [SallaPush.Notifications didReceiveRemoteNotification:userInfo];
    completionHandler(UIBackgroundFetchResultNoData);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    UNNotificationPresentationOptions options = UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList
        | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionBadge;
    // YES for a SallaPush notification, with options set to SallaPush's choice; NO leaves your options as they are.
    (void)[SallaPush.Notifications willPresentNotification:notification presentationOptions:&options];
    completionHandler(options);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler {
    [SallaPush.Notifications didReceiveNotificationResponse:response];
    completionHandler();
}
// end-snippet

@end
