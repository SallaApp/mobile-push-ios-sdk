// docs/REFERENCE.md "Objective-C": the Notification Service Extension in Objective-C.
@import SallaPushExtension;
@import UserNotifications;

// snippet:objc-notification-service
@interface NotificationService : UNNotificationServiceExtension
@end

@implementation NotificationService {
    SallaPushServiceExtension *_sallaPushService;
}

- (void)didReceiveNotificationRequest:(UNNotificationRequest *)request
                   withContentHandler:(void (^)(UNNotificationContent *))contentHandler {
    if ([SallaPushServiceExtension isSallaPushNotification:request]) {
        _sallaPushService = [[SallaPushServiceExtension alloc] init];
        [_sallaPushService didReceive:request withContentHandler:contentHandler];
    } else {
        contentHandler(request.content);
    }
}

- (void)serviceExtensionTimeWillExpire {
    [_sallaPushService serviceExtensionTimeWillExpire];
}

@end
// end-snippet
