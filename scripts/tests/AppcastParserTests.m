// Tesserae: a disk-space visualizer.
// Copyright (C) 2026 Stephen de la Vega
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.


#import <Foundation/Foundation.h>

// Exercise the pinned client's private XML initializer without networking.
@interface NSObject (AppcastParserTest)
- (id)initWithXMLData:(NSData *)data relativeToURL:(NSURL *)url stateResolver:(id)resolver
    signingValidationStatus:(NSUInteger)status error:(NSError **)error;
- (NSArray *)items;
- (NSDictionary *)deltaUpdates;
- (NSURL *)fileURL;
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2 || ![[NSBundle bundleWithPath:@(argv[1])] load]) return 1;
        NSString *xml = @"<rss xmlns:sparkle='http://www.andymatuschak.org/xml-namespaces/sparkle'><channel><item>"
            "<sparkle:version>100</sparkle:version><enclosure url='https://example.invalid/current.dmg' length='1'/>"
            "<sparkle:deltas xmlns:sparkle='urn:unverified'><enclosure xmlns='urn:unverified' "
            "url='https://example.invalid/unverified.delta' length='1' sparkle:deltaFrom='99' sparkle:edSignature='INVALID'/>"
            "</sparkle:deltas></item></channel></rss>";
        NSError *error = nil;
        id feed = [[NSClassFromString(@"SUAppcast") alloc] initWithXMLData:[xml dataUsingEncoding:NSUTF8StringEncoding]
            relativeToURL:nil stateResolver:nil signingValidationStatus:0 error:&error];
        if (error || feed == nil || [feed items].count != 1) return 2;
        id delta = [[feed items][0] deltaUpdates][@"99"];
        if (![[[delta fileURL] absoluteString] isEqualToString:@"https://example.invalid/unverified.delta"]) return 3;
        return 0;
    }
}
