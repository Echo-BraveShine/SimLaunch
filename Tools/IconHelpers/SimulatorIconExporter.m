#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

// Runs inside the selected simulator so UIKit can decode that runtime's Assets.car.
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSString *identifier = [NSString stringWithUTF8String:argv[1]];
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[2]]];
        if (!bundle || ![bundle.bundleIdentifier isEqualToString:identifier]) return 3;
        if (!bundle.infoDictionary[@"CFBundleIcons"] && !bundle.infoDictionary[@"CFBundleIcons~ipad"] && !bundle.infoDictionary[@"CFBundleIconFile"] && !bundle.infoDictionary[@"CFBundleIconFiles"]) {
            fprintf(stderr, "SIMLAUNCH_ERROR:No declared application icon\n"); return 4;
        }
        UIImage *image = nil;
        // Runtime-guarded compatibility adapter; never link private simulator frameworks on the Mac.
        SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        if ([UIImage respondsToSelector:selector]) {
            image = ((id (*)(id, SEL, id, int, CGFloat))objc_msgSend)(UIImage.class, selector, identifier, 10, 2.0);
        }
        if (!image) {
            NSDictionary *icons = bundle.infoDictionary[@"CFBundleIcons"] ?: bundle.infoDictionary[@"CFBundleIcons~ipad"];
            NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
            NSMutableArray *names = [NSMutableArray array];
            if ([primary[@"CFBundleIconName"] isKindOfClass:NSString.class]) [names addObject:primary[@"CFBundleIconName"]];
            if ([primary[@"CFBundleIconFiles"] isKindOfClass:NSArray.class]) [names addObjectsFromArray:primary[@"CFBundleIconFiles"]];
            if ([bundle.infoDictionary[@"CFBundleIconFiles"] isKindOfClass:NSArray.class]) [names addObjectsFromArray:bundle.infoDictionary[@"CFBundleIconFiles"]];
            [names addObjectsFromArray:@[@"AppIcon", @"Icon"]];
            for (NSString *name in names) {
                if (![name isKindOfClass:NSString.class]) continue;
                image = [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil];
                if (image) break;
            }
        }
        if (!image) { fprintf(stderr, "SIMLAUNCH_ERROR:Simulator runtime did not expose the icon\n"); return 4; }
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = 1; format.opaque = NO;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(128, 128) format:format];
        NSData *png = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *ctx) { [image drawInRect:CGRectMake(0, 0, 128, 128)]; }];
        if (!png) return 5;
        printf("SIMLAUNCH_ICON:%s\n", [[png base64EncodedStringWithOptions:0] UTF8String]);
    }
    return 0;
}
