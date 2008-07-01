//
//  Controller.h
//  FVIBPluginTest
//
//  Created by Adam Maxwell on 6/30/08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <FileView/FileView.h>

@interface Controller : NSObject {
    IBOutlet FileView          *_fileView;
    IBOutlet NSArrayController *_arrayController;
    NSMutableArray             *_iconURLs;
}

@end
